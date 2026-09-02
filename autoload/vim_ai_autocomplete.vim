scriptencoding utf-8
" Default that preserves exactly what the plugin does today (Gemini plus
" Claude, same model_ids) when the user does not set g:vim_ai_autocomplete_models.
function! vim_ai_autocomplete#DefaultModels() abort
  return [
        \ {'name': 'gemini', 'family': 'gemini', 'model_id': 'gemini-3.1-flash-lite', 'api_key_env': 'GEMINI_API_KEY'},
        \ {'name': 'claude', 'family': 'anthropic', 'model_id': 'claude-sonnet-4-5-20250929', 'api_key_env': 'ANTHROPIC_API_KEY'},
        \ ]
endfunction

" Filters the raw list (from g:vim_ai_autocomplete_models, or the default)
" down to the models whose api_key_env is actually set and non-empty in the
" environment -- that is the "active" list feeding the ,pr / :VimAiAutocompleteModel
" rotation. Duplicate names: only the FIRST occurrence gets in
" (deterministic), the rest are ignored and reported in "warnings" (the
" function is pure -- the caller decides what to do with them, e.g. echoerr).
function! vim_ai_autocomplete#ResolveActiveModels(models) abort
  let active = []
  let warnings = []
  let seen_names = {}
  for model in a:models
    if has_key(seen_names, model.name)
      call add(warnings, 'duplicate model "' . model.name . '" in g:vim_ai_autocomplete_models -- ignoring')
      continue
    endif
    let seen_names[model.name] = 1
    let key_value = getenv(model.api_key_env)
    if type(key_value) == v:t_string && !empty(key_value)
      call add(active, model)
    endif
  endfor
  return [active, warnings]
endfunction

function! vim_ai_autocomplete#FindModelByName(models, name) abort
  for model in a:models
    if model.name ==# a:name
      return model
    endif
  endfor
  return v:null
endfunction

" Public entry point: reads g:vim_ai_autocomplete_models (or the default when
" the user configured nothing), resolves the active list, and reports any
" invalid-config warning (echohl WarningMsg + echomsg, NOT echoerr -- echoerr
" throws an exception and aborts the function before "return active",
" breaking the whole completion on every keystroke whenever a warning exists,
" e.g. a duplicate name). ResolveActiveModels() stays pure; the side effect
" lives only here.
function! vim_ai_autocomplete#ActiveModels() abort
  let models = get(g:, 'vim_ai_autocomplete_models', vim_ai_autocomplete#DefaultModels())
  let [active, warnings] = vim_ai_autocomplete#ResolveActiveModels(models)
  for warning in warnings
    echohl WarningMsg
    echomsg 'vim-ai-autocomplete: ' . warning
    echohl None
  endfor
  return active
endfunction

" Generalises the old ResolveProvider(has_gemini, has_claude): decides the
" default model and whether to warn or hard-stop, starting from the ACTIVE
" model list (already filtered by ResolveActiveModels). all_models is only
" used to list the configured api_key_env names in the error message (which
" ones are active does not matter -- the user wants to know what to set up).
function! vim_ai_autocomplete#ResolveDefaultModel(all_models, active_models) abort
  if empty(a:active_models)
    let env_names = map(copy(a:all_models), 'v:val.api_key_env')
    return [v:null, 'error', 'no API key found (' . join(env_names, ' nor ') . ') -- configure at least one']
  endif
  if len(a:active_models) == 1
    let name = a:active_models[0].name
    return [name, 'warn', printf('only %s available -- the ,pr toggle is disabled', name)]
  endif
  return [a:active_models[0].name, v:null, v:null]
endfunction

" The Vim-side answer to Neovim's Treesitter scope cut (issue #5). Measured
" there: feeding the whole file as context made claude-haiku complete some
" OTHER unfinished function 2/3 of the time, while the enclosing scope alone
" gave 0/3 -- the extra context is noise, and the weaker the model the harder
" it is pulled toward the first unfinished thing it sees.
"
" Deliberately a heuristic, not a parser: walk backwards for the nearest line
" that both looks like a DEFINITION and is indented less than the cursor line
" (or the cursor line itself, when the cursor sits on the definition -- which
" is exactly the reported failure, "class Stack:" at end of file). Returns 0
" when nothing matches, and 0 means "keep the whole-file anchor", so a miss
" only ever costs context, never correctness.
"
" Only definitions count, never a plain block opener: `if cond:` opens a block
" but Treesitter does not treat it as a scope, so neither do we.
let s:definition_pattern = '\v^\s*%(%(export|public|private|protected|internal|static|final|abstract|async|local|pub|open)\s+)*%(def|defp|defmodule|defmacro|class|module|function|func|fn|impl|struct|interface|trait)>'

function! vim_ai_autocomplete#ScopeStartLine(lines) abort
  if len(a:lines) == 0
    return 0
  endif
  let last = len(a:lines)
  " the cursor line itself may BE the definition (cursor at the end of
  " "class Stack:") -- that is the innermost scope, nothing to walk back to.
  if a:lines[last - 1] =~# s:definition_pattern
    return last
  endif
  let cursor_indent = strlen(matchstr(a:lines[last - 1], '^\s*'))
  let i = last - 1
  while i >= 1
    let line = a:lines[i - 1]
    if line !~# '^\s*$'
      let line_indent = strlen(matchstr(line, '^\s*'))
      if line_indent < cursor_indent && line =~# s:definition_pattern
        return i
      endif
    endif
    let i -= 1
  endwhile
  return 0
endfunction

" The other half of the scope cut. Cutting at the enclosing definition also
" HIDES the rest of the file, and that is a real loss: measured with real
" claude-haiku calls, completing a call to a helper defined earlier in the
" file went from 6/6 correct (whole file) to 0/6 (scope only) -- the model
" reinvented the helper inline instead of calling it. Neovim compensates
" through LSP (context.lsp_related_definitions); Vim has no LSP here, so it
" rebuilds the same section from the buffer itself.
"
" Signature PLUS a few body lines, not the signature alone: measured over both
" scenarios, signature-only recovered just 3/6 and signature+docstring 1/6,
" while signature + 3 body lines scored 6/6 -- with the wrong-target rate
" staying at 0/6, which is what the cut was for. Bodies are cut at the first
" blank line or the next definition, so no unfinished body ever arrives whole
" enough to look like the thing being asked for.
function! vim_ai_autocomplete#CollectDefinitions(lines, scope_idx, max_body_lines) abort
  if a:scope_idx <= 0 || len(a:lines) == 0
    return []
  endif
  let out = []
  " strictly before the scope line: the enclosing definition itself is already
  " in BEFORE, and repeating it would only spend tokens
  let limit = a:scope_idx - 1
  let i = 0
  while i < limit
    if a:lines[i] =~# s:definition_pattern
      let chunk = [substitute(a:lines[i], '\s*$', '', '')]
      let j = i + 1
      while j < limit && len(chunk) <= a:max_body_lines
        let line = a:lines[j]
        if line =~# '^\s*$' || line =~# s:definition_pattern
          break
        endif
        call add(chunk, substitute(line, '\s*$', '', ''))
        let j += 1
      endwhile
      call add(out, join(chunk, "\n"))
    endif
    let i += 1
  endwhile
  return out
endfunction

" Byte-for-byte the same format Neovim builds in
" context.build_related_definitions_section, so swapping sides never changes
" what the model reads.
function! vim_ai_autocomplete#BuildRelatedDefinitionsSection(definitions) abort
  if len(a:definitions) == 0
    return ''
  endif
  return "\n\nRELATED DEFINITIONS:\n" . join(a:definitions, "\n---\n")
endfunction

" Everything that turns the BUFFER into the prompt context, in one place.
" Extracted from RequestCompletion() so the whole buffer -> prompt path can be
" tested against a real buffer with no network call -- the pure functions
" below were already covered, but nothing proved they were WIRED (and a fix
" that lands in an unwired function is the silent kind of regression).
"
" Returns the context the handler gets, plus raw_after: the text after the
" cursor exactly as it sits in the buffer, BEFORE the related-definitions
" section is appended. s:OnExit needs that raw form -- feeding it the prompt
" context instead would make CountRedundantAfterChars believe the buffer holds
" text it does not.
function! vim_ai_autocomplete#BuildRequestContext() abort
  " Anchored at line 1 (not a sliding cursor-100 window): prefix caches --
  " explicit on Anthropic, implicit on Gemini/DeepSeek -- only hit when the
  " prompt prefix repeats byte-for-byte, and a sliding window changes the
  " prefix on every new line. The 2000-line cap keeps the per-keystroke
  " getline+join cheap on huge files (beyond it, back to the window and
  " caching naturally stops paying).
  let anchor = line('.') <= 2000 ? 1 : max([1, line('.') - 100])
  " Prefer the enclosing definition, mirroring the Treesitter cut on the
  " Neovim side (issue #5): the whole file is noise, and the weaker the model
  " the harder it is pulled toward the first unfinished thing it sees.
  " ScopeStartLine gets a bounded window (500 lines back) so this stays cheap
  " per keystroke, and returns 0 when it finds nothing -- then the anchor
  " stands, so a miss only costs context, never correctness.
  let scope_window_start = max([1, line('.') - 500])
  let scope_window = getline(scope_window_start, line('.'))
  let scope_idx = vim_ai_autocomplete#ScopeStartLine(scope_window)
  let first = scope_idx > 0 ? scope_window_start + scope_idx - 1 : anchor
  let last = min([line('$'), line('.') + 20])
  let lines_before_full = getline(first, line('.') - 1)
  let lines_after_full = getline(line('.') + 1, last)
  let [lines_before, lines_after] = vim_ai_autocomplete#SplitLinesAtCursor(
        \ lines_before_full, getline('.'), col('.'), lines_after_full)
  let context = vim_ai_autocomplete#BuildContext(lines_before, lines_after, 16000)
  " the current line's before-part: the volatile half of the Anthropic cache
  " split (see BuildClaudeRequest); other families ignore it.
  let context.before_tail = col('.') > 1 ? strpart(getline('.'), 0, col('.') - 1) : ''
  let context.raw_after = context.after
  " the other half of the scope cut: give back the neighbours the cut hid,
  " as signature + a few body lines (see CollectDefinitions).
  let context.after = context.after . vim_ai_autocomplete#BuildRelatedDefinitionsSection(
        \ vim_ai_autocomplete#CollectDefinitions(scope_window, scope_idx, 3))
  return context
endfunction

" The CURRENT line (the one the cursor is really on) should never go in whole
" into either "before" or "after" -- it has to be split at the cursor column.
" Real finding (2026-07-20): without this, "def sum(" with the cursor between
" the parentheses auto-pairs had just inserted sent the WHOLE line ("def
" sum()") to BOTH sides of the FIM prompt, with no indication of where the
" cursor actually was -- the model, confused, went as far as generating
" "(a, b):\n    return a + b" from scratch, duplicating the opening
" parenthesis.
function! vim_ai_autocomplete#SplitLinesAtCursor(lines_before_full, current_line, col, lines_after_full) abort
  let before_part = a:col > 1 ? a:current_line[: a:col - 2] : ''
  let after_part = a:current_line[a:col - 1 :]
  return [a:lines_before_full + [before_part], [after_part] + a:lines_after_full]
endfunction

function! vim_ai_autocomplete#BuildContext(lines_before, lines_after, max_chars) abort
  let before = join(a:lines_before, "\n")
  let after = join(a:lines_after, "\n")
  let total = len(before) + len(after)
  if total > a:max_chars
    " more weight to the text BEFORE the cursor (75/25) -- same criterion as
    " the context_ratio of minuet-ai.nvim on the Neovim side
    let before_budget = float2nr(a:max_chars * 0.75)
    let after_budget = a:max_chars - before_budget
    let before = strcharpart(before, max([0, strchars(before) - before_budget]))
    let after = strcharpart(after, 0, after_budget)
  endif
  return {'before': before, 'after': after}
endfunction

" FIM-style prompt (fill-in-the-middle): we used to send only context.before,
" so the model had no way to know text already exists after the cursor (e.g.
" the ")" auto-pairs inserted when the parenthesis was opened) -- it produced
" a suggestion "blind", with a closing character of its own, and Accept() kept
" the real text after the cursor as well, duplicating it (real finding: "it
" pushes the character after it past the suggestion").
" Confirmed with a real call: WITHOUT the "AFTER THE CURSOR" block the model
" returns 'x):\n    return x * 2' for "def foo(" (closing its own
" parenthesis); WITH it, it returns just 'x, y' (no duplication). The
" instruction alone is not 100% reliable (another real test showed the model
" repeating the whole suffix 3/3 times) -- which is why
" ComputeTextOverlapLength() also exists as a post-processing safety net.
" One prompt for every family -- swapping engines must never change what the
" model reads (pinned by the engine-agnostic invariant test UN-006a).
let s:instruction_head = "Complete the following code. The cursor sits between the BEFORE text and the AFTER text, both of which already exist in the buffer. Reply ONLY with the text that should be inserted BETWEEN them -- do not repeat anything already present in BEFORE or AFTER, and do not complete any other unfinished code elsewhere in the file. No explanation, no markdown. Example: for BEFORE ending in \"foo(\" with AFTER \")\", a good reply is \"a, b)\" -- it writes the closer itself.\n\nBEFORE THE CURSOR:\n"

" Field finding 2026-08-26 (reproduced 6/6 with real calls): in a file full of
" unfinished stubs, with an empty AFTER, every model -- including claude-haiku
" -- completed the file's FIRST visible hole instead of continuing at the
" cursor. Quoting the exact last characters of BEFORE as a final anchor line
" measured 4/4 correct on gemini and deepseek in a real shootout (a <CURSOR>
" sentinel and DeepSeek's native FIM endpoint both failed: 1/2 wrong and 2/2
" empty). Character-based slicing, not bytes -- a byte cut could split a
" multibyte char and quote garbage.
function! s:AnchorLine(before) abort
  if empty(a:before)
    return ''
  endif
  let chars = strchars(a:before)
  let tail = chars > 20 ? strcharpart(a:before, chars - 20) : a:before
  return "\n\nYour completion must continue immediately after these exact characters: " . json_encode(tail)
endfunction

function! s:BuildFullPrompt(context) abort
  return s:instruction_head . a:context.before . "\n\nAFTER THE CURSOR:\n" . a:context.after . s:AnchorLine(a:context.before)
endfunction

" n (optional): how many candidates to ask for IN THIS request -- the cheap
" half of the hybrid strategy for issue #3 (one request, several completions).
" n absent or 1 keeps the request byte-identical to what it always was.
function! vim_ai_autocomplete#BuildGeminiRequest(context, ...) abort
  let body = {'contents': [{'parts': [{'text': s:BuildFullPrompt(a:context)}]}]}
  let n = a:0 > 0 ? a:1 : 0
  if type(n) == v:t_number && n > 1
    let body.generationConfig = {'candidateCount': n}
  endif
  return json_encode(body)
endfunction

" Anthropic prefix caching only pays when the prefix repeats byte-for-byte
" between requests. While typing inside a line, everything ABOVE that line is
" stable -- so when context.before_tail (the current line's before-part) is
" present, the request is split into two text blocks: block 1 = instruction +
" stable before-context, marked cache_control ephemeral (below the model's
" cacheable minimum Anthropic silently skips it -- no penalty); block 2 = the
" volatile tail + AFTER. Anthropic concatenates text blocks, so the model
" sees exactly the same prompt as the single-string form.
"
" thinking is disabled explicitly: claude-sonnet-5 thinks by default and, at
" a real end-of-file context, returned an EMPTY text block 4/4 (242 thinking
" tokens, no visible output) even with max_tokens raised to 1024. Disabling
" it measured 3/3 non-empty and 40% faster (2026-08-26) -- the same call we
" made for deepseek.
function! vim_ai_autocomplete#BuildClaudeRequest(context, model) abort
  let tail = get(a:context, 'before_tail', '')
  if type(tail) == v:t_string && !empty(tail) && len(tail) < len(a:context.before)
        \ && strpart(a:context.before, len(a:context.before) - len(tail)) ==# tail
    let stable = strpart(a:context.before, 0, len(a:context.before) - len(tail))
    " the anchor quotes the end of BEFORE (the volatile tail), so it lives in
    " block 2 -- block 1 stays byte-identical across keystrokes (pinned by
    " the cache-stability test UN-006f).
    let block1 = s:instruction_head . stable
    let block2 = tail . "\n\nAFTER THE CURSOR:\n" . a:context.after . s:AnchorLine(a:context.before)
    return json_encode({'model': a:model, 'max_tokens': 256, 'thinking': {'type': 'disabled'}, 'messages': [{'role': 'user', 'content': [
          \ {'type': 'text', 'text': block1, 'cache_control': {'type': 'ephemeral'}},
          \ {'type': 'text', 'text': block2},
          \ ]}]})
  endif
  return json_encode({'model': a:model, 'max_tokens': 256, 'thinking': {'type': 'disabled'}, 'messages': [{'role': 'user', 'content': s:BuildFullPrompt(a:context)}]})
endfunction

" DeepSeek's API is OpenAI-compatible chat completions: no "max_tokens"
" requirement, just {model, messages: [{role, content}]}. Confirmed against
" the official docs (api-docs.deepseek.com) on 2026-08-10, not assumed from
" memory.
" thinking must be disabled explicitly: deepseek-v4-flash reasons by default,
" and the reasoning made a completion take 55.6s against 1.6s with it off
" (both measured with real calls, 2026-08-25) -- useless for an autocomplete
" either way.
function! vim_ai_autocomplete#BuildDeepseekRequest(context, model, ...) abort
  let body = {'model': a:model, 'thinking': {'type': 'disabled'}, 'messages': [{'role': 'user', 'content': s:BuildFullPrompt(a:context)}]}
  " the OpenAI-compatible multi-candidate field (hybrid strategy, issue #3)
  let n = a:0 > 0 ? a:1 : 0
  if type(n) == v:t_number && n > 1
    let body.n = n
  endif
  return json_encode(body)
endfunction

" Finds the longest overlap between the END of the suggestion and the START
" of the "after" text (whatever is left once the structural redundancy from
" CountRedundantAfterChars() has been accounted for -- see s:OnExit). It only
" COMPUTES the overlap length -- it does NOT trim the suggestion. Previously
" (until 2026-07-20) this function (TrimSuggestionOverlapWithAfter) trimmed
" the suggestion silently whenever it found an overlap, which hid the change
" from the user -- the grey ghost text showed up adjusted but never turned
" red, unlike the structural case (brackets/quotes), which always shows the
" real redundant character in red before deleting it. Unified: both sources
" of redundancy (structural plus textual overlap) now add up into a single
" redundant_after, always with the same visual treatment (real finding: "the
" red never shows up, even with the grey already written" -- the grey had
" been adjusted by this mechanism, but nothing turned red because trimming
" the suggestion text and marking a real character as redundant were two
" different things).
function! vim_ai_autocomplete#ComputeTextOverlapLength(lines, after_text) abort
  if empty(a:lines) || empty(a:after_text)
    return 0
  endif
  let suggestion_text = join(a:lines, "\n")
  let max_check = min([len(suggestion_text), len(a:after_text)])
  let n = max_check
  while n > 0
    let suffix = strpart(suggestion_text, len(suggestion_text) - n, n)
    let prefix = strpart(a:after_text, 0, n)
    if suffix ==# prefix
      return n
    endif
    let n -= 1
  endwhile
  return 0
endfunction

" Trims from the END of the DISPLAYED suggestion the characters that already
" exist, identical, in the buffer right after the cursor -- so the screen
" shows exactly the final text (a single ')') instead of the suggestion's
" ')' plus the real one struck through. Ghost text is virtual text: every one
" of its characters pushes the real line to the right, so showing the closing
" character twice moved the real ')' away from the cursor and made the line
" reflow on every keystroke.
"
" It only trims when the suggestion ENDS with those characters. A closing
" character in the MIDDLE of the suggestion (e.g. 'x) { return; }' closing an
" earlier '(') keeps being handled by discarding the real character, because
" trimming the tail there would produce wrong text. Returns the adjusted
function! vim_ai_autocomplete#SplitDisplayTail(lines, after_text, redundant_after) abort
  if empty(a:lines) || a:redundant_after <= 0
    return [a:lines, a:redundant_after]
  endif
  let suggestion_text = join(a:lines, "\n")
  " keep = how many real characters stay discarded. Searches from the largest
  " trim (keep 0) down to the smallest, stopping at the first match.
  let keep = 0
  while keep < a:redundant_after
    let tail = strpart(a:after_text, keep, a:redundant_after - keep)
    if len(tail) <= len(suggestion_text)
          \ && strpart(suggestion_text, len(suggestion_text) - len(tail), len(tail)) ==# tail
      let cut = strpart(suggestion_text, 0, len(suggestion_text) - len(tail))
      if empty(cut)
        return [[], keep]
      endif
      return [split(cut, "\n", 1), keep]
    endif
    let keep += 1
  endwhile
  return [a:lines, a:redundant_after]
endfunction

" Covers STRUCTURAL overlap: when the suggestion closes, with its own text, a
" bracket/brace/quote that was already open BEFORE the cursor, the real
" closing character sitting in "after" (e.g. inserted by auto-pairs) is left
" orphaned. Real finding (2026-07-20, "def sum(" with the cursor between the
" parentheses): the suggestion "a, b):\n    return a + b" closes the very "("
" of "def sum(" -- the real ")" was left over at the end of the accepted text
" ("def sum(a, b):\n    return a + b)"). Returns how many characters from the
" START of "after" must be discarded (not written
" back) on accept.
" g:AutoPairs (plugins/auto-pairs) closes (){}[] AND single/double/back
" quotes -- both kinds of pair are covered here. Brackets are ASYMMETRIC
" (opener != closer, they really nest); quotes are SYMMETRIC (the same
" character opens and closes -- alternate: if the top of the stack already is
" that same quote it closes, otherwise it opens a new one). Real finding,
" reported after the parentheses-only fix: "it has to show up for any
" character that is going to be removed" -- not just ( ) [ ] { }.
function! s:AdvanceBracketStack(stack, text) abort
  let pairs = {'(': ')', '[': ']', '{': '}'}
  let closers = ')]}'
  let quotes = '"''`'
  for char in split(a:text, '\zs')
    if stridx(quotes, char) >= 0
      if !empty(a:stack) && a:stack[-1] ==# char
        call remove(a:stack, -1)
      else
        call add(a:stack, char)
      endif
    elseif has_key(pairs, char)
      call add(a:stack, char)
    elseif stridx(closers, char) >= 0 && !empty(a:stack) && get(pairs, a:stack[-1], '') ==# char
      call remove(a:stack, -1)
    endif
  endfor
  return a:stack
endfunction

function! vim_ai_autocomplete#CountRedundantAfterChars(before_text, suggestion_text, after_text) abort
  let closers = ')]}"''`'
  let stack = s:AdvanceBracketStack([], a:before_text)
  let depth_before = len(stack)
  let stack = s:AdvanceBracketStack(stack, a:suggestion_text)
  let redundant = max([0, depth_before - len(stack)])
  if redundant > 0
    " only discards when "after" really does start with that many closing
    " characters -- otherwise it might not be the same bracket/quote (an
    " unusual edit), and it is better not to risk deleting something that is
    " not obviously redundant.
    let n = 0
    while n < redundant && n < len(a:after_text) && stridx(closers, a:after_text[n]) >= 0
      let n += 1
    endwhile
    return n
  endif
  return s:CountLeadingTrivialPairRedundancy(a:suggestion_text, a:after_text)
endfunction

" Covers the case where the cursor sits BEFORE the opening bracket itself
" (not INSIDE the pair auto-pairs already opened) -- "before" has no pending
" bracket/quote (depth_before == 0), so the structural computation above
" never finds anything to close, and the untouched empty pair in "after"
" (e.g. the "()" from auto-pairs, with nothing typed inside yet) does not
" match the END of the suggestion textually (the suggestion ends in a ")"
" closer, "after" starts with a "(" opener -- different characters, so
" ComputeTextOverlapLength finds nothing either). The suggestion, unaware
" that this empty pair exists, writes its OWN complete version of the pair
" ("(arr):" for "def quicksort") -- the original empty pair is left orphaned
" ("def quicksort(arr):()"). Real finding, reported on 2026-07-21 and
" root-caused through a temporary debug log (removed after the fix).
" It only discards when the suggestion does USE that same kind of
" bracket/quote somewhere -- the same conservative spirit as the block
" above, avoiding the deletion of an empty pair that merely happens to sit
" right after the cursor with no relation to what the suggestion wrote.
function! s:CountLeadingTrivialPairRedundancy(suggestion_text, after_text) abort
  let pairs = {'(': ')', '[': ']', '{': '}'}
  let quotes = '"''`'
  if len(a:after_text) < 2
    return 0
  endif
  let opener = a:after_text[0]
  if has_key(pairs, opener)
    let closer = pairs[opener]
  elseif stridx(quotes, opener) >= 0
    let closer = opener
  else
    return 0
  endif
  if a:after_text[1] !=# closer
    return 0
  endif
  return stridx(a:suggestion_text, opener) >= 0 ? 2 : 0
endfunction

" `ant` (Anthropic's official CLI for the Developer Platform, OAuth) bills
" the SAME per-token paid API credit a static ANTHROPIC_API_KEY does -- it
" gives no access to the usage included in a Claude Pro/Max subscription
" (that is a separate product, Claude.ai/Claude Code, with its own usage
" system). Dropped from here on 2026-07-20 ("ant is useless here") -- it
" only changed how you authenticate, with no billing advantage for this
" plugin's use case. It always uses the static key now.
" accepts (and ignores) the n argument the uniform handler signature carries:
" the Messages API has no multi-candidate field, which is exactly why the
" anthropic side of the hybrid fetches alternatives lazily (issue #3).
function! vim_ai_autocomplete#BuildClaudeCommand(context, model, api_key, ...) abort
  let body = vim_ai_autocomplete#BuildClaudeRequest(a:context, a:model)
  return ['curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
        \ '-H', 'x-api-key: ' . a:api_key,
        \ '-H', 'anthropic-version: 2023-06-01',
        \ '-H', 'Content-Type: application/json', '-d', body]
endfunction

" Mirrors BuildClaudeCommand -- Gemini used to assemble its curl command
" inline inside RequestCompletion, with no function of its own (inconsistent
" with Claude). Extracted so the families share a uniform interface
" (build_command(context, model_id, api_key) -> cmd), used by FamilyHandler()
" below.
function! vim_ai_autocomplete#BuildGeminiCommand(context, model_id, api_key, ...) abort
  let body = vim_ai_autocomplete#BuildGeminiRequest(a:context, a:0 > 0 ? a:1 : 0)
  let endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/' . a:model_id . ':generateContent?key=' . a:api_key
  return ['curl', '-s', '-X', 'POST', endpoint, '-H', 'Content-Type: application/json', '-d', body]
endfunction

function! vim_ai_autocomplete#BuildDeepseekCommand(context, model_id, api_key, ...) abort
  let body = vim_ai_autocomplete#BuildDeepseekRequest(a:context, a:model_id, a:0 > 0 ? a:1 : 0)
  return ['curl', '-s', '-X', 'POST', 'https://api.deepseek.com/chat/completions',
        \ '-H', 'Authorization: Bearer ' . a:api_key,
        \ '-H', 'Content-Type: application/json', '-d', body]
endfunction

" Every API family implements two operations with a uniform signature:
" build_command(context, model_id, api_key) -> list for job_start
" parse_response(body) -> list of suggestion lines
" Adding a new API family (e.g. OpenAI) means implementing those two
" functions and registering them here -- it is the "escape hatch" for APIs
" very different from Gemini/Anthropic (see the spec, "Approaches considered").
"
" The dict is built INSIDE the function (not as a top-level `let`) because
" proposito: `function('vim_ai_autocomplete#ParseGeminiResponse')` etc
" have to be evaluated during a call, AFTER the whole file has already been
" loaded -- tested live (vim -N -es): a top-level script `let`
" runs during the SINGLE sourcing pass of the file, so if that line comes
" BEFORE the textual definition of ParseGeminiResponse (which today sits
" further down the file), function() throws no error at all but returns a
" NON-callable value (silently -- confirmed with `E1085: Not a callable
" type` only at call time). Building the dict inside the function body means
" it only runs when FamilyHandler() is actually called -- and by then
" autoload has loaded the whole file (the call itself triggers the load, if
" it has not happened yet), so every function really does exist.
" loaded), so every function really does exist by then.
function! vim_ai_autocomplete#FamilyHandler(family) abort
  " max_candidates_per_request makes the hybrid cost model visible: gemini
  " and deepseek deliver up to 8 alternatives in the SAME request; anthropic
  " delivers 1, so every extra alternative there is one extra (lazy) request.
  let handlers = {
        \ 'gemini': {'build_command': function('vim_ai_autocomplete#BuildGeminiCommand'), 'parse_response': function('vim_ai_autocomplete#ParseGeminiResponse'),
        \   'parse_alternatives': function('vim_ai_autocomplete#ParseGeminiAlternatives'), 'max_candidates_per_request': 8},
        \ 'anthropic': {'build_command': function('vim_ai_autocomplete#BuildClaudeCommand'), 'parse_response': function('vim_ai_autocomplete#ParseClaudeResponse'),
        \   'parse_alternatives': function('vim_ai_autocomplete#ParseClaudeAlternatives'), 'max_candidates_per_request': 1},
        \ 'deepseek': {'build_command': function('vim_ai_autocomplete#BuildDeepseekCommand'), 'parse_response': function('vim_ai_autocomplete#ParseDeepseekResponse'),
        \   'parse_alternatives': function('vim_ai_autocomplete#ParseDeepseekAlternatives'), 'max_candidates_per_request': 8},
        \ }
  if !has_key(handlers, a:family)
    throw 'vim-ai-autocomplete: unknown family "' . a:family . '"'
  endif
  return handlers[a:family]
endfunction

" Extracts the error message from a JSON error response from the API (a
" shape common to Gemini and Claude: {"error": {"message": ...}}). Returns '' when the
" body is not JSON, or does not have that shape.
function! vim_ai_autocomplete#ExtractApiErrorMessage(raw_output) abort
  try
    let data = json_decode(a:raw_output)
    if type(data) == v:t_dict
      return get(get(data, 'error', {}), 'message', '')
    endif
  catch
  endtry
  return ''
endfunction

" U+FFFD (EF BF BD) is never legitimate code, but it intermittently reached
" a real buffer (field report 2026-08-25: ga showed 65533, three in a row).
" The local pipeline was exonerated by experiment -- clean raw bodies over 15
" real calls, json_decode handles emoji, and a multibyte char split across
" raw job chunks reassembles byte-perfectly -- so it arrives from upstream:
" strip it before it can be displayed or accepted.
function! s:StripReplacementChars(text) abort
  return substitute(a:text, "\xef\xbf\xbd", '', 'g')
endfunction

" Observed live 2026-08-26: claude-haiku wrapped a completion in ```python
" fences even though the prompt forbids markdown. A fenced suggestion is
" never insertable as-is -- unwrap a leading ```lang line and a trailing ```
" line. Fences in the MIDDLE are left alone: they can be legitimate content
" (e.g. completing a markdown document).
function! s:StripWrappingFences(text) abort
  " .\{-}\n, not [^\n]*: inside a collection, \n is NOT "any char but newline"
  " on every build -- Apple's vim 9.1.1752 matched [^\n]* straight across the
  " line breaks (measured 2026-09-01: "```python\nx = 1\n```" stripped down to
  " "```"), while brew's 9.2 did not. `.` never matches a newline, so this is
  " the portable spelling.
  let text = substitute(a:text, '^```.\{-}\n', '', '')
  let text = substitute(text, '\n```\s*$', '', '')
  return text
endfunction

function! s:SanitizeSuggestionText(text) abort
  return s:StripWrappingFences(s:StripReplacementChars(a:text))
endfunction

" A suggestion that sanitizes down to pure whitespace (e.g. sonnet once
" answered exactly "```\n\n```") is an invisible ghost the user can accept
" by accident -- collapse it to "no suggestion".
function! s:SplitSuggestion(text) abort
  let clean = s:SanitizeSuggestionText(a:text)
  " \_s, not \s: Vim's \s does not match newlines, and a multi-line
  " whitespace-only suggestion must still collapse (Lua's %s covers \n).
  if clean =~# '^\_s*$'
    return []
  endif
  return split(clean, "\n", 1)
endfunction

" A blocked candidate (safety filter, finishReason SAFETY/RECITATION)
" comes back WITHOUT "content", or without "parts" -- a legitimate HTTP 200
" response, just with no actual suggestion. Real finding, reported from a
" smoke test of the Neovim port): the unguarded direct access threw.
function! vim_ai_autocomplete#ParseGeminiResponse(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || !has_key(data, 'candidates') || empty(data.candidates)
    return []
  endif
  let candidate = data.candidates[0]
  if type(candidate) != v:t_dict || type(get(candidate, 'content', v:null)) != v:t_dict
    return []
  endif
  let parts = get(candidate.content, 'parts', [])
  if type(parts) != v:t_list || empty(parts)
    return []
  endif
  let text = parts[0].text
  return s:SplitSuggestion(text)
endfunction

" content is a LIST of typed blocks, and the text block is not necessarily
" first: claude-sonnet-5 prepends a {"type":"thinking"} block (observed live
" 5/5, 2026-08-25). Indexing content[0].text blindly threw E716 mid-typing
" whenever thinking came first.
function! vim_ai_autocomplete#ParseClaudeResponse(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || type(get(data, 'content', v:null)) != v:t_list
    return []
  endif
  for block in data.content
    if type(block) == v:t_dict && type(get(block, 'text', v:null)) == v:t_string
      return s:SplitSuggestion(block.text)
    endif
  endfor
  return []
endfunction

" Same defensive shape as ParseGeminiResponse: a malformed/blocked response
" is a legitimate possibility (rate limit, content filter), not an error to
" crash on -- guard every level instead of indexing straight through
" choices[0].message.content.
function! vim_ai_autocomplete#ParseDeepseekResponse(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || !has_key(data, 'choices') || empty(data.choices)
    return []
  endif
  let message = get(data.choices[0], 'message', v:null)
  if type(message) != v:t_dict || type(get(message, 'content', v:null)) != v:t_string
    return []
  endif
  return s:SplitSuggestion(message.content)
endfunction

" Shared tail of every Parse*Alternatives: sanitize/split each candidate with
" the same rules as the single-suggestion parsers, drop the ones that vanish,
" and collapse duplicates (deepseek with n>1 does return identical choices).
function! s:CollectAlternatives(texts) abort
  let out = []
  let seen = {}
  for text in a:texts
    let lines = s:SplitSuggestion(text)
    if !empty(lines)
      let key = join(lines, "\n")
      if !has_key(seen, key)
        let seen[key] = 1
        call add(out, lines)
      endif
    endif
  endfor
  return out
endfunction

" Parse*Alternatives(body) -> list of suggestion-line-lists, one per usable
" candidate (issue #3). Same defensive guards as the single parsers: a
" blocked/malformed candidate is skipped, never a throw.
function! vim_ai_autocomplete#ParseGeminiAlternatives(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || type(get(data, 'candidates', v:null)) != v:t_list
    return []
  endif
  let texts = []
  for candidate in data.candidates
    if type(candidate) == v:t_dict && type(get(candidate, 'content', v:null)) == v:t_dict
      let parts = get(candidate.content, 'parts', [])
      if type(parts) == v:t_list && !empty(parts) && type(get(parts[0], 'text', v:null)) == v:t_string
        call add(texts, parts[0].text)
      endif
    endif
  endfor
  return s:CollectAlternatives(texts)
endfunction

function! vim_ai_autocomplete#ParseDeepseekAlternatives(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || type(get(data, 'choices', v:null)) != v:t_list
    return []
  endif
  let texts = []
  for choice in data.choices
    let message = type(choice) == v:t_dict ? get(choice, 'message', v:null) : v:null
    if type(message) == v:t_dict && type(get(message, 'content', v:null)) == v:t_string
      call add(texts, message.content)
    endif
  endfor
  return s:CollectAlternatives(texts)
endfunction

function! vim_ai_autocomplete#ParseClaudeAlternatives(body) abort
  let lines = vim_ai_autocomplete#ParseClaudeResponse(a:body)
  return empty(lines) ? [] : [lines]
endfunction

" Symmetric counterpart of ComputeTextOverlapLength: that one catches the
" model repeating what comes AFTER the cursor, this one what comes BEFORE.
" Field report 2026-08-27 (reproduced 3/3 with real deepseek calls): the user
" indents by hand, waits, and the model returns its own indentation on top --
" 4 typed spaces plus 4 suggested spaces became 8.
"
" Deliberately limited to whitespace-only before_tail: stripping real code
" would be a guess, and a wrong guess deletes the user's own characters. At
" most len(before_tail) characters come off, so a deeper suggested indent
" keeps the extra levels (user 2 + model 4 -> 2 remain, total 4).
" The model echoes the character(s) just before the cursor: field report
" 2026-09-02 (gemini) -- "(a, b):" right after "(" showed an extra pair on
" screen, ":\n    def ..." right after "class Stack:" put a second colon on
" the line below. Strips from the START of the suggestion the longest prefix
" that equals a suffix of before_tail, but only when that overlap is made of
" punctuation/brackets/whitespace: a word-character overlap ("fo" + "o = 1")
" is a legitimate continuation, never an echo. Nothing is deleted from the
" buffer, so nothing new has to be highlighted red. Subsumes
" StripLeadingIndentOverlap (whitespace is one kind of non-word overlap).
function! vim_ai_autocomplete#StripLeadingOverlap(lines, before_tail) abort
  if empty(a:lines) || type(a:before_tail) != v:t_string || empty(a:before_tail)
    return a:lines
  endif
  let first = a:lines[0]
  let n = min([len(first), len(a:before_tail)])
  while n >= 1
    let head = strpart(first, 0, n)
    if strpart(a:before_tail, len(a:before_tail) - n) ==# head && head !~# '[[:alnum:]_]'
      let result = copy(a:lines)
      let result[0] = strpart(first, n)
      return result
    endif
    let n -= 1
  endwhile
  return a:lines
endfunction

function! vim_ai_autocomplete#StripLeadingIndentOverlap(lines, before_tail) abort
  if empty(a:lines) || type(a:before_tail) != v:t_string || empty(a:before_tail)
        \ || a:before_tail =~# '\S'
    return a:lines
  endif
  let leading = matchstr(a:lines[0], '^\s*')
  let strip = min([len(leading), len(a:before_tail)])
  if strip == 0
    return a:lines
  endif
  let result = copy(a:lines)
  let result[0] = strpart(a:lines[0], strip)
  return result
endfunction

" Some models (confirmed with gemini-3.1-flash-lite, reproducible 3/3
" real calls) treat the response as a literal continuation of bytes: when the
" context ends in ":" (a Python block opener), the first line of the
" suggestion comes with no line break AND no indentation of its own -- the
" text sticks straight onto the current line (e.g. "def fibonacci(n):if n
" <= 1:"). Asking the model to include the line break through a prompt
" instruction did NOT fix it (tested, same behaviour). Fix: when the context
" ends in ":" and the filetype is python, insert a line break and one level
" of indentation (shiftwidth) on the first line of the suggestion -- the
" following lines already come with the right relative indentation from the
" desse ajuste.
function! vim_ai_autocomplete#AdjustSuggestionLines(lines, current_line_before_cursor, filetype, shiftwidth, expandtab) abort
  if empty(a:lines) || a:filetype !=# 'python'
    return a:lines
  endif
  let trimmed = substitute(a:current_line_before_cursor, '\s*$', '', '')
  if trimmed !~# ':$'
    return a:lines
  endif
  if a:lines[0] ==# ''
    " it already came with a line break of its own -- leave it alone
    return a:lines
  endif
  let indent_str = a:expandtab ? repeat(' ', a:shiftwidth) : "\t"
  let first_line_stripped = substitute(a:lines[0], '^\s*', '', '')
  return [''] + [indent_str . first_line_stripped] + a:lines[1:]
endfunction

let s:prop_type = 'VimAiAutocompleteSuggestion'
let s:redundant_prop_type = 'VimAiAutocompleteRedundant'
let s:current_suggestion = []
let s:suggestion_lnum = 0
let s:suggestion_col = 0
let s:suggestion_redundant_after = 0
" issue #3: the alternatives being cycled through -- a list of
" {'lines', 'redundant_after'} entries -- and which one is on screen.
let s:alternatives = []
let s:alt_index = 0
" issue #4: the in-flight marker -- its own prop type (never touched by the
" suggestion props), a timer for the delayed show, and where it was put.
let s:pending_prop_type = 'VimAiAutocompletePending'
let s:pending = 0
let s:pending_lnum = 0
let s:pending_bufnr = 0
let s:pending_timer = -1

function! s:EnsurePropType() abort
  if empty(prop_type_get(s:prop_type))
    call prop_type_add(s:prop_type, {'highlight': 'Comment'})
  endif
endfunction

" A highlight of its OWN for the real redundant character -- strikethrough,
" not the ghost text style. Reusing the ghost text highlight (which means
" "this is going to be inserted") for a character that is in fact going to
" be REMOVED was misleading: it looked like ghost text but vanished on Tab
" instead of "solidifying" like the rest of the suggestion (real finding,
" reported as: "the wrong parenthesis shows up as ghost text but when I
" press tab it does not show up").
function! s:EnsureRedundantPropType() abort
  if empty(prop_type_get(s:redundant_prop_type))
    if !hlexists('VimAiAutocompleteRedundant')
      " strikethrough alone is not reliable (it depends on the terminal's
      " t_Cs/t_Ce -- confirmed not to render, through a real colour capture
      " inside tmux). Red (gruvbox) is the PRIMARY signal, always visible,
      " with strikethrough as a bonus when the terminal supports it.
      highlight default VimAiAutocompleteRedundant cterm=strikethrough gui=strikethrough ctermfg=167 guifg=#fb4934
    endif
    call prop_type_add(s:redundant_prop_type, {'highlight': 'VimAiAutocompleteRedundant'})
  endif
endfunction

" redundant_after (optional, defaults to 0): how many characters from the
" START of the real text AFTER the cursor must be DISCARDED (not preserved)
" on accept -- see CountRedundantAfterChars(). Used when the suggestion already
" closes, with its own text, a bracket/brace that was open before the cursor,
" leaving the real closer (e.g. the one auto-pairs inserted) orphaned or
" duplicated.
function! vim_ai_autocomplete#ShowSuggestion(lines, ...) abort
  call vim_ai_autocomplete#ClearPending()
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(a:lines)
    return
  endif
  call s:EnsurePropType()
  " never add an inline prop with empty text: Vim stores it as a control
  " byte (prop_list shows 'text': '^D') and renders it as three U+FFFD --
  " isolated in bare `vim -u NONE`. An empty first line (every python
  " block-opener suggestion, via AdjustSuggestionLines) simply has nothing
  " to render inline; the below-lines carry the visible ghost.
  if !empty(a:lines[0])
    call prop_add(line('.'), col('.'), {'type': s:prop_type, 'text': a:lines[0]})
  endif
  " an EMPTY below-line renders as "@" (measured in bare vim -u NONE,
  " 2026-09-02: a blank line between two methods came out as "@" and
  " garbled the line after it) -- same class as the empty inline prop above.
  " A single space renders as the blank line the model meant.
  for l in a:lines[1:]
    call prop_add(line('.'), 0, {'type': s:prop_type, 'text_align': 'below', 'text': empty(l) ? ' ' : l})
  endfor
  let redundant = a:0 > 0 ? a:1 : 0
  if redundant > 0
    call s:EnsureRedundantPropType()
    call prop_add(line('.'), col('.'), {'type': s:redundant_prop_type, 'length': redundant})
  endif
  let s:current_suggestion = copy(a:lines)
  let s:suggestion_lnum = line('.')
  let s:suggestion_col = col('.')
  let s:suggestion_redundant_after = redundant
  call s:DebugLog(s:gen, 0, '', printf('shown at (%d,%d) mode=%s lines=%d', s:suggestion_lnum, s:suggestion_col, mode(1), len(a:lines)))
endfunction

function! vim_ai_autocomplete#ClearSuggestion() abort
  if empty(s:current_suggestion)
    return
  endif
  call prop_remove({'type': s:prop_type, 'all': v:true}, s:suggestion_lnum)
  if !empty(prop_type_get(s:redundant_prop_type))
    call prop_remove({'type': s:redundant_prop_type, 'all': v:true}, s:suggestion_lnum)
  endif
  let s:current_suggestion = []
  let s:suggestion_lnum = 0
  let s:suggestion_col = 0
  let s:suggestion_redundant_after = 0
  let s:alternatives = []
  let s:alt_index = 0
endfunction

" issue #3: show a SET of alternatives, starting at the first. Each entry is
" {'lines', 'redundant_after'}; cycling re-renders another entry at the same
" cursor position. ShowSuggestion stays the single-suggestion primitive (it
" clears any alternatives state, so a fresh trigger never leaks stale ones).
function! vim_ai_autocomplete#ShowAlternatives(entries) abort
  if empty(a:entries)
    return
  endif
  call vim_ai_autocomplete#ShowSuggestion(a:entries[0].lines, a:entries[0].redundant_after)
  let s:alternatives = deepcopy(a:entries)
  let s:alt_index = 1
endfunction

" Moves delta (+1/-1) through the known alternatives, wrapping at both ends.
" Returns the new 1-based index, or 0 when there is no alternatives state (a
" plain single suggestion, or nothing visible) -- the caller decides whether
" that means "fetch one lazily" or "nothing to do".
function! vim_ai_autocomplete#CycleAlternatives(delta) abort
  if empty(s:alternatives) || s:alt_index == 0
    return 0
  endif
  let n = len(s:alternatives)
  let index = ((s:alt_index - 1 + a:delta) % n + n) % n + 1
  let alternatives = s:alternatives
  let entry = alternatives[index - 1]
  call vim_ai_autocomplete#ShowSuggestion(entry.lines, entry.redundant_after)
  let s:alternatives = alternatives
  let s:alt_index = index
  return index
endfunction

" Appends a lazily fetched entry (the anthropic side of the hybrid) and jumps
" to it -- the user pressed "next", so the new entry is what they asked for.
function! vim_ai_autocomplete#AppendAlternative(entry) abort
  let alternatives = s:alternatives
  call add(alternatives, deepcopy(a:entry))
  call vim_ai_autocomplete#ShowSuggestion(a:entry.lines, a:entry.redundant_after)
  let s:alternatives = alternatives
  let s:alt_index = len(alternatives)
endfunction

function! vim_ai_autocomplete#Alternatives() abort
  return deepcopy(s:alternatives)
endfunction

function! vim_ai_autocomplete#AlternativesCount() abort
  return len(s:alternatives)
endfunction

function! vim_ai_autocomplete#AlternativesIndex() abort
  return s:alt_index
endfunction

" issue #4: a transient marker while a request is in flight. Field report:
" "sometimes I wait a reasonable time and I cannot tell whether the
" suggestion is coming or not". The API round-trip (1.4-4.5 s) dominates and
" cannot be shrunk from here, so this is about legibility, not speed.
"
" text_align 'after' (end of line), never inline: an inline prop shifts the
" real line on every keystroke -- the flicker the ghost-text work removed --
" and the text is never empty (an empty prop renders as U+FFFD). Shown only
" after a delay (SchedulePending), so a fast answer never flashes anything;
" cleared on EVERY exit of the request by the request layer, and by
" ShowSuggestion itself.
function! s:EnsurePendingPropType() abort
  if empty(prop_type_get(s:pending_prop_type))
    call prop_type_add(s:pending_prop_type, {'highlight': 'Comment'})
  endif
endfunction

function! vim_ai_autocomplete#ShowPending() abort
  call vim_ai_autocomplete#ClearPending()
  call s:EnsurePendingPropType()
  call prop_add(line('.'), 0, {'type': s:pending_prop_type, 'text': '…', 'text_align': 'after'})
  let s:pending = 1
  let s:pending_lnum = line('.')
  let s:pending_bufnr = bufnr('%')
endfunction

function! s:OnPendingTimer(timer_id) abort
  let s:pending_timer = -1
  if !s:pending
    call vim_ai_autocomplete#ShowPending()
  endif
endfunction

" Shows the marker only if nothing cancels it within delay_ms -- a
" ClearPending() in between (the answer came fast) stops the timer.
function! vim_ai_autocomplete#SchedulePending(delay_ms) abort
  if s:pending_timer != -1
    call timer_stop(s:pending_timer)
  endif
  let s:pending_timer = timer_start(a:delay_ms, function('s:OnPendingTimer'))
endfunction

function! vim_ai_autocomplete#ClearPending() abort
  if s:pending_timer != -1
    call timer_stop(s:pending_timer)
    let s:pending_timer = -1
  endif
  if s:pending && bufexists(s:pending_bufnr) && !empty(prop_type_get(s:pending_prop_type))
    call prop_remove({'type': s:pending_prop_type, 'bufnr': s:pending_bufnr, 'all': v:true})
  endif
  let s:pending = 0
  let s:pending_lnum = 0
  let s:pending_bufnr = 0
endfunction

function! vim_ai_autocomplete#IsPending() abort
  return s:pending
endfunction

function! vim_ai_autocomplete#IsVisible() abort
  return !empty(s:current_suggestion)
endfunction

function! vim_ai_autocomplete#CurrentSuggestion() abort
  return copy(s:current_suggestion)
endfunction

let s:tab_fallback_rhs = '"\<Tab>"'
let s:tab_fallback_is_expr = 1

function! vim_ai_autocomplete#SetupTabWrap() abort
  let original_map = maparg('<Tab>', 'i', 0, 1)
  if !empty(original_map)
    " <Tab> mappings backed by a Lua callback (e.g. blink.cmp on Neovim,
    " "jump to the next snippet placeholder or fall back to a normal Tab")
    " have no 'rhs' key in the dict maparg() returns -- reading .rhs directly
    " throws E716 on EVERY Neovim startup (real finding: an error and a
    " "Press ENTER" prompt right after opening). Reading it with a default
    " covers both shapes (classic string rhs and callback).
    let s:tab_fallback_rhs = get(original_map, 'rhs', '')
    let s:tab_fallback_is_expr = get(original_map, 'expr', 0)
    let s:tab_fallback_callback = get(original_map, 'callback', v:null)
  endif
  inoremap <script><silent><expr> <Tab> vim_ai_autocomplete#TabHandler()
endfunction

function! vim_ai_autocomplete#TabHandler() abort
  if vim_ai_autocomplete#IsVisible()
    return vim_ai_autocomplete#Accept()
  endif
  if !empty(get(s:, 'tab_fallback_callback', v:null))
    " the original mapping is <expr>: the callback return value IS the result
    " of the expr (the same mechanism Neovim uses internally for <expr>
    " mappings with a Lua callback, e.g. blink.cmp).
    let result = s:tab_fallback_callback()
    return s:tab_fallback_is_expr ? result : ''
  endif
  return s:tab_fallback_is_expr ? eval(s:tab_fallback_rhs) : s:tab_fallback_rhs
endfunction

" Dismisses the suggestion WITHOUT leaving insert mode. This used to live in
" an <Esc> wrap that swallowed the key whenever a suggestion was visible: the
" user pressed <Esc> to leave insert mode, stayed in insert mode, and the
" following keystrokes landed in the buffer as text. One key cannot carry two
" meanings when the user has no way to predict which one applies, so <Esc> is
" plain <Esc> again -- the suggestion is cleared by the InsertLeavePre
" autocmd -- and dismiss-without-leaving got a key of its own. <C-]> is the
" same choice copilot.vim makes for dismissing a suggestion.
function! vim_ai_autocomplete#Dismiss() abort
  call vim_ai_autocomplete#ClearSuggestion()
  return ''
endfunction

function! vim_ai_autocomplete#Accept() abort
  let lines = vim_ai_autocomplete#CurrentSuggestion()
  let redundant_after = s:suggestion_redundant_after
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(lines)
    return ''
  endif
  " Writes straight into the buffer through setline()/append() instead of a
  " simulated <CR> -- typing <CR> fires Vim's real autoindent/indentexpr on
  " every line, stacking on top of the indentation the API text already
  " carries, doubling/misaligning the real indentation (found through real
  " debugging with Gemini: a line expected to have 8 spaces became 12, another became 24).
  "
  " The buffer mutation has to be DEFERRED through timer_start(0, ...): an
  " <expr> mapping (like the <Tab> that calls this function) may NOT change
  " the buffer text during its own evaluation -- doing it directly here
  " dispara E565 (confirmado rodando de verdade contra o mapeamento real de
  " <Tab>, not only through :call). timer_start with a 0 delay runs the
  " callback as soon as Vim is back in its event loop, outside the <expr>
  let lnum = line('.')
  let col = col('.')
  call timer_start(0, {-> vim_ai_autocomplete#InsertAcceptedLines(lines, lnum, col, redundant_after)})
  return ''
endfunction

function! vim_ai_autocomplete#InsertAcceptedLines(lines, lnum, col, ...) abort
  let redundant_after = a:0 > 0 ? a:1 : 0
  let current_line = getline(a:lnum)
  let before = a:col > 1 ? current_line[: a:col - 2] : ''
  let after = strpart(current_line, a:col - 1 + redundant_after)
  let new_first_line = before . a:lines[0]
  if len(a:lines) == 1
    call setline(a:lnum, new_first_line . after)
    call cursor(a:lnum, len(new_first_line) + 1)
  else
    let middle_lines = a:lines[1:]
    let middle_lines[-1] .= after
    call setline(a:lnum, new_first_line)
    call append(a:lnum, middle_lines)
    call cursor(a:lnum + len(middle_lines), len(middle_lines[-1]) - len(after) + 1)
  endif
endfunction

" active_models: the ALREADY FILTERED list (see vim_ai_autocomplete#ActiveModels())
" -- registers ,pr and the :VimAiAutocompleteModel command only with 2+ active
" models (same rule as today -- previously "both keys present", generalised).
function! vim_ai_autocomplete#SetupProviderToggle(active_models) abort
  if len(a:active_models) >= 2
    " <leader>pr, not <leader>ap nor <leader>pv: <leader>a is already CoC code
    " actions (configs.vim) -- <leader>ap shared a prefix with an existing
    " complete mapping (real finding). <leader>pv was dropped too: it collides
    " with the Python venv selector on the Neovim side
    " (nvim/lua/user/venv.lua) -- the same key is chosen on both sides for
    " consistency, so it has to be free on both.
    nnoremap <silent> <leader>pr :call vim_ai_autocomplete#ToggleProvider()<CR>
    nnoremap <silent> <leader>pm :call vim_ai_autocomplete#OpenModelPicker()<CR>
    command! -nargs=1 -complete=customlist,vim_ai_autocomplete#CompleteModelNames VimAiAutocompleteModel call vim_ai_autocomplete#SelectModel(<q-args>)
  endif
endfunction

" ,pm parity with the Neovim side (which uses vim.ui.select): a popup_menu
" of the active model names. The selection logic lives in OnModelPicked so
" it is testable without a real popup -- popup_menu passes (id, result)
" where result is the 1-based index, or -1 on cancel.
function! vim_ai_autocomplete#OpenModelPicker() abort
  let active = vim_ai_autocomplete#ActiveModels()
  let names = map(copy(active), 'v:val.name')
  call popup_menu(names, {
        \ 'title': ' vim-ai-autocomplete: pick a model ',
        \ 'callback': {id, result -> vim_ai_autocomplete#OnModelPicked(names, id, result)},
        \ })
endfunction

function! vim_ai_autocomplete#OnModelPicked(names, id, result) abort
  if a:result < 1 || a:result > len(a:names)
    return
  endif
  call vim_ai_autocomplete#SelectModel(a:names[a:result - 1])
endfunction

function! vim_ai_autocomplete#ToggleProvider() abort
  let active = vim_ai_autocomplete#ActiveModels()
  let names = map(copy(active), 'v:val.name')
  let idx = index(names, g:vim_ai_autocomplete_provider)
  let next_idx = (idx + 1) % len(names)
  let g:vim_ai_autocomplete_provider = names[next_idx]
  echom 'vim-ai-autocomplete: provider is now ' . g:vim_ai_autocomplete_provider
  call s:CheckModelKey(g:vim_ai_autocomplete_provider)
endfunction

function! vim_ai_autocomplete#SelectModel(name) abort
  let active = vim_ai_autocomplete#ActiveModels()
  let model = vim_ai_autocomplete#FindModelByName(active, a:name)
  if model is v:null
    echoerr 'vim-ai-autocomplete: model "' . a:name . '" does not exist or is not active (no API key)'
    return
  endif
  let g:vim_ai_autocomplete_provider = a:name
  echom 'vim-ai-autocomplete: provider is now ' . a:name
  call s:CheckModelKey(a:name)
endfunction

function! vim_ai_autocomplete#CompleteModelNames(arglead, cmdline, cursorpos) abort
  let active = vim_ai_autocomplete#ActiveModels()
  let names = map(copy(active), 'v:val.name')
  return filter(names, 'stridx(v:val, a:arglead) == 0')
endfunction

" Generalises s:CheckClaudeKey/s:OnClaudeKeyCheckExit (which used to exist
" only for Claude, hardcoded). Fires a cheap call (minimal "hi" context) at
" the model just switched to; on error it only WARNS, it no longer reverts
" to the previous model (it used to revert automatically; changed on request
" 2026-07-22, "I want to be able to cycle freely", e.g. pressing ,pr
" repeatedly to try the next models even after a credit warning, without
" having to switch back by hand).
function! s:CheckModelKey(name) abort
  let model = vim_ai_autocomplete#FindModelByName(vim_ai_autocomplete#ActiveModels(), a:name)
  if model is v:null
    return
  endif
  let api_key = getenv(model.api_key_env)
  let handler = vim_ai_autocomplete#FamilyHandler(model.family)
  let cmd = handler.build_command({'before': 'hi', 'after': ''}, model.model_id, api_key)
  let l:chunks = []
  let l:checked_name = a:name
  call job_start(cmd, {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnModelKeyCheckExit(l:checked_name, l:chunks)},
        \ 'out_mode': 'raw',
        \ })
endfunction

function! s:OnModelKeyCheckExit(checked_name, chunks) abort
  let message = vim_ai_autocomplete#ExtractApiErrorMessage(join(a:chunks, ''))
  if empty(message)
    return
  endif
  echohl WarningMsg
  echomsg printf('vim-ai-autocomplete (%s): %s', a:checked_name, message)
  echohl None
endfunction

let s:timer_id = -1
let s:gen = 0

function! vim_ai_autocomplete#Trigger() abort
  " if the cursor moved away from where the suggestion was shown (e.g. arrow
  " keys to review the text before accepting), the suggestion is stale --
  " accepting it as is would insert the wrong text at the wrong position.
  " Real finding: moving the cursor with the arrows before Tab corrupted the
  " buffer ("def mergesortarr):" -- the "(" vanished and an extra ")" was
  " left at the end -- the STALE suggestion (computed for
  " one position) was accepted at a DIFFERENT position (the new,
  " post-movement one). Clears unconditionally, even with auto_trigger off --
  " this is about correctness (not letting an invalid suggestion be
  " accepted), not about asking for a new suggestion.
  if vim_ai_autocomplete#IsVisible() && (line('.') != s:suggestion_lnum || col('.') != s:suggestion_col)
    call s:DebugLog(s:gen, 0, '', printf('Trigger cleared: stored (%d,%d) now (%d,%d) mode=%s', s:suggestion_lnum, s:suggestion_col, line('.'), col('.'), mode(1)))
    call vim_ai_autocomplete#ClearSuggestion()
  endif
  if !get(g:, 'vim_ai_autocomplete_auto_trigger', 1)
    return
  endif
  if s:timer_id != -1
    call timer_stop(s:timer_id)
  endif
  let s:timer_id = timer_start(600, function('vim_ai_autocomplete#OnTimer'))
endfunction

function! vim_ai_autocomplete#ToggleAutoTrigger() abort
  let g:vim_ai_autocomplete_auto_trigger = !get(g:, 'vim_ai_autocomplete_auto_trigger', 1)
  echom 'vim-ai-autocomplete: auto-trigger ' . (g:vim_ai_autocomplete_auto_trigger ? 'on' : 'off')
endfunction

function! vim_ai_autocomplete#OnTimer(timer_id) abort
  let s:timer_id = -1
  call s:DebugLog(s:gen, 0, '', 'OnTimer: clearing (visible=' . vim_ai_autocomplete#IsVisible() . ') and re-requesting')
  call vim_ai_autocomplete#ClearSuggestion()
  if mode() !=# 'i'
    return
  endif
  call vim_ai_autocomplete#RequestCompletion()
endfunction

" issue #2: is a completion menu on screen? Two suggestion UIs at the same
" cursor position compete, and the menu wins: nothing is requested while it
" is open, and an answer that lands while it is open is dropped. CoC draws
" its own popup (not the native pum), so coc#pum#visible() is consulted as
" well whenever it exists.
function! vim_ai_autocomplete#CompletionMenuVisible() abort
  if pumvisible()
    return 1
  endif
  " a guarded CALL, not exists('*coc#pum#visible'): exists() never autoloads,
  " so it stays 0 until something else has called the function -- which would
  " leave this blind until the user's first <Tab>. Calling it autoloads the
  " script; E117 means there is no CoC at all.
  try
    return coc#pum#visible() ? 1 : 0
  catch /E117/
    return 0
  endtry
endfunction

function! vim_ai_autocomplete#RequestCompletion() abort
  " issue #2: a completion menu is open -- let it win, ask for nothing.
  if vim_ai_autocomplete#CompletionMenuVisible()
    return
  endif
  let all_models = get(g:, 'vim_ai_autocomplete_models', vim_ai_autocomplete#DefaultModels())
  let active = vim_ai_autocomplete#ActiveModels()
  let [default_name, level, _] = vim_ai_autocomplete#ResolveDefaultModel(all_models, active)
  if level ==# 'error'
    return
  endif
  let provider_name = get(g:, 'vim_ai_autocomplete_provider', default_name)
  let model = vim_ai_autocomplete#FindModelByName(active, provider_name)
  if model is v:null
    " the configured provider is no longer active (e.g. its key was removed at
    " runtime, or was never set) -- fall back to the default resolved above.
    let model = vim_ai_autocomplete#FindModelByName(active, default_name)
  endif
  let handler = vim_ai_autocomplete#FamilyHandler(model.family)
  let api_key = getenv(model.api_key_env)

  let context = vim_ai_autocomplete#BuildRequestContext()
  " raw_after is for s:OnExit, never for the prompt -- pull it out before the
  " context reaches the handler.
  let l:after = remove(context, 'raw_after')
  " issue #3, the hybrid strategy: batch N candidates into ONE request only
  " where the MODEL opts in (candidates_per_request in its config entry);
  " everything else fetches one per request, lazily, through
  " CycleSuggestion. Lazy is the default because the batch fields are
  " rejected by the models we measured: gemini-3.1-flash-lite answers
  " "Multiple candidates is not enabled for this model" and deepseek-v4-pro
  " "Invalid n value (currently only n = 1 is supported)" (real calls,
  " 2026-09-01) -- shipping the batch blindly would have killed the first
  " suggestion whenever the feature was on. 0 keeps the request unchanged.
  let wanted = s:AlternativesN()
  let per_request = wanted > 0
        \ ? max([1, min([wanted, get(model, 'candidates_per_request', 1), handler.max_candidates_per_request])])
        \ : 0
  let cmd = handler.build_command(context, model.model_id, api_key, per_request)

  let s:gen += 1
  let l:gen = s:gen
  let l:chunks = []
  let l:bufnr = bufnr('%')
  let l:lnum = line('.')
  let l:col = col('.')
  let l:provider = model.name
  let l:ParseResponse = handler.parse_response
  let l:ParseAlternatives = handler.parse_alternatives
  let l:wanted = wanted
  let s:lazy_in_flight = 0
  let s:last_trigger = {'handler': handler, 'model_id': model.model_id, 'api_key': api_key, 'context': context,
        \ 'after': l:after, 'bufnr': l:bufnr, 'lnum': l:lnum, 'col': l:col, 'provider': l:provider, 'gen': l:gen,
        \ 'per_request': max([1, per_request])}

  let opts = {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnExit(l:gen, l:chunks, status, l:provider, l:ParseResponse, l:ParseAlternatives, l:wanted, l:bufnr, l:lnum, l:col, l:after)},
        \ 'out_mode': 'raw',
        \ }
  call job_start(cmd, opts)
  call vim_ai_autocomplete#SchedulePending(s:PendingDelayMs())
endfunction

" issue #3: how many alternatives the user asked to cycle through.
" 0 = feature off (the default -- every alternative is a paid API call).
function! s:AlternativesN() abort
  let n = get(g:, 'vim_ai_autocomplete_alternatives', 0)
  return type(n) == v:t_number && n >= 2 ? n : 0
endfunction

" issue #4: how long a request may stay silent before the in-flight marker
" shows. Fast answers (most gemini/deepseek ones) never flash anything.
function! s:PendingDelayMs() abort
  let n = get(g:, 'vim_ai_autocomplete_pending_delay_ms', 400)
  return type(n) == v:t_number && n >= 0 ? n : 400
endfunction

" everything the lazy fetch (the anthropic side of the hybrid) needs to
" rebuild the SAME request later, captured at trigger time.
let s:last_trigger = {}
let s:lazy_in_flight = 0

" The cycle decision, pure so the lazy branch is testable without job_start:
" fetch only past the end, below N, when this model delivers one candidate
" per request; otherwise cycle through what is already there.
function! vim_ai_autocomplete#CycleDecision(delta, index, count, wanted, max_per_request) abort
  if a:wanted < 2 || a:count == 0 || a:index == 0
    return 'noop'
  endif
  if a:delta > 0 && a:index == a:count && a:count < a:wanted && a:max_per_request == 1
    return 'fetch'
  endif
  return 'cycle'
endfunction

" issue #3: alternatives are off by default (each one is a paid call), and
" the cycle keys are only claimed when the feature is on -- <M-.>/<M-,> stay
" untouched otherwise. <Cmd> keeps insert mode and moves nothing.
" The keys are configurable because <M-.> only arrives if the terminal sends
" Option/Alt as Meta -- on macOS that is iTerm's "Option key: Esc+"; with the
" default "Normal" mode Option+. types "≥" instead (measured 2026-09-02).
" Anyone who prefers not to touch the terminal picks other keys.
function! vim_ai_autocomplete#SetupAlternativesKeys() abort
  if s:AlternativesN() < 2
    return
  endif
  let next_key = get(g:, 'vim_ai_autocomplete_cycle_next', '<M-.>')
  let prev_key = get(g:, 'vim_ai_autocomplete_cycle_prev', '<M-,>')
  call s:DeclareMetaTermcode(next_key)
  call s:DeclareMetaTermcode(prev_key)
  execute 'inoremap <silent> ' . next_key . ' <Cmd>call vim_ai_autocomplete#CycleSuggestion(1)<CR>'
  execute 'inoremap <silent> ' . prev_key . ' <Cmd>call vim_ai_autocomplete#CycleSuggestion(-1)<CR>'
endfunction

" Terminal Vim receives Alt+x from the terminal as ESC followed by x and, unlike
" Neovim, does not decode that into <M-x> by itself: the ESC left insert mode
" and the "," became the leader key (measured inside tmux, 2026-09-02 --
" which-key popped up instead of cycling). Declaring the termcode teaches Vim
" that ESC x is one key. Only for the <M-c> shape, only outside the GUI, and
" never on Neovim, which handles Alt natively.
function! s:DeclareMetaTermcode(key) abort
  if has('nvim') || has('gui_running')
    return
  endif
  let char = matchstr(a:key, '\c^<M-\zs.\ze>$')
  if empty(char)
    return
  endif
  execute 'set ' . a:key . "=\<Esc>" . char
endfunction

" <M-.> / <M-,> while a suggestion is visible (issue #3).
function! vim_ai_autocomplete#CycleSuggestion(delta) abort
  if !vim_ai_autocomplete#IsVisible() || empty(s:last_trigger)
    return
  endif
  let decision = vim_ai_autocomplete#CycleDecision(a:delta, s:alt_index, len(s:alternatives),
        \ s:AlternativesN(), s:last_trigger.per_request)
  if decision ==# 'fetch'
    call s:FetchLazyAlternative()
  elseif decision ==# 'cycle'
    call vim_ai_autocomplete#CycleAlternatives(a:delta)
  endif
endfunction

" The lazy half of the hybrid (issue #3): one more request, same context,
" appended as a new alternative when it arrives -- unless the cursor moved,
" a newer trigger superseded it, or the model just repeated itself.
function! s:FetchLazyAlternative() abort
  if s:lazy_in_flight
    return
  endif
  let s:lazy_in_flight = 1
  let t = s:last_trigger
  let cmd = t.handler.build_command(t.context, t.model_id, t.api_key)
  let l:chunks = []
  let opts = {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnLazyExit(t, l:chunks, status)},
        \ 'out_mode': 'raw',
        \ }
  call job_start(cmd, opts)
  call vim_ai_autocomplete#SchedulePending(s:PendingDelayMs())
endfunction

function! s:OnLazyExit(t, chunks, status) abort
  let s:lazy_in_flight = 0
  if a:t.gen != s:gen
    return
  endif
  call vim_ai_autocomplete#ClearPending()
  if !vim_ai_autocomplete#IsVisible() || vim_ai_autocomplete#CompletionMenuVisible()
    return
  endif
  if bufnr('%') != a:t.bufnr || line('.') != a:t.lnum || col('.') != a:t.col
    return
  endif
  let body = join(a:chunks, '')
  let lines = a:t.handler.parse_response(body)
  if empty(lines)
    call s:WarnCompletionFailure(a:t.provider, a:status, body)
    return
  endif
  let [display, redundant_after] = s:ProcessCandidate(lines, a:t.lnum, a:t.col, a:t.after)
  let key = join(display, "\n")
  for existing in s:alternatives
    if join(existing.lines, "\n") ==# key
      echo 'vim-ai-autocomplete: no new alternative (the model repeated itself)'
      return
    endif
  endfor
  call vim_ai_autocomplete#AppendAlternative({'lines': display, 'redundant_after': redundant_after})
endfunction

" Previously any failure (exit != 0, or an error response from the API) meant
" no suggestion appeared and NO warning was shown -- real finding, while
" testing with an API credit balance of zero: it looked as if the completion
" simply did nothing, with no hint why. Returns '' when there is nothing
" wrong to report (a legitimately empty response, e.g. the cursor at the end
" of a complete file).
" A gemini candidate blocked by RECITATION/SAFETY legitimately carries no
" parts -- but reporting nothing made "gemini returned nothing" undiagnosable
" in the field (2026-08-26). Name the block reason instead of staying silent.
function! vim_ai_autocomplete#DescribeCompletionFailure(provider, status, raw_output) abort
  let message = vim_ai_autocomplete#ExtractApiErrorMessage(a:raw_output)
  if !empty(message)
    return printf('vim-ai-autocomplete (%s): %s', a:provider, message)
  endif
  try
    let data = json_decode(a:raw_output)
    if type(data) == v:t_dict && type(get(data, 'candidates', v:null)) == v:t_list && !empty(data.candidates)
      let reason = get(data.candidates[0], 'finishReason', '')
      if index(['RECITATION', 'SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST'], reason) >= 0
        return printf('vim-ai-autocomplete (%s): suggestion blocked (%s)', a:provider, reason)
      endif
    endif
  catch
  endtry
  if a:status != 0
    return printf('vim-ai-autocomplete (%s): request failed (exit %d), no detail in the response', a:provider, a:status)
  endif
  return ''
endfunction

let s:last_completion_error = ''

function! s:WarnCompletionFailure(provider, status, raw_output) abort
  let message = vim_ai_autocomplete#DescribeCompletionFailure(a:provider, a:status, a:raw_output)
  if empty(message) || message ==# s:last_completion_error
    return
  endif
  let s:last_completion_error = message
  echohl WarningMsg
  echomsg message
  echohl None
endfunction

" The per-candidate post-processing pipeline, shared by the single-suggestion
" path and every alternative (issue #3 requires it to run per candidate).
" Returns [display_lines, redundant_after].
function! s:ProcessCandidate(lines, lnum, col, after) abort
  let lines = a:lines
  let current_line = getline(a:lnum)
  let before_cursor = a:col > 1 ? current_line[: a:col - 2] : ''
  " CountRedundantAfterChars MUST run against the ORIGINAL suggestion,
  " before any adjustment -- real finding ("def fibonacci(", where the last
  " parenthesis never turned red): the real suggestion closes an INNER call
  " (fibonacci(n - 2)) whose final ")" coincides textually with the "after"
  " of the cursor (a single ")"). Trimming the suggestion FIRST corrupted
  " that legitimate closer and zeroed the depth computation. Fixed by
  " running the structural computation FIRST, with the text intact.
  "
  " Both sources of redundancy -- structural (brackets/quotes) and textual
  " overlap (ComputeTextOverlapLength) -- ADD UP into a single
  " redundant_after, and the suggestion is NEVER trimmed here: it always
  " shows the complete API text, with the real "after" marked in red and
  " discarded on accept.
  let redundant_after = vim_ai_autocomplete#CountRedundantAfterChars(before_cursor, join(lines, "\n"), a:after)
  let remaining_after = strpart(a:after, redundant_after)
  let redundant_after += vim_ai_autocomplete#ComputeTextOverlapLength(lines, remaining_after)
  " a:after may span SEVERAL real buffer lines (up to 20 lines below the
  " cursor go to the prompt) -- but the highlight and Accept() only operate
  " on the cursor line. Cap redundant_after at what is really left ON THIS
  " LINE (a whole suggestion duplicating several existing lines is a known,
  " uncovered scope).
  let current_line_remainder = strpart(current_line, a:col - 1)
  let redundant_after = min([redundant_after, len(current_line_remainder)])
  " before AdjustSuggestionLines: this one works on the raw model output,
  " which is where the duplicated indentation lives.
  let lines = vim_ai_autocomplete#StripLeadingOverlap(lines, before_cursor)
  let lines = vim_ai_autocomplete#AdjustSuggestionLines(lines, before_cursor, &filetype, shiftwidth(), &expandtab)
  " last, with the lines already in the final shape that reaches the screen:
  " drop from the suggestion the closing characters the buffer already has,
  " so ")" is not rendered twice, pushing the real one away from the cursor.
  return vim_ai_autocomplete#SplitDisplayTail(lines, a:after, redundant_after)
endfunction

" Optional field diagnostics: when g:vim_ai_autocomplete_debug_log names a
" file, every response appends one line there -- generation, exit status,
" body size, whether it was current, and the first bytes -- so a silently
" dropped answer can be traced without a debugger (added 2026-09-02 for a
" Gemini answer that vanished between the API and the screen).
function! s:DebugLog(gen, status, body, note) abort
  let path = get(g:, 'vim_ai_autocomplete_debug_log', '')
  if empty(path)
    return
  endif
  call writefile([printf('%s gen=%d/%d status=%d len=%d %s :: %s', strftime('%H:%M:%S'), a:gen, s:gen, a:status, len(a:body), a:note, strtrans(a:body[:160]))], path, 'a')
endfunction

function! s:OnExit(gen, chunks, status, provider, parse_response, parse_alternatives, wanted, bufnr, lnum, col, after) abort
  call s:DebugLog(a:gen, a:status, join(a:chunks, ''), a:gen == s:gen ? 'current' : 'stale')
  if a:gen != s:gen
    return
  endif
  " issue #4: this request is over, whatever comes next -- the marker goes
  " on every path below (answer, stale, failure).
  call vim_ai_autocomplete#ClearPending()
  " drop it if the cursor already moved since the request was made (the
  " response arrived too late, the context changed) -- this applies to the
  " error path as well, otherwise an error from a stale request could surface
  " out of context after the user has already moved on.
  if bufnr('%') != a:bufnr || line('.') != a:lnum || col('.') != a:col
    call s:DebugLog(a:gen, a:status, '', printf('dropped: cursor moved (%d,%d -> %d,%d)', a:lnum, a:col, line('.'), col('.')))
    return
  endif
  " issue #2: the menu may have opened while the request was in flight.
  if vim_ai_autocomplete#CompletionMenuVisible()
    call s:DebugLog(a:gen, a:status, '', 'dropped: completion menu visible')
    return
  endif
  let body = join(a:chunks, '')
  if a:wanted > 0
    " the whole post-processing pipeline runs PER candidate (issue #3): each
    " alternative closes (or not) its own brackets, duplicates (or not) its
    " own indentation.
    let entries = []
    for candidate in a:parse_alternatives(body)
      let [display, redundant_after] = s:ProcessCandidate(candidate, a:lnum, a:col, a:after)
      call add(entries, {'lines': display, 'redundant_after': redundant_after})
    endfor
    if !empty(entries)
      let s:last_completion_error = ''
      call vim_ai_autocomplete#ShowAlternatives(entries)
    else
      call s:WarnCompletionFailure(a:provider, a:status, body)
    endif
    return
  endif
  let lines = a:parse_response(body)
  if !empty(lines)
    let s:last_completion_error = ''
    let [display, redundant_after] = s:ProcessCandidate(lines, a:lnum, a:col, a:after)
    call vim_ai_autocomplete#ShowSuggestion(display, redundant_after)
  else
    call s:WarnCompletionFailure(a:provider, a:status, body)
  endif
endfunction
