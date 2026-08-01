local M = {}

local PAIRS = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local CLOSERS = ')]}"\'`'
local QUOTES = '"\'`'

-- g:AutoPairs (Vim side) closes (){}[] AND single/double/back quotes --
-- brackets are ASYMMETRIC (they really nest), quotes are SYMMETRIC (they
-- alternate: if the top of the stack already is that same quote it closes,
-- otherwise it opens).
local function advance_bracket_stack(stack, text)
  for _, char in ipairs(vim.fn.split(text, '\\zs')) do
    if QUOTES:find(char, 1, true) then
      if #stack > 0 and stack[#stack] == char then
        table.remove(stack)
      else
        table.insert(stack, char)
      end
    elseif PAIRS[char] then
      table.insert(stack, char)
    elseif CLOSERS:find(char, 1, true) and #stack > 0 and PAIRS[stack[#stack]] == char then
      table.remove(stack)
    end
  end
  return stack
end

-- Covers the case where the cursor sits BEFORE the opening bracket itself
-- (not INSIDE the pair auto-pairs already opened) -- "before" has no pending
-- bracket/quote (depth_before == 0), so the structural computation never
-- finds anything to close, and the untouched empty pair in "after" (e.g. the
-- "()" from auto-pairs) does not match the end of the suggestion textually.
-- The suggestion, unaware that this empty pair exists, writes its OWN
-- complete version of the pair -- leaving the original empty pair orphaned at
-- the end. Only discards when the suggestion does USE that same kind of
-- bracket/quote somewhere.
function M.count_leading_trivial_pair_redundancy(suggestion_text, after_text)
  if #after_text < 2 then
    return 0
  end
  local opener = after_text:sub(1, 1)
  local closer = PAIRS[opener]
  if not closer then
    if QUOTES:find(opener, 1, true) then
      closer = opener
    else
      return 0
    end
  end
  if after_text:sub(2, 2) ~= closer then
    return 0
  end
  if suggestion_text:find(opener, 1, true) then
    return 2
  end
  return 0
end

-- Covers STRUCTURAL overlap: when the suggestion closes, with its own text, a
-- bracket/brace/quote that was already open BEFORE the cursor, the real
-- closing character sitting in "after" is left orphaned. Returns how many
-- characters from the START of "after" must be discarded on accept.
function M.count_redundant_after_chars(before_text, suggestion_text, after_text)
  local stack = advance_bracket_stack({}, before_text)
  local depth_before = #stack
  stack = advance_bracket_stack(stack, suggestion_text)
  local redundant = math.max(0, depth_before - #stack)
  if redundant > 0 then
    -- only discards when "after" really does start with that many closing
    -- characters -- otherwise it might not be the same bracket/quote, and it
    -- is better not to risk deleting something that is not obviously
    -- redundant.
    local n = 0
    while n < redundant and n < #after_text do
      local char = after_text:sub(n + 1, n + 1)
      if CLOSERS:find(char, 1, true) or QUOTES:find(char, 1, true) then
        n = n + 1
      else
        break
      end
    end
    return n
  end
  return M.count_leading_trivial_pair_redundancy(suggestion_text, after_text)
end

-- Finds the longest overlap between the END of the suggestion and the START
-- of the "after" text (whatever is left once structural redundancy has been
-- accounted for -- see request.lua). It only COMPUTES the length -- it does
-- NOT trim the suggestion (both sources of redundancy ADD UP into a single
-- redundant_after, with the same visual treatment).
function M.compute_text_overlap_length(lines, after_text)
  if #lines == 0 or after_text == '' then
    return 0
  end
  local suggestion_text = table.concat(lines, '\n')
  local max_check = math.min(#suggestion_text, #after_text)
  for n = max_check, 1, -1 do
    local suffix = suggestion_text:sub(-n)
    local prefix = after_text:sub(1, n)
    if suffix == prefix then
      return n
    end
  end
  return 0
end

-- Trims from the END of the DISPLAYED suggestion the characters that already
-- exist, identical, in the buffer right after the cursor -- so the screen
-- shows exactly the final text (a single ')') instead of the suggestion's
-- ')' plus the real one struck through. Ghost text is inline virtual text:
-- every one of its characters pushes the real line to the right, so showing
-- the closing character twice moved the real ')' away from the cursor and
-- made the line reflow on every keystroke (reported while writing markdown,
-- where suggestions are long and arrive on every keystroke).
--
-- It only trims when the suggestion ENDS with those characters. A closing
-- character in the MIDDLE of the suggestion (e.g. 'x) { return; }' closing an
-- earlier '(') keeps being handled by discarding the real character, because
-- trimming the tail there would produce wrong text. Returns the adjusted
-- (lines, redundant_after) -- the text produced on accept is identical to
-- what it was before the trim, only what is displayed changes.
function M.split_display_tail(lines, after_text, redundant_after)
  redundant_after = redundant_after or 0
  if #lines == 0 or redundant_after <= 0 then
    return lines, redundant_after
  end
  local suggestion_text = table.concat(lines, '\n')
  -- keep = how many real characters stay discarded. Searches from the largest
  -- trim (keep 0) down to the smallest, stopping at the first match.
  for keep = 0, redundant_after - 1 do
    local tail = after_text:sub(keep + 1, redundant_after)
    if #tail <= #suggestion_text and suggestion_text:sub(-#tail) == tail then
      local cut = suggestion_text:sub(1, #suggestion_text - #tail)
      if cut == '' then
        return {}, keep
      end
      return vim.split(cut, '\n', { plain = true }), keep
    end
  end
  return lines, redundant_after
end

-- Some models treat the response as a literal continuation of bytes: when the
-- context ends in ":" (a Python block opener), the first line of the
-- suggestion comes with no line break and no indentation of its own -- same
-- finding as on the Vim side (confirmed with gemini-3.1-flash-lite).
function M.adjust_suggestion_lines(lines, current_line_before_cursor, filetype, shiftwidth, expandtab)
  if #lines == 0 or filetype ~= 'python' then
    return lines
  end
  local trimmed = current_line_before_cursor:gsub('%s*$', '')
  if not trimmed:match(':$') then
    return lines
  end
  if lines[1] == '' then
    -- it already came with a line break of its own -- leave it alone
    return lines
  end
  local indent_str = expandtab and string.rep(' ', shiftwidth) or '\t'
  local first_line_stripped = lines[1]:gsub('^%s*', '')
  local result = { '', indent_str .. first_line_stripped }
  for i = 2, #lines do
    table.insert(result, lines[i])
  end
  return result
end

return M
