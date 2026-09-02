local M = {}

local ns = vim.api.nvim_create_namespace('vim_ai_autocomplete')
local HL_GROUP = 'VimAiAutocompleteRedundant'
-- issue #4: the in-flight marker has a namespace of its own, so clearing a
-- suggestion never touches it and vice versa.
local pending_ns = vim.api.nvim_create_namespace('vim_ai_autocomplete_pending')
local PENDING_MARKER = '…'

local state = {
  suggestion = {},
  lnum = 0,
  col = 0,
  redundant_after = 0,
  -- issue #3: the alternatives being cycled through -- a list of
  -- {lines, redundant_after} entries -- and which one is on screen.
  alternatives = {},
  alt_index = 0,
  -- issue #4: whether the in-flight marker is on screen, where it was put,
  -- and a token that lets clear_pending() cancel a scheduled show.
  pending = false,
  pending_bufnr = 0,
  pending_token = 0,
}

-- A highlight of its OWN for the real redundant character -- red plus
-- strikethrough, not the ghost text style (same finding as on the Vim side:
-- reusing the ghost text highlight for what is about to be REMOVED was
-- misleading).
local function ensure_redundant_highlight()
  if vim.fn.hlexists(HL_GROUP) == 0 then
    vim.api.nvim_set_hl(0, HL_GROUP, { strikethrough = true, ctermfg = 167, fg = '#fb4934', default = true })
  end
end

-- redundant_after (optional, defaults to 0): how many characters from the
-- START of the real text AFTER the cursor must be DISCARDED on accept.
function M.show_suggestion(lines, redundant_after)
  M.clear_pending()
  M.clear_suggestion()
  if #lines == 0 then
    return
  end
  redundant_after = redundant_after or 0
  local lnum0 = vim.fn.line('.') - 1 -- extmarks are 0-indexed
  local col0 = vim.fn.col('.') - 1

  local virt_lines = {}
  for i = 2, #lines do
    table.insert(virt_lines, { { lines[i], 'Comment' } })
  end
  -- mirror of the Vim-side guard: an empty first line has nothing to render
  -- inline (on Vim an empty-text prop even renders as U+FFFD garbage), so
  -- the extmark only carries virt_text when there is text to show.
  vim.api.nvim_buf_set_extmark(0, ns, lnum0, col0, {
    virt_text = lines[1] ~= '' and { { lines[1], 'Comment' } } or nil,
    virt_text_pos = lines[1] ~= '' and 'inline' or nil,
    virt_lines = #virt_lines > 0 and virt_lines or nil,
  })

  if redundant_after > 0 then
    ensure_redundant_highlight()
    vim.api.nvim_buf_set_extmark(0, ns, lnum0, col0, {
      end_col = col0 + redundant_after,
      hl_group = HL_GROUP,
    })
  end

  state.suggestion = vim.deepcopy(lines)
  state.lnum = vim.fn.line('.')
  state.col = vim.fn.col('.')
  state.redundant_after = redundant_after
end

function M.clear_suggestion()
  if #state.suggestion == 0 then
    return
  end
  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
  state.suggestion = {}
  state.lnum = 0
  state.col = 0
  state.redundant_after = 0
  state.alternatives = {}
  state.alt_index = 0
end

function M.is_visible()
  return #state.suggestion > 0
end

function M.current_suggestion()
  return vim.deepcopy(state.suggestion)
end

function M.suggestion_position()
  return state.lnum, state.col
end

-- issue #3: show a SET of alternatives, starting at the first. Each entry is
-- {lines, redundant_after}; cycling re-renders another entry at the same
-- cursor position. show_suggestion stays the single-suggestion primitive (it
-- clears any alternatives state, so a fresh trigger never leaks stale ones).
function M.show_alternatives(entries)
  if #entries == 0 then
    return
  end
  M.show_suggestion(entries[1].lines, entries[1].redundant_after)
  state.alternatives = vim.deepcopy(entries)
  state.alt_index = 1
end

-- Moves delta (+1/-1) through the known alternatives, wrapping at both ends.
-- Returns the new index, or nil when there is no alternatives state (a plain
-- single suggestion, or nothing visible) -- the caller decides whether that
-- means "fetch one lazily" or "nothing to do".
function M.cycle(delta)
  if #state.alternatives < 1 or state.alt_index == 0 then
    return nil
  end
  local n = #state.alternatives
  local index = ((state.alt_index - 1 + delta) % n) + 1
  local alternatives = state.alternatives
  local entry = alternatives[index]
  M.show_suggestion(entry.lines, entry.redundant_after)
  state.alternatives = alternatives
  state.alt_index = index
  return index
end

-- Appends a lazily fetched entry (the anthropic side of the hybrid) and jumps
-- to it -- the user pressed "next", so the new entry is what they asked for.
function M.append_alternative(entry)
  local alternatives = state.alternatives
  table.insert(alternatives, vim.deepcopy(entry))
  M.show_suggestion(entry.lines, entry.redundant_after)
  state.alternatives = alternatives
  state.alt_index = #alternatives
end

function M.alternatives()
  return vim.deepcopy(state.alternatives)
end

function M.alternatives_count()
  return #state.alternatives
end

function M.alternatives_index()
  return state.alt_index
end

-- issue #4: a transient marker while a request is in flight. Field report:
-- "sometimes I wait a reasonable time and I cannot tell whether the
-- suggestion is coming or not". The API round-trip (1.4-4.5 s) dominates and
-- cannot be shrunk from here, so this is about legibility, not speed.
--
-- End-of-line virtual text, never inline: inline text shifts the real line
-- on every keystroke, which is exactly the flicker the ghost-text work
-- removed. Shown only after a delay (schedule_pending), so a fast answer
-- never flashes anything; cleared on EVERY exit of the request (answer,
-- stale, failure) by the request layer, and by show_suggestion itself.
function M.show_pending()
  M.clear_pending()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_extmark(bufnr, pending_ns, vim.fn.line('.') - 1, 0, {
    virt_text = { { PENDING_MARKER, 'Comment' } },
    virt_text_pos = 'eol',
  })
  state.pending = true
  state.pending_bufnr = bufnr
end

-- Shows the marker only if nothing cancels it within delay_ms -- the token
-- makes a clear_pending() in between (the answer came fast) win the race.
function M.schedule_pending(delay_ms)
  state.pending_token = state.pending_token + 1
  local token = state.pending_token
  vim.defer_fn(function()
    if token == state.pending_token and not state.pending then
      M.show_pending()
    end
  end, delay_ms)
end

function M.clear_pending()
  state.pending_token = state.pending_token + 1
  if state.pending and vim.api.nvim_buf_is_valid(state.pending_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.pending_bufnr, pending_ns, 0, -1)
  end
  state.pending = false
  state.pending_bufnr = 0
end

function M.is_pending()
  return state.pending
end

function M.insert_accepted_lines(lines, lnum, col, redundant_after)
  redundant_after = redundant_after or 0
  local current_line = vim.fn.getline(lnum)
  local before = col > 1 and current_line:sub(1, col - 1) or ''
  local after = current_line:sub(col + redundant_after)
  local new_first_line = before .. lines[1]
  if #lines == 1 then
    vim.fn.setline(lnum, new_first_line .. after)
    vim.fn.cursor(lnum, #new_first_line + 1)
  else
    local middle_lines = {}
    for i = 2, #lines do
      table.insert(middle_lines, lines[i])
    end
    middle_lines[#middle_lines] = middle_lines[#middle_lines] .. after
    vim.fn.setline(lnum, new_first_line)
    vim.fn.append(lnum, middle_lines)
    vim.fn.cursor(lnum + #middle_lines, #middle_lines[#middle_lines] - #after + 1)
  end
end

-- Writes straight into the buffer through setline()/append() instead of
-- "typing" it via a simulated <CR> (same reason as on the Vim side:
-- autoindent would duplicate the indentation the API already sent). Always
-- deferred through vim.schedule() -- simpler and safer than checking whether
-- direct mutation would work inside the <expr> mapping on every Neovim
-- version.
function M.accept()
  local lines = M.current_suggestion()
  local redundant_after = state.redundant_after
  M.clear_suggestion()
  if #lines == 0 then
    return ''
  end
  local lnum = vim.fn.line('.')
  local col = vim.fn.col('.')
  vim.schedule(function()
    M.insert_accepted_lines(lines, lnum, col, redundant_after)
  end)
  return ''
end

return M
