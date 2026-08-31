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
      pending('python parser unavailable in this test environment')
      return
    end
    local start_line = context.treesitter_scope_start_line(buf, 4, 9) -- inside inner()
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
      pending('ruby parser unavailable in this test environment')
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
      pending('elixir parser unavailable in this test environment')
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
      pending('elixir parser unavailable in this test environment')
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

describe("vim-ai-autocomplete.context.collect_definitions", function()
  -- The no-LSP fallback for the Treesitter scope cut. Neovim compensates for
  -- the cut through LSP, but a buffer with no client attached used to get the
  -- cut and nothing back: measured on the Vim side (same shape) as 0/6 on
  -- completing a call to a helper defined earlier in the file, against 6/6
  -- with the neighbours restored. Mirrors CollectDefinitions in
  -- autoload/vim_ai_autocomplete.vim, case for case.
  it("collects the definitions that come before the scope", function()
    local lines = { 'def helper(raw):', '    return raw.strip()', '', 'def target(x):', '    y = ' }
    local defs = context.collect_definitions(lines, 4, 3)
    assert.are.same({ 'def helper(raw):\n    return raw.strip()' }, defs)
  end)

  it("never repeats the enclosing scope (it is already in BEFORE)", function()
    local defs = context.collect_definitions({ 'def a():', '    pass', '', 'def b():', '    ' }, 4, 3)
    assert.are.equal(1, #defs)
    assert.is_truthy(defs[1]:find('def a', 1, true))
    assert.is_nil(defs[1]:find('def b', 1, true))
  end)

  it("caps the body at max_body_lines", function()
    local lines = { 'def big():', '    one', '    two', '    three', '    four', '', 'def here():', '    ' }
    assert.are.same({ 'def big():\n    one\n    two' }, context.collect_definitions(lines, 7, 2))
  end)

  it("a blank line ends the body before the cap", function()
    local lines = { 'def small():', '    only', '', 'def here():', '    ' }
    assert.are.same({ 'def small():\n    only' }, context.collect_definitions(lines, 4, 5))
  end)

  it("a following definition ends the body (never swallows the next one)", function()
    local lines = { 'def a():', '    x = 1', 'def b():', '    y = 2', 'def here():', '    ' }
    assert.are.same({ 'def a():\n    x = 1', 'def b():\n    y = 2' }, context.collect_definitions(lines, 5, 5))
  end)

  it("no enclosing scope -> nothing (the whole file is already the context)", function()
    assert.are.same({}, context.collect_definitions({ 'def a():', '    pass', 'x = ' }, 0, 3))
  end)

  it("strips trailing whitespace (it only costs tokens)", function()
    local lines = { 'def a():   ', '    pass  ', '', 'def here():', '    ' }
    assert.are.same({ 'def a():\n    pass' }, context.collect_definitions(lines, 4, 3))
  end)

  it("empty input is harmless", function()
    assert.are.same({}, context.collect_definitions({}, 3, 3))
  end)

  it("a word merely containing a keyword is not a definition", function()
    assert.are.same({}, context.collect_definitions({ 'defaults = {}', 'deferred = 1', 'def here():', '  ' }, 3, 3))
  end)

  it("recognises the same languages the Vim side does", function()
    for _, opener in ipairs({ 'function foo() {', 'func main() {', 'impl Stack {', 'defmodule Foo do', 'export async function go() {' }) do
      local defs = context.collect_definitions({ opener, '  body', '', 'def here():', '  ' }, 4, 3)
      assert.are.equal(1, #defs, 'should have recognised: ' .. opener)
    end
  end)
end)

describe("vim-ai-autocomplete.context.wrap_related_definitions", function()
  it("formats the section exactly like the Vim side's BuildRelatedDefinitionsSection", function()
    assert.are.equal("\n\nRELATED DEFINITIONS:\ndef a():\n---\ndef b():",
      context.wrap_related_definitions({ 'def a():', 'def b():' }))
  end)

  it("nothing to say -> empty string, no dangling header", function()
    assert.are.equal('', context.wrap_related_definitions({}))
  end)
end)

describe("vim-ai-autocomplete.context.heuristic_scope_start_line", function()
  -- Mirrors UN-065a..j on the Vim side, case for case. This is not just a
  -- no-Treesitter fallback: measured 2026-08-31, treesitter_scope_start_line
  -- returns nil whenever the cursor line is INCOMPLETE ("cleaned = " with
  -- nothing after it) -- the only state this plugin ever runs in -- so
  -- without the heuristic the cut silently never happened while typing.
  it("cursor inside a function body -> the def line", function()
    assert.are.equal(3, context.heuristic_scope_start_line(
      { 'import os', '', 'def fibonacci(n):', '    if n <= 1:', '        return n', '    ' }))
  end)

  it("cursor ON the definition itself -> that same line", function()
    assert.are.equal(5, context.heuristic_scope_start_line(
      { '# comment', 'def other():', '    pass', '', 'class Stack:' }))
  end)

  it("nested method -> the INNERMOST definition, not the class", function()
    assert.are.equal(2, context.heuristic_scope_start_line(
      { 'class Stack:', '    def push(self, item):', '        self.items.append(item)', '        ' }))
  end)

  it("top level, no enclosing definition -> 0 (fall back to the anchor)", function()
    assert.are.equal(0, context.heuristic_scope_start_line({ 'import os', 'x = 1', 'y = ' }))
  end)

  it("blank lines on the way back are skipped", function()
    assert.are.equal(1, context.heuristic_scope_start_line({ 'def outer():', '', '', '    body' }))
  end)

  it("a plain block opener is NOT a scope (only definitions are)", function()
    assert.are.equal(1, context.heuristic_scope_start_line({ 'def f():', '    if cond:', '        ' }))
  end)

  it("recognises other languages: JS, Go, Rust, Elixir, Ruby", function()
    assert.are.equal(1, context.heuristic_scope_start_line({ 'function foo() {', '  ' }))
    assert.are.equal(1, context.heuristic_scope_start_line({ 'func main() {', '\t' }))
    assert.are.equal(1, context.heuristic_scope_start_line({ 'impl Stack {', '    ' }))
    assert.are.equal(1, context.heuristic_scope_start_line({ 'defmodule Foo do', '  ' }))
    assert.are.equal(1, context.heuristic_scope_start_line({ '  def bar(x)', '    ' }))
  end)

  it("modifiers before the keyword do not hide the definition", function()
    assert.are.equal(1, context.heuristic_scope_start_line({ 'export async function go() {', '  ' }))
    assert.are.equal(1, context.heuristic_scope_start_line({ '  private static class Inner {', '    ' }))
  end)

  it("a word merely containing a keyword is not a definition", function()
    assert.are.equal(0, context.heuristic_scope_start_line({ 'defaults = {}', 'x = ' }))
  end)

  it("empty input and a single line are harmless", function()
    assert.are.equal(0, context.heuristic_scope_start_line({}))
    assert.are.equal(0, context.heuristic_scope_start_line({ 'x = 1' }))
  end)

  it("answers where Treesitter gives up: an incomplete assignment line", function()
    -- the regression this exists for -- see the describe() comment
    assert.are.equal(2, context.heuristic_scope_start_line(
      { 'class Registry:', '    def slugify(self, raw):', '        cleaned = ' }))
  end)
end)
