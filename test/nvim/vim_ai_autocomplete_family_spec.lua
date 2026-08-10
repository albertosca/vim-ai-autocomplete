local family = require('vim-ai-autocomplete.family')

describe("vim-ai-autocomplete.family.extract_api_error_message", function()
  it("extracts the message from a valid error JSON", function()
    local msg = family.extract_api_error_message('{"error": {"message": "credito insuficiente"}}')
    assert.are.equal('credito insuficiente', msg)
  end)

  it("returns nil when it is not JSON", function()
    assert.is_nil(family.extract_api_error_message('not json'))
  end)

  it("returns nil when it does not have the expected shape", function()
    assert.is_nil(family.extract_api_error_message('{"outracoisa": 1}'))
  end)
end)

describe("vim-ai-autocomplete.family.parse_gemini_response", function()
  it("extracts the text from the response", function()
    local body = vim.json.encode({ candidates = { { content = { parts = { { text = 'ola\nmundo' } } } } } })
    local lines = family.parse_gemini_response(body)
    assert.are.same({ 'ola', 'mundo' }, lines)
  end)

  it("response with no candidates -> empty list", function()
    assert.are.same({}, family.parse_gemini_response('{}'))
  end)

  -- a blocked candidate (safety filter, finishReason SAFETY/RECITATION) comes
  -- back without "content", or without "parts" -- a legitimate HTTP 200
  -- response, just with no suggestion. Real finding, from a live smoke test on
  -- 2026-07-22: "attempt to index field 'parts' (a nil value)".
  it('candidate with no "content" (blocked by a safety filter) -> empty list, no error', function()
    local body = vim.json.encode({ candidates = { { finishReason = 'SAFETY' } } })
    assert.are.same({}, family.parse_gemini_response(body))
  end)

  it('candidate with "content" but no "parts" -> empty list, no error', function()
    local body = vim.json.encode({ candidates = { { content = { role = 'model' }, finishReason = 'RECITATION' } } })
    assert.are.same({}, family.parse_gemini_response(body))
  end)
end)

describe("vim-ai-autocomplete.family.parse_claude_response", function()
  it("extracts the text from the response", function()
    local body = vim.json.encode({ content = { { text = 'x\ny' } } })
    assert.are.same({ 'x', 'y' }, family.parse_claude_response(body))
  end)

  it("response with no content -> empty list", function()
    assert.are.same({}, family.parse_claude_response('{}'))
  end)
end)

describe("vim-ai-autocomplete.family.parse_deepseek_response", function()
  it("extracts the text from the response (OpenAI-compatible choices/message/content)", function()
    local body = vim.json.encode({ choices = { { message = { content = 'ola\nmundo' } } } })
    assert.are.same({ 'ola', 'mundo' }, family.parse_deepseek_response(body))
  end)

  it("response with no choices -> empty list", function()
    assert.are.same({}, family.parse_deepseek_response('{}'))
  end)

  it("choice with no message/content -> empty list, no error", function()
    local body = vim.json.encode({ choices = { { finish_reason = 'content_filter' } } })
    assert.are.same({}, family.parse_deepseek_response(body))
  end)
end)

describe("vim-ai-autocomplete.family.family_handler", function()
  it("gemini: build_command builds the right curl", function()
    local handler = family.family_handler('gemini')
    local cmd = handler.build_command({ before = 'a', after = 'b' }, 'gemini-3.1-flash-lite', 'KEY')
    assert.are.equal('curl', cmd[1])
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'gemini%-3%.1%-flash%-lite'))
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'key=KEY'))
  end)

  it("anthropic: build_command builds the right curl with the auth header", function()
    local handler = family.family_handler('anthropic')
    local cmd = handler.build_command({ before = 'a', after = 'b' }, 'claude-sonnet-5', 'KEY')
    assert.is_not_nil(string.find(table.concat(cmd, ' '), 'x%-api%-key: KEY'))
  end)

  it("deepseek: build_command builds the right curl (OpenAI-compatible, Bearer auth)", function()
    local handler = family.family_handler('deepseek')
    local cmd = handler.build_command({ before = 'def foo(', after = ')' }, 'deepseek-v4-flash', 'KEY')
    assert.are.equal('curl', cmd[1])
    local joined = table.concat(cmd, ' ')
    assert.is_not_nil(string.find(joined, 'https://api%.deepseek%.com/chat/completions'))
    assert.is_not_nil(string.find(joined, 'Authorization: Bearer KEY'))
    local d_idx
    for i, v in ipairs(cmd) do
      if v == '-d' then d_idx = i + 1 end
    end
    local decoded = vim.json.decode(cmd[d_idx])
    assert.are.equal('deepseek-v4-flash', decoded.model)
    assert.are.equal('user', decoded.messages[1].role)
    assert.is_not_nil(string.find(decoded.messages[1].content, 'def foo%('))
  end)

  it("unknown family: errors", function()
    assert.has_error(function() family.family_handler('openai') end)
  end)
end)

describe("vim-ai-autocomplete.family.describe_completion_failure", function()
  it("with an error message from the API", function()
    local msg = family.describe_completion_failure('gemini', 1, '{"error": {"message": "billing"}}')
    assert.is_not_nil(string.find(msg, 'billing'))
  end)

  it("no message, exit != 0", function()
    local msg = family.describe_completion_failure('gemini', 1, '')
    assert.is_not_nil(string.find(msg, 'exit 1'))
  end)

  it("nothing wrong at all -> nil", function()
    assert.is_nil(family.describe_completion_failure('gemini', 0, ''))
  end)
end)
