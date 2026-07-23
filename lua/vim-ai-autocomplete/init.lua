local ghost_text = require('vim-ai-autocomplete.ghost_text')
local request = require('vim-ai-autocomplete.request')
local keymaps = require('vim-ai-autocomplete.keymaps')
local models = require('vim-ai-autocomplete.models')

local M = {}

local timer = nil

local function on_timer()
  timer = nil
  ghost_text.clear_suggestion()
  if vim.fn.mode() ~= 'i' then
    return
  end
  request.request_completion()
end

-- Se o cursor se moveu pra longe de onde a sugestao foi mostrada (ex: setas
-- pra revisar o texto antes de aceitar), ela fica invalida -- aceitar do
-- jeito que esta inseriria o texto errado na posicao errada. Mesmo fix do
-- lado Vim (commit 84a2975). Limpa incondicionalmente, mesmo com
-- auto_trigger desligado -- isso e sobre correcao, nao sobre pedir uma
-- sugestao nova.
function M.trigger()
  if ghost_text.is_visible() then
    local sug_lnum, sug_col = ghost_text.suggestion_position()
    if vim.fn.line('.') ~= sug_lnum or vim.fn.col('.') ~= sug_col then
      ghost_text.clear_suggestion()
    end
  end
  local auto_trigger = vim.g.vim_ai_autocomplete_auto_trigger
  if auto_trigger ~= nil and auto_trigger == 0 then
    return
  end
  if timer then
    timer:stop()
    timer:close()
  end
  timer = vim.defer_fn(on_timer, 600)
end

-- opts (opcional): {models = lista_de_modelos, auto_trigger = boolean}.
-- Acucar sobre os mesmos vim.g.* -- nunca um caminho de config paralelo.
-- Quem configura via vim.g direto continua funcionando identico; opts e'
-- so uma forma mais idiomatica (estilo lazy.nvim opts={}) de escrever a
-- mesma coisa. setup() sem argumento continua igual a antes.
function M.setup(opts)
  opts = opts or {}
  if opts.models ~= nil then
    vim.g.vim_ai_autocomplete_models = opts.models
  end
  if opts.auto_trigger ~= nil then
    vim.g.vim_ai_autocomplete_auto_trigger = opts.auto_trigger and 1 or 0
  end

  if vim.g.vim_ai_autocomplete_auto_trigger == nil then
    vim.g.vim_ai_autocomplete_auto_trigger = 1
  end

  keymaps.setup_tab_wrap()
  keymaps.setup_esc_wrap()

  -- ,pt nao depende de API key (so liga/desliga o debounce automatico) --
  -- registrado sempre, diferente de ,pr (so com 2+ modelos ativos).
  vim.keymap.set('n', '<leader>pt', keymaps.toggle_auto_trigger, { silent = true, desc = 'vim-ai-autocomplete: toggle auto-trigger' })

  local active_models = models.active_models()
  keymaps.setup_provider_toggle(active_models)

  if #active_models >= 2 then
    vim.keymap.set('n', '<leader>pm', keymaps.open_model_picker, { silent = true, desc = 'vim-ai-autocomplete: pick model' })
  end

  local all_models = vim.g.vim_ai_autocomplete_models or models.default_models()
  local default_name = models.resolve_default_model(all_models, active_models)
  if vim.g.vim_ai_autocomplete_provider == nil and default_name then
    vim.g.vim_ai_autocomplete_provider = default_name
  end

  local group = vim.api.nvim_create_augroup('vim_ai_autocomplete', { clear = true })
  vim.api.nvim_create_autocmd('CursorMovedI', { group = group, callback = M.trigger })
  vim.api.nvim_create_autocmd('InsertLeavePre', { group = group, callback = ghost_text.clear_suggestion })
end

return M
