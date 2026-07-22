local models = require('vim-ai-autocomplete.models')
local family = require('vim-ai-autocomplete.family')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

local M = {}

local tab_fallback = { rhs = '\t', is_expr = false, callback = nil }
local esc_fallback = { rhs = '\27', is_expr = false, callback = nil } -- \27 = <Esc>

-- Mapeamentos baseados em callback Lua (ex: blink.cmp, "pula pro proximo
-- placeholder do snippet ou cai pro Tab normal") nao tem 'rhs' classico --
-- get() com default cobre os dois formatos, mesmo fallback do lado Vim.
function M.setup_tab_wrap()
  local original = vim.fn.maparg('<Tab>', 'i', false, true)
  if original and original.lhs then
    tab_fallback.rhs = original.rhs or '\t'
    tab_fallback.is_expr = original.expr == 1
    tab_fallback.callback = original.callback
  end
  vim.keymap.set('i', '<Tab>', M.tab_handler, { expr = true, silent = true })
end

function M.tab_handler()
  if ghost_text.is_visible() then
    return ghost_text.accept()
  end
  if tab_fallback.callback then
    local result = tab_fallback.callback()
    return tab_fallback.is_expr and result or ''
  end
  if tab_fallback.is_expr then
    return vim.api.nvim_eval(tab_fallback.rhs)
  end
  return tab_fallback.rhs
end

function M.setup_esc_wrap()
  local original = vim.fn.maparg('<Esc>', 'i', false, true)
  if original and original.lhs then
    esc_fallback.rhs = original.rhs or '\27'
    esc_fallback.is_expr = original.expr == 1
    esc_fallback.callback = original.callback
  end
  vim.keymap.set('i', '<Esc>', M.esc_handler, { expr = true, silent = true })
end

function M.esc_handler()
  if ghost_text.is_visible() then
    ghost_text.clear_suggestion()
    return ''
  end
  if esc_fallback.callback then
    local result = esc_fallback.callback()
    return esc_fallback.is_expr and result or ''
  end
  if esc_fallback.is_expr then
    return vim.api.nvim_eval(esc_fallback.rhs)
  end
  return esc_fallback.rhs
end

function M.toggle_auto_trigger()
  local current = vim.g.vim_ai_autocomplete_auto_trigger
  if current == nil then
    current = 1
  end
  local new_value = (current ~= 0) and 0 or 1
  vim.g.vim_ai_autocomplete_auto_trigger = new_value
  vim.notify('vim-ai-autocomplete: auto-trigger ' .. (new_value == 1 and 'ligado' or 'desligado'))
end

-- Generaliza a checagem de key -- dispara uma chamada leve pro modelo pra
-- qual acabou de trocar; se der erro, so AVISA -- nao reverte mais pro
-- modelo anterior (antes revertia automaticamente; mudanca pedida pelo
-- Alberto 2026-07-22: "quero que a pessoa possa ciclar a vontade", ex:
-- ,pr repetido pra tentar os modelos seguintes mesmo depois de um aviso de
-- credito, sem ficar precisando trocar de volta manualmente).
function M.on_model_key_check_exit(checked_name, chunks)
  local message = family.extract_api_error_message(table.concat(chunks, ''))
  if not message then
    return
  end
  vim.notify(string.format('vim-ai-autocomplete (%s): %s', checked_name, message), vim.log.levels.WARN)
end

function M.check_model_key(name)
  local model = models.find_model_by_name(models.active_models(), name)
  if not model then
    return
  end
  local api_key = vim.fn.getenv(model.api_key_env)
  local handler = family.family_handler(model.family)
  local cmd = handler.build_command({ before = 'hi', after = '' }, model.model_id, api_key)
  local chunks = {}
  vim.system(cmd, { text = true }, function(result)
    if result.stdout then
      table.insert(chunks, result.stdout)
    end
    vim.schedule(function()
      M.on_model_key_check_exit(name, chunks)
    end)
  end)
end

function M.select_model(name)
  local active = models.active_models()
  local model = models.find_model_by_name(active, name)
  if not model then
    vim.notify('vim-ai-autocomplete: modelo "' .. name .. '" nao existe ou nao esta ativo (sem API key)', vim.log.levels.ERROR)
    return
  end
  vim.g.vim_ai_autocomplete_provider = name
  vim.notify('vim-ai-autocomplete: provider agora e ' .. name)
  M.check_model_key(name)
end

function M.toggle_provider()
  local active = models.active_models()
  local names = {}
  for _, m in ipairs(active) do
    table.insert(names, m.name)
  end
  local idx = 0
  for i, n in ipairs(names) do
    if n == vim.g.vim_ai_autocomplete_provider then
      idx = i
    end
  end
  local next_idx = (idx % #names) + 1
  vim.g.vim_ai_autocomplete_provider = names[next_idx]
  vim.notify('vim-ai-autocomplete: provider agora e ' .. vim.g.vim_ai_autocomplete_provider)
  M.check_model_key(vim.g.vim_ai_autocomplete_provider)
end

function M.complete_model_names(arglead)
  local active = models.active_models()
  local result = {}
  for _, m in ipairs(active) do
    if m.name:sub(1, #arglead) == arglead then
      table.insert(result, m.name)
    end
  end
  return result
end

-- active_models: lista JA FILTRADA (ver models.active_models()) -- so
-- registra ,pr e :VimAiAutocompleteModel com 2+ modelos ativos, mesma
-- regra do lado Vim. <leader>pr, nao <leader>ap/<leader>pv -- mesmas
-- colisoes ja documentadas do lado Vim/minuet.
function M.setup_provider_toggle(active_models)
  if #active_models >= 2 then
    vim.keymap.set('n', '<leader>pr', M.toggle_provider, { silent = true, desc = 'vim-ai-autocomplete: toggle provider' })
    vim.api.nvim_create_user_command('VimAiAutocompleteModel', function(opts)
      M.select_model(opts.args)
    end, {
      nargs = 1,
      complete = function(arglead) return M.complete_model_names(arglead) end,
    })
  end
end

-- Extra exclusivo do Neovim: seleciona o modelo via vim.ui.select em vez de
-- digitar :VimAiAutocompleteModel <nome> de cor. Funciona com Telescope
-- automaticamente se instalado (Telescope substitui o handler global de
-- vim.ui.select) -- nao precisamos detectar Telescope, e assim que
-- vim.ui.select ja funciona por design.
function M.open_model_picker()
  local active = models.active_models()
  local names = {}
  for _, m in ipairs(active) do
    table.insert(names, m.name)
  end
  vim.ui.select(names, { prompt = 'vim-ai-autocomplete: escolha o modelo' }, function(choice)
    if choice then
      M.select_model(choice)
    end
  end)
end

return M
