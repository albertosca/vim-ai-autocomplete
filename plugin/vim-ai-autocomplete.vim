if exists('g:loaded_vim_ai_autocomplete')
  finish
endif
let g:loaded_vim_ai_autocomplete = 1

" Plugin so-Vim (usa maparg().rhs assumindo o formato classico de mapeamento
" do CoC, e job_start(), API exclusiva do Vim). ~/.vimrc e sourced dentro do
" Neovim tambem (nvim/init.vim), entao esse plugin carregava la e quebrava:
" job_start() nao existe no Neovim (E117), e o <Tab> de blink.cmp (callback
" Lua, sem chave 'rhs') dispara E716 em SetupTabWrap -- os dois em TODA
" inicializacao do Neovim, reportado pelo Alberto ("Press ENTER" ao abrir).
" O Neovim ja tem o equivalente nativo (minuet-ai.nvim, nvim/lua/user/minuet.lua,
" usa jobstart() -- API async correta do Neovim), entao esse plugin nunca
" deveria rodar la.
if has('nvim')
  finish
endif

" Arquitetura de ghost-text (debounce + prop_add + wrap do mapeamento de Tab)
" inspirada na tecnica publica do github/copilot.vim (APIs do Vim 9: prop_add,
" timer_start, textprop) -- implementacao propria, sem codigo copiado. O
" copilot.vim e "All Rights Reserved" (nao open-source), so a tecnica com
" APIs publicas do Vim foi reaproveitada.

" O default nao pode ser mais o literal 'gemini' hardcoded -- com N modelos
" configuraveis (g:vim_ai_autocomplete_models), o primeiro modelo ativo pode
" ter QUALQUER nome (ex: 'gemini-flash'). Resolve via a mesma logica que
" RequestCompletion usa, senao o provider mostrado (,pr/:messages) fica
" errado ate a primeira troca manual, mesmo a completion em si ja caindo
" certo no fallback (achado real, testando modelos com nomes customizados).
let g:vim_ai_autocomplete_provider = get(g:, 'vim_ai_autocomplete_provider',
      \ vim_ai_autocomplete#ResolveDefaultModel(
      \   get(g:, 'vim_ai_autocomplete_models', vim_ai_autocomplete#DefaultModels()),
      \   vim_ai_autocomplete#ActiveModels())[0])
let g:vim_ai_autocomplete_auto_trigger = get(g:, 'vim_ai_autocomplete_auto_trigger', 1)

" ,pt nao depende de API key (so liga/desliga o debounce automatico), entao
" e registrado direto aqui -- diferente de ,pr (SetupProviderToggle), que so
" existe se houver mais de um provider pra alternar.
nnoremap <silent> <leader>pt :call vim_ai_autocomplete#ToggleAutoTrigger()<CR>

augroup vim_ai_autocomplete
  autocmd!
  autocmd VimEnter * call vim_ai_autocomplete#SetupTabWrap()
        \ | call vim_ai_autocomplete#SetupEscWrap()
        \ | call vim_ai_autocomplete#SetupProviderToggle(vim_ai_autocomplete#ActiveModels())
  autocmd CursorMovedI * call vim_ai_autocomplete#Trigger()
  autocmd InsertLeavePre * call vim_ai_autocomplete#ClearSuggestion()
augroup END
