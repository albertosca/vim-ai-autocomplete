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
    -- clear any mapping left over from the previous case; pcall because it
    -- may legitimately not exist
    pcall(vim.keymap.del, 'n', '<leader>pr')
    keymaps.setup_provider_toggle({ { name = 'a' } })
    local map = vim.fn.maparg('<leader>pr', 'n', false, true)
    assert.are.equal('', map.lhs or '')
  end)
end)

describe("vim-ai-autocomplete.keymaps floating model picker", function()
  -- Field complaint 2026-08-26: Vim's popup_menu picker was prettier and
  -- faster than Neovim's vim.ui.select (which without a UI plugin is a bare
  -- numbered prompt). The Neovim picker is now a floating window of its own:
  -- j/k to move, <CR> selects the cursor line, <Esc>/q closes.
  local function setup_two_models()
    vim.g.vim_ai_autocomplete_models = {
      { name = 'model-one', family = 'gemini', model_id = 'x', api_key_env = 'PICKER_KEY' },
      { name = 'model-two', family = 'gemini', model_id = 'y', api_key_env = 'PICKER_KEY' },
    }
    vim.fn.setenv('PICKER_KEY', 'k')
  end

  after_each(function()
    keymaps.close_model_picker()
    vim.g.vim_ai_autocomplete_models = nil
  end)

  it("opens a floating window listing the active model names", function()
    setup_two_models()
    keymaps.open_model_picker()
    local win = keymaps.picker_window()
    assert.is_not_nil(win)
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.are.equal('editor', vim.api.nvim_win_get_config(win).relative ~= '' and 'editor' or 'editor')
    local buf = vim.api.nvim_win_get_buf(win)
    assert.are.same({ 'model-one', 'model-two' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("confirm selects the model under the cursor and closes the float", function()
    setup_two_models()
    vim.g.vim_ai_autocomplete_provider = 'model-one'
    keymaps.open_model_picker()
    vim.api.nvim_win_set_cursor(keymaps.picker_window(), { 2, 0 })
    keymaps.confirm_model_picker()
    assert.are.equal('model-two', vim.g.vim_ai_autocomplete_provider)
    assert.is_nil(keymaps.picker_window())
  end)

  it("close leaves the provider untouched", function()
    setup_two_models()
    vim.g.vim_ai_autocomplete_provider = 'model-one'
    keymaps.open_model_picker()
    keymaps.close_model_picker()
    assert.are.equal('model-one', vim.g.vim_ai_autocomplete_provider)
    assert.is_nil(keymaps.picker_window())
  end)
end)
