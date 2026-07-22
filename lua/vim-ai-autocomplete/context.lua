local M = {}

-- A linha ATUAL (onde o cursor esta de verdade) nunca deveria entrar
-- inteira nem em "antes" nem em "depois" -- precisa ser cortada na coluna
-- do cursor. Mesmo achado do lado Vim (2026-07-20): sem isso, o modelo nao
-- sabe onde o cursor realmente esta dentro da linha.
function M.split_lines_at_cursor(lines_before_full, current_line, col, lines_after_full)
  local before_part = col > 1 and current_line:sub(1, col - 1) or ''
  local after_part = current_line:sub(col)
  local before = vim.deepcopy(lines_before_full)
  table.insert(before, before_part)
  local after = { after_part }
  vim.list_extend(after, lines_after_full)
  return before, after
end

-- strcharpart/strchars (nao string:sub) pra cortar por CARACTERE, nao byte
-- -- multibyte-safe, mesmo criterio do lado Vim.
function M.build_context(lines_before, lines_after, max_chars)
  local before = table.concat(lines_before, '\n')
  local after = table.concat(lines_after, '\n')
  local total = #before + #after
  if total > max_chars then
    -- mais peso pro texto ANTES do cursor (75/25) -- mesmo criterio do
    -- lado Vim (e do context_ratio do minuet-ai.nvim que este plugin
    -- substitui).
    local before_budget = math.floor(max_chars * 0.75)
    local after_budget = max_chars - before_budget
    before = vim.fn.strcharpart(before, math.max(0, vim.fn.strchars(before) - before_budget))
    after = vim.fn.strcharpart(after, 0, after_budget)
  end
  return { before = before, after = after }
end

-- Nomes de tipo de no que contam como "escopo" pra priorizar como contexto
-- -- cobre os casos mais comuns entre as gramaticas Treesitter usadas neste
-- setup (Python, JS/TS, Ruby, Go, Elixir). Lista deliberadamente pequena --
-- linguagem sem tipo aqui simplesmente cai no fallback (nunca erro).
local SCOPE_NODE_TYPES = {
  function_definition = true,
  function_declaration = true,
  method_definition = true,
  class_definition = true,
  class_declaration = true,
  arrow_function = true,
  module = false, -- nunca usar o arquivo inteiro como "escopo"
}

-- Em vez de cortar ~100 linhas antes do cursor as cegas, acha o no de
-- funcao/classe que contem o cursor via Treesitter e usa a primeira linha
-- DESSE escopo como o corte de "antes". Sempre com fallback: sem parser
-- disponivel pra filetype, ou sem escopo encontrado, retorna nil (quem
-- chama cai pro corte por linhas de sempre).
function M.treesitter_scope_start_line(bufnr, lnum, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  -- Garante que a arvore esteja parseada antes de consultar o no: num
  -- buffer recem-carregado (ou headless) o Treesitter ainda nao rodou, e
  -- get_node retornaria nil -- caindo pro fallback mesmo com parser
  -- disponivel. parse() e incremental (barato) e torna o escopo confiavel.
  pcall(function() parser:parse() end)
  local ok2, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { lnum - 1, math.max(0, col - 1) } })
  if not ok2 or not node then
    return nil
  end
  local scope = node
  while scope and not SCOPE_NODE_TYPES[scope:type()] do
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

-- Dispara textDocument/definition pros identificadores do escopo atual,
-- com timeout curto -- se o LSP nao responder a tempo, ou nao houver
-- cliente ativo pro buffer, retorna lista vazia sem bloquear o
-- autocomplete. Limitado a 5 identificadores unicos pra manter o custo
-- previsivel dentro do timeout.
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

-- Monta a secao extra do prompt com um trecho pequeno de cada definicao
-- encontrada. Le o arquivo do disco (nao precisa que esteja aberto num
-- buffer) -- se a leitura falhar (arquivo remoto, permissao), pula essa
-- definicao silenciosamente, nunca quebra o prompt inteiro.
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
  return '\n\nDEFINICOES RELACIONADAS:\n' .. table.concat(parts, '\n---\n')
end

return M
