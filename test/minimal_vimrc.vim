" Minimal vimrc pra rodar a suite vader deste plugin isoladamente -- sem
" ~/.vimrc, sem CoC, sem nenhuma config pessoal. `runtimepath+=.` assume que
" o Vim foi iniciado com cwd na raiz deste repo (autoload/ e plugin/ vivem
" ali direto, nao debaixo de plugins/vim-ai-autocomplete/ como no
" ~/.vim_runtime -- este repo JA E' o plugin).
set nocompatible
let mapleader = ','
set runtimepath+=.
set runtimepath+=./test/vendor/vader.vim
filetype plugin on
syntax on
