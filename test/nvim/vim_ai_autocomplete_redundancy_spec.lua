local redundancy = require('vim-ai-autocomplete.redundancy')

describe("vim-ai-autocomplete.redundancy.count_redundant_after_chars", function()
  it("the suggestion closes the parenthesis opened before it -> the real ')' becomes redundant", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars('def sum(', 'a, b):\n    return a + b', ')'))
  end)

  it("the suggestion closes nothing opened before it -> nothing redundant", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo', 'bar', ')'))
  end)

  it('"after" does not start with a closer -> plays it safe, returns 0', function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def sum(', 'a, b)', 'not_a_closer'))
  end)

  it("several levels closed by the suggestion", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('foo([', '])', '])'))
  end)

  it("the suggestion opens and closes its own parenthesis -> leaves what already existed alone", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo(', 'bar(1, 2)', ')'))
  end)

  it("the suggestion closes the double quote opened before it -> the real quote becomes redundant", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars('name = "', 'John"', '"'))
  end)

  it("the suggestion closes the single quote opened before it", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars("name = '", "John'", "'"))
  end)

  it('mixes parentheses and quotes -- print("|") with a suggestion closing both', function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('print("', 'hi")', '")'))
  end)

  it("a quote inside the suggestion that closes NOTHING opened before -> leaves it alone", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo(', '"bar"', ')'))
  end)

  -- Cursor BEFORE the opening bracket itself (fix 2026-07-21, commit a435b21
  -- on the Vim side): depth_before == 0, and the untouched empty pair in
  -- "after" is left orphaned when the suggestion writes its own complete
  -- version of the pair.
  it("cursor before the opening bracket, suggestion writes its own pair -> the original empty pair becomes redundant", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('def quicksort', '(arr):', '()'))
  end)

  it("same case with a square bracket", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('items', '[x, y]', '[]'))
  end)

  it('"after" is not really an empty pair (there is content between the two) -> leaves it alone', function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def quicksort', '(arr):', '(x)'))
  end)

  it("the suggestion does not use that kind of bracket -> plays it safe, returns 0", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def quicksort', 'pass', '()'))
  end)
end)

describe("vim-ai-autocomplete.redundancy.compute_text_overlap_length", function()
  it("finds the longest overlap between the end of the suggestion and the start of 'after'", function()
    assert.are.equal(2, redundancy.compute_text_overlap_length({ 'foo()' }, '()bar'))
  end)

  it("no overlap -> 0", function()
    assert.are.equal(0, redundancy.compute_text_overlap_length({ 'foo' }, 'bar'))
  end)

  it("empty lines -> 0", function()
    assert.are.equal(0, redundancy.compute_text_overlap_length({}, 'bar'))
  end)
end)

describe("vim-ai-autocomplete.redundancy.adjust_suggestion_lines", function()
  it("python filetype, context ends in ':' -> line break plus indentation on the first line", function()
    local lines = redundancy.adjust_suggestion_lines({ 'if x:', '    pass' }, 'def foo():', 'python', 4, true)
    assert.are.same({ '', '    if x:', '    pass' }, lines)
  end)

  it("non-python -> leaves it alone", function()
    local lines = redundancy.adjust_suggestion_lines({ 'if x:' }, 'def foo():', 'javascript', 4, true)
    assert.are.same({ 'if x:' }, lines)
  end)

  it("context does not end in ':' -> leaves it alone", function()
    local lines = redundancy.adjust_suggestion_lines({ 'x = 1' }, 'foo', 'python', 4, true)
    assert.are.same({ 'x = 1' }, lines)
  end)

  it("it already came with a line break of its own -> leaves it alone", function()
    local lines = redundancy.adjust_suggestion_lines({ '', 'pass' }, 'def foo():', 'python', 4, true)
    assert.are.same({ '', 'pass' }, lines)
  end)
end)

describe("vim-ai-autocomplete.redundancy.split_display_tail", function()
  -- The final text on accept, the way ghost_text.insert_accepted_lines builds
  -- it: suggestion plus whatever is left of "after" once the redundant
  -- characters have been discarded.
  local function accepted(lines, after, ra)
    return table.concat(lines, '\n') .. after:sub(ra + 1)
  end

  it("the suggestion ends exactly with the real ')' -> trims the tail, discards nothing", function()
    local lines, ra = redundancy.split_display_tail({ 'Continuous Integration)' }, ')', 1)
    assert.are.same({ 'Continuous Integration' }, lines)
    assert.are.equal(0, ra)
  end)

  it('print("|") -- trims the \'")\' from the suggestion and keeps the real ones', function()
    local lines, ra = redundancy.split_display_tail({ 'hi")' }, '")', 2)
    assert.are.same({ 'hi' }, lines)
    assert.are.equal(0, ra)
  end)

  it("a closer in the MIDDLE of the suggestion -> does NOT trim (trimming the tail would produce wrong text)", function()
    local lines, ra = redundancy.split_display_tail({ 'x) { return; }' }, ')', 1)
    assert.are.same({ 'x) { return; }' }, lines)
    assert.are.equal(1, ra)
  end)

  it("partial trim: only part of what would be discarded matches", function()
    local lines, ra = redundancy.split_display_tail({ 'x)' }, '")', 2)
    assert.are.same({ 'x' }, lines)
    assert.are.equal(1, ra)
  end)

  it("redundant_after of zero -> leaves it alone", function()
    local lines, ra = redundancy.split_display_tail({ 'foo' }, ')', 0)
    assert.are.same({ 'foo' }, lines)
    assert.are.equal(0, ra)
  end)

  it("multi-line suggestion -> trims only the last line", function()
    local lines, ra = redundancy.split_display_tail({ 'a,', '    b)' }, ')', 1)
    assert.are.same({ 'a,', '    b' }, lines)
    assert.are.equal(0, ra)
  end)

  it("empty lines -> leaves it alone", function()
    local lines, ra = redundancy.split_display_tail({}, ')', 1)
    assert.are.same({}, lines)
    assert.are.equal(1, ra)
  end)

  it("the whole suggestion is just the redundant part -> nothing to show", function()
    local lines, ra = redundancy.split_display_tail({ ')' }, ')', 1)
    assert.are.same({}, lines)
    assert.are.equal(0, ra)
  end)

  it("a tail longer than the suggestion does not match, but the shorter tail still does", function()
    -- keep=0 would ask for the '")' tail (2 chars) against a 1-char
    -- suggestion -- no match. keep=1 asks for just ')', which does match: the
    -- real '"' stays discarded and the whole suggestion becomes redundant,
    -- leaving nothing to display.
    local lines, ra = redundancy.split_display_tail({ ')' }, '")', 2)
    assert.are.same({}, lines)
    assert.are.equal(1, ra)
  end)

  it("the suggestion ends with no suffix of what would be discarded -> does not trim", function()
    local lines, ra = redundancy.split_display_tail({ 'x' }, '")', 2)
    assert.are.same({ 'x' }, lines)
    assert.are.equal(2, ra)
  end)

  it("INVARIANT: the final accepted text is identical with and without the trim", function()
    local cases = {
      { { 'Continuous Integration)' }, ')', 1 },
      { { 'hi")' }, '")', 2 },
      { { 'x) { return; }' }, ')', 1 },
      { { 'x)' }, '")', 2 },
      { { 'a,', '    b)' }, ')', 1 },
      { { ')' }, ')', 1 },
      { { ')' }, '")', 2 },
      { { 'foo' }, ')', 0 },
    }
    for _, c in ipairs(cases) do
      local lines, ra = redundancy.split_display_tail(c[1], c[2], c[3])
      assert.are.equal(accepted(c[1], c[2], c[3]), accepted(lines, c[2], ra))
    end
  end)
end)
