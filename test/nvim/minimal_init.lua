-- Minimal init to run this plugin's plenary suite in isolation -- no
-- nvim/init.vim, no lazy.nvim, no personal config at all. It only appends to
-- the runtimepath: (1) the root of this repo, so require('vim-ai-autocomplete.*')
-- resolves to its own code (lua/vim-ai-autocomplete/*.lua lives at the root,
-- this repo IS the plugin); (2) plenary.nvim (a submodule in test/vendor/).
local this_file = debug.getinfo(1, "S").source:sub(2)
local test_nvim_dir = vim.fn.fnamemodify(this_file, ":h")
local test_dir = vim.fn.fnamemodify(test_nvim_dir, ":h")
local repo_root = vim.fn.fnamemodify(test_dir, ":h")

vim.opt.rtp:append(repo_root)
vim.opt.rtp:append(test_dir .. "/vendor/plenary.nvim")
