# vim-ai-autocomplete

[Leia em português](README.pt.md)

Ghost-text AI autocomplete for Vim 9+ and Neovim, with pluggable multi-model round-robin (Gemini, Claude, or any model you configure).

## Installation

Requires `curl` on `$PATH`. Set at least one API key as an environment variable before starting Vim/Neovim (`GEMINI_API_KEY` and/or `ANTHROPIC_API_KEY`, or whatever `api_key_env` you configure per model — see [Configuration](#configuration)).

### Pathogen (Vim)

```bash
git submodule add https://github.com/albertosca/vim-ai-autocomplete.git ~/.vim/bundle/vim-ai-autocomplete
```

### lazy.nvim (Neovim)

```lua
{
  'albertosca/vim-ai-autocomplete',
  config = function()
    require('vim-ai-autocomplete').setup()
  end,
}
```

### vim-plug

```vim
Plug 'albertosca/vim-ai-autocomplete'
```

On Neovim, call `require('vim-ai-autocomplete').setup()` somewhere in your `init.lua` after plug is loaded. On Vim, no extra call is needed — `plugin/vim-ai-autocomplete.vim` loads itself.

### mini.deps

```lua
local add = MiniDeps.add
add({
  source = 'albertosca/vim-ai-autocomplete',
})
require('vim-ai-autocomplete').setup()
```

### Native packages (`:packadd`, no manager)

```bash
# Vim
git clone https://github.com/albertosca/vim-ai-autocomplete ~/.vim/pack/plugins/start/vim-ai-autocomplete
# Neovim
git clone https://github.com/albertosca/vim-ai-autocomplete ~/.local/share/nvim/site/pack/plugins/start/vim-ai-autocomplete
```

## Configuration

Both sides read the same globals — Vimscript globals are visible from Lua via `vim.g`, so there's a single source of truth even on Neovim.

```vim
" Vim (~/.vimrc) or Neovim (init.vim, or before require(...).setup() in init.lua)
let g:vim_ai_autocomplete_models = [
      \ {'name': 'gemini-flash', 'family': 'gemini', 'model_id': 'gemini-3.1-flash-lite', 'api_key_env': 'GEMINI_API_KEY'},
      \ {'name': 'claude-sonnet', 'family': 'anthropic', 'model_id': 'claude-sonnet-5', 'api_key_env': 'ANTHROPIC_API_KEY'},
      \ ]
```

Or, on Neovim, the equivalent via the `setup(opts)` facilitator (sugar over the same globals above — pick either style, not both):

```lua
require('vim-ai-autocomplete').setup({
  models = {
    { name = 'gemini-flash', family = 'gemini', model_id = 'gemini-3.1-flash-lite', api_key_env = 'GEMINI_API_KEY' },
    { name = 'claude-sonnet', family = 'anthropic', model_id = 'claude-sonnet-5', api_key_env = 'ANTHROPIC_API_KEY' },
  },
  auto_trigger = true, -- optional, defaults to true
})
```

| Field | Meaning |
|---|---|
| `name` | Whatever you want to call this model in `,pr`/`,pm`/`:VimAiAutocompleteModel` |
| `family` | `'gemini'` or `'anthropic'` — determines the request/response shape |
| `model_id` | The real model ID sent to the provider's API |
| `api_key_env` | Name of the environment variable holding that provider's API key |

If you configure nothing, it defaults to one Gemini and one Claude model. A model only becomes "active" (eligible for `,pr` cycling) if its `api_key_env` is actually set and non-empty in the environment.

## Usage

| Key | Action |
|---|---|
| `Tab` | Accept the visible suggestion (falls through to your original `Tab` mapping otherwise) |
| `Esc` | Dismiss the visible suggestion (falls through to your original `Esc` mapping otherwise) |
| `,pt` | Toggle auto-trigger on/off |
| `,pr` | Cycle to the next active model (only registered with 2+ active models) |
| `,pm` | Pick a model via `vim.ui.select` (Neovim only, only registered with 2+ active models) |
| `:VimAiAutocompleteModel <name>` | Switch directly to a named model, with completion |

## Architecture

- **FIM (fill-in-the-middle) prompting**: the buffer around the cursor is split into a "before" and "after" section (never sending the current line whole to either side), so the model knows exactly where the cursor sits and what already exists after it.
- **Redundancy detection**: two mechanisms, summed into one count of "characters to discard" from the real buffer text after the cursor — a structural bracket/quote-stack comparison (catches the case where the suggestion closes something already open before the cursor) and a textual suffix/prefix overlap check (catches the model literally repeating what's already there). The discarded span is always shown in red/strikethrough before being dropped on accept, never silently trimmed.
- **Ghost text rendering**: Vim uses `prop_add`/textprop (Vim 9+); Neovim uses extmarks (`nvim_buf_set_extmark` with `virt_text`/`virt_lines`).
- **Context enrichment (Neovim only)**: the buffer cut is Treesitter-scope-aware (uses the enclosing function/class instead of a naive line count) when a parser is available, falling back to the naive cut otherwise; a short-timeout (150ms) LSP `textDocument/definition` lookup optionally appends real cross-file definitions for symbols in scope.

## Contributing

```bash
bash test/run.sh
```

Runs the full suite (vader for the Vim side, plenary for the Neovim side) — see [CI](.github/workflows/test.yml) for how it runs in GitHub Actions. No API key or network access is required; every test is either pure logic or mocks the API call.

## Credits

- [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim) inspired one specific design decision — the 75/25 `context_ratio` weighting of the FIM prompt (more weight to the text before the cursor). No code was copied.
- [copilot.vim](https://github.com/github/copilot.vim) inspired the ghost-text *technique* (Vim 9's `prop_add`/textprop APIs, debounced via `timer_start`) — not its code. `copilot.vim` is "All Rights Reserved", not open-source, so only the publicly-documented Vim APIs were reused, independently implemented.

## License

MIT — see [LICENSE](LICENSE).
