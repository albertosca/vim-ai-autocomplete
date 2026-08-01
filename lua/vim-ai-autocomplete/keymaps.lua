local models = require('vim-ai-autocomplete.models')
local family = require('vim-ai-autocomplete.family')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

local M = {}

local tab_fallback = { rhs = '\t', is_expr = false, callback = nil }

-- Mappings backed by a Lua callback (e.g. blink.cmp's "jump to the next
-- snippet placeholder or fall back to a normal Tab") have no classic 'rhs' --
-- reading it with a default covers both shapes, same fallback as the Vim
-- side.
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

-- Dismisses the suggestion WITHOUT leaving insert mode. This used to live in
-- an <Esc> wrap that swallowed the key whenever a suggestion was visible: the
-- user pressed <Esc> to leave insert mode, stayed in insert mode, and the
-- following keystrokes landed in the buffer as text (reproduced while writing
-- markdown, where a suggestion is visible almost all the time). One key
-- cannot carry two meanings when the user has no way to predict which one
-- applies, so <Esc> is plain <Esc> again -- the suggestion is cleared by the
-- InsertLeavePre autocmd -- and dismiss-without-leaving got a key of its own.
-- <C-]> is the same choice copilot.vim makes for dismissing a suggestion.
function M.dismiss()
  ghost_text.clear_suggestion()
  return ''
end

function M.toggle_auto_trigger()
  local current = vim.g.vim_ai_autocomplete_auto_trigger
  if current == nil then
    current = 1
  end
  local new_value = (current ~= 0) and 0 or 1
  vim.g.vim_ai_autocomplete_auto_trigger = new_value
  vim.notify('vim-ai-autocomplete: auto-trigger ' .. (new_value == 1 and 'on' or 'off'))
end

-- Generalises the key check -- fires a cheap call against the model just
-- switched to; on error it only WARNS, it no longer reverts to the previous
-- model (it used to revert automatically; changed on request 2026-07-22, "I
-- want to be able to cycle freely", e.g. pressing ,pr repeatedly to try the
-- next models even after a credit warning, without having to switch back by
-- hand).
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
    vim.notify('vim-ai-autocomplete: model "' .. name .. '" does not exist or is not active (no API key)', vim.log.levels.ERROR)
    return
  end
  vim.g.vim_ai_autocomplete_provider = name
  vim.notify('vim-ai-autocomplete: provider is now ' .. name)
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
  vim.notify('vim-ai-autocomplete: provider is now ' .. vim.g.vim_ai_autocomplete_provider)
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

-- active_models: the ALREADY FILTERED list (see models.active_models()) --
-- registers ,pr and :VimAiAutocompleteModel only with 2+ active models, same
-- rule as the Vim side. <leader>pr, not <leader>ap/<leader>pv -- same
-- collisions already documented on the Vim/minuet side.
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

-- Neovim-only extra: pick the model through vim.ui.select instead of typing
-- :VimAiAutocompleteModel <name> from memory. Works with Telescope
-- automatically when installed (Telescope replaces the global vim.ui.select
-- handler) -- no Telescope detection needed, that is how vim.ui.select is
-- meant to work.
function M.open_model_picker()
  local active = models.active_models()
  local names = {}
  for _, m in ipairs(active) do
    table.insert(names, m.name)
  end
  vim.ui.select(names, { prompt = 'vim-ai-autocomplete: pick a model' }, function(choice)
    if choice then
      M.select_model(choice)
    end
  end)
end

return M
