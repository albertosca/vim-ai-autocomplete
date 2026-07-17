if exists('g:loaded_vim_ai_autocomplete')
  finish
endif
let g:loaded_vim_ai_autocomplete = 1

" Arquitetura de ghost-text (debounce + prop_add + wrap do mapeamento de Tab)
" inspirada na tecnica publica do github/copilot.vim (APIs do Vim 9: prop_add,
" timer_start, textprop) -- implementacao propria, sem codigo copiado. O
" copilot.vim e "All Rights Reserved" (nao open-source), so a tecnica com
" APIs publicas do Vim foi reaproveitada.

let g:vim_ai_autocomplete_provider = get(g:, 'vim_ai_autocomplete_provider', 'gemini')

augroup vim_ai_autocomplete
  autocmd!
  autocmd VimEnter * call vim_ai_autocomplete#SetupTabWrap()
        \ | call vim_ai_autocomplete#SetupEscWrap()
        \ | call vim_ai_autocomplete#SetupProviderToggle(!empty($GEMINI_API_KEY), !empty($ANTHROPIC_API_KEY))
        \ | call vim_ai_autocomplete#CheckAntAuth()
  autocmd CursorMovedI * call vim_ai_autocomplete#Trigger()
  autocmd InsertLeavePre * call vim_ai_autocomplete#ClearSuggestion()
augroup END
