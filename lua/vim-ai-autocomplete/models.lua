local M = {}

-- Default that preserves exactly what the Vim side does today (Gemini plus
-- Claude, same model_ids) when the user does not set
-- vim.g.vim_ai_autocomplete_models.
function M.default_models()
  return {
    { name = 'gemini', family = 'gemini', model_id = 'gemini-3.1-flash-lite', api_key_env = 'GEMINI_API_KEY' },
    { name = 'claude', family = 'anthropic', model_id = 'claude-sonnet-4-5-20250929', api_key_env = 'ANTHROPIC_API_KEY' },
  }
end

-- Filters the raw list down to the models whose api_key_env is actually set
-- and non-empty in the environment -- that is the "active" list feeding the
-- ,pr / :VimAiAutocompleteModel rotation. Duplicate names: only the FIRST
-- occurrence gets in (deterministic), the rest become warnings (pure
-- function -- the caller decides what to do with them, e.g. vim.notify).
function M.resolve_active_models(models_list)
  local active = {}
  local warnings = {}
  local seen_names = {}
  for _, model in ipairs(models_list) do
    if seen_names[model.name] then
      table.insert(warnings, 'duplicate model "' .. model.name .. '" in vim.g.vim_ai_autocomplete_models -- ignoring')
    else
      seen_names[model.name] = true
      local key_value = vim.fn.getenv(model.api_key_env)
      if type(key_value) == 'string' and key_value ~= '' then
        table.insert(active, model)
      end
    end
  end
  return active, warnings
end

function M.find_model_by_name(models_list, name)
  for _, model in ipairs(models_list) do
    if model.name == name then
      return model
    end
  end
  return nil
end

-- Public entry point: reads vim.g.vim_ai_autocomplete_models (or the default
-- when the user configured nothing), resolves the active list, and reports
-- any invalid-config warning through vim.notify (WARN).
function M.active_models()
  local models_list = vim.g.vim_ai_autocomplete_models or M.default_models()
  local active, warnings = M.resolve_active_models(models_list)
  for _, warning in ipairs(warnings) do
    vim.notify('vim-ai-autocomplete: ' .. warning, vim.log.levels.WARN)
  end
  return active
end

-- Decides the default model and whether to warn or hard-stop, starting from
-- the ACTIVE model list (already filtered by resolve_active_models).
-- all_models is only used to list the configured api_key_env names in the
-- error message.
function M.resolve_default_model(all_models, active_models)
  if #active_models == 0 then
    local env_names = {}
    for _, model in ipairs(all_models) do
      table.insert(env_names, model.api_key_env)
    end
    return nil, 'error', 'no API key found (' .. table.concat(env_names, ' nor ') .. ') -- configure at least one'
  end
  if #active_models == 1 then
    local name = active_models[1].name
    return name, 'warn', string.format('only %s available -- the ,pr toggle is disabled', name)
  end
  return active_models[1].name, nil, nil
end

return M
