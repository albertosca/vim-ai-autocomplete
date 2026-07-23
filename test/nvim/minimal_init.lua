-- Init minimo pra rodar a suite plenary deste plugin isoladamente -- sem
-- nvim/init.vim, sem lazy.nvim, sem nenhuma config pessoal. So adiciona ao
-- runtimepath: (1) a raiz deste repo, pra que require('vim-ai-autocomplete.*')
-- resolva pro proprio codigo (lua/vim-ai-autocomplete/*.lua vive na raiz,
-- este repo JA E' o plugin); (2) plenary.nvim (submodule em test/vendor/).
local this_file = debug.getinfo(1, "S").source:sub(2)
local test_nvim_dir = vim.fn.fnamemodify(this_file, ":h")
local test_dir = vim.fn.fnamemodify(test_nvim_dir, ":h")
local repo_root = vim.fn.fnamemodify(test_dir, ":h")

vim.opt.rtp:append(repo_root)
vim.opt.rtp:append(test_dir .. "/vendor/plenary.nvim")
