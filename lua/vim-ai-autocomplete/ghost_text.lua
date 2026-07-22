local M = {}

local ns = vim.api.nvim_create_namespace('vim_ai_autocomplete')
local HL_GROUP = 'VimAiAutocompleteRedundant'

local state = {
  suggestion = {},
  lnum = 0,
  col = 0,
  redundant_after = 0,
}

-- Highlight PROPRIO pro caractere real redundante -- vermelho + riscado,
-- nao o mesmo estilo do ghost text (mesmo achado do lado Vim: reusar o
-- highlight do ghost text pro que vai ser REMOVIDO era enganoso).
local function ensure_redundant_highlight()
  if vim.fn.hlexists(HL_GROUP) == 0 then
    vim.api.nvim_set_hl(0, HL_GROUP, { strikethrough = true, ctermfg = 167, fg = '#fb4934', default = true })
  end
end

-- redundant_after (opcional, default 0): quantos caracteres do INICIO do
-- texto real DEPOIS do cursor devem ser DESCARTADOS ao aceitar.
function M.show_suggestion(lines, redundant_after)
  M.clear_suggestion()
  if #lines == 0 then
    return
  end
  redundant_after = redundant_after or 0
  local lnum0 = vim.fn.line('.') - 1 -- extmarks sao 0-indexed
  local col0 = vim.fn.col('.') - 1

  local virt_lines = {}
  for i = 2, #lines do
    table.insert(virt_lines, { { lines[i], 'Comment' } })
  end
  vim.api.nvim_buf_set_extmark(0, ns, lnum0, col0, {
    virt_text = { { lines[1], 'Comment' } },
    virt_text_pos = 'inline',
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

-- Insere direto no buffer via setline()/append() em vez de "digitar" via
-- <CR> simulado (mesmo motivo do lado Vim: autoindent duplicaria a
-- indentacao que a API ja trouxe). Sempre adiada via vim.schedule() --
-- mais simples e mais seguro que testar se a mutacao direta funcionaria
-- dentro do mapeamento <expr> em toda versao do Neovim.
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
