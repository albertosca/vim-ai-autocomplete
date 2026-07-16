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

function! vim_ai_autocomplete#BuildClaudeCommand(context, model, has_ant_authenticated, api_key) abort
  let body = vim_ai_autocomplete#BuildClaudeRequest(a:context, a:model)
  if a:has_ant_authenticated
    return {'cmd': ['ant', 'messages', 'create', '--model', a:model, '--max-tokens', '256', '--format', 'json'], 'stdin': body}
  else
    return {'cmd': ['curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
          \ '-H', 'x-api-key: ' . a:api_key,
          \ '-H', 'anthropic-version: 2023-06-01',
          \ '-H', 'Content-Type: application/json', '-d', body], 'stdin': ''}
  endif
endfunction

function! vim_ai_autocomplete#RunWithoutAnthropicKey(Fn) abort
  let had_key = exists('$ANTHROPIC_API_KEY')
  let saved = had_key ? $ANTHROPIC_API_KEY : ''
  unlet $ANTHROPIC_API_KEY
  try
    let result = a:Fn()
  finally
    if had_key
      let $ANTHROPIC_API_KEY = saved
    endif
  endtry
  return result
endfunction

let s:ant_authenticated = 0

function! vim_ai_autocomplete#CheckAntAuth() abort
  if !executable('ant')
    return
  endif
  call vim_ai_autocomplete#RunWithoutAnthropicKey({-> s:StartAntAuthCheckJob()})
endfunction

function! s:StartAntAuthCheckJob() abort
  let job = job_start(['ant', 'messages', 'create', '--model', 'claude-sonnet-4-5-20250929', '--max-tokens', '1', '--format', 'json'], {
        \ 'in_io': 'pipe',
        \ 'exit_cb': function('s:OnAntAuthCheckExit'),
        \ 'out_mode': 'raw',
        \ })
  call ch_sendraw(job_getchannel(job), '{"model":"claude-sonnet-4-5-20250929","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')
  call ch_close_in(job_getchannel(job))
  return job
endfunction

function! s:OnAntAuthCheckExit(job, status) abort
  let s:ant_authenticated = (a:status == 0)
  if s:ant_authenticated
    call vim_ai_autocomplete#SetupProviderToggle(!empty($GEMINI_API_KEY), 1)
  else
    echomsg 'vim-ai-autocomplete: ant instalado mas nao autenticado -- rode "ant auth login" pra usar credito da assinatura Claude'
  endif
endfunction

function! vim_ai_autocomplete#ParseGeminiResponse(body) abort
  try
    let data = json_decode(a:body)
  catch
    return []
  endtry
  if type(data) != v:t_dict || !has_key(data, 'candidates') || empty(data.candidates)
    return []
  endif
  let text = data.candidates[0].content.parts[0].text
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

let s:tab_fallback_rhs = '"\<Tab>"'
let s:tab_fallback_is_expr = 1

function! vim_ai_autocomplete#SetupTabWrap() abort
  let original_map = maparg('<Tab>', 'i', 0, 1)
  if !empty(original_map)
    let s:tab_fallback_rhs = original_map.rhs
    let s:tab_fallback_is_expr = get(original_map, 'expr', 0)
  endif
  inoremap <script><silent><expr> <Tab> vim_ai_autocomplete#TabHandler()
endfunction

function! vim_ai_autocomplete#TabHandler() abort
  if vim_ai_autocomplete#IsVisible()
    return vim_ai_autocomplete#Accept()
  endif
  return s:tab_fallback_is_expr ? eval(s:tab_fallback_rhs) : s:tab_fallback_rhs
endfunction

function! vim_ai_autocomplete#Accept() abort
  let lines = vim_ai_autocomplete#CurrentSuggestion()
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(lines)
    return ''
  endif
  return join(lines, "\<CR>")
endfunction

function! vim_ai_autocomplete#SetupProviderToggle(has_gemini, has_claude) abort
  if a:has_gemini && a:has_claude
    nnoremap <silent> <leader>ap :call vim_ai_autocomplete#ToggleProvider()<CR>
  endif
endfunction

function! vim_ai_autocomplete#ToggleProvider() abort
  let g:vim_ai_autocomplete_provider = g:vim_ai_autocomplete_provider ==# 'gemini' ? 'claude' : 'gemini'
  echom 'vim-ai-autocomplete: provider agora e ' . g:vim_ai_autocomplete_provider
endfunction

let s:timer_id = -1
let s:gen = 0

function! vim_ai_autocomplete#Trigger() abort
  if s:timer_id != -1
    call timer_stop(s:timer_id)
  endif
  let s:timer_id = timer_start(600, function('vim_ai_autocomplete#OnTimer'))
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
  let has_gemini = !empty($GEMINI_API_KEY)
  let has_claude = !empty($ANTHROPIC_API_KEY)
  let [default_provider, level, _] = vim_ai_autocomplete#ResolveProvider(has_gemini, has_claude)
  if level ==# 'error'
    return
  endif
  let provider = get(g:, 'vim_ai_autocomplete_provider', default_provider)

  let first = max([1, line('.') - 100])
  let last = min([line('$'), line('.') + 20])
  let lines_before = getline(first, line('.'))
  let lines_after = getline(line('.'), last)
  let context = vim_ai_autocomplete#BuildContext(lines_before, lines_after, 16000)

  if provider ==# 'gemini'
    let body = vim_ai_autocomplete#BuildGeminiRequest(context)
    let endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent?key=' . $GEMINI_API_KEY
    let cmd = ['curl', '-s', '-X', 'POST', endpoint, '-H', 'Content-Type: application/json', '-d', body]
  else
    let body = vim_ai_autocomplete#BuildClaudeRequest(context, 'claude-sonnet-4-5-20250929')
    let cmd = ['curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
          \ '-H', 'x-api-key: ' . $ANTHROPIC_API_KEY,
          \ '-H', 'anthropic-version: 2023-06-01',
          \ '-H', 'Content-Type: application/json', '-d', body]
  endif

  let s:gen += 1
  let l:gen = s:gen
  let l:chunks = []
  let l:bufnr = bufnr('%')
  let l:lnum = line('.')
  let l:col = col('.')
  let l:provider = provider
  call job_start(cmd, {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnExit(l:gen, l:chunks, status, l:provider, l:bufnr, l:lnum, l:col)},
        \ 'out_mode': 'raw',
        \ })
endfunction

function! s:OnExit(gen, chunks, status, provider, bufnr, lnum, col) abort
  if a:gen != s:gen
    " uma requisicao mais nova ja superou esta -- descarta
    return
  endif
  if a:status != 0
    return
  endif
  " descarta se o cursor ja se moveu desde que o request foi feito
  " (resposta chegou tarde demais, contexto mudou)
  if bufnr('%') != a:bufnr || line('.') != a:lnum || col('.') != a:col
    return
  endif
  let body = join(a:chunks, '')
  let lines = a:provider ==# 'gemini'
        \ ? vim_ai_autocomplete#ParseGeminiResponse(body)
        \ : vim_ai_autocomplete#ParseClaudeResponse(body)
  if !empty(lines)
    call vim_ai_autocomplete#ShowSuggestion(lines)
  endif
endfunction
