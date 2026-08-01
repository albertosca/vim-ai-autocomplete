local models = require('vim-ai-autocomplete.models')

describe("vim-ai-autocomplete.models.resolve_active_models (pure logic)", function()
  it("keeps only the models whose api_key_env is set in the environment", function()
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

  it("duplicate name: only the first occurrence gets in, the rest become warnings", function()
    vim.fn.setenv('VAA_TEST_KEY_A', 'x')
    local list = {
      { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'VAA_TEST_KEY_A' },
      { name = 'a', family = 'gemini', model_id = 'm2', api_key_env = 'VAA_TEST_KEY_A' },
    }
    local active, warnings = models.resolve_active_models(list)
    assert.are.equal(1, #active)
    assert.are.equal(1, #warnings)
    assert.is_not_nil(string.find(warnings[1], 'duplicate'))
  end)
end)

describe("vim-ai-autocomplete.models.find_model_by_name", function()
  it("finds it by name", function()
    local list = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'X' } }
    assert.are.equal('a', models.find_model_by_name(list, 'a').name)
  end)

  it("returns nil when it does not exist", function()
    assert.is_nil(models.find_model_by_name({}, 'z'))
  end)
end)

describe("vim-ai-autocomplete.models.resolve_default_model", function()
  it("no active model: errors listing the configured api_key_env names", function()
    local all = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'ENV_A' } }
    local name, level, message = models.resolve_default_model(all, {})
    assert.is_nil(name)
    assert.are.equal('error', level)
    assert.is_not_nil(string.find(message, 'ENV_A'))
  end)

  it("a single active model: warns that the toggle is disabled", function()
    local active = { { name = 'a', family = 'gemini', model_id = 'm1', api_key_env = 'ENV_A' } }
    local name, level, message = models.resolve_default_model(active, active)
    assert.are.equal('a', name)
    assert.are.equal('warn', level)
    assert.is_not_nil(string.find(message, 'a'))
  end)

  it("2+ active models: no warning, first of the list wins", function()
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
