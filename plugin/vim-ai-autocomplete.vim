if exists('g:loaded_vim_ai_autocomplete')
  finish
endif
let g:loaded_vim_ai_autocomplete = 1

" Vim-only plugin (it reads maparg().rhs assuming CoC's classic mapping shape,
" and uses job_start(), a Vim-exclusive API). ~/.vimrc is sourced inside
" Neovim as well (nvim/init.vim), so this plugin used to load there and break:
" job_start() does not exist in Neovim (E117), and blink.cmp's <Tab> (a Lua
" callback, with no 'rhs' key) throws E716 in SetupTabWrap -- both on EVERY
" Neovim startup, reported as a "Press ENTER" prompt on open. Neovim has its
" own native equivalent (the Lua port in lua/vim-ai-autocomplete/, which uses
" vim.system() -- the correct async API there), so this plugin should never
" run under Neovim.
if has('nvim')
  finish
endif

" The ghost-text architecture (debounce plus prop_add plus wrapping the Tab
" mapping) is inspired by the public technique of github/copilot.vim (Vim 9
" APIs: prop_add, timer_start, textprop) -- own implementation, no code
" copied. copilot.vim is "All Rights Reserved" (not open source); only the
" technique, built on public Vim APIs, was reused.

" The default can no longer be the hardcoded literal 'gemini' -- with N
" configurable models (g:vim_ai_autocomplete_models), the first active model
" may have ANY name (e.g. 'gemini-flash'). Resolve it through the same logic
" RequestCompletion uses, otherwise the provider shown (,pr/:messages) stays
" wrong until the first manual switch, even though the completion itself
" already falls back correctly (real finding, while testing models with
" custom names).
let g:vim_ai_autocomplete_provider = get(g:, 'vim_ai_autocomplete_provider',
      \ vim_ai_autocomplete#ResolveDefaultModel(
      \   get(g:, 'vim_ai_autocomplete_models', vim_ai_autocomplete#DefaultModels()),
      \   vim_ai_autocomplete#ActiveModels())[0])
let g:vim_ai_autocomplete_auto_trigger = get(g:, 'vim_ai_autocomplete_auto_trigger', 1)

" ,pt does not depend on an API key (it only toggles the automatic debounce),
" so it is registered right here -- unlike ,pr (SetupProviderToggle), which
" only exists when there is more than one provider to cycle through.
nnoremap <silent> <leader>pt :call vim_ai_autocomplete#ToggleAutoTrigger()<CR>

" Dismisses the suggestion without leaving insert mode. It lives on a key of
" its own (and no longer in an <Esc> wrap) so that <Esc> stays plain <Esc> --
" see vim_ai_autocomplete#Dismiss().
inoremap <script><silent><expr> <C-]> vim_ai_autocomplete#Dismiss()

" Cycle keys for the alternatives feature (issue #3) -- only claimed when
" g:vim_ai_autocomplete_alternatives >= 2, see SetupAlternativesKeys().
call vim_ai_autocomplete#SetupAlternativesKeys()

augroup vim_ai_autocomplete
  autocmd!
  autocmd VimEnter * call vim_ai_autocomplete#SetupTabWrap()
        \ | call vim_ai_autocomplete#SetupProviderToggle(vim_ai_autocomplete#ActiveModels())
  autocmd CursorMovedI * call vim_ai_autocomplete#Trigger()
  autocmd InsertLeavePre * call vim_ai_autocomplete#ClearSuggestion()
augroup END
