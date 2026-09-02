local ghost_text = require('vim-ai-autocomplete.ghost_text')

describe("vim-ai-autocomplete.ghost_text empty first line", function()
  -- Mirror of the Vim-side finding (bare vim -u NONE renders an empty-text
  -- inline prop as three U+FFFD): an empty first line has nothing to render
  -- inline, so no inline virt_text extmark is created -- only the virt_lines
  -- below. Accept still receives the full lines including the empty first.
  it("creates no inline virt_text when the first line is empty", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def fibonacci(n):' })
    vim.fn.cursor(1, 18)
    local gt = require('vim-ai-autocomplete.ghost_text')
    gt.show_suggestion({ '', '    pass' })
    local ns = vim.api.nvim_create_namespace('vim_ai_autocomplete')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      local vt = mark[4].virt_text
      if vt then
        assert.are_not.equal('', vt[1][1])
      end
    end
    assert.is_true(gt.is_visible())
    assert.are.same({ '', '    pass' }, gt.current_suggestion())
    gt.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("vim-ai-autocomplete.ghost_text", function()
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

  it("show_suggestion makes the suggestion visible", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'x):', '    return x' }, 0)
    assert.is_true(ghost_text.is_visible())
    assert.are.same({ 'x):', '    return x' }, ghost_text.current_suggestion())
  end)

  it("clear_suggestion hides the suggestion", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'x)' }, 0)
    ghost_text.clear_suggestion()
    assert.is_false(ghost_text.is_visible())
  end)

  it("accept writes the suggestion into the buffer, discarding the redundant part", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def quicksort()' })
    vim.api.nvim_win_set_cursor(0, { 1, 13 }) -- antes do "("
    ghost_text.show_suggestion({ '(arr):' }, 2)
    ghost_text.accept()
    vim.wait(200, function() return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'def quicksort(arr):' end, 10)
    assert.are.same({ 'def quicksort(arr):' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("accept with a multi-line suggestion", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def foo()' })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    ghost_text.show_suggestion({ 'x):', '    return x' }, 1)
    ghost_text.accept()
    vim.wait(200, function() return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 2 end, 10)
    assert.are.same({ 'def foo(x):', '    return x' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)

describe("vim-ai-autocomplete.ghost_text alternatives cycling (issue #3)", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum(' })
    vim.fn.cursor(1, 9)
  end)

  after_each(function()
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  local entries = {
    { lines = { 'a, b):' }, redundant_after = 1 },
    { lines = { '*args):' }, redundant_after = 0 },
    { lines = { 'x):', '    return x' }, redundant_after = 1 },
  }

  it("show_alternatives displays the first entry and tracks count/index", function()
    ghost_text.show_alternatives(entries)
    assert.is_true(ghost_text.is_visible())
    assert.are.same({ 'a, b):' }, ghost_text.current_suggestion())
    assert.are.equal(3, ghost_text.alternatives_count())
    assert.are.equal(1, ghost_text.alternatives_index())
  end)

  it("cycle(1) moves to the next entry, with that entry's own redundant_after", function()
    ghost_text.show_alternatives(entries)
    ghost_text.cycle(1)
    assert.are.same({ '*args):' }, ghost_text.current_suggestion())
    assert.are.equal(2, ghost_text.alternatives_index())
  end)

  it("cycling wraps around at both ends", function()
    ghost_text.show_alternatives(entries)
    ghost_text.cycle(-1)
    assert.are.equal(3, ghost_text.alternatives_index())
    ghost_text.cycle(1)
    assert.are.equal(1, ghost_text.alternatives_index())
  end)

  it("accept() after cycling inserts the CURRENTLY shown alternative", function()
    ghost_text.show_alternatives(entries)
    ghost_text.cycle(1)
    -- accept path: the state the accept reads must be the cycled entry
    assert.are.same({ '*args):' }, ghost_text.current_suggestion())
  end)

  it("append_alternative adds a lazily fetched entry and jumps to it", function()
    ghost_text.show_alternatives({ entries[1] })
    ghost_text.append_alternative(entries[2])
    assert.are.equal(2, ghost_text.alternatives_count())
    assert.are.equal(2, ghost_text.alternatives_index())
    assert.are.same({ '*args):' }, ghost_text.current_suggestion())
  end)

  it("cycle with no alternatives state is a no-op returning nil", function()
    ghost_text.show_suggestion({ 'plain' })
    assert.is_nil(ghost_text.cycle(1))
  end)

  it("clear_suggestion resets the alternatives state too", function()
    ghost_text.show_alternatives(entries)
    ghost_text.clear_suggestion()
    assert.are.equal(0, ghost_text.alternatives_count())
    assert.is_false(ghost_text.is_visible())
  end)

  it("show_suggestion (the single-suggestion path) leaves no stale alternatives behind", function()
    ghost_text.show_alternatives(entries)
    ghost_text.show_suggestion({ 'fresh' })
    assert.are.equal(0, ghost_text.alternatives_count())
    assert.are.same({ 'fresh' }, ghost_text.current_suggestion())
  end)
end)

describe("vim-ai-autocomplete.ghost_text pending marker (issue #4)", function()
  -- A transient end-of-line marker while a request is in flight: at the eol
  -- (never inline, so it shifts no buffer text), shown only after a short
  -- delay so fast requests never flicker, cleared on every exit path.
  local buf
  local ns = vim.api.nvim_create_namespace('vim_ai_autocomplete_pending')

  local function pending_marks()
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'def sum(' })
    vim.fn.cursor(1, 9)
  end)

  after_each(function()
    ghost_text.clear_pending()
    ghost_text.clear_suggestion()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("show_pending places an eol marker that shifts no text", function()
    ghost_text.show_pending()
    local marks = pending_marks()
    assert.are.equal(1, #marks)
    assert.are.equal('eol', marks[1][4].virt_text_pos)
    assert.are.equal('def sum(', vim.fn.getline(1))
    assert.is_true(ghost_text.is_pending())
  end)

  it("clear_pending removes it and is idempotent", function()
    ghost_text.show_pending()
    ghost_text.clear_pending()
    ghost_text.clear_pending()
    assert.are.same({}, pending_marks())
    assert.is_false(ghost_text.is_pending())
  end)

  it("schedule_pending shows the marker only after the delay", function()
    ghost_text.schedule_pending(30)
    assert.are.same({}, pending_marks(), 'nothing yet')
    vim.wait(200, function() return ghost_text.is_pending() end, 10)
    assert.are.equal(1, #pending_marks())
  end)

  it("clear_pending before the delay cancels the scheduled marker (fast request: no flicker)", function()
    ghost_text.schedule_pending(30)
    ghost_text.clear_pending()
    vim.wait(120, function() return ghost_text.is_pending() end, 10)
    assert.are.same({}, pending_marks())
  end)

  it("show_suggestion clears the pending marker (the answer arrived)", function()
    ghost_text.show_pending()
    ghost_text.show_suggestion({ 'a, b)' })
    assert.are.same({}, pending_marks())
    assert.is_true(ghost_text.is_visible())
  end)
end)
