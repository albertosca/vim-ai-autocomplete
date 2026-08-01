local keymaps = require('vim-ai-autocomplete.keymaps')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

describe("vim-ai-autocomplete.keymaps.tab_handler", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    ghost_text.clear_suggestion()
  end)

  after_each(function()
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("with a visible suggestion: accepts it (returns '')", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'x)' }, 0)
    assert.are.equal('', keymaps.tab_handler())
  end)

  it("no visible suggestion and no original mapping: falls back to a literal Tab", function()
    -- tab_handler() is used as the rhs of an 'expr' mapping backed by a Lua
    -- callback: its return value is used DIRECTLY as the typed keys, without
    -- being re-evaluated as a Vimscript expression (verified empirically
    -- through nvim_feedkeys) -- which is why we compare the return value
    -- directly instead of wrapping it in nvim_eval() (which throws E15 on a
    -- literal tab).
    assert.are.equal('\t', keymaps.tab_handler())
  end)

  it("no visible suggestion, with a classic original <expr> mapping: evaluates the rhs", function()
    -- Simulates a pre-existing classic <expr> mapping (Vimscript rhs, no Lua
    -- callback) -- e.g. another plugin doing
    -- `inoremap <expr> <Tab> '"literal"'`. setup_tab_wrap() must capture that
    -- rhs with is_expr=true; tab_handler() has to evaluate the rhs through
    -- nvim_eval() and return the result.
    vim.keymap.set('i', '<Tab>', '"literal"', { expr = true })
    keymaps.setup_tab_wrap()
    assert.are.equal('literal', keymaps.tab_handler())
    vim.keymap.del('i', '<Tab>')
  end)

  it("no visible suggestion, with an <expr> mapping backed by a Lua callback: calls it and returns its result", function()
    -- Simulates something like blink.cmp: an <expr> mapping whose rhs is a
    -- Lua callback (no classic 'rhs'). setup_tab_wrap() captures callback plus
    -- is_expr=true; tab_handler() must call the callback and, because
    -- is_expr=true, return ITS result (not ''), matching the Vimscript
    -- semantics: `s:tab_fallback_is_expr ? result : ''`.
    vim.keymap.set('i', '<Tab>', function() return 'from-callback' end, { expr = true })
    keymaps.setup_tab_wrap()
    assert.are.equal('from-callback', keymaps.tab_handler())
    vim.keymap.del('i', '<Tab>')
  end)

  it("no visible suggestion, with a NON-<expr> mapping backed by a Lua callback: does not return the callback result", function()
    -- Simulates a <Tab> mapping backed by a Lua callback that is NOT <expr>
    -- (e.g. `vim.keymap.set('i', '<Tab>', function() ... end)` without
    -- { expr = true }). setup_tab_wrap() captures callback plus is_expr=false;
    -- tab_handler() may NOT return the callback result in that case (it was
    -- never designed to be used as an expr-map value and would leak text into
    -- the buffer) -- it has to return '' like any other non-expr fallback.
    -- This distinguishes the fix (gated on is_expr) from the old bug (an
    -- unconditional return of tab_fallback.callback()).
    vim.keymap.set('i', '<Tab>', function() return 'should-not-leak-into-buffer' end)
    keymaps.setup_tab_wrap()
    assert.are.equal('', keymaps.tab_handler())
    vim.keymap.del('i', '<Tab>')
  end)
end)

describe("vim-ai-autocomplete.keymaps.dismiss", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    ghost_text.clear_suggestion()
  end)

  after_each(function()
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clears the visible suggestion and injects nothing into the buffer", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foo' })
    vim.fn.cursor(1, 3)
    ghost_text.show_suggestion({ 'bar' })
    assert.is_true(ghost_text.is_visible())
    assert.are.equal('', keymaps.dismiss())
    assert.is_false(ghost_text.is_visible())
  end)

  it("with no visible suggestion it is harmless", function()
    assert.is_false(ghost_text.is_visible())
    assert.are.equal('', keymaps.dismiss())
    assert.is_false(ghost_text.is_visible())
  end)

  -- Root-cause regression: the plugin may no longer hijack <Esc>. Previously,
  -- with a suggestion visible, the wrap returned '' and the user was stuck in
  -- insert mode -- the following keystrokes turned into buffer text. Those two
  -- functions were the only path to that hijack; without them <Esc> is plain
  -- <Esc> and the suggestion goes away through the InsertLeavePre autocmd.
  it("no longer exposes the <Esc> wrap", function()
    assert.is_nil(keymaps.setup_esc_wrap)
    assert.is_nil(keymaps.esc_handler)
  end)
end)

describe("vim-ai-autocomplete.keymaps.complete_model_names", function()
  it("filters by literal prefix (not regex)", function()
    vim.g.vim_ai_autocomplete_models = {
      { name = 'gemini-flash', family = 'gemini', model_id = 'x', api_key_env = 'VAA_TEST_KEY_A' },
      { name = 'claude-sonnet', family = 'anthropic', model_id = 'y', api_key_env = 'VAA_TEST_KEY_A' },
    }
    vim.fn.setenv('VAA_TEST_KEY_A', 'x')
    local result = keymaps.complete_model_names('gem')
    assert.are.same({ 'gemini-flash' }, result)
    vim.g.vim_ai_autocomplete_models = nil
  end)
end)

describe("vim-ai-autocomplete.keymaps.setup_provider_toggle", function()
  it("with 2+ active models, registers ,pr and the VimAiAutocompleteModel command", function()
    keymaps.setup_provider_toggle({ { name = 'a' }, { name = 'b' } })
    local map = vim.fn.maparg('<leader>pr', 'n', false, true)
    assert.is_not_nil(map.callback)
    assert.is_not_nil(vim.fn.exists(':VimAiAutocompleteModel'))
  end)

  it("with only 1 active model, does not register ,pr", function()
    vim.keymap.del('n', '<leader>pr', { buffer = false })
    local ok = pcall(vim.keymap.del, 'n', '<leader>pr')
    keymaps.setup_provider_toggle({ { name = 'a' } })
    local map = vim.fn.maparg('<leader>pr', 'n', false, true)
    assert.are.equal('', map.lhs or '')
  end)
end)

describe("vim-ai-autocomplete.keymaps.open_model_picker", function()
  it("calls vim.ui.select with the active model names and selects the chosen one", function()
    vim.g.vim_ai_autocomplete_models = {
      { name = 'gemini-flash', family = 'gemini', model_id = 'x', api_key_env = 'VAA_TEST_KEY_A' },
      { name = 'claude-sonnet', family = 'anthropic', model_id = 'y', api_key_env = 'VAA_TEST_KEY_A' },
    }
    vim.fn.setenv('VAA_TEST_KEY_A', 'x')
    local original_select = vim.ui.select
    local captured_items
    vim.ui.select = function(items, _, on_choice)
      captured_items = items
      on_choice(items[2])
    end

    keymaps.open_model_picker()

    assert.are.same({ 'gemini-flash', 'claude-sonnet' }, captured_items)
    assert.are.equal('claude-sonnet', vim.g.vim_ai_autocomplete_provider)

    vim.ui.select = original_select
    vim.g.vim_ai_autocomplete_models = nil
  end)
end)
