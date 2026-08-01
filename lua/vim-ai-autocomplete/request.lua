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

-- count_redundant_after_chars MUST run against the ORIGINAL suggestion,
-- before any adjustment (same finding as on the Vim side: trimming the
-- suggestion first corrupts the structural computation). Both sources of
-- redundancy -- structural and textual overlap -- ADD UP into a single
-- redundant_after.
local function on_exit(request_gen, out_chunks, status, provider, parse_response, bufnr, lnum, col, after)
  if request_gen ~= gen then
    return
  end
  -- drop it if the cursor already moved since the request was made.
  if vim.api.nvim_get_current_buf() ~= bufnr or vim.fn.line('.') ~= lnum or vim.fn.col('.') ~= col then
    return
  end
  local body = table.concat(out_chunks, '')
  local lines = parse_response(body)
  if #lines > 0 then
    last_completion_error = nil
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
    lines = redundancy.adjust_suggestion_lines(lines, before_cursor, vim.bo.filetype, vim.fn.shiftwidth(), vim.bo.expandtab)
    -- last, with the lines already in the final shape that reaches the
    -- screen: drop from the suggestion the closing characters the buffer
    -- already has, so ')' is not rendered twice and the real ')' is not
    -- pushed away from the cursor.
    lines, redundant_after = redundancy.split_display_tail(lines, after, redundant_after)
    ghost_text.show_suggestion(lines, redundant_after)
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
  local scope_start = context_mod.treesitter_scope_start_line(bufnr_now, cur_lnum, cur_col)
  local first = scope_start or math.max(1, cur_lnum - 100)
  local last = math.min(vim.fn.line('$'), cur_lnum + 20)
  local lines_before_full = vim.fn.getline(first, cur_lnum - 1)
  local lines_after_full = vim.fn.getline(cur_lnum + 1, last)
  local lines_before, lines_after = context_mod.split_lines_at_cursor(
    lines_before_full, vim.fn.getline('.'), cur_col, lines_after_full)
  local context = context_mod.build_context(lines_before, lines_after, 16000)
  -- capture the RAW after (from the buffer) BEFORE any LSP augmentation --
  -- redundancy.count_redundant_after_chars/compute_text_overlap_length in
  -- on_exit need the real text after the cursor, not the prompt context (the
  -- "RELATED DEFINITIONS" section), which only makes sense in the API
  -- request.
  local after = context.after

  local ok_node, scope_node = pcall(vim.treesitter.get_node, { bufnr = bufnr_now, pos = { cur_lnum - 1, math.max(0, cur_col - 1) } })
  if ok_node and scope_node then
    local definitions = context_mod.lsp_related_definitions(bufnr_now, scope_node, 150)
    context.after = context.after .. context_mod.build_related_definitions_section(definitions, 10)
  end

  local cmd = handler.build_command(context, model.model_id, api_key)

  gen = gen + 1
  local request_gen = gen
  local chunks = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cur_lnum
  local col = vim.fn.col('.')
  local provider = model.name
  local parse_response = handler.parse_response

  vim.system(cmd, { text = true }, function(result)
    if result.stdout then
      table.insert(chunks, result.stdout)
    end
    vim.schedule(function()
      on_exit(request_gen, chunks, result.code, provider, parse_response, bufnr, lnum, col, after)
    end)
  end)
end

return M
