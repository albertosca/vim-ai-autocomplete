local vai = require('vim-ai-autocomplete')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

describe("vim-ai-autocomplete.trigger", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    ghost_text.clear_suggestion()
    vim.g.vim_ai_autocomplete_auto_trigger = nil
  end)

  after_each(function()
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- the 2026-07-21 fix from the Vim side (commit 84a2975), ported here:
  -- moving the cursor away from where the suggestion was shown invalidates it
  -- -- accepting it as is would insert the wrong text at the wrong position.
  it("invalidates the visible suggestion when the cursor moved away from where it was shown", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'a, b):' }, 0)
    assert.is_true(ghost_text.is_visible())

    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vai.trigger()
    assert.is_false(ghost_text.is_visible())
  end)

  it("does NOT invalidate it when the cursor is still at the same position", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'a, b):' }, 0)
    vai.trigger()
    assert.is_true(ghost_text.is_visible())
  end)
end)

describe("vim-ai-autocomplete.setup", function()
  it("runs without error and registers ,pt", function()
    vai.setup()
    local map = vim.fn.maparg('<leader>pt', 'n', false, true)
    assert.is_not_nil(map.callback)
  end)
end)

describe("vim-ai-autocomplete.setup com opts", function()
  after_each(function()
    vim.g.vim_ai_autocomplete_models = nil
    vim.g.vim_ai_autocomplete_auto_trigger = nil
    vim.g.vim_ai_autocomplete_provider = nil
  end)

  it("opts.models sets vim.g.vim_ai_autocomplete_models", function()
    local models_list = { { name = 'a', family = 'gemini', model_id = 'x', api_key_env = 'VAA_TEST_KEY_SETUP' } }
    vai.setup({ models = models_list })
    assert.are.same(models_list, vim.g.vim_ai_autocomplete_models)
  end)

  it("opts.auto_trigger = false becomes vim.g.vim_ai_autocomplete_auto_trigger = 0", function()
    vai.setup({ auto_trigger = false })
    assert.are.equal(0, vim.g.vim_ai_autocomplete_auto_trigger)
  end)

  it("with no opts.auto_trigger, keeps the default of 1", function()
    vai.setup({})
    assert.are.equal(1, vim.g.vim_ai_autocomplete_auto_trigger)
  end)

  it("calling setup() with no argument at all keeps working (nil opts)", function()
    assert.has_no.errors(function() vai.setup() end)
  end)
end)

describe("vim-ai-autocomplete.init alternatives keymaps (issue #3)", function()
  after_each(function()
    vim.g.vim_ai_autocomplete_alternatives = nil
    pcall(vim.keymap.del, 'i', '<M-.>')
    pcall(vim.keymap.del, 'i', '<M-,>')
    package.loaded['vim-ai-autocomplete'] = nil
  end)

  it("feature off (default): <M-.> and <M-,> are NOT claimed", function()
    vim.fn.setenv('GEMINI_API_KEY', 'k')
    require('vim-ai-autocomplete').setup()
    assert.are.equal('', vim.fn.maparg('<M-.>', 'i'))
    assert.are.equal('', vim.fn.maparg('<M-,>', 'i'))
  end)

  it("setup({ alternatives = 3 }) sets the global and maps both cycle keys", function()
    vim.fn.setenv('GEMINI_API_KEY', 'k')
    require('vim-ai-autocomplete').setup({ alternatives = 3 })
    assert.are.equal(3, vim.g.vim_ai_autocomplete_alternatives)
    assert.are_not.equal('', vim.fn.maparg('<M-.>', 'i'))
    assert.are_not.equal('', vim.fn.maparg('<M-,>', 'i'))
  end)
end)
