if exists('g:loaded_vim_ai_autocomplete')
  finish
endif
let g:loaded_vim_ai_autocomplete = 1

" Arquitetura de ghost-text (debounce + prop_add + wrap do mapeamento de Tab)
" inspirada na tecnica publica do github/copilot.vim (APIs do Vim 9: prop_add,
" timer_start, textprop) -- implementacao propria, sem codigo copiado. O
" copilot.vim e "All Rights Reserved" (nao open-source), so a tecnica com
" APIs publicas do Vim foi reaproveitada.
