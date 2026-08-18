local context = require('vim-ai-autocomplete.context')

describe("vim-ai-autocomplete.context.split_lines_at_cursor", function()
  it("splits the current line at the cursor column -- it never goes in whole on either side", function()
    local before, after = context.split_lines_at_cursor({ 'line -1' }, 'def sum()', 9, { 'line +1' })
    assert.are.same({ 'line -1', 'def sum(' }, before)
    assert.are.same({ ')', 'line +1' }, after)
  end)

  it("col=1: nothing before it on the current line", function()
    local before, after = context.split_lines_at_cursor({}, 'abc', 1, {})
    assert.are.same({ '' }, before)
    assert.are.same({ 'abc' }, after)
  end)
end)

describe("vim-ai-autocomplete.context.build_context", function()
  it("joins the lines with a line break, without truncating when it fits the budget", function()
    local ctx = context.build_context({ 'a', 'b' }, { 'c', 'd' }, 1000)
    assert.are.equal('a\nb', ctx.before)
    assert.are.equal('c\nd', ctx.after)
  end)

  it("truncates 75/25 when it exceeds the budget", function()
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

  it("finds the first line of the function containing the cursor (Python)", function()
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'def outer():',
      '    x = 1',
      '    def inner():',
      '        return x',
      '    return inner',
    })
    vim.api.nvim_set_current_buf(buf)
    -- get_parser is lazy: it builds the LanguageTree without loading the .so,
    -- so on its own it does NOT prove the parser exists (it only fails at
    -- parse()). language.add really does load the .so -- when no python parser
    -- is installed in this environment (e.g. the tests' isolated XDG), skip
    -- with pending.
    local ok, added = pcall(vim.treesitter.language.add, 'python')
    if not ok or not added then
      pending('parser python indisponivel neste ambiente de teste')
      return
    end
    local start_line = context.treesitter_scope_start_line(buf, 4, 9) -- dentro de inner()
    assert.are.equal(3, start_line)
  end)

  -- tree-sitter-ruby names the nodes `method`/`class`, NOT
  -- `method_definition`/`class_definition` -- confirmed live on 2026-08-13:
  -- cursor inside `def bar` gives `binary <- body_statement <- method <-
  -- body_statement <- class <- program`. The old list silently never matched,
  -- so Ruby always fell back to the naive line cut.
  it("finds the first line of the method containing the cursor (Ruby)", function()
    vim.bo[buf].filetype = 'ruby'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'class Foo',
      '  def bar(x)',
      '    x + 1',
      '  end',
      'end',
    })
    vim.api.nvim_set_current_buf(buf)
    local ok, added = pcall(vim.treesitter.language.add, 'ruby')
    if not ok or not added then
      pending('parser ruby indisponivel neste ambiente de teste')
      return
    end
    local start_line = context.treesitter_scope_start_line(buf, 3, 5) -- inside bar()
    assert.are.equal(2, start_line)
  end)

  -- Elixir's grammar has no function_definition node at all: def/defmodule
  -- parse as a generic `call` node whose first child is the `def`/`defmodule`
  -- identifier -- confirmed live on 2026-08-13: cursor inside `def bar` gives
  -- `binary_operator <- do_block <- call <- do_block <- call <- source`. A
  -- plain call like Enum.map(...) must NOT count as a scope.
  it("finds the first line of the def containing the cursor (Elixir)", function()
    vim.bo[buf].filetype = 'elixir'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'defmodule Foo do',
      '  def bar(x) do',
      '    x + 1',
      '  end',
      'end',
    })
    vim.api.nvim_set_current_buf(buf)
    local ok, added = pcall(vim.treesitter.language.add, 'elixir')
    if not ok or not added then
      pending('parser elixir indisponivel neste ambiente de teste')
      return
    end
    local start_line = context.treesitter_scope_start_line(buf, 3, 5) -- inside bar()
    assert.are.equal(2, start_line)
  end)

  it("a plain Elixir call (Enum.map) does NOT count as a scope", function()
    vim.bo[buf].filetype = 'elixir'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'Enum.map([1, 2], fn x ->',
      '  x + 1',
      'end)',
    })
    vim.api.nvim_set_current_buf(buf)
    local ok, added = pcall(vim.treesitter.language.add, 'elixir')
    if not ok or not added then
      pending('parser elixir indisponivel neste ambiente de teste')
      return
    end
    -- no def/defp/defmodule anywhere -> no scope, naive fallback (nil)
    assert.is_nil(context.treesitter_scope_start_line(buf, 2, 3))
  end)

  it("no parser available for the filetype -> nil (falls back to the line-based cut)", function()
    vim.bo[buf].filetype = 'no-such-language'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'qualquer coisa' })
    vim.api.nvim_set_current_buf(buf)
    assert.is_nil(context.treesitter_scope_start_line(buf, 1, 1))
  end)
end)

describe("vim-ai-autocomplete.context.build_related_definitions_section", function()
  it("empty list -> empty string", function()
    assert.are.equal('', context.build_related_definitions_section({}, 5))
  end)
end)
