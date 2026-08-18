# Contributing

Thanks for taking an interest! This project is small on purpose — most contributions fit in one focused PR.

## Running the tests

```bash
git submodule update --init --recursive   # first time only: pulls test/vendor/{vader.vim,plenary.nvim}
bash test/run.sh
```

The runner executes both halves and fails if either fails:

| Half | Tool | Covers |
|---|---|---|
| vader | vader.vim (Vim) | `autoload/vim_ai_autocomplete.vim` — the classic Vim side |
| plenary | plenary.nvim (Neovim) | `lua/vim-ai-autocomplete/` — the Neovim side |

No API key or network access is needed: every test is either pure logic or mocks the API call. CI runs the same script on every push.

Two gotchas worth knowing:

- Without the vendored submodules the runner **hangs** instead of failing — run the `submodule update` line above first.
- Use `PlenaryBustedDirectory` (what the runner and CI use) when running plenary specs by hand; `PlenaryBustedFile` runs in-process and can report a different result.

## The two-sided rule

The plugin has two independent implementations that must stay in behavioural parity: Vimscript (`autoload/`, `plugin/`) for Vim 9+ and Lua (`lua/vim-ai-autocomplete/`) for Neovim. A change to shared behaviour (prompt template, redundancy logic, a new model family) lands on **both** sides in the same PR, each with its own tests. Neovim-only features (Treesitter scope, LSP context, `vim.ui.select` picker) live only in Lua.

## Adding a model family

`family_handler()` — in both `lua/vim-ai-autocomplete/family.lua` and `autoload/vim_ai_autocomplete.vim` — is the escape hatch. A family is two functions with a uniform signature:

- `build_command(context, model_id, api_key)` → a curl argv list
- `parse_response(body)` → a list of suggestion lines

Copy an existing pair (`gemini` has its own JSON shape; `anthropic` is a second reference), register the new family in both handler dicts, and mirror the existing unit tests. Parse defensively: a filtered/malformed response must return `[]`, never throw.

## Style

- Follow TDD where practical: the existing suites show the house pattern (write the failing test, then the code).
- Everything in the repo is written in English; `README.pt.md` is the deliberate exception (it is the translated README).
- Keep comments to the *why* — the code already says the what.

## Sending the PR

- One topic per PR, tests included, `bash test/run.sh` green locally.
- If your change is visual (ghost text, highlights), note how you verified it — rendering cannot be checked headlessly, so a short "tested in a real terminal via tmux" note (or a screenshot/GIF) helps a lot.
