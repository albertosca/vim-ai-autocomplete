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

  it("com sugestao visivel: aceita (retorna '')", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'x)' }, 0)
    assert.are.equal('', keymaps.tab_handler())
  end)

  it("sem sugestao visivel e sem mapeamento original: cai pro Tab literal", function()
    -- tab_handler() e usado como rhs de um mapeamento 'expr' baseado em
    -- callback Lua: o retorno e usado DIRETO como as keys tecladas, sem
    -- ser reavaliado como expressao Vimscript (verificado empiricamente
    -- via nvim_feedkeys) -- por isso comparamos o retorno diretamente,
    -- em vez de envolver com nvim_eval() (que da E15 num tab literal).
    assert.are.equal('\t', keymaps.tab_handler())
  end)

  it("sem sugestao visivel, com mapeamento <expr> classico original: avalia o rhs", function()
    -- Simula um mapeamento <expr> classico (rhs Vimscript, sem callback
    -- Lua) preexistente -- ex: outro plugin que faz
    -- `inoremap <expr> <Tab> '"literal"'`. setup_tab_wrap() deve capturar
    -- esse rhs e is_expr=true; tab_handler() precisa avaliar o rhs via
    -- nvim_eval() e retornar o resultado.
    vim.keymap.set('i', '<Tab>', '"literal"', { expr = true })
    keymaps.setup_tab_wrap()
    assert.are.equal('literal', keymaps.tab_handler())
    vim.keymap.del('i', '<Tab>')
  end)

  it("sem sugestao visivel, com mapeamento <expr> baseado em callback Lua: chama o callback e retorna seu resultado", function()
    -- Simula algo como blink.cmp: mapeamento <expr> cujo rhs e um
    -- callback Lua (sem 'rhs' classico). setup_tab_wrap() captura
    -- callback + is_expr=true; tab_handler() deve chamar o callback e,
    -- por ser is_expr=true, retornar o resultado DELE (nao ''), batendo
    -- com a semantica do Vimscript: `s:tab_fallback_is_expr ? result : ''`.
    vim.keymap.set('i', '<Tab>', function() return 'from-callback' end, { expr = true })
    keymaps.setup_tab_wrap()
    assert.are.equal('from-callback', keymaps.tab_handler())
    vim.keymap.del('i', '<Tab>')
  end)

  it("sem sugestao visivel, com mapeamento NAO-<expr> baseado em callback Lua: nao retorna o resultado do callback", function()
    -- Simula um mapeamento de <Tab> baseado em callback Lua que NAO e
    -- <expr> (ex: `vim.keymap.set('i', '<Tab>', function() ... end)` sem
    -- { expr = true }). setup_tab_wrap() captura callback + is_expr=false;
    -- tab_handler() NAO pode retornar o resultado do callback nesse caso
    -- (ele nao foi desenhado pra ser usado como valor de expr map e
    -- vazaria texto pro buffer) -- precisa retornar '' como qualquer outro
    -- fallback nao-expr. Distingue o fix (gate por is_expr) do bug antigo
    -- (return incondicional de tab_fallback.callback()).
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

  it("limpa a sugestao visivel e nao injeta nada no buffer", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foo' })
    vim.fn.cursor(1, 3)
    ghost_text.show_suggestion({ 'bar' })
    assert.is_true(ghost_text.is_visible())
    assert.are.equal('', keymaps.dismiss())
    assert.is_false(ghost_text.is_visible())
  end)

  it("sem sugestao visivel e' inofensivo", function()
    assert.is_false(ghost_text.is_visible())
    assert.are.equal('', keymaps.dismiss())
    assert.is_false(ghost_text.is_visible())
  end)

  -- Regressao da causa raiz: o plugin nao pode mais sequestrar o <Esc>.
  -- Antes, com sugestao visivel, o wrap devolvia '' e o usuario ficava preso
  -- no insert mode -- as teclas seguintes viravam texto no buffer. O unico
  -- caminho pra esse sequestro eram estas duas funcoes; sem elas, <Esc> e'
  -- so <Esc> e a sugestao sai pelo autocmd InsertLeavePre.
  it("nao expoe mais o wrap de <Esc>", function()
    assert.is_nil(keymaps.setup_esc_wrap)
    assert.is_nil(keymaps.esc_handler)
  end)
end)

describe("vim-ai-autocomplete.keymaps.complete_model_names", function()
  it("filtra pelo prefixo literal (nao regex)", function()
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
  it("com 2+ modelos ativos, registra ,pr e o comando VimAiAutocompleteModel", function()
    keymaps.setup_provider_toggle({ { name = 'a' }, { name = 'b' } })
    local map = vim.fn.maparg('<leader>pr', 'n', false, true)
    assert.is_not_nil(map.callback)
    assert.is_not_nil(vim.fn.exists(':VimAiAutocompleteModel'))
  end)

  it("com so 1 modelo ativo, nao registra ,pr", function()
    vim.keymap.del('n', '<leader>pr', { buffer = false })
    local ok = pcall(vim.keymap.del, 'n', '<leader>pr')
    keymaps.setup_provider_toggle({ { name = 'a' } })
    local map = vim.fn.maparg('<leader>pr', 'n', false, true)
    assert.are.equal('', map.lhs or '')
  end)
end)

describe("vim-ai-autocomplete.keymaps.open_model_picker", function()
  it("chama vim.ui.select com os nomes dos modelos ativos e seleciona o escolhido", function()
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
