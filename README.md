# vim-ai-autocomplete

🇺🇸 [English](README.md) · 🇧🇷 [Português](README.pt.md)

[![test](https://github.com/albertosca/vim-ai-autocomplete/actions/workflows/test.yml/badge.svg)](https://github.com/albertosca/vim-ai-autocomplete/actions/workflows/test.yml)
[![lint](https://github.com/albertosca/vim-ai-autocomplete/actions/workflows/lint.yml/badge.svg)](https://github.com/albertosca/vim-ai-autocomplete/actions/workflows/lint.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Vim 9+](https://img.shields.io/badge/Vim-9%2B-019733?logo=vim&logoColor=white)
![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)

Ghost-text AI autocomplete for Vim 9+ and Neovim, with pluggable multi-model round-robin (Gemini, Claude, or any model you configure).

![demo: ghost-text suggestion appearing and being accepted with Tab](demo.gif)

## Under the hood

- **Two native implementations in behavioural parity** — pure Vimscript (Vim 9 textprops) and pure Lua (Neovim extmarks), no shared shim layer, each idiomatic to its editor.
- **206 tests, no network required** — 105 vader (Vim) + 101 plenary (Neovim), every API call mocked, running on every push in CI plus luacheck/vint linting.
- **FIM prompting with redundancy detection** — the model knows what sits after the cursor, and anything it repeats (a closing bracket auto-pairs already inserted, a duplicated suffix) is detected structurally, shown struck-through, and discarded on accept — never silently.
- **Fails soft** — malformed responses, safety-filtered candidates and billing errors surface as a single warning, never a stack trace mid-typing.

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
| `family` | `'gemini'`, `'anthropic'` or `'deepseek'` — determines the request/response shape |
| `model_id` | The real model ID sent to the provider's API |
| `api_key_env` | Name of the environment variable holding that provider's API key |

If you configure nothing, it defaults to one Gemini and one Claude model. A model only becomes "active" (eligible for `,pr` cycling) if its `api_key_env` is actually set and non-empty in the environment.

## Usage

| Key | Action |
|---|---|
| `Tab` | Accept the visible suggestion (falls through to your original `Tab` mapping otherwise) |
| `<C-]>` | Dismiss the visible suggestion without leaving insert mode |
| `,pt` | Toggle auto-trigger on/off |
| `,pr` | Cycle to the next active model (only registered with 2+ active models) |
| `,pm` | Pick a model from a menu — `popup_menu` on Vim, `vim.ui.select` on Neovim (only registered with 2+ active models) |
| `:VimAiAutocompleteModel <name>` | Switch directly to a named model, with completion |

## Architecture

- **FIM (fill-in-the-middle) prompting**: the buffer around the cursor is split into a "before" and "after" section (never sending the current line whole to either side), so the model knows exactly where the cursor sits and what already exists after it.
- **Redundancy detection**: two mechanisms, summed into one count of "characters to discard" from the real buffer text after the cursor — a structural bracket/quote-stack comparison (catches the case where the suggestion closes something already open before the cursor) and a textual suffix/prefix overlap check (catches the model literally repeating what's already there). The discarded span is always shown in red/strikethrough before being dropped on accept, never silently trimmed.
- **Ghost text rendering**: Vim uses `prop_add`/textprop (Vim 9+); Neovim uses extmarks (`nvim_buf_set_extmark` with `virt_text`/`virt_lines`).
- **Prompt-cache-friendly by construction**: the before-context is anchored (not a sliding window) so the prompt prefix repeats byte-for-byte between keystrokes — Gemini and DeepSeek cache it implicitly, and the Anthropic request marks the stable block with `cache_control` (measured live: 2,876 of 2,895 input tokens read from cache at 0.1× while typing inside a line).
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

## Author

[Alberto de Sá Cavalcanti de Albuquerque](https://github.com/albertosca) — [LinkedIn](https://www.linkedin.com/in/albertosca/)
