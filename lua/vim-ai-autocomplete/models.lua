local M = {}

-- Default preservando exatamente o comportamento de hoje do lado Vim
-- (Gemini + Claude, mesmos model_id) quando o usuario nao define
-- vim.g.vim_ai_autocomplete_models.
function M.default_models()
  return {
    { name = 'gemini', family = 'gemini', model_id = 'gemini-3.1-flash-lite', api_key_env = 'GEMINI_API_KEY' },
    { name = 'claude', family = 'anthropic', model_id = 'claude-sonnet-4-5-20250929', api_key_env = 'ANTHROPIC_API_KEY' },
  }
end

-- Filtra a lista crua pelos modelos cuja api_key_env esta de fato setada e
-- nao-vazia no ambiente -- essa e a lista "ativa" que entra no rodizio do
-- ,pr / :VimAiAutocompleteModel. Nomes duplicados: so a PRIMEIRA ocorrencia
-- entra (deterministico), as seguintes viram warnings (funcao pura -- quem
-- chama decide o que fazer com eles, ex: vim.notify).
function M.resolve_active_models(models_list)
  local active = {}
  local warnings = {}
  local seen_names = {}
  for _, model in ipairs(models_list) do
    if seen_names[model.name] then
      table.insert(warnings, 'modelo duplicado "' .. model.name .. '" em vim.g.vim_ai_autocomplete_models -- ignorando')
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

-- Ponto de entrada publico: le vim.g.vim_ai_autocomplete_models (ou o
-- default se o usuario nao configurou nada), resolve a lista ativa, e
-- reporta via vim.notify (WARN) qualquer aviso de config invalida.
function M.active_models()
  local models_list = vim.g.vim_ai_autocomplete_models or M.default_models()
  local active, warnings = M.resolve_active_models(models_list)
  for _, warning in ipairs(warnings) do
    vim.notify('vim-ai-autocomplete: ' .. warning, vim.log.levels.WARN)
  end
  return active
end

-- Decide o modelo default e se precisa avisar/travar, a partir da lista de
-- modelos ATIVOS (ja filtrada por resolve_active_models). all_models e
-- usada so pra listar as api_key_env configuradas na mensagem de erro.
function M.resolve_default_model(all_models, active_models)
  if #active_models == 0 then
    local env_names = {}
    for _, model in ipairs(all_models) do
      table.insert(env_names, model.api_key_env)
    end
    return nil, 'error', 'nenhuma API key encontrada (' .. table.concat(env_names, ' nem ') .. ') -- configure pelo menos uma'
  end
  if #active_models == 1 then
    local name = active_models[1].name
    return name, 'warn', string.format('so %s disponivel -- toggle ,pr desabilitado', name)
  end
  return active_models[1].name, nil, nil
end

return M
