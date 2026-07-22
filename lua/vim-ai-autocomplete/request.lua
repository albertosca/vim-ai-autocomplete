local models = require('vim-ai-autocomplete.models')
local family = require('vim-ai-autocomplete.family')
local context_mod = require('vim-ai-autocomplete.context')
local redundancy = require('vim-ai-autocomplete.redundancy')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

local M = {}

local gen = 0
local last_completion_error = nil

local function warn_completion_failure(provider, status, raw_output)
  local message = family.describe_completion_failure(provider, status, raw_output)
  if not message or message == last_completion_error then
    return
  end
  last_completion_error = message
  vim.notify(message, vim.log.levels.WARN)
end

-- CountRedundantAfterChars PRECISA rodar com a sugestao ORIGINAL, antes de
-- qualquer ajuste (mesmo achado do lado Vim: cortar a sugestao antes
-- corrompe o calculo estrutural). As duas fontes de redundancia --
-- estrutural e sobreposicao textual -- se SOMAM num so redundant_after.
local function on_exit(request_gen, out_chunks, status, provider, parse_response, bufnr, lnum, col, after)
  if request_gen ~= gen then
    return
  end
  -- descarta se o cursor ja se moveu desde que o request foi feito.
  if vim.api.nvim_get_current_buf() ~= bufnr or vim.fn.line('.') ~= lnum or vim.fn.col('.') ~= col then
    return
  end
  local body = table.concat(out_chunks, '')
  local lines = parse_response(body)
  if #lines > 0 then
    last_completion_error = nil
    local current_line = vim.fn.getline(lnum)
    local before_cursor = col > 1 and current_line:sub(1, col - 1) or ''
    local redundant_after = redundancy.count_redundant_after_chars(before_cursor, table.concat(lines, '\n'), after)
    local remaining_after = after:sub(redundant_after + 1)
    redundant_after = redundant_after + redundancy.compute_text_overlap_length(lines, remaining_after)
    -- limita ao que sobra de verdade NESSA linha -- mesmo escopo conhecido
    -- do lado Vim (nao cobre sugestao inteira duplicando varias linhas).
    local current_line_remainder = current_line:sub(col)
    redundant_after = math.min(redundant_after, #current_line_remainder)
    lines = redundancy.adjust_suggestion_lines(lines, before_cursor, vim.bo.filetype, vim.fn.shiftwidth(), vim.bo.expandtab)
    ghost_text.show_suggestion(lines, redundant_after)
  else
    warn_completion_failure(provider, status, body)
  end
end

function M.request_completion()
  local all_models = vim.g.vim_ai_autocomplete_models or models.default_models()
  local active = models.active_models()
  local default_name, level = models.resolve_default_model(all_models, active)
  if level == 'error' then
    return
  end
  local provider_name = vim.g.vim_ai_autocomplete_provider or default_name
  local model = models.find_model_by_name(active, provider_name)
  if not model then
    -- o provider configurado nao esta mais ativo (ex: key removida em
    -- runtime) -- cai pro default resolvido acima.
    model = models.find_model_by_name(active, default_name)
  end
  local handler = family.family_handler(model.family)
  local api_key = vim.fn.getenv(model.api_key_env)

  local cur_lnum = vim.fn.line('.')
  local first = math.max(1, cur_lnum - 100)
  local last = math.min(vim.fn.line('$'), cur_lnum + 20)
  local lines_before_full = vim.fn.getline(first, cur_lnum - 1)
  local lines_after_full = vim.fn.getline(cur_lnum + 1, last)
  local lines_before, lines_after = context_mod.split_lines_at_cursor(
    lines_before_full, vim.fn.getline('.'), vim.fn.col('.'), lines_after_full)
  local context = context_mod.build_context(lines_before, lines_after, 16000)

  local cmd = handler.build_command(context, model.model_id, api_key)

  gen = gen + 1
  local request_gen = gen
  local chunks = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cur_lnum
  local col = vim.fn.col('.')
  local provider = model.name
  local parse_response = handler.parse_response
  local after = context.after

  vim.system(cmd, { text = true }, function(result)
    if result.stdout then
      table.insert(chunks, result.stdout)
    end
    vim.schedule(function()
      on_exit(request_gen, chunks, result.code, provider, parse_response, bufnr, lnum, col, after)
    end)
  end)
end

return M
