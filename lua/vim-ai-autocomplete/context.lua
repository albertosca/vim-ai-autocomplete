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

return M
