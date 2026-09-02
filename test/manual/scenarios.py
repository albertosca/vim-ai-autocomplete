# Manual test drive for vim-ai-autocomplete -- open this file in Vim or Neovim
# with the plugin active and walk the scenarios below with each model:
#   Vim:    :VimAiAutocompleteModel <name>   (tab-completes) -- or ,pr to cycle
#   Neovim: ,pm opens the picker -- or the same command / ,pr above
# What to look at is described in docs/manual-checks.md.

# --- Scenario 1: latency + basic quality -------------------------------------
# Put the cursor at the end of the line below, enter insert mode, wait ~2s.
# Watch: how long until grey text shows up, and does it complete the body well?

def fibonacci(n):
    




# --- Scenario 2: FIM discipline (does it respect what's AFTER the cursor?) ---
# Type an open paren at the end of the line below (auto-pairs adds the ")").
# Watch: if part of the real ")" turns RED/strikethrough, the model repeated
# the closer and the plugin had to clean it up. A disciplined model returns
# only "a, b" style content with nothing red.

def add()


# --- Scenario 3: block opener (the ":" edge case) ----------------------------
# Put the cursor right after the ":" below and trigger.
# Watch: does the suggestion start on a NEW indented line, or does the plugin
# have to inject the newline itself? (Gemini historically glues bytes here.)

class Stack:
