local ghost_text = require('vim-ai-autocomplete.ghost_text')

describe("vim-ai-autocomplete.request.request_completion (vim.system mocked)", function()
  local buf, original_system, captured_cmd

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    ghost_text.clear_suggestion()
    vim.g.vim_ai_autocomplete_models = nil
    vim.g.vim_ai_autocomplete_provider = nil
    vim.fn.setenv('GEMINI_API_KEY', 'test-key')
    vim.fn.setenv('ANTHROPIC_API_KEY', vim.NIL)
    package.loaded['vim-ai-autocomplete.request'] = nil
    original_system = vim.system
  end)

  after_each(function()
    vim.system = original_system
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("builds the right command and shows the suggestion once the response arrives", function()
    vim.system = function(cmd, _, on_exit)
      captured_cmd = cmd
      on_exit({ code = 0, stdout = vim.json.encode({ candidates = { { content = { parts = { { text = 'x):\n    return x' } } } } } }) })
    end
    local request = require('vim-ai-autocomplete.request')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)

    assert.is_not_nil(string.find(table.concat(captured_cmd, ' '), 'gemini%-3%.1%-flash%-lite'))
    assert.is_true(ghost_text.is_visible())
  end)

  it("with no API key configured: makes no request at all", function()
    vim.fn.setenv('GEMINI_API_KEY', vim.NIL)
    local called = false
    vim.system = function() called = true end
    local request = require('vim-ai-autocomplete.request')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()

    assert.is_false(called)
  end)
end)

describe("vim-ai-autocomplete.request alternatives cycling (issue #3, vim.system mocked)", function()
  local buf, original_system

  local function gemini_body(texts)
    local candidates = {}
    for _, t in ipairs(texts) do
      table.insert(candidates, { content = { parts = { { text = t } } } })
    end
    return vim.json.encode({ candidates = candidates })
  end

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    ghost_text.clear_suggestion()
    vim.g.vim_ai_autocomplete_models = nil
    vim.g.vim_ai_autocomplete_provider = nil
    vim.g.vim_ai_autocomplete_alternatives = nil
    vim.fn.setenv('GEMINI_API_KEY', 'test-key')
    vim.fn.setenv('ANTHROPIC_API_KEY', vim.NIL)
    package.loaded['vim-ai-autocomplete.request'] = nil
    original_system = vim.system
  end)

  after_each(function()
    vim.system = original_system
    vim.g.vim_ai_autocomplete_alternatives = nil
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("feature off: the request body carries no candidateCount (unchanged behavior)", function()
    local captured
    vim.system = function(cmd, _, on_exit)
      captured = cmd[#cmd]
      on_exit({ code = 0, stdout = gemini_body({ 'x' }) })
    end
    local request = require('vim-ai-autocomplete.request')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)
    assert.is_nil(vim.json.decode(captured).generationConfig)
    assert.are.equal(0, ghost_text.alternatives_count())
  end)

  it("N=3 on a gemini model that opted in: one request asks for 3 candidates and all cycle through the pipeline", function()
    vim.g.vim_ai_autocomplete_alternatives = 3
    vim.g.vim_ai_autocomplete_models = {
      { name = 'gemini', family = 'gemini', model_id = 'x', api_key_env = 'GEMINI_API_KEY', candidates_per_request = 3 },
    }
    local captured
    vim.system = function(cmd, _, on_exit)
      captured = cmd[#cmd]
      on_exit({ code = 0, stdout = gemini_body({ 'a, b)', 'x' }) })
    end
    local request = require('vim-ai-autocomplete.request')
    -- 'def sum(' with the auto-paired ')' after the cursor: candidate 1 closes
    -- it (its ')' is trimmed from display, the real one stays), candidate 2
    -- does not -- per-candidate post-processing, as the issue requires.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)

    assert.are.equal(3, vim.json.decode(captured).generationConfig.candidateCount)
    assert.are.equal(2, ghost_text.alternatives_count())
    assert.are.same({ 'a, b' }, ghost_text.current_suggestion())
    request.cycle_suggestion(1)
    assert.are.same({ 'x' }, ghost_text.current_suggestion())
    request.cycle_suggestion(1)
    assert.are.same({ 'a, b' }, ghost_text.current_suggestion(), 'wraps around')
  end)

  it("gemini WITHOUT the opt-in stays lazy: no candidateCount, one extra request per cycle", function()
    -- the measured default: gemini-3.1-flash-lite rejects candidateCount > 1
    -- ("Multiple candidates is not enabled for this model", 2026-09-01), so
    -- without candidates_per_request in the model entry the batch field must
    -- never be sent.
    vim.g.vim_ai_autocomplete_alternatives = 2
    local calls, captured = 0, nil
    local replies = { gemini_body({ 'a, b)' }), gemini_body({ '*args)' }) }
    vim.system = function(cmd, _, on_exit)
      calls = calls + 1
      captured = cmd[#cmd]
      on_exit({ code = 0, stdout = replies[math.min(calls, #replies)] })
    end
    local request = require('vim-ai-autocomplete.request')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum(' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)
    assert.is_nil(vim.json.decode(captured).generationConfig)
    assert.are.equal(1, ghost_text.alternatives_count())
    request.cycle_suggestion(1)
    vim.wait(200, function() return ghost_text.alternatives_count() == 2 end, 10)
    assert.are.equal(2, calls)
    assert.are.same({ '*args)' }, ghost_text.current_suggestion())
  end)

  it("anthropic lazy: cycling past the end fetches ONE more request, then wraps", function()
    vim.g.vim_ai_autocomplete_alternatives = 2
    vim.fn.setenv('ANTHROPIC_API_KEY', 'test-key')
    vim.fn.setenv('GEMINI_API_KEY', vim.NIL)
    local calls = 0
    local replies = {
      vim.json.encode({ content = { { type = 'text', text = 'a, b)' } } }),
      vim.json.encode({ content = { { type = 'text', text = '*args)' } } }),
    }
    vim.system = function(_, _, on_exit)
      calls = calls + 1
      on_exit({ code = 0, stdout = replies[math.min(calls, #replies)] })
    end
    local request = require('vim-ai-autocomplete.request')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum(' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)

    assert.are.equal(1, calls, 'anthropic prefetches nothing (1 candidate per request)')
    assert.are.equal(1, ghost_text.alternatives_count())

    request.cycle_suggestion(1)
    vim.wait(200, function() return ghost_text.alternatives_count() == 2 end, 10)
    assert.are.equal(2, calls, 'first cycle past the end fetches lazily')
    assert.are.same({ '*args)' }, ghost_text.current_suggestion())

    request.cycle_suggestion(1)
    assert.are.equal(2, calls, 'N reached: cycling only wraps, no more requests')
    assert.are.same({ 'a, b)' }, ghost_text.current_suggestion())
  end)

  it("anthropic lazy duplicate: an identical lazy result is not added twice", function()
    vim.g.vim_ai_autocomplete_alternatives = 3
    vim.fn.setenv('ANTHROPIC_API_KEY', 'test-key')
    vim.fn.setenv('GEMINI_API_KEY', vim.NIL)
    local calls = 0
    vim.system = function(_, _, on_exit)
      calls = calls + 1
      on_exit({ code = 0, stdout = vim.json.encode({ content = { { type = 'text', text = 'same)' } } }) })
    end
    local request = require('vim-ai-autocomplete.request')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum(' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)

    request.cycle_suggestion(1)
    vim.wait(100, function() return calls == 2 end, 10)
    assert.are.equal(1, ghost_text.alternatives_count(), 'duplicate collapsed')
    assert.are.same({ 'same)' }, ghost_text.current_suggestion())
  end)

  it("cycle_suggestion with the feature off is a silent no-op", function()
    vim.system = function(_, _, on_exit)
      on_exit({ code = 0, stdout = gemini_body({ 'x' }) })
    end
    local request = require('vim-ai-autocomplete.request')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    request.request_completion()
    vim.wait(200, function() return ghost_text.is_visible() end, 10)
    request.cycle_suggestion(1)
    assert.are.same({ 'x' }, ghost_text.current_suggestion())
  end)
end)
