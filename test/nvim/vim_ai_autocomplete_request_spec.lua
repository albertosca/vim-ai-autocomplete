local ghost_text = require('vim-ai-autocomplete.ghost_text')

describe("vim-ai-autocomplete.request.request_completion (vim.system mockado)", function()
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

  it("monta o comando certo e mostra a sugestao quando a resposta chega", function()
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

  it("sem nenhuma API key configurada: nao faz request nenhuma", function()
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
