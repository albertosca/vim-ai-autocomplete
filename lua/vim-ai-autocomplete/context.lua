local M = {}

-- The CURRENT line (the one the cursor is really on) should never go in whole
-- into either "before" or "after" -- it has to be split at the cursor column.
-- Same finding as on the Vim side (2026-07-20): without this the model has no
-- idea where the cursor actually sits inside the line.
function M.split_lines_at_cursor(lines_before_full, current_line, col, lines_after_full)
  local before_part = col > 1 and current_line:sub(1, col - 1) or ''
  local after_part = current_line:sub(col)
  local before = vim.deepcopy(lines_before_full)
  table.insert(before, before_part)
  local after = { after_part }
  vim.list_extend(after, lines_after_full)
  return before, after
end

-- strcharpart/strchars (not string:sub) so the cut happens per CHARACTER, not
-- per byte -- multibyte-safe, same criterion as the Vim side.
function M.build_context(lines_before, lines_after, max_chars)
  local before = table.concat(lines_before, '\n')
  local after = table.concat(lines_after, '\n')
  local total = #before + #after
  if total > max_chars then
    -- more weight to the text BEFORE the cursor (75/25) -- same criterion as
    -- the Vim side (and as the context_ratio of the minuet-ai.nvim this
    -- plugin replaces).
    local before_budget = math.floor(max_chars * 0.75)
    local after_budget = max_chars - before_budget
    before = vim.fn.strcharpart(before, math.max(0, vim.fn.strchars(before) - before_budget))
    after = vim.fn.strcharpart(after, 0, after_budget)
  end
  return { before = before, after = after }
end

-- Node type names that count as a "scope" worth prioritising as context --
-- covers the most common cases across the Treesitter grammars used in this
-- setup (Python, JS/TS, Ruby, Go, Elixir). The list is deliberately small: a
-- language missing from it simply falls back (never an error).
--
-- Each name was verified against the real grammar, not assumed -- the list
-- originally claimed Ruby/Elixir coverage with node names that never existed
-- in those grammars (tree-sitter-ruby uses `method`/`class`, not
-- `method_definition`/`class_definition`), so both silently always fell back
-- to the naive line cut.
local SCOPE_NODE_TYPES = {
  function_definition = true,
  function_declaration = true,
  method_definition = true,
  class_definition = true,
  class_declaration = true,
  arrow_function = true,
  method = true, -- Ruby
  class = true, -- Ruby
  module = false, -- never use the whole file as a "scope"
}

-- Elixir has no function_definition node at all: def/defp/defmodule parse as
-- a generic `call` node whose FIRST CHILD is the def/defp/defmodule
-- identifier (verified live: `binary_operator <- do_block <- call <- ...`).
-- A plain call like Enum.map(...) must NOT count as a scope, hence the
-- first-child check instead of accepting every `call`.
local ELIXIR_DEF_CALLS = { def = true, defp = true, defmodule = true }

local function is_scope_node(node, bufnr)
  local node_type = node:type()
  if SCOPE_NODE_TYPES[node_type] then
    return true
  end
  if node_type == 'call' then
    local first_child = node:child(0)
    if first_child and first_child:type() == 'identifier' then
      local ok, text = pcall(vim.treesitter.get_node_text, first_child, bufnr)
      return ok and ELIXIR_DEF_CALLS[text] or false
    end
  end
  return false
end

-- Instead of blindly cutting ~100 lines before the cursor, find the
-- function/class node containing the cursor through Treesitter and use the
-- first line of THAT scope as the "before" cut. Always with a fallback: no
-- parser available for the filetype, or no scope found, returns nil (the
-- caller falls back to the usual line-based cut).
function M.treesitter_scope_start_line(bufnr, lnum, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  -- Make sure the tree is parsed before querying the node: in a freshly
  -- loaded (or headless) buffer Treesitter has not run yet and get_node would
  -- return nil -- falling back even though a parser was available. parse() is
  -- incremental (cheap) and makes the scope reliable.
  pcall(function() parser:parse() end)
  local ok2, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { lnum - 1, math.max(0, col - 1) } })
  if not ok2 or not node then
    return nil
  end
  local scope = node
  while scope and not is_scope_node(scope, bufnr) do
    scope = scope:parent()
  end
  if not scope then
    return nil
  end
  local start_row = scope:start()
  return start_row + 1
end

local function collect_identifier_nodes(node, bufnr, limit)
  local result = {}
  local seen = {}
  local function walk(n)
    if #result >= limit then
      return
    end
    if n:type() == 'identifier' then
      local text = vim.treesitter.get_node_text(n, bufnr)
      if not seen[text] then
        seen[text] = true
        table.insert(result, n)
      end
    end
    for child in n:iter_children() do
      if #result >= limit then
        return
      end
      walk(child)
    end
  end
  walk(node)
  return result
end

-- Fires textDocument/definition for the identifiers in the current scope,
-- with a short timeout -- if the LSP does not answer in time, or there is no
-- client attached to the buffer, returns an empty list without blocking the
-- completion. Capped at 5 unique identifiers to keep the cost predictable
-- within the timeout.
function M.lsp_related_definitions(bufnr, scope_node, timeout_ms)
  if not scope_node then
    return {}
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return {}
  end
  local identifiers = collect_identifier_nodes(scope_node, bufnr, 5)
  if #identifiers == 0 then
    return {}
  end

  local pending = 0
  local results = {}
  for _, node in ipairs(identifiers) do
    local row, col = node:start()
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = row, character = col },
    }
    pending = pending + 1
    vim.lsp.buf_request(bufnr, 'textDocument/definition', params, function(err, resp)
      pending = pending - 1
      if not err and resp and resp[1] then
        table.insert(results, resp[1])
      end
    end)
  end

  vim.wait(timeout_ms, function() return pending == 0 end, 10)
  return results
end

local function slice_lines(lines, first, last)
  local out = {}
  for i = first, last do
    table.insert(out, lines[i])
  end
  return out
end

-- Builds the extra prompt section with a small excerpt of each definition
-- found. Reads the file from disk (it does not need to be open in a buffer)
-- -- if the read fails (remote file, permissions), that definition is skipped
-- silently, never breaking the whole prompt.
function M.build_related_definitions_section(definitions, max_lines_per_def)
  if #definitions == 0 then
    return ''
  end
  local parts = {}
  for _, def in ipairs(definitions) do
    local uri = def.uri or def.targetUri
    local range = def.range or def.targetRange
    if uri and range then
      local path = vim.uri_to_fname(uri)
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok then
        local start_line = range.start.line + 1
        local last_line = math.min(#lines, start_line + max_lines_per_def - 1)
        if start_line <= last_line then
          table.insert(parts, table.concat(slice_lines(lines, start_line, last_line), '\n'))
        end
      end
    end
  end
  if #parts == 0 then
    return ''
  end
  return '\n\nRELATED DEFINITIONS:\n' .. table.concat(parts, '\n---\n')
end

return M
