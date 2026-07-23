local context = require('vim-ai-autocomplete.context')

describe("vim-ai-autocomplete.context.split_lines_at_cursor", function()
  it("corta a linha atual na coluna do cursor -- nao entra inteira em nenhum lado", function()
    local before, after = context.split_lines_at_cursor({ 'linha -1' }, 'def soma()', 10, { 'linha +1' })
    assert.are.same({ 'linha -1', 'def soma(' }, before)
    assert.are.same({ ')', 'linha +1' }, after)
  end)

  it("col=1: nada antes na linha atual", function()
    local before, after = context.split_lines_at_cursor({}, 'abc', 1, {})
    assert.are.same({ '' }, before)
    assert.are.same({ 'abc' }, after)
  end)
end)

describe("vim-ai-autocomplete.context.build_context", function()
  it("junta as linhas com quebra de linha, sem truncar se cabe no budget", function()
    local ctx = context.build_context({ 'a', 'b' }, { 'c', 'd' }, 1000)
    assert.are.equal('a\nb', ctx.before)
    assert.are.equal('c\nd', ctx.after)
  end)

  it("trunca 75/25 quando excede o budget", function()
    local before_lines = { string.rep('x', 100) }
    local after_lines = { string.rep('y', 100) }
    local ctx = context.build_context(before_lines, after_lines, 40)
    assert.are.equal(30, #ctx.before)
    assert.are.equal(10, #ctx.after)
    assert.are.equal(string.rep('x', 30), ctx.before)
    assert.are.equal(string.rep('y', 10), ctx.after)
  end)
end)

describe("vim-ai-autocomplete.context.treesitter_scope_start_line", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("acha a primeira linha da funcao que contem o cursor (Python)", function()
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'def outer():',
      '    x = 1',
      '    def inner():',
      '        return x',
      '    return inner',
    })
    vim.api.nvim_set_current_buf(buf)
    -- get_parser e lazy: constroi a LanguageTree sem carregar o .so, entao
    -- so ele sozinho NAO prova que o parser existe (falha so no parse()).
    -- language.add carrega a .so de fato -- se nao houver parser python
    -- instalado neste ambiente (ex: XDG isolado dos testes), pula com pending.
    local ok, added = pcall(vim.treesitter.language.add, 'python')
    if not ok or not added then
      pending('parser python indisponivel neste ambiente de teste')
      return
    end
    local start_line = context.treesitter_scope_start_line(buf, 4, 9) -- dentro de inner()
    assert.are.equal(3, start_line)
  end)

  it("sem parser disponivel para a filetype -> nil (fallback pro corte por linhas)", function()
    vim.bo[buf].filetype = 'nao-existe-essa-linguagem'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'qualquer coisa' })
    vim.api.nvim_set_current_buf(buf)
    assert.is_nil(context.treesitter_scope_start_line(buf, 1, 1))
  end)
end)

describe("vim-ai-autocomplete.context.build_related_definitions_section", function()
  it("lista vazia -> string vazia", function()
    assert.are.equal('', context.build_related_definitions_section({}, 5))
  end)
end)
