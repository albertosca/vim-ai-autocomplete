local models = require('vim-ai-autocomplete.models')

describe("vim-ai-autocomplete.models.resolve_active_models (logica pura)", function()
  it("filtra so os modelos com api_key_env setada no ambiente", function()
    vim.fn.setenv('VAA_TEST_KEY_A', 'x')
    vim.fn.setenv('VAA_TEST_KEY_B', vim.NIL)
    local list = {
      { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'VAA_TEST_KEY_A' },
      { name = 'b', family = 'anthropic', model_id = 'm2', api_key_env = 'VAA_TEST_KEY_B' },
    }
    local active, warnings = models.resolve_active_models(list)
    assert.are.equal(1, #active)
    assert.are.equal('a', active[1].name)
    assert.are.equal(0, #warnings)
  end)

  it("nome duplicado: so a primeira ocorrencia entra, resto vira warning", function()
    vim.fn.setenv('VAA_TEST_KEY_A', 'x')
    local list = {
      { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'VAA_TEST_KEY_A' },
      { name = 'a', family = 'gemini', model_id = 'm2', api_key_env = 'VAA_TEST_KEY_A' },
    }
    local active, warnings = models.resolve_active_models(list)
    assert.are.equal(1, #active)
    assert.are.equal(1, #warnings)
    assert.is_not_nil(string.find(warnings[1], 'duplicado'))
  end)
end)

describe("vim-ai-autocomplete.models.find_model_by_name", function()
  it("acha pelo nome", function()
    local list = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'X' } }
    assert.are.equal('a', models.find_model_by_name(list, 'a').name)
  end)

  it("retorna nil se nao existe", function()
    assert.is_nil(models.find_model_by_name({}, 'z'))
  end)
end)

describe("vim-ai-autocomplete.models.resolve_default_model", function()
  it("nenhum modelo ativo: erro listando as api_key_env configuradas", function()
    local all = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'ENV_A' } }
    local name, level, message = models.resolve_default_model(all, {})
    assert.is_nil(name)
    assert.are.equal('error', level)
    assert.is_not_nil(string.find(message, 'ENV_A'))
  end)

  it("so um modelo ativo: aviso que o toggle fica desabilitado", function()
    local active = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'ENV_A' } }
    local name, level, message = models.resolve_default_model(active, active)
    assert.are.equal('a', name)
    assert.are.equal('warn', level)
    assert.is_not_nil(string.find(message, 'a'))
  end)

  it("2+ modelos ativos: sem aviso, primeiro da lista", function()
    local active = {
      { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'ENV_A' },
      { name = 'b', family = 'anthropic', model_id = 'm2', api_key_env = 'ENV_B' },
    }
    local name, level, message = models.resolve_default_model(active, active)
    assert.are.equal('a', name)
    assert.is_nil(level)
    assert.is_nil(message)
  end)
end)
