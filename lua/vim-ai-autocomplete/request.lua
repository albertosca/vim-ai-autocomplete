local models = require('vim-ai-autocomplete.models')
local family = require('vim-ai-autocomplete.family')
local context_mod = require('vim-ai-autocomplete.context')
local redundancy = require('vim-ai-autocomplete.redundancy')
local ghost_text = require('vim-ai-autocomplete.ghost_text')

local M = {}

local gen = 0
local last_completion_error = nil

local function warn_completion_failure(provider, status, raw_output)
  local message = family.describe_completion_failure(provider, status, raw_output)
  if not message or message == last_completion_error then
    return
  end
  last_completion_error = message
  vim.notify(message, vim.log.levels.WARN)
end

-- issue #3: how many alternatives the user asked to cycle through.
-- nil = feature off (the default -- every alternative is a paid API call).
local function alternatives_n()
  local n = vim.g.vim_ai_autocomplete_alternatives
  if type(n) ~= 'number' or n < 2 then
    return nil
  end
  return math.floor(n)
end

-- issue #4: how long a request may stay silent before the in-flight marker
-- shows. Fast answers (most gemini/deepseek ones) never flash anything.
local function pending_delay_ms()
  local n = vim.g.vim_ai_autocomplete_pending_delay_ms
  if type(n) == 'number' and n >= 0 then
    return n
  end
  return 400
end

-- everything the lazy fetch (the anthropic side of the hybrid) needs to
-- rebuild the SAME request later, captured at trigger time.
local last_trigger = nil
local lazy_in_flight = false

-- The per-candidate post-processing pipeline, shared by the single-suggestion
-- path and every alternative (issue #3 requires it to run per candidate).
local function process_candidate(lines, lnum, col, after)
  local current_line = vim.fn.getline(lnum)
  local before_cursor = col > 1 and current_line:sub(1, col - 1) or ''
  local redundant_after = redundancy.count_redundant_after_chars(before_cursor, table.concat(lines, '\n'), after)
  local remaining_after = after:sub(redundant_after + 1)
  redundant_after = redundant_after + redundancy.compute_text_overlap_length(lines, remaining_after)
  -- cap it at what is really left ON THIS LINE -- same known scope as the
  -- Vim side (it does not cover a whole suggestion duplicating several
  -- existing lines).
  local current_line_remainder = current_line:sub(col)
  redundant_after = math.min(redundant_after, #current_line_remainder)
  -- before adjust_suggestion_lines: this one works on the raw model output,
  -- which is where the duplicated indentation lives.
  lines = redundancy.strip_leading_indent_overlap(lines, before_cursor)
  lines = redundancy.adjust_suggestion_lines(lines, before_cursor, vim.bo.filetype, vim.fn.shiftwidth(), vim.bo.expandtab)
  -- last, with the lines already in the final shape that reaches the
  -- screen: drop from the suggestion the closing characters the buffer
  -- already has, so ')' is not rendered twice and the real ')' is not
  -- pushed away from the cursor.
  return redundancy.split_display_tail(lines, after, redundant_after)
end

-- count_redundant_after_chars MUST run against the ORIGINAL suggestion,
-- before any adjustment (same finding as on the Vim side: trimming the
-- suggestion first corrupts the structural computation). Both sources of
-- redundancy -- structural and textual overlap -- ADD UP into a single
-- redundant_after.
local function on_exit(request_gen, out_chunks, status, provider, parse_response, parse_alternatives, alternatives_wanted, bufnr, lnum, col, after)
  if request_gen ~= gen then
    return
  end
  -- issue #4: this request is over, whatever comes next -- the marker goes
  -- on every path below (answer, stale, failure).
  ghost_text.clear_pending()
  -- drop it if the cursor already moved since the request was made.
  if vim.api.nvim_get_current_buf() ~= bufnr or vim.fn.line('.') ~= lnum or vim.fn.col('.') ~= col then
    return
  end
  local body = table.concat(out_chunks, '')
  if alternatives_wanted then
    local entries = {}
    -- the whole post-processing pipeline runs PER candidate (issue #3):
    -- each alternative closes (or not) its own brackets, duplicates (or not)
    -- its own indentation.
    for _, candidate in ipairs(parse_alternatives(body)) do
      local lines, redundant_after = process_candidate(candidate, lnum, col, after)
      table.insert(entries, { lines = lines, redundant_after = redundant_after })
    end
    if #entries > 0 then
      last_completion_error = nil
      ghost_text.show_alternatives(entries)
    else
      warn_completion_failure(provider, status, body)
    end
    return
  end
  local lines = parse_response(body)
  if #lines > 0 then
    last_completion_error = nil
    local display, redundant_after = process_candidate(lines, lnum, col, after)
    ghost_text.show_suggestion(display, redundant_after)
  else
    warn_completion_failure(provider, status, body)
  end
end

function M.request_completion()
  local all_models = vim.g.vim_ai_autocomplete_models or models.default_models()
  local active = models.active_models()
  local default_name, level = models.resolve_default_model(all_models, active)
  if level == 'error' then
    return
  end
  local provider_name = vim.g.vim_ai_autocomplete_provider or default_name
  local model = models.find_model_by_name(active, provider_name)
  if not model then
    -- the configured provider is no longer active (e.g. its key was removed
    -- at runtime) -- fall back to the default resolved above.
    model = models.find_model_by_name(active, default_name)
  end
  local handler = family.family_handler(model.family)
  local api_key = vim.fn.getenv(model.api_key_env)

  local bufnr_now = vim.api.nvim_get_current_buf()
  local cur_lnum = vim.fn.line('.')
  local cur_col = vim.fn.col('.')
  local scope_window_start = math.max(1, cur_lnum - 500)
  local scope_window = vim.fn.getline(scope_window_start, cur_lnum)
  local scope_start = context_mod.treesitter_scope_start_line(bufnr_now, cur_lnum, cur_col)
  if not scope_start then
    -- Treesitter returns nil on an incomplete line, which is the only kind of
    -- line this plugin ever runs on -- without this fallback the cut silently
    -- never happened while typing (measured 2026-08-31).
    local idx = context_mod.heuristic_scope_start_line(scope_window)
    scope_start = idx > 0 and (scope_window_start + idx - 1) or nil
  end
  -- Anchored at line 1 (not a sliding cursor-100 window): prefix caches --
  -- explicit on Anthropic, implicit on Gemini/DeepSeek -- only hit when the
  -- prompt prefix repeats byte-for-byte, and a sliding window changes the
  -- prefix on every new line. The 2000-line cap keeps the per-keystroke
  -- getline+join cheap on huge files (beyond it, back to the window and
  -- caching naturally stops paying).
  local first = scope_start or ((cur_lnum <= 2000) and 1 or math.max(1, cur_lnum - 100))
  local last = math.min(vim.fn.line('$'), cur_lnum + 20)
  local lines_before_full = vim.fn.getline(first, cur_lnum - 1)
  local lines_after_full = vim.fn.getline(cur_lnum + 1, last)
  local lines_before, lines_after = context_mod.split_lines_at_cursor(
    lines_before_full, vim.fn.getline('.'), cur_col, lines_after_full)
  local context = context_mod.build_context(lines_before, lines_after, 16000)
  -- the current line's before-part: the volatile half of the Anthropic
  -- cache split (see family.build_claude_request); other families ignore it.
  context.before_tail = cur_col > 1 and vim.fn.getline('.'):sub(1, cur_col - 1) or ''
  -- capture the RAW after (from the buffer) BEFORE any LSP augmentation --
  -- redundancy.count_redundant_after_chars/compute_text_overlap_length in
  -- on_exit need the real text after the cursor, not the prompt context (the
  -- "RELATED DEFINITIONS" section), which only makes sense in the API
  -- request.
  local after = context.after

  local section = ''
  local ok_node, scope_node = pcall(vim.treesitter.get_node, { bufnr = bufnr_now, pos = { cur_lnum - 1, math.max(0, cur_col - 1) } })
  if ok_node and scope_node then
    local definitions = context_mod.lsp_related_definitions(bufnr_now, scope_node, 150)
    section = context_mod.build_related_definitions_section(definitions, 10)
  end
  -- No LSP client attached (or it found nothing) and the scope cut still
  -- happened: without this the buffer's own neighbours are simply lost, which
  -- measured 0/6 against 6/6 on completing a call to a helper defined earlier
  -- in the file. Falls back to the same buffer scan the Vim side uses.
  if section == '' and scope_start then
    section = context_mod.wrap_related_definitions(
      context_mod.collect_definitions(scope_window, scope_start - scope_window_start + 1, 3))
  end
  context.after = context.after .. section

  -- issue #3, the hybrid strategy: batch N candidates into ONE request only
  -- where the MODEL opts in (candidates_per_request in its config entry);
  -- everything else fetches one per request, lazily, through
  -- cycle_suggestion. Lazy is the default because the batch fields are
  -- rejected by the models we measured: gemini-3.1-flash-lite answers
  -- "Multiple candidates is not enabled for this model" and deepseek-v4-pro
  -- "Invalid n value (currently only n = 1 is supported)" (real calls,
  -- 2026-09-01) -- shipping the batch blindly would have killed the first
  -- suggestion whenever the feature was on. nil keeps the request unchanged.
  local wanted = alternatives_n()
  local per_request = wanted and math.max(1, math.min(wanted, model.candidates_per_request or 1,
    handler.max_candidates_per_request)) or nil
  local cmd = handler.build_command(context, model.model_id, api_key, per_request)

  gen = gen + 1
  local request_gen = gen
  local chunks = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cur_lnum
  local col = vim.fn.col('.')
  local provider = model.name
  local parse_response = handler.parse_response
  local parse_alternatives = handler.parse_alternatives
  lazy_in_flight = false
  last_trigger = {
    handler = handler, model_id = model.model_id, api_key = api_key, context = context,
    after = after, bufnr = bufnr, lnum = lnum, col = col, provider = provider, gen = request_gen,
    per_request = per_request or 1,
  }

  vim.system(cmd, { text = true }, function(result)
    if result.stdout then
      table.insert(chunks, result.stdout)
    end
    vim.schedule(function()
      on_exit(request_gen, chunks, result.code, provider, parse_response, parse_alternatives, wanted ~= nil, bufnr, lnum, col, after)
    end)
  end)
  ghost_text.schedule_pending(pending_delay_ms())
end

-- The lazy half of the hybrid (issue #3): one more request, same context,
-- appended as a new alternative when it arrives -- unless the cursor moved,
-- a newer trigger superseded it, or the model just repeated itself.
local function fetch_lazy_alternative()
  local t = last_trigger
  if not t or lazy_in_flight then
    return
  end
  lazy_in_flight = true
  local cmd = t.handler.build_command(t.context, t.model_id, t.api_key)
  local chunks = {}
  vim.system(cmd, { text = true }, function(result)
    if result.stdout then
      table.insert(chunks, result.stdout)
    end
    vim.schedule(function()
      lazy_in_flight = false
      if t.gen ~= gen then
        return
      end
      ghost_text.clear_pending()
      if not ghost_text.is_visible() then
        return
      end
      if vim.api.nvim_get_current_buf() ~= t.bufnr or vim.fn.line('.') ~= t.lnum or vim.fn.col('.') ~= t.col then
        return
      end
      local body = table.concat(chunks, '')
      local lines = t.handler.parse_response(body)
      if #lines == 0 then
        warn_completion_failure(t.provider, result.code, body)
        return
      end
      local display, redundant_after = process_candidate(lines, t.lnum, t.col, t.after)
      local key = table.concat(display, '\n')
      for _, existing in ipairs(ghost_text.alternatives()) do
        if table.concat(existing.lines, '\n') == key then
          vim.notify('vim-ai-autocomplete: no new alternative (the model repeated itself)', vim.log.levels.INFO)
          return
        end
      end
      ghost_text.append_alternative({ lines = display, redundant_after = redundant_after })
    end)
  end)
  ghost_text.schedule_pending(pending_delay_ms())
end

-- <M-.> / <M-,> while a suggestion is visible (issue #3). Moves through the
-- alternatives already fetched; past the end, when this model delivers one
-- candidate per request, fetches one more -- up to the configured N.
function M.cycle_suggestion(delta)
  local wanted = alternatives_n()
  if not wanted or not ghost_text.is_visible() then
    return
  end
  local count = ghost_text.alternatives_count()
  if count == 0 then
    return
  end
  local at_end = ghost_text.alternatives_index() == count
  if delta > 0 and at_end and count < wanted and last_trigger
      and last_trigger.per_request == 1 then
    fetch_lazy_alternative()
    return
  end
  ghost_text.cycle(delta)
end

return M
