function! vim_ai_autocomplete#ResolveProvider(has_gemini, has_claude) abort
  if !a:has_gemini && !a:has_claude
    return [v:null, 'error', 'nenhuma API key encontrada (GEMINI_API_KEY nem ANTHROPIC_API_KEY) -- configure pelo menos uma em ~/.zsh_secrets']
  endif
  if a:has_gemini && a:has_claude
    return ['gemini', v:null, v:null]
  endif
  let provider = a:has_gemini ? 'gemini' : 'claude'
  let message = printf('só %s disponível (falta a outra API key) -- toggle ,ap desabilitado', provider)
  return [provider, 'warn', message]
endfunction

function! vim_ai_autocomplete#BuildContext(lines_before, lines_after, max_chars) abort
  let before = join(a:lines_before, "\n")
  let after = join(a:lines_after, "\n")
  let total = len(before) + len(after)
  if total > a:max_chars
    " mais peso pro texto ANTES do cursor (75/25) -- mesmo criterio do
    " context_ratio do minuet-ai.nvim no lado Neovim
    let before_budget = float2nr(a:max_chars * 0.75)
    let after_budget = a:max_chars - before_budget
    let before = strcharpart(before, max([0, strchars(before) - before_budget]))
    let after = strcharpart(after, 0, after_budget)
  endif
  return {'before': before, 'after': after}
endfunction

function! vim_ai_autocomplete#BuildGeminiRequest(context) abort
  let prompt = "Complete o codigo a seguir. Responda SOMENTE com a continuacao do codigo, sem explicacao, sem markdown.\n\n" . a:context.before
  return json_encode({'contents': [{'parts': [{'text': prompt}]}]})
endfunction

function! vim_ai_autocomplete#BuildClaudeRequest(context, model) abort
  let prompt = "Complete o codigo a seguir. Responda SOMENTE com a continuacao do codigo, sem explicacao, sem markdown.\n\n" . a:context.before
  return json_encode({'model': a:model, 'max_tokens': 256, 'messages': [{'role': 'user', 'content': prompt}]})
endfunction

function! vim_ai_autocomplete#ParseGeminiResponse(body) abort
  let data = json_decode(a:body)
  if type(data) != v:t_dict || !has_key(data, 'candidates') || empty(data.candidates)
    return []
  endif
  let text = data.candidates[0].content.parts[0].text
  return split(text, "\n", 1)
endfunction

function! vim_ai_autocomplete#ParseClaudeResponse(body) abort
  let data = json_decode(a:body)
  if type(data) != v:t_dict || !has_key(data, 'content') || empty(data.content)
    return []
  endif
  let text = data.content[0].text
  return split(text, "\n", 1)
endfunction

let s:prop_type = 'VimAiAutocompleteSuggestion'
let s:current_suggestion = []
let s:suggestion_lnum = 0

function! s:EnsurePropType() abort
  if empty(prop_type_get(s:prop_type))
    call prop_type_add(s:prop_type, {'highlight': 'Comment'})
  endif
endfunction

function! vim_ai_autocomplete#ShowSuggestion(lines) abort
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(a:lines)
    return
  endif
  call s:EnsurePropType()
  call prop_add(line('.'), col('.'), {'type': s:prop_type, 'text': a:lines[0]})
  for l in a:lines[1:]
    call prop_add(line('.'), 0, {'type': s:prop_type, 'text_align': 'below', 'text': l})
  endfor
  let s:current_suggestion = copy(a:lines)
  let s:suggestion_lnum = line('.')
endfunction

function! vim_ai_autocomplete#ClearSuggestion() abort
  if empty(s:current_suggestion)
    return
  endif
  call prop_remove({'type': s:prop_type, 'all': v:true}, s:suggestion_lnum)
  let s:current_suggestion = []
  let s:suggestion_lnum = 0
endfunction

function! vim_ai_autocomplete#IsVisible() abort
  return !empty(s:current_suggestion)
endfunction

function! vim_ai_autocomplete#CurrentSuggestion() abort
  return copy(s:current_suggestion)
endfunction
