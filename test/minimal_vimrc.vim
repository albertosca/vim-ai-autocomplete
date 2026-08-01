" Minimal vimrc to run this plugin's vader suite in isolation -- no ~/.vimrc,
" no CoC, no personal config at all. `runtimepath+=.` assumes Vim was started
" with its cwd at the root of this repo (autoload/ and plugin/ live right
" there, not under plugins/vim-ai-autocomplete/ the way they do inside
" ~/.vim_runtime -- this repo IS the plugin).
set nocompatible
let mapleader = ','
set runtimepath+=.
set runtimepath+=./test/vendor/vader.vim
filetype plugin on
syntax on
