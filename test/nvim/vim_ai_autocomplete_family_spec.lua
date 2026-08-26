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

describe("vim-ai-autocomplete.family sanitization", function()
  -- U+FFFD (the "diamond with a question mark") reached a real buffer via
  -- Tab-accept (field report 2026-08-25, ga showed 65533/Hex fffd, three in
  -- a row). The whole local pipeline was exonerated by experiment -- raw
  -- bodies clean over 15 real calls, json_decode handles emoji (literal and
  -- escaped), and a multibyte char split across job chunks reassembles
  -- byte-perfectly -- so the junk arrives from upstream, intermittently.
  -- U+FFFD is never legitimate code: strip it in every parser.
  it("strips U+FFFD from gemini suggestions", function()
    local body = vim.json.encode({ candidates = { { content = { parts = { { text = 'a\239\191\189b\239\191\189\239\191\189' } } } } } })
    assert.are.same({ 'ab' }, family.parse_gemini_response(body))
  end)

  it("strips U+FFFD from claude suggestions", function()
    local body = vim.json.encode({ content = { { type = 'text', text = 'x\239\191\189y' } } })
    assert.are.same({ 'xy' }, family.parse_claude_response(body))
  end)

  it("strips U+FFFD from deepseek suggestions", function()
    local body = vim.json.encode({ choices = { { message = { content = 'q\239\191\189w' } } } })
    assert.are.same({ 'qw' }, family.parse_deepseek_response(body))
  end)
end)

describe("vim-ai-autocomplete.family.parse_claude_response", function()
  it("extracts the text from the response", function()
    local body = vim.json.encode({ content = { { text = 'x\ny' } } })
    assert.are.same({ 'x', 'y' }, family.parse_claude_response(body))
  end)

  -- claude-sonnet-5 prepends a {"type":"thinking"} block to content (observed
  -- live 5/5 on 2026-08-25) -- the text block is NOT content[1]. Indexing
  -- content[1].text blindly threw and killed the whole completion.
  it("skips a leading thinking block and reads the first text block", function()
    local body = vim.json.encode({ content = {
      { type = 'thinking', thinking = '', signature = 'abc' },
      { type = 'text', text = 'x\ny' },
    } })
    assert.are.same({ 'x', 'y' }, family.parse_claude_response(body))
  end)

  it("content with only thinking blocks -> empty list, no error", function()
    local body = vim.json.encode({ content = { { type = 'thinking', thinking = '' } } })
    assert.are.same({}, family.parse_claude_response(body))
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

describe("vim-ai-autocomplete.family.build_claude_request prompt caching", function()
  -- Anthropic prefix caching only pays when the prefix repeats byte-for-byte
  -- between requests. While typing inside a line, everything ABOVE that line
  -- is stable -- so the request is split into two text blocks: block 1 =
  -- instruction + stable before-context, marked cache_control ephemeral;
  -- block 2 = the current line's before-part + AFTER. Anthropic concatenates
  -- text blocks, so the model sees the exact same prompt as the single-string
  -- form -- pinned below as an invariant.
  it("splits into two blocks with cache_control when before_tail is present", function()
    local ctx = { before = 'line one\nline two\ncurrent', before_tail = 'current', after = ')' }
    local body = vim.json.decode(family.build_claude_request(ctx, 'claude-sonnet-5'))
    assert.are.equal(2, #body.messages[1].content)
    local b1, b2 = body.messages[1].content[1], body.messages[1].content[2]
    assert.are.equal('ephemeral', b1.cache_control.type)
    assert.is_nil(b2.cache_control)
    -- stable block ends right where the current line begins
    assert.is_not_nil(b1.text:find('line one\nline two\n', 1, true))
    assert.is_nil(b1.text:find('current', 1, true))
    assert.are.equal('current', b2.text:sub(1, 7))
  end)

  it("INVARIANT: block concatenation equals the single-string prompt byte for byte", function()
    local ctx = { before = 'a\nb\ncur', before_tail = 'cur', after = 'x' }
    local plain = vim.json.decode(family.build_claude_request({ before = ctx.before, after = ctx.after }, 'm'))
    local split = vim.json.decode(family.build_claude_request(ctx, 'm'))
    assert.are.equal(plain.messages[1].content, split.messages[1].content[1].text .. split.messages[1].content[2].text)
  end)

  it("without before_tail keeps the old single-string content", function()
    local body = vim.json.decode(family.build_claude_request({ before = 'a', after = 'b' }, 'm'))
    assert.are.equal('string', type(body.messages[1].content))
  end)

  it("before_tail equal to the whole before -> falls back to single string (nothing stable to cache)", function()
    local body = vim.json.decode(family.build_claude_request({ before = 'cur', before_tail = 'cur', after = '' }, 'm'))
    assert.are.equal('string', type(body.messages[1].content))
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
    -- without this, deepseek-v4-flash reasons before answering: 55.6s
    -- measured vs 1.6s with thinking disabled (real calls, 2026-08-25)
    assert.are.equal('disabled', decoded.thinking.type)
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
