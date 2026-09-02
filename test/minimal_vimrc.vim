" Minimal vimrc to run this plugin's vader suite in isolation -- no ~/.vimrc,
" no CoC, no personal config at all. `runtimepath+=.` assumes Vim was started
" with its cwd at the root of this repo (autoload/ and plugin/ live right
" there, not under plugins/vim-ai-autocomplete/ the way they do inside
" ~/.vim_runtime -- this repo IS the plugin).
set nocompatible
" Real isolation: packpath reduced to Vim's own runtime keeps the machine's
" native packages out (~/.vim/pack/*/start/* loads on ANY Vim start
" otherwise, -u or not) while Vim's bundled packs (netrw) keep working. On
" 2026-09-01 github/copilot.vim from ~/.vim/pack spawned its language server
" through npx on every vader run, prompting for the keychain each time.
" g:loaded_copilot is the belt to that brace: copilot.vim honours it even if
" a pack sneaks in.
let &packpath = $VIMRUNTIME
let g:loaded_copilot = 1
let mapleader = ','
set runtimepath+=.
set runtimepath+=./test/vendor/vader.vim
filetype plugin on
syntax on
