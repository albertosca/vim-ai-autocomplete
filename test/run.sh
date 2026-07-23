#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== vader (Vim) =="
vim_out=$(vim -N -u test/minimal_vimrc.vim -c "Vader! test/vader/*.vader" -c "qa!" 2>&1) || true
echo "$vim_out" | grep -E "Success/Total|Vader error" || true
vim_summary=$(echo "$vim_out" | grep 'Success/Total:' | tail -1)
vim_passed=$(echo "$vim_summary" | sed 's|.*Success/Total: \([0-9]*\)/\([0-9]*\).*|\1|')
vim_total=$(echo "$vim_summary" | sed 's|.*Success/Total: \([0-9]*\)/\([0-9]*\).*|\2|')
vim_failed=$((vim_total - vim_passed))

echo ""
echo "== plenary (Neovim) =="
nvim_out=$(nvim --headless -u test/nvim/minimal_init.lua \
  -c "PlenaryBustedDirectory test/nvim/ {minimal_init = 'test/nvim/minimal_init.lua'}" 2>&1) || true
echo "$nvim_out" | grep -E "Success|Fail|Error" || true
nvim_failed=$(echo "$nvim_out" | grep -c "Fail ||" || true)

echo ""
echo "== Summary =="
echo "vader:    $vim_passed/$vim_total passed"
echo "plenary:  failures: $nvim_failed"

if [[ "$vim_failed" -gt 0 || "$nvim_failed" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL GREEN"
