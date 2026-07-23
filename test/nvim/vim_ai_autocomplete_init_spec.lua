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

  -- fix de 2026-07-21 do lado Vim (commit 84a2975), portado aqui: mover o
  -- cursor pra longe de onde a sugestao foi mostrada invalida ela --
  -- aceitar do jeito que esta inseriria o texto errado na posicao errada.
  it("invalida a sugestao visivel se o cursor se moveu pra longe de onde ela foi mostrada", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'a, b):' }, 0)
    assert.is_true(ghost_text.is_visible())

    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vai.trigger()
    assert.is_false(ghost_text.is_visible())
  end)

  it("NAO invalida se o cursor continua na mesma posicao", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'a, b):' }, 0)
    vai.trigger()
    assert.is_true(ghost_text.is_visible())
  end)
end)

describe("vim-ai-autocomplete.setup", function()
  it("roda sem erro e registra ,pt", function()
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

  it("opts.models seta vim.g.vim_ai_autocomplete_models", function()
    local models_list = { { name = 'a', family = 'gemini', model_id = 'x', api_key_env = 'VAA_TEST_KEY_SETUP' } }
    vai.setup({ models = models_list })
    assert.are.same(models_list, vim.g.vim_ai_autocomplete_models)
  end)

  it("opts.auto_trigger = false vira vim.g.vim_ai_autocomplete_auto_trigger = 0", function()
    vai.setup({ auto_trigger = false })
    assert.are.equal(0, vim.g.vim_ai_autocomplete_auto_trigger)
  end)

  it("sem opts.auto_trigger, mantem o default 1", function()
    vai.setup({})
    assert.are.equal(1, vim.g.vim_ai_autocomplete_auto_trigger)
  end)

  it("chamar setup() sem argumento nenhum continua funcionando (nil opts)", function()
    assert.has_no.errors(function() vai.setup() end)
  end)
end)
