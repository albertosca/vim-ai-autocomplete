-- Shared config for `luacheck lua/ test/nvim/` (run locally and in CI).
std = 'lua51'
globals = { 'vim' }
-- 631 = "line too long": comments and the FIM prompt template follow a
-- one-line-per-paragraph convention, so line length is deliberately not
-- enforced. Everything else stays on.
ignore = { '631' }
files['test/nvim/'] = {
  -- plenary/busted test globals
  globals = { 'vim', 'describe', 'it', 'before_each', 'after_each', 'pending', 'assert' },
}
exclude_files = { 'test/vendor/' }
