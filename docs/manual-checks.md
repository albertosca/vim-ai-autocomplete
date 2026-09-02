# Manual checks

What cannot be proven headless and needs a human eye. Do each in Vim, then in Neovim. Every item says how to provoke it and what to expect. The drive file is `test/manual/scenarios.py`; `test/manual/crossref.py` is the helper-reuse fixture.

**First:** restart the editor after updating, and confirm the alternatives feature is on: `:echo g:vim_ai_autocomplete_alternatives` → `3` (or whatever you set).

## 1. Cycling alternatives (`<M-.>` / `<M-,>`)

- **Provoke:** let a suggestion appear (any model), then `<M-.>`.
- **Expect:** the `…` marker at the end of the line, then the suggestion is replaced by another one (one extra request: 1–4 s); `<M-,>` goes back; `Tab` accepts whichever is on screen. Identical alternatives collapse — if the model repeats itself a short message says so and nothing changes.
- **If it fails:** `<M-.>` leaving insert mode means the key arrived as `Esc` + `.`. In the terminal, `cat -v` then the key must print `^[.`; `≥` means the terminal still sends Option as a symbol (iTerm2: *Profiles › Keys › Left Option key → Esc+*, new windows only). Terminal Vim also needs the termcode, which the plugin declares when the feature is on.

## 2. In-flight marker (`…`)

- **Provoke:** a slow model (claude-haiku / claude-sonnet). Type and pause.
- **Expect:** ~400 ms after the pause, `…` at the end of the line; gone the instant the suggestion shows (or the request fails / goes stale). With gemini it rarely shows — the answer beats the delay. That is by design.

## 3. The completion menu wins

- **Provoke (Vim + CoC):** with a long word already in the file (e.g. `helper`), type its first three letters on another line and pause. CoC's popup opens with `helper` (buffer source, no LSP needed). Wait 3 s **with the popup open**.
- **Expect:** no ghost text and no `…` while the popup is open. Close it (`Ctrl-e`) and pause again: the suggestion comes back.
- **Neovim:** same steps; the menu is blink.cmp's.

## 4. Scope cut (the original wrong-target bug)

- **Provoke:** `test/manual/scenarios.py`, model claude-haiku, cursor right after `class Stack:` (last line), insert mode, pause.
- **Expect:** the body of `Stack` (`__init__`, `push`, `pop`…). **Wrong** would be completing `fibonacci` or `def add()` above — what happened when the whole file went as context.
- **Bonus:** `test/manual/crossref.py`, cursor at the end of the last line → the suggestion calls `normalize_name` instead of re-inventing it (RELATED DEFINITIONS).

## 5. Echoed punctuation is stripped

- **Provoke:** scenario 2 (`def add(|)` with the auto-paired `)`), and scenario 3 (`class Stack:|`), gemini.
- **Expect:** never `def add((a, b):)` nor a second `:` on the next line — a model that repeats the `(` or the `:` just before the cursor has that echo removed. What stays red is only what accept deletes (the real `)` when the suggestion closes the bracket itself).

## 6. Nothing red that is not deleted, nothing deleted that is not red

- The red/strikethrough characters after the cursor are exactly the ones `Tab` removes. If something disappears on accept without having been red, that is a bug — report the before/after text.

## 7. Diagnostics when something is silently dropped

- `let g:vim_ai_autocomplete_debug_log = '/tmp/vai.log'` (Vim or Neovim). Every response appends one line: generation, exit status, body size, whether it was still current, and the first bytes; a dropped answer says why (cursor moved, menu visible).
- Do not measure state with `<C-o>` from insert mode: it fires `InsertLeavePre`, which clears the suggestion — the instrument destroys the evidence.

## Known non-issues

- `-> None` / `n:` text appearing inside your code in Python buffers is **pyright's inlay hints** through CoC (`pyright.inlayHints.*` in coc-settings.json), not the plugin.
