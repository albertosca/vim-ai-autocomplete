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
function! vim_ai_autocomplete#BuildGeminiRequest(context) abort
  let prompt = "Complete the following code. The cursor sits between the BEFORE text and the AFTER text, both of which already exist in the buffer. Reply ONLY with the text that should be inserted BETWEEN them -- do not repeat anything already present in BEFORE or AFTER. No explanation, no markdown.\n\nBEFORE THE CURSOR:\n" . a:context.before . "\n\nAFTER THE CURSOR:\n" . a:context.after
  return json_encode({'contents': [{'parts': [{'text': prompt}]}]})
endfunction

function! vim_ai_autocomplete#BuildClaudeRequest(context, model) abort
  let prompt = "Complete the following code. The cursor sits between the BEFORE text and the AFTER text, both of which already exist in the buffer. Reply ONLY with the text that should be inserted BETWEEN them -- do not repeat anything already present in BEFORE or AFTER. No explanation, no markdown.\n\nBEFORE THE CURSOR:\n" . a:context.before . "\n\nAFTER THE CURSOR:\n" . a:context.after
  return json_encode({'model': a:model, 'max_tokens': 256, 'messages': [{'role': 'user', 'content': prompt}]})
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
function! vim_ai_autocomplete#BuildClaudeCommand(context, model, api_key) abort
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
function! vim_ai_autocomplete#BuildGeminiCommand(context, model_id, api_key) abort
  let body = vim_ai_autocomplete#BuildGeminiRequest(a:context)
  let endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/' . a:model_id . ':generateContent?key=' . a:api_key
  return ['curl', '-s', '-X', 'POST', endpoint, '-H', 'Content-Type: application/json', '-d', body]
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
  let handlers = {
        \ 'gemini': {'build_command': function('vim_ai_autocomplete#BuildGeminiCommand'), 'parse_response': function('vim_ai_autocomplete#ParseGeminiResponse')},
        \ 'anthropic': {'build_command': function('vim_ai_autocomplete#BuildClaudeCommand'), 'parse_response': function('vim_ai_autocomplete#ParseClaudeResponse')},
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
  return split(text, "\n", 1)
endfunction

function! vim_ai_autocomplete#ParseClaudeResponse(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || !has_key(data, 'content') || empty(data.content)
    return []
  endif
  let text = data.content[0].text
  return split(text, "\n", 1)
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
" reportado pelo Alberto: "o parenteses errado aparece como ghost text mas
" when I press tab it does not show up").
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
" texto real DEPOIS do cursor devem ser DESCARTADOS (nao preservados) ao
" accept -- see CountRedundantAfterChars(). Used when the suggestion already
" closes, with its own text, a bracket/brace that was open
" aberto antes do cursor, deixando o fechamento real (ex: do auto-pairs)
" orfao/duplicado.
function! vim_ai_autocomplete#ShowSuggestion(lines, ...) abort
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(a:lines)
    return
  endif
  call s:EnsurePropType()
  call prop_add(line('.'), col('.'), {'type': s:prop_type, 'text': a:lines[0]})
  for l in a:lines[1:]
    call prop_add(line('.'), 0, {'type': s:prop_type, 'text_align': 'below', 'text': l})
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
  " Writes straight into the buffer through setline()/append() instead of
  " <CR> simulado -- digitar <CR> dispara o autoindent/indentexpr real do
  " Vim on every line, stacking on top of the indentation the API text
  " trouxe, dobrando/desalinhando a indentacao real (achado via debug real
  " with Gemini: a line expected to have 8 spaces became 12, another became 24).
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
    command! -nargs=1 -complete=customlist,vim_ai_autocomplete#CompleteModelNames VimAiAutocompleteModel call vim_ai_autocomplete#SelectModel(<q-args>)
  endif
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
  call vim_ai_autocomplete#ClearSuggestion()
  if mode() !=# 'i'
    return
  endif
  call vim_ai_autocomplete#RequestCompletion()
endfunction

function! vim_ai_autocomplete#RequestCompletion() abort
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

  let first = max([1, line('.') - 100])
  let last = min([line('$'), line('.') + 20])
  let lines_before_full = getline(first, line('.') - 1)
  let lines_after_full = getline(line('.') + 1, last)
  let [lines_before, lines_after] = vim_ai_autocomplete#SplitLinesAtCursor(
        \ lines_before_full, getline('.'), col('.'), lines_after_full)
  let context = vim_ai_autocomplete#BuildContext(lines_before, lines_after, 16000)

  let cmd = handler.build_command(context, model.model_id, api_key)

  let s:gen += 1
  let l:gen = s:gen
  let l:chunks = []
  let l:bufnr = bufnr('%')
  let l:lnum = line('.')
  let l:col = col('.')
  let l:provider = model.name
  let l:ParseResponse = handler.parse_response
  let l:after = context.after

  let opts = {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnExit(l:gen, l:chunks, status, l:provider, l:ParseResponse, l:bufnr, l:lnum, l:col, l:after)},
        \ 'out_mode': 'raw',
        \ }
  call job_start(cmd, opts)
endfunction

" Antes, qualquer falha (exit != 0, ou resposta de erro da API) resultava em
" no suggestion appeared and NO warning was shown -- real finding, while
" testing with an API credit balance of zero: it looked as if the completion
" simply did nothing, with no hint why. Returns '' when there is nothing
" wrong to report (a legitimately empty response, e.g. the cursor at the end
" de um arquivo completo).
function! vim_ai_autocomplete#DescribeCompletionFailure(provider, status, raw_output) abort
  let message = vim_ai_autocomplete#ExtractApiErrorMessage(a:raw_output)
  if !empty(message)
    return printf('vim-ai-autocomplete (%s): %s', a:provider, message)
  endif
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

function! s:OnExit(gen, chunks, status, provider, parse_response, bufnr, lnum, col, after) abort
  if a:gen != s:gen
    return
  endif
  " drop it if the cursor already moved since the request was made (the
  " response arrived too late, the context changed) -- this applies to the
  " de erro, senao um erro de um request velho poderia aparecer fora de
  " context after the user has already moved on.
  if bufnr('%') != a:bufnr || line('.') != a:lnum || col('.') != a:col
    return
  endif
  let body = join(a:chunks, '')
  let lines = a:parse_response(body)
  if !empty(lines)
    let s:last_completion_error = ''
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
    " discarded on accept. Previously the textual overlap trimmed the
    " suggestion silently (marking nothing red) -- real finding: "the red
    " never shows up, even with the grey already written" (the grey had been
    " adjusted by that mechanism, but the real character was never marked,
    " because the two were handled differently).
    let redundant_after = vim_ai_autocomplete#CountRedundantAfterChars(before_cursor, join(lines, "\n"), a:after)
    let remaining_after = strpart(a:after, redundant_after)
    let redundant_after += vim_ai_autocomplete#ComputeTextOverlapLength(lines, remaining_after)
    " a:after may span SEVERAL real buffer lines (RequestCompletion
    " sends up to 20 lines below the cursor to the prompt) -- but the
    " highlight (prop_add with 'length') and Accept() (strpart on the current
    " line) only operate on the cursor line. Caps redundant_after at what is
    " really left ON THIS LINE, so it never tries to mark or delete text from
    " following real lines (a rare case: a whole suggestion duplicating
    " several existing lines) -- known scope, not covered.
    let current_line_remainder = strpart(current_line, a:col - 1)
    let redundant_after = min([redundant_after, len(current_line_remainder)])
    let lines = vim_ai_autocomplete#AdjustSuggestionLines(lines, before_cursor, &filetype, shiftwidth(), &expandtab)
    " last, with the lines already in the final shape that reaches the screen:
    " drop from the suggestion the closing characters the buffer already has,
    " so ")" is not rendered twice, pushing the real one away from the cursor.
    let [lines, redundant_after] = vim_ai_autocomplete#SplitDisplayTail(lines, a:after, redundant_after)
    call vim_ai_autocomplete#ShowSuggestion(lines, redundant_after)
  else
    call s:WarnCompletionFailure(a:provider, a:status, body)
  endif
endfunction
