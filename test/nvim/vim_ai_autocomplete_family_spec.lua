local family = require('vim-ai-autocomplete.family')

describe("vim-ai-autocomplete.family.extract_api_error_message", function()
  it("extrai a mensagem de um JSON de erro valido", function()
    local msg = family.extract_api_error_message('{"error": {"message": "credito insuficiente"}}')
    assert.are.equal('credito insuficiente', msg)
  end)

  it("retorna nil se nao for JSON", function()
    assert.is_nil(family.extract_api_error_message('nao e json'))
  end)

  it("retorna nil se nao tiver o formato esperado", function()
    assert.is_nil(family.extract_api_error_message('{"outracoisa": 1}'))
  end)
end)

describe("vim-ai-autocomplete.family.parse_gemini_response", function()
  it("extrai o texto da resposta", function()
    local body = vim.json.encode({ candidates = { { content = { parts = { { text = 'ola\nmundo' } } } } } })
    local lines = family.parse_gemini_response(body)
    assert.are.same({ 'ola', 'mundo' }, lines)
  end)

  it("resposta sem candidates -> lista vazia", function()
    assert.are.same({}, family.parse_gemini_response('{}'))
  end)

  -- candidate bloqueado (filtro de seguranca, finishReason SAFETY/RECITATION)
  -- vem sem "content" ou sem "parts" -- resposta HTTP 200 legitima, so sem
  -- sugestao. Achado real, reportado pelo Alberto 2026-07-22 (smoke test ao
  -- vivo): "attempt to index field 'parts' (a nil value)".
  it('candidate sem "content" (bloqueado por filtro de seguranca) -> lista vazia, sem erro', function()
    local body = vim.json.encode({ candidates = { { finishReason = 'SAFETY' } } })
    assert.are.same({}, family.parse_gemini_response(body))
  end)

  it('candidate com "content" mas sem "parts" -> lista vazia, sem erro', function()
    local body = vim.json.encode({ candidates = { { content = { role = 'model' }, finishReason = 'RECITATION' } } })
    assert.are.same({}, family.parse_gemini_response(body))
  end)
end)

describe("vim-ai-autocomplete.family.parse_claude_response", function()
  it("extrai o texto da resposta", function()
    local body = vim.json.encode({ content = { { text = 'x\ny' } } })
    assert.are.same({ 'x', 'y' }, family.parse_claude_response(body))
  end)

  it("resposta sem content -> lista vazia", function()
    assert.are.same({}, family.parse_claude_response('{}'))
  end)
end)

describe("vim-ai-autocomplete.family.family_handler", function()
  it("gemini: build_command monta o curl certo", function()
    local handler = family.family_handler('gemini')
    local cmd = handler.build_command({ before = 'a', after = 'b' }, 'gemini-3.1-flash-lite', 'KEY')
    assert.are.equal('curl', cmd[1])
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'gemini%-3%.1%-flash%-lite'))
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'key=KEY'))
  end)

  it("anthropic: build_command monta o curl certo com header de auth", function()
    local handler = family.family_handler('anthropic')
    local cmd = handler.build_command({ before = 'a', after = 'b' }, 'claude-sonnet-5', 'KEY')
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'x%-api%-key: KEY'))
  end)

  it("familia desconhecida: erro", function()
    assert.has_error(function() family.family_handler('openai') end)
  end)
end)

describe("vim-ai-autocomplete.family.describe_completion_failure", function()
  it("com mensagem de erro da API", function()
    local msg = family.describe_completion_failure('gemini', 1, '{"error": {"message": "billing"}}')
    assert.is_not_nil(string.find(msg, 'billing'))
  end)

  it("sem mensagem, exit != 0", function()
    local msg = family.describe_completion_failure('gemini', 1, '')
    assert.is_not_nil(string.find(msg, 'exit 1'))
  end)

  it("sem erro nenhum -> nil", function()
    assert.is_nil(family.describe_completion_failure('gemini', 0, ''))
  end)
end)
