# vim-ai-autocomplete — Guide for AI

Ghost-text AI completion for **both** Vim 9 (textprops) and Neovim (extmarks). Public repo: everything in it is written in English, except `README.pt.md`.

## The rule that shapes everything: two sides, one behaviour

Every feature exists twice — `autoload/vim_ai_autocomplete.vim` (Vimscript) and `lua/vim-ai-autocomplete/*.lua` — and the two must behave identically. A fix on one side without the other is a bug, not a partial delivery. Both read the same `vim.g` / `g:` variables; there is never a parallel config path.

```
autoload/vim_ai_autocomplete.vim   ← the whole Vim side, one file
plugin/vim-ai-autocomplete.vim     ← Vim mappings and autocmds
lua/vim-ai-autocomplete/
  init.lua       ← setup(opts), trigger/debounce, keymaps
  request.lua    ← builds the context, fires the job, post-processes
  family.lua     ← per-API request/response (gemini, anthropic, deepseek)
  context.lua    ← scope cut, related definitions, LSP
  redundancy.lua ← bracket/overlap/indent cleanup of the suggestion
  ghost_text.lua ← rendering, alternatives state, accept
  models.lua     ← model list, which are active, provider switching
  keymaps.lua    ← Tab wrap, dismiss, model picker
```

## Test suite

```bash
bash test/run.sh          # vader (Vim) + plenary (Neovim)
luacheck lua/ test/nvim/  # lint, green in CI
vint autoload/ plugin/    # lint, green in CI
```

- First time: `git submodule update --init --recursive` — `test/vendor/{vader.vim,plenary.nvim}` ship empty and the runner hangs without them.
- Use `PlenaryBustedDirectory` (what the runner and CI use); `PlenaryBustedFile` runs in-process and can report a different result.
- **Run the vader suite on BOTH Vim binaries.** `/usr/bin/vim` (Apple 9.1.1752) and `/opt/homebrew/bin/vim` (9.2) differ on regex: inside `substitute()`, `[^\n]*` matches across line breaks on Apple's build and not on brew's. `/usr/bin` comes first in PATH.
- `test/minimal_vimrc.vim` sets `packpath` to `$VIMRUNTIME` on purpose — native packages under `~/.vim/pack` load on ANY Vim start (regardless of `-u`) and have spawned external processes during test runs. Empty `packpath` breaks netrw, which is a bundled pack.
- A change here means **2 commits**: one in this repo, one in `~/.vim_runtime` bumping the pointer.

## Writing tests — non-obvious rules

- **Vader's `Before:`/`After:` are sticky and apply to the blocks that FOLLOW them**, never to the preceding one. Cleanup declared after a block leaks into the next test — one such leak wiped Vader's own workbench and killed the run with E86.
- **`exists('*autoload#fn')` never triggers autoload.** To detect an optional autoloaded function (e.g. `coc#pum#visible`), CALL it inside `try` and catch `E117`.
- **Redirect stdin** when running Vim/Neovim from a script (`vim ... </dev/null`) — without it a non-headless Vim waits forever on a prompt.
- **Rendering cannot be verified headlessly.** Ghost text, colours and cursor position need a real pty: `tmux new-session -d`, `tmux capture-pane -p`. `docs/manual-checks.md` lists what only a human can confirm; `test/manual/` holds the drive files.

## Rendering gotchas (Vim only)

- A text property with **empty text** is stored as a control byte: inline it renders as three U+FFFD, and as a below-line it renders as `@` and garbles the following line. Guard every empty line — inline props are skipped, below-lines become a single space. Neovim's extmarks handle empty text correctly (probed side by side).
- Ghost text is **inline virtual text**: every character pushes the real line right. Anything drawn twice (a closing bracket the suggestion repeats) makes the line reflow on each keystroke.
- Red/strikethrough marks exactly what accept deletes — never more, never less. Text that should not be drawn is removed from the suggestion, not painted red.

## Debugging a suggestion that never shows

```vim
let g:vim_ai_autocomplete_debug_log = '/tmp/vai.log'
```

One line per response: generation, exit status, body size, whether it was still current, and the first bytes; a dropped answer says why (cursor moved, completion menu visible). **Do not inspect state with `<C-o>` from insert mode** — it fires `InsertLeavePre`, which clears the suggestion: the instrument destroys the evidence.

## Public configuration

`g:vim_ai_autocomplete_` + `models`, `provider`, `auto_trigger`, `alternatives`, `cycle_next`, `cycle_prev`, `pending_delay_ms`, `debug_log`. On Neovim, `setup(opts)` is sugar over these very variables.

## Measure before claiming an API supports something

The alternatives feature was designed around batching N candidates in one request; real calls proved `gemini-3.1-flash-lite` rejects `candidateCount > 1` and the DeepSeek API rejects `n > 1`, and a model that rejects the field returns **no suggestion at all**. Batching became a per-model opt-in (`candidates_per_request`) and lazy fetching the default. Prompt and context changes are the same: state a rate (`4/6 wrong`), not an impression, and re-run enough trials to separate signal from noise.

## What NOT to do

- Do not fix one side without the other (Vimscript and Lua must match).
- Do not use `[^\n]` in a Vim regex — use `.\{-}\n`; the two Vim builds disagree.
- Do not trim the suggestion before `CountRedundantAfterChars` runs — the structural computation needs the original text.
- Do not add a keymap that only works with Alt without making it configurable: on macOS the terminal must be sending Option as Esc+, and terminal Vim needs the termcode declared.
- Never reintroduce anything Copilot — see the parent repo's CLAUDE.md.
