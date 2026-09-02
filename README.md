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
- **366 tests, no network required** — 167 vader (Vim) + 199 plenary (Neovim), every API call mocked, running on every push in CI plus luacheck/vint linting.
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
  alternatives = 3, -- optional, defaults to off; see "Alternatives" below
})
```

| Field | Meaning |
|---|---|
| `name` | Whatever you want to call this model in `,pr`/`,pm`/`:VimAiAutocompleteModel` |
| `family` | `'gemini'`, `'anthropic'` or `'deepseek'` — determines the request/response shape |
| `model_id` | The real model ID sent to the provider's API |
| `api_key_env` | Name of the environment variable holding that provider's API key |
| `candidates_per_request` | Optional, default 1 — how many alternatives this model returns per request; see "Alternatives" below before setting it above 1 |

If you configure nothing, it defaults to one Gemini and one Claude model. A model only becomes "active" (eligible for `,pr` cycling) if its `api_key_env` is actually set and non-empty in the environment.

### Alternatives (cycling through several suggestions)

Off by default — every alternative is a paid API call. Turn it on with the number of suggestions you want per trigger:

```vim
let g:vim_ai_autocomplete_alternatives = 3   " or setup({ alternatives = 3 }) on Neovim
```

While a suggestion is visible, `<M-.>` (Alt+.) shows the next alternative and `<M-,>` the previous one, wrapping around at both ends; `Tab` accepts whichever is on screen. The keys are only claimed when the feature is on, and they are configurable:

```vim
let g:vim_ai_autocomplete_cycle_next = '<C-Right>'   " or setup({ cycle_next = ..., cycle_prev = ... })
let g:vim_ai_autocomplete_cycle_prev = '<C-Left>'
```

> **macOS:** Alt is the Option key, and by default the terminal uses it to type symbols (Option+. types `≥`) instead of sending Alt. In iTerm2 set *Preferences › Profiles › Keys › Left Option key → Esc+* (new windows only), or pick keys without Alt as above. Neovim inside a terminal has the same constraint — it is the terminal, not the editor. Each alternative goes through the same post-processing as a single suggestion (bracket redundancy, indent overlap, fence unwrapping), so they behave identically on accept.

**What it costs — measured, not assumed:**

By default every alternative is **one extra request**, fetched lazily: the first trigger gets one suggestion, and each `<M-.>` past the end asks for one more — up to N, and only for what you actually look at. Identical alternatives collapse into one; if a lazy fetch merely repeats the model's previous answer, nothing is added and a short message says so.

Gemini (`candidateCount`) and OpenAI-compatible APIs such as DeepSeek (`n`) have a field to return several candidates in the **same** request, which would make alternatives nearly free — so the plugin supports it as a **per-model opt-in**:

```vim
let g:vim_ai_autocomplete_models = [
      \ {'name': 'gemini-flash', 'family': 'gemini', 'model_id': '...', 'api_key_env': 'GEMINI_API_KEY', 'candidates_per_request': 3},
      \ ]
```

Opt in only after checking your model accepts it: with real calls on 2026-09-01, `gemini-3.1-flash-lite` answered *"Multiple candidates is not enabled for this model"* and `deepseek-v4-pro` *"Invalid n value (currently only n = 1 is supported)"* — and a model that rejects the field returns **no suggestion at all**, which is why lazy is the default. Anthropic's Messages API has no such field, so it is always lazy.

## Usage

| Key | Action |
|---|---|
| `Tab` | Accept the visible suggestion (falls through to your original `Tab` mapping otherwise) |
| `<C-]>` | Dismiss the visible suggestion without leaving insert mode |
| `<M-.>` / `<M-,>` | Next / previous alternative — only with `g:vim_ai_autocomplete_alternatives >= 2` (see Configuration) |
| *(menu open)* | While a completion menu is showing (CoC's popup on Vim, blink.cmp / nvim-cmp on Neovim) nothing is requested and nothing is rendered — the menu wins, even if an answer lands while it is open |
| `…` at the end of the line | A request is in flight (appears only after 400 ms — `g:vim_ai_autocomplete_pending_delay_ms` — so fast answers never flash it; gone the moment the answer, a stale result or a failure lands) |
| `,pt` | Toggle auto-trigger on/off |
| `,pr` | Cycle to the next active model (only registered with 2+ active models) |
| `,pm` | Pick a model from a floating menu (`j`/`k` to move, `<CR>` to select, `<Esc>`/`q` to close) — only registered with 2+ active models |
| `:VimAiAutocompleteModel <name>` | Switch directly to a named model, with completion |

## Architecture

- **FIM (fill-in-the-middle) prompting**: the buffer around the cursor is split into a "before" and "after" section (never sending the current line whole to either side), so the model knows exactly where the cursor sits and what already exists after it.
- **Redundancy detection**: two mechanisms, summed into one count of "characters to discard" from the real buffer text after the cursor — a structural bracket/quote-stack comparison (catches the case where the suggestion closes something already open before the cursor) and a textual suffix/prefix overlap check (catches the model literally repeating what's already there). The discarded span is always shown in red/strikethrough before being dropped on accept, never silently trimmed.
- **Ghost text rendering**: Vim uses `prop_add`/textprop (Vim 9+); Neovim uses extmarks (`nvim_buf_set_extmark` with `virt_text`/`virt_lines`).
- **Prompt-cache-friendly by construction**: the before-context is anchored (not a sliding window) so the prompt prefix repeats byte-for-byte between keystrokes — Gemini and DeepSeek cache it implicitly, and the Anthropic request marks the stable block with `cache_control` (measured live: 2,876 of 2,895 input tokens read from cache at 0.1× while typing inside a line).
- **Scope-aware context on both sides**: the before-context is cut at the enclosing definition, so the model sees the function being written instead of the whole file. Neovim asks Treesitter first and falls back to an indentation-and-keyword heuristic, which matters more than it sounds: Treesitter returns nothing whenever the cursor line is still incomplete -- the only state this plugin ever runs in -- so before the fallback the cut silently never happened while typing. Vim uses the heuristic alone. Measured with real calls on a file full of unfinished stubs: 4/6 completions landed on the wrong function with the whole file as context, 0/6 with the cut.
- **The neighbours come back as RELATED DEFINITIONS**: cutting at the scope also hides the rest of the file, and that costs real accuracy -- completing a call to a helper defined earlier went from 6/6 correct to 0/6, with the model reinventing the helper inline. Each neighbouring definition is sent back as its signature plus a few body lines (through LSP on Neovim, straight from the buffer otherwise), which restored 6/6 while keeping the wrong-target rate at 0/6.
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
