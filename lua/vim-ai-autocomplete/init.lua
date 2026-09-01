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

-- If the cursor moved away from where the suggestion was shown (e.g. arrow
-- keys to review the text before accepting), the suggestion is stale --
-- accepting it as is would insert the wrong text at the wrong position. Same
-- fix as on the Vim side (commit 84a2975). Clears unconditionally, even with
-- auto_trigger off -- this is about correctness, not about asking for a new
-- suggestion.
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

-- opts (optional): {models = model_list, auto_trigger = boolean}. Sugar over
-- the very same vim.g.* variables -- never a parallel config path. Anyone
-- setting vim.g directly keeps working identically; opts is just a more
-- idiomatic way (lazy.nvim opts={} style) of writing the same thing.
-- setup() with no argument behaves exactly as before.
function M.setup(opts)
  opts = opts or {}
  if opts.models ~= nil then
    vim.g.vim_ai_autocomplete_models = opts.models
  end
  if opts.auto_trigger ~= nil then
    vim.g.vim_ai_autocomplete_auto_trigger = opts.auto_trigger and 1 or 0
  end
  if opts.alternatives ~= nil then
    vim.g.vim_ai_autocomplete_alternatives = opts.alternatives
  end

  if vim.g.vim_ai_autocomplete_auto_trigger == nil then
    vim.g.vim_ai_autocomplete_auto_trigger = 1
  end

  keymaps.setup_tab_wrap()
  vim.keymap.set('i', '<C-]>', keymaps.dismiss, { expr = true, silent = true, desc = 'vim-ai-autocomplete: dismiss suggestion' })

  -- issue #3: alternatives are off by default (each one is a paid call), and
  -- the cycle keys are only claimed when the feature is on -- <M-.>/<M-,>
  -- stay untouched otherwise.
  local alternatives = vim.g.vim_ai_autocomplete_alternatives
  if type(alternatives) == 'number' and alternatives >= 2 then
    vim.keymap.set('i', '<M-.>', function() require('vim-ai-autocomplete.request').cycle_suggestion(1) end,
      { silent = true, desc = 'vim-ai-autocomplete: next alternative' })
    vim.keymap.set('i', '<M-,>', function() require('vim-ai-autocomplete.request').cycle_suggestion(-1) end,
      { silent = true, desc = 'vim-ai-autocomplete: previous alternative' })
  end

  -- ,pt does not depend on an API key (it only toggles the automatic
  -- debounce) -- always registered, unlike ,pr (2+ active models only).
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
