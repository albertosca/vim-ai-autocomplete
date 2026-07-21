function! vim_ai_autocomplete#ResolveProvider(has_gemini, has_claude) abort
  if !a:has_gemini && !a:has_claude
    return [v:null, 'error', 'nenhuma API key encontrada (GEMINI_API_KEY nem ANTHROPIC_API_KEY) -- configure pelo menos uma em ~/.zsh_secrets']
  endif
  if a:has_gemini && a:has_claude
    return ['gemini', v:null, v:null]
  endif
  let provider = a:has_gemini ? 'gemini' : 'claude'
  let message = printf('só %s disponível (falta a outra API key) -- toggle ,pr desabilitado', provider)
  return [provider, 'warn', message]
endfunction

" A linha ATUAL (onde o cursor esta de verdade) nunca deveria entrar
" inteira nem em "antes" nem em "depois" -- precisa ser cortada na coluna
" do cursor. Achado real (2026-07-20, reportado pelo Alberto): sem isso,
" "def soma(" com cursor entre os parenteses que o auto-pairs ja inseriu
" mandava a linha INTEIRA ("def soma()") pros DOIS lados do prompt FIM, sem
" indicar onde o cursor realmente estava -- o modelo, confuso, chegou a
" gerar "(a, b):\n    return a + b)" do zero, duplicando o parenteses de
" abertura.
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
    " mais peso pro texto ANTES do cursor (75/25) -- mesmo criterio do
    " context_ratio do minuet-ai.nvim no lado Neovim
    let before_budget = float2nr(a:max_chars * 0.75)
    let after_budget = a:max_chars - before_budget
    let before = strcharpart(before, max([0, strchars(before) - before_budget]))
    let after = strcharpart(after, 0, after_budget)
  endif
  return {'before': before, 'after': after}
endfunction

" Prompt estilo FIM (fill-in-the-middle): antes so mandavamos context.before,
" entao o modelo nao tinha como saber que ja existe texto depois do cursor
" (ex: o ")" que o auto-pairs ja inseriu ao abrir o parenteses) -- ele gerava
" uma sugestao "as cegas" com seu proprio fechamento, e o Accept() preservava
" o texto real depois do cursor tambem, duplicando (achado real, reportado
" pelo Alberto: "empurra o caractere pos la pra depois da sugestao").
" Confirmado com chamada real: SEM o "DEPOIS DO CURSOR" o modelo devolve
" 'x):\n    return x * 2' pra "def foo(" (fecha o proprio parenteses); COM,
" devolve so 'x, y' (sem duplicar). A instrucao sozinha nao e 100%
" confiavel (outro teste real mostrou o modelo repetindo o sufixo inteiro
" 3/3 vezes) -- por isso tambem existe TrimSuggestionOverlapWithAfter()
" como rede de seguranca no pos-processamento.
function! vim_ai_autocomplete#BuildGeminiRequest(context) abort
  let prompt = "Complete o codigo a seguir. O cursor esta entre o texto ANTES e o texto DEPOIS, que ja existem no buffer. Responda SOMENTE com o texto que deve ser inserido ENTRE eles -- nao repita nada que ja aparece em ANTES ou DEPOIS. Sem explicacao, sem markdown.\n\nANTES DO CURSOR:\n" . a:context.before . "\n\nDEPOIS DO CURSOR:\n" . a:context.after
  return json_encode({'contents': [{'parts': [{'text': prompt}]}]})
endfunction

function! vim_ai_autocomplete#BuildClaudeRequest(context, model) abort
  let prompt = "Complete o codigo a seguir. O cursor esta entre o texto ANTES e o texto DEPOIS, que ja existem no buffer. Responda SOMENTE com o texto que deve ser inserido ENTRE eles -- nao repita nada que ja aparece em ANTES ou DEPOIS. Sem explicacao, sem markdown.\n\nANTES DO CURSOR:\n" . a:context.before . "\n\nDEPOIS DO CURSOR:\n" . a:context.after
  return json_encode({'model': a:model, 'max_tokens': 256, 'messages': [{'role': 'user', 'content': prompt}]})
endfunction

" Rede de seguranca pro prompt FIM acima -- se o modelo mesmo assim repetir
" (parcial ou totalmente) o texto que ja existe depois do cursor, remove
" essa sobreposicao da sugestao. Acha a maior sobreposicao entre o FIM da
" sugestao e o INICIO do texto depois do cursor e corta ela. Se a sugestao
" inteira for so essa repeticao (nada de novo pra inserir), retorna lista
" vazia -- nao [''], que apareceria como uma sugestao fantasma vazia mas
" "visivel" (IsVisible() conta [''] como visivel).
function! vim_ai_autocomplete#TrimSuggestionOverlapWithAfter(lines, after_text) abort
  if empty(a:lines) || empty(a:after_text)
    return a:lines
  endif
  let suggestion_text = join(a:lines, "\n")
  let max_check = min([len(suggestion_text), len(a:after_text)])
  let overlap_len = 0
  let n = max_check
  while n > 0
    let suffix = strpart(suggestion_text, len(suggestion_text) - n, n)
    let prefix = strpart(a:after_text, 0, n)
    if suffix ==# prefix
      let overlap_len = n
      break
    endif
    let n -= 1
  endwhile
  if overlap_len == 0
    return a:lines
  endif
  let trimmed_text = strpart(suggestion_text, 0, len(suggestion_text) - overlap_len)
  " se o corte caiu exatamente numa quebra de linha, sobra um "\n" pendurado
  " no fim -- split() geraria uma linha vazia fantasma extra no resultado.
  let trimmed_text = substitute(trimmed_text, '\n$', '', '')
  if empty(trimmed_text)
    return []
  endif
  return split(trimmed_text, "\n", 1)
endfunction

" Complementa TrimSuggestionOverlapWithAfter() -- essa cobre sobreposicao
" de TEXTO (sugestao termina com o que "depois" comeca); esta cobre
" sobreposicao de ESTRUTURA: quando a sugestao fecha, com seu proprio
" texto, um parenteses/colchete/chave que ja estava aberto ANTES do
" cursor, o fechamento real que ja existe em "depois" (ex: inserido pelo
" auto-pairs) fica orfao. Achado real (2026-07-20, "def soma(" com cursor
" entre os parenteses): a sugestao "a, b):\n    return a + b" fecha o
" proprio "(" de "def soma(" -- o ")" real sobrava no fim do texto
" aceito ("def soma(a, b):\n    return a + b)"). Retorna quantos
" caracteres do INICIO de "depois" devem ser descartados (nao inseridos
" de volta) ao aceitar.
function! vim_ai_autocomplete#CountRedundantAfterChars(before_text, suggestion_text, after_text) abort
  let pairs = {'(': ')', '[': ']', '{': '}'}
  let closers = ')]}'
  let stack = []
  for char in split(a:before_text, '\zs')
    if has_key(pairs, char)
      call add(stack, char)
    elseif stridx(closers, char) >= 0 && !empty(stack) && pairs[stack[-1]] ==# char
      call remove(stack, -1)
    endif
  endfor
  let depth_before = len(stack)
  for char in split(a:suggestion_text, '\zs')
    if has_key(pairs, char)
      call add(stack, char)
    elseif stridx(closers, char) >= 0 && !empty(stack) && pairs[stack[-1]] ==# char
      call remove(stack, -1)
    endif
  endfor
  let redundant = max([0, depth_before - len(stack)])
  if redundant == 0
    return 0
  endif
  " so descarta se "depois" realmente comecar com essa quantidade de
  " fechamentos -- senao pode nao ser o mesmo bracket (edicao incomum),
  " melhor nao arriscar apagar algo que nao e obviamente redundante.
  let n = 0
  while n < redundant && n < len(a:after_text) && stridx(closers, a:after_text[n]) >= 0
    let n += 1
  endwhile
  return n
endfunction

" `ant` (CLI oficial da Anthropic pro Developer Platform, OAuth) cobra do
" MESMO credito de API pago por token que uma ANTHROPIC_API_KEY estatica --
" nao da acesso ao credito incluso da assinatura Claude Pro/Max (esse e um
" produto separado, Claude.ai/Claude Code, com seu proprio sistema de uso).
" Removido daqui 2026-07-20 (Alberto: "visto que o ant e inutil aqui") --
" so trocava a forma de autenticar, sem nenhuma vantagem de billing pro
" caso de uso deste plugin. Sempre usa a key estatica agora.
function! vim_ai_autocomplete#BuildClaudeCommand(context, model, api_key) abort
  let body = vim_ai_autocomplete#BuildClaudeRequest(a:context, a:model)
  return ['curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
        \ '-H', 'x-api-key: ' . a:api_key,
        \ '-H', 'anthropic-version: 2023-06-01',
        \ '-H', 'Content-Type: application/json', '-d', body]
endfunction

" Extrai a mensagem de erro de uma resposta JSON de erro da API (formato
" comum entre Gemini e Claude: {"error": {"message": ...}}). Retorna '' se
" nao for JSON, ou nao tiver esse formato.
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

" Alguns modelos (confirmado com gemini-3.1-flash-lite, reproduzivel 3/3
" chamadas reais) tratam a resposta como continuacao literal de bytes: se o
" contexto termina em ":" (abertura de bloco Python), a primeira linha da
" sugestao vem sem quebra de linha E sem indentacao propria -- o texto gruda
" direto na linha atual (ex: "def fibonacci(n):if n <= 1:"). Pedir pro
" modelo incluir a quebra de linha via instrucao no prompt NAO resolveu
" (testado, mesmo comportamento). Fix: quando o contexto termina em ":" e a
" filetype e python, insere uma quebra de linha e um nivel de indentacao
" (shiftwidth) na primeira linha da sugestao -- as linhas seguintes ja vem
" com indentacao relativa correta do proprio modelo, so a primeira precisa
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
    " ja veio com quebra de linha propria -- nao mexe
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
let s:suggestion_redundant_after = 0

function! s:EnsurePropType() abort
  if empty(prop_type_get(s:prop_type))
    call prop_type_add(s:prop_type, {'highlight': 'Comment'})
  endif
endfunction

" Highlight PROPRIO pro caractere real redundante -- riscado (strikethrough),
" nao o mesmo estilo do ghost text. Reusar o highlight do ghost text (que
" significa "isso vai ser inserido") pro caractere que na verdade vai ser
" REMOVIDO era enganoso: aparecia como ghost text mas sumia ao aceitar com
" Tab, em vez de "solidificar" como o resto da sugestao (achado real,
" reportado pelo Alberto: "o parenteses errado aparece como ghost text mas
" quando aperto tab ele nao aparece").
function! s:EnsureRedundantPropType() abort
  if empty(prop_type_get(s:redundant_prop_type))
    if !hlexists('VimAiAutocompleteRedundant')
      " strikethrough sozinho nao e confiavel (depende de t_Cs/t_Ce do
      " terminal -- confirmado nao aparecer via captura de cores real
      " dentro do tmux). Vermelho (gruvbox) como sinal PRINCIPAL, sempre
      " visivel, com strikethrough de bonus quando o terminal suportar.
      highlight default VimAiAutocompleteRedundant cterm=strikethrough gui=strikethrough ctermfg=167 guifg=#fb4934
    endif
    call prop_type_add(s:redundant_prop_type, {'highlight': 'VimAiAutocompleteRedundant'})
  endif
endfunction

" redundant_after (opcional, default 0): quantos caracteres do INICIO do
" texto real DEPOIS do cursor devem ser DESCARTADOS (nao preservados) ao
" aceitar -- ver CountRedundantAfterChars(). Usado quando a sugestao ja
" fecha, com seu proprio texto, um parenteses/colchete/chave que estava
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
    " Mapeamentos <Tab> baseados em callback Lua (ex: blink.cmp no Neovim,
    " "pula pro proximo placeholder do snippet ou cai pro Tab normal") nao
    " tem chave 'rhs' no dict devolvido por maparg() -- acessar .rhs direto
    " dispara E716 em TODA inicializacao do Neovim (achado real, reportado
    " pelo Alberto: erro/prompt "Press ENTER" logo ao abrir). get() com
    " default cobre os dois formatos (rhs string classico e callback).
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
    " mapeamento original e <expr>: o retorno do callback E' o resultado do
    " expr (mesmo mecanismo que o Neovim usa internamente pra mapeamentos
    " <expr> com callback Lua, ex: blink.cmp).
    let result = s:tab_fallback_callback()
    return s:tab_fallback_is_expr ? result : ''
  endif
  return s:tab_fallback_is_expr ? eval(s:tab_fallback_rhs) : s:tab_fallback_rhs
endfunction

let s:esc_fallback_rhs = '"\<Esc>"'
let s:esc_fallback_is_expr = 1

function! vim_ai_autocomplete#SetupEscWrap() abort
  let original_map = maparg('<Esc>', 'i', 0, 1)
  if !empty(original_map)
    let s:esc_fallback_rhs = original_map.rhs
    let s:esc_fallback_is_expr = get(original_map, 'expr', 0)
  endif
  inoremap <script><silent><expr> <Esc> vim_ai_autocomplete#EscHandler()
endfunction

function! vim_ai_autocomplete#EscHandler() abort
  if vim_ai_autocomplete#IsVisible()
    call vim_ai_autocomplete#ClearSuggestion()
    return ''
  endif
  return s:esc_fallback_is_expr ? eval(s:esc_fallback_rhs) : s:esc_fallback_rhs
endfunction

function! vim_ai_autocomplete#Accept() abort
  let lines = vim_ai_autocomplete#CurrentSuggestion()
  let redundant_after = s:suggestion_redundant_after
  call vim_ai_autocomplete#ClearSuggestion()
  if empty(lines)
    return ''
  endif
  " Insere direto no buffer via setline()/append() em vez de "digitar" via
  " <CR> simulado -- digitar <CR> dispara o autoindent/indentexpr real do
  " Vim a cada linha, que soma em cima da indentacao que o texto da API ja
  " trouxe, dobrando/desalinhando a indentacao real (achado via debug real
  " com o Gemini: linha esperada com 8 espacos virava 12, outra virava 24).
  "
  " A mutacao do buffer precisa ser ADIADA via timer_start(0, ...): um
  " mapeamento <expr> (como o <Tab> que chama esta funcao) NAO pode mudar o
  " texto do buffer durante sua propria avaliacao -- fazer isso direto aqui
  " dispara E565 (confirmado rodando de verdade contra o mapeamento real de
  " <Tab>, nao só via :call). timer_start com delay 0 roda o callback assim
  " que o Vim volta pro loop de eventos, ja fora da avaliacao do <expr>.
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

function! vim_ai_autocomplete#SetupProviderToggle(has_gemini, has_claude) abort
  if a:has_gemini && a:has_claude
    " <leader>pr, nao <leader>ap nem <leader>pv: <leader>a ja e code actions
    " do CoC (configs.vim) -- <leader>ap compartilhava prefixo com um
    " mapeamento completo existente (achado real, reportado pelo Alberto).
    " <leader>pv tambem foi descartado: colide com o seletor de venv Python
    " do lado Neovim (nvim/lua/user/venv.lua) -- mesma tecla escolhida nos
    " dois lados por consistencia, entao precisa ser livre nos dois.
    nnoremap <silent> <leader>pr :call vim_ai_autocomplete#ToggleProvider()<CR>
  endif
endfunction

function! vim_ai_autocomplete#ToggleProvider() abort
  let g:vim_ai_autocomplete_provider = g:vim_ai_autocomplete_provider ==# 'gemini' ? 'claude' : 'gemini'
  echom 'vim-ai-autocomplete: provider agora e ' . g:vim_ai_autocomplete_provider
  " avisa na hora se a key estatica do Claude nao funciona (billing, key
  " invalida, etc) -- sem isso, o usuario so descobre no primeiro completion
  " de verdade (achado real, reportado pelo Alberto depois de remover o
  " ant: "agora quando troco de provider nao tem mensagem de erro alguma").
  " Chamada leve (max_tokens=1), disparada so ao alternar PRA claude, nao
  " em todo VimEnter como o antigo CheckAntAuth fazia.
  if g:vim_ai_autocomplete_provider ==# 'claude'
    call s:CheckClaudeKey()
  endif
endfunction

function! s:CheckClaudeKey() abort
  if empty($ANTHROPIC_API_KEY)
    return
  endif
  let body = json_encode({'model': 'claude-sonnet-4-5-20250929', 'max_tokens': 1,
        \ 'messages': [{'role': 'user', 'content': 'hi'}]})
  let cmd = ['curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
        \ '-H', 'x-api-key: ' . $ANTHROPIC_API_KEY,
        \ '-H', 'anthropic-version: 2023-06-01',
        \ '-H', 'Content-Type: application/json', '-d', body]
  let l:chunks = []
  call job_start(cmd, {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnClaudeKeyCheckExit(status, l:chunks)},
        \ 'out_mode': 'raw',
        \ })
endfunction

function! s:OnClaudeKeyCheckExit(status, chunks) abort
  let message = vim_ai_autocomplete#ExtractApiErrorMessage(join(a:chunks, ''))
  if empty(message)
    return
  endif
  echohl WarningMsg
  echomsg 'vim-ai-autocomplete (claude): ' . message
  echohl None
endfunction

let s:timer_id = -1
let s:gen = 0

function! vim_ai_autocomplete#Trigger() abort
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
  echom 'vim-ai-autocomplete: auto-trigger ' . (g:vim_ai_autocomplete_auto_trigger ? 'ligado' : 'desligado')
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
  let lines_before_full = getline(first, line('.') - 1)
  let lines_after_full = getline(line('.') + 1, last)
  let [lines_before, lines_after] = vim_ai_autocomplete#SplitLinesAtCursor(
        \ lines_before_full, getline('.'), col('.'), lines_after_full)
  let context = vim_ai_autocomplete#BuildContext(lines_before, lines_after, 16000)

  if provider ==# 'gemini'
    let body = vim_ai_autocomplete#BuildGeminiRequest(context)
    let endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=' . $GEMINI_API_KEY
    let cmd = ['curl', '-s', '-X', 'POST', endpoint, '-H', 'Content-Type: application/json', '-d', body]
  else
    let cmd = vim_ai_autocomplete#BuildClaudeCommand(context, 'claude-sonnet-4-5-20250929', $ANTHROPIC_API_KEY)
  endif

  let s:gen += 1
  let l:gen = s:gen
  let l:chunks = []
  let l:bufnr = bufnr('%')
  let l:lnum = line('.')
  let l:col = col('.')
  let l:provider = provider
  let l:after = context.after

  let opts = {
        \ 'out_cb': {ch, msg -> add(l:chunks, msg)},
        \ 'exit_cb': {job, status -> s:OnExit(l:gen, l:chunks, status, l:provider, l:bufnr, l:lnum, l:col, l:after)},
        \ 'out_mode': 'raw',
        \ }
  call job_start(cmd, opts)
endfunction

" Antes, qualquer falha (exit != 0, ou resposta de erro da API) resultava em
" nenhuma sugestao aparecer e NENHUM aviso -- achado real, reportado pelo
" Alberto testando com credito de API zerado: parecia que o autocomplete
" simplesmente nao fazia nada, sem pista do motivo. Retorna '' quando nao ha
" nada de errado pra reportar (resposta vazia legitima, ex: cursor no fim
" de um arquivo completo).
function! vim_ai_autocomplete#DescribeCompletionFailure(provider, status, raw_output) abort
  let message = vim_ai_autocomplete#ExtractApiErrorMessage(a:raw_output)
  if !empty(message)
    return printf('vim-ai-autocomplete (%s): %s', a:provider, message)
  endif
  if a:status != 0
    return printf('vim-ai-autocomplete (%s): request falhou (exit %d), sem detalhe na resposta', a:provider, a:status)
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

function! s:OnExit(gen, chunks, status, provider, bufnr, lnum, col, after) abort
  if a:gen != s:gen
    return
  endif
  " descarta se o cursor ja se moveu desde que o request foi feito
  " (resposta chegou tarde demais, contexto mudou) -- vale tambem pro aviso
  " de erro, senao um erro de um request velho poderia aparecer fora de
  " contexto depois que o usuario ja seguiu em frente.
  if bufnr('%') != a:bufnr || line('.') != a:lnum || col('.') != a:col
    return
  endif
  let body = join(a:chunks, '')
  let lines = a:provider ==# 'gemini'
        \ ? vim_ai_autocomplete#ParseGeminiResponse(body)
        \ : vim_ai_autocomplete#ParseClaudeResponse(body)
  if !empty(lines)
    let s:last_completion_error = ''
    let lines = vim_ai_autocomplete#TrimSuggestionOverlapWithAfter(lines, a:after)
    if !empty(lines)
      let current_line = getline(a:lnum)
      let before_cursor = a:col > 1 ? current_line[: a:col - 2] : ''
      let lines = vim_ai_autocomplete#AdjustSuggestionLines(lines, before_cursor, &filetype, shiftwidth(), &expandtab)
      let redundant_after = vim_ai_autocomplete#CountRedundantAfterChars(before_cursor, join(lines, "\n"), a:after)
      call vim_ai_autocomplete#ShowSuggestion(lines, redundant_after)
    endif
  else
    call s:WarnCompletionFailure(a:provider, a:status, body)
  endif
endfunction
