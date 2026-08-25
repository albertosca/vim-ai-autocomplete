local M = {}

local PROMPT_TEMPLATE = 'Complete the following code. The cursor sits between the BEFORE text and the AFTER text, both of which already exist in the buffer. Reply ONLY with the text that should be inserted BETWEEN them -- do not repeat anything already present in BEFORE or AFTER. No explanation, no markdown.\n\nBEFORE THE CURSOR:\n%s\n\nAFTER THE CURSOR:\n%s'

-- Extracts the error message from a JSON error response from the API (a
-- shape common to Gemini and Claude: {"error": {"message": ...}}). Returns
-- nil when the body is not JSON, or does not have that shape.
function M.extract_api_error_message(raw_output)
  local ok, data = pcall(vim.json.decode, raw_output)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  local err = data.error
  if type(err) == 'table' and type(err.message) == 'string' then
    return err.message
  end
  return nil
end

function M.build_gemini_request(context)
  local prompt = string.format(PROMPT_TEMPLATE, context.before, context.after)
  return vim.json.encode({ contents = { { parts = { { text = prompt } } } } })
end

function M.build_claude_request(context, model)
  local prompt = string.format(PROMPT_TEMPLATE, context.before, context.after)
  return vim.json.encode({ model = model, max_tokens = 256, messages = { { role = 'user', content = prompt } } })
end

function M.build_gemini_command(context, model_id, api_key)
  local body = M.build_gemini_request(context)
  local endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/' .. model_id .. ':generateContent?key=' .. api_key
  return { 'curl', '-s', '-X', 'POST', endpoint, '-H', 'Content-Type: application/json', '-d', body }
end

-- `ant` (Anthropic's official CLI) was dropped on the Vim side on 2026-07-20
-- -- no billing advantage for this plugin's use case. Static key only.
function M.build_claude_command(context, model, api_key)
  local body = M.build_claude_request(context, model)
  return {
    'curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
    '-H', 'x-api-key: ' .. api_key,
    '-H', 'anthropic-version: 2023-06-01',
    '-H', 'Content-Type: application/json', '-d', body,
  }
end

-- DeepSeek's API is OpenAI-compatible chat completions: POST
-- https://api.deepseek.com/chat/completions, `Authorization: Bearer <key>`,
-- body {model, messages: [{role, content}]}. Confirmed against the official
-- docs (api-docs.deepseek.com) on 2026-08-10, not assumed from memory.
function M.build_deepseek_request(context, model)
  local prompt = string.format(PROMPT_TEMPLATE, context.before, context.after)
  -- thinking must be disabled explicitly: deepseek-v4-flash reasons by
  -- default, and the reasoning made a completion take 55.6s against 1.6s
  -- with it off (both measured with real calls, 2026-08-25) -- useless for
  -- an autocomplete either way.
  return vim.json.encode({
    model = model,
    thinking = { type = 'disabled' },
    messages = { { role = 'user', content = prompt } },
  })
end

function M.build_deepseek_command(context, model_id, api_key)
  local body = M.build_deepseek_request(context, model_id)
  return {
    'curl', '-s', '-X', 'POST', 'https://api.deepseek.com/chat/completions',
    '-H', 'Authorization: Bearer ' .. api_key,
    '-H', 'Content-Type: application/json', '-d', body,
  }
end

-- U+FFFD (EF BF BD) is never legitimate code, but it intermittently reached
-- a real buffer (field report 2026-08-25: ga showed 65533, three in a row).
-- The local pipeline was exonerated by experiment -- clean raw bodies over 15
-- real calls, json_decode handles emoji, and a multibyte char split across
-- job chunks reassembles byte-perfectly -- so it arrives from upstream:
-- strip it before it can be displayed or accepted.
local function strip_replacement_chars(text)
  return (text:gsub('\239\191\189', ''))
end

-- Same defensive shape as parse_gemini_response: a malformed/blocked
-- response is a legitimate possibility (rate limit, content filter), not an
-- error to crash on -- guard every level instead of indexing straight
-- through choices[1].message.content.
function M.parse_deepseek_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or type(data.choices) ~= 'table' or #data.choices == 0 then
    return {}
  end
  local message = data.choices[1].message
  if type(message) ~= 'table' or type(message.content) ~= 'string' then
    return {}
  end
  return vim.split(strip_replacement_chars(message.content), '\n', { plain = true, trimempty = false })
end

-- A blocked candidate (safety filter, finishReason SAFETY/RECITATION) comes
-- back WITHOUT "content", or without "parts" -- a legitimate HTTP 200
-- response, just with no actual suggestion. Real finding, reported from a
-- live smoke test on 2026-07-22: "attempt to index field 'parts' (a nil
-- value)" when the direct access had no guard.
function M.parse_gemini_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or type(data.candidates) ~= 'table' or #data.candidates == 0 then
    return {}
  end
  local candidate = data.candidates[1]
  if type(candidate) ~= 'table' or type(candidate.content) ~= 'table' then
    return {}
  end
  local parts = candidate.content.parts
  if type(parts) ~= 'table' or #parts == 0 then
    return {}
  end
  local text = parts[1].text
  return vim.split(strip_replacement_chars(text), '\n', { plain = true, trimempty = false })
end

-- content is a LIST of typed blocks, and the text block is not necessarily
-- first: claude-sonnet-5 prepends a {"type":"thinking"} block (observed live
-- 5/5, 2026-08-25). Indexing content[1].text blindly crashed the completion
-- mid-typing whenever thinking came first.
function M.parse_claude_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or type(data.content) ~= 'table' then
    return {}
  end
  for _, block in ipairs(data.content) do
    if type(block) == 'table' and type(block.text) == 'string' then
      return vim.split(strip_replacement_chars(block.text), '\n', { plain = true, trimempty = false })
    end
  end
  return {}
end

-- Every API family implements two operations with a uniform signature:
-- build_command(context, model_id, api_key) -> argv list for vim.system
-- parse_response(body) -> list of suggestion lines
-- Adding a new family (e.g. OpenAI) means implementing those two functions
-- and registering them here -- the same escape hatch as on the Vim side.
function M.family_handler(family_name)
  local handlers = {
    gemini = { build_command = M.build_gemini_command, parse_response = M.parse_gemini_response },
    anthropic = { build_command = M.build_claude_command, parse_response = M.parse_claude_response },
    deepseek = { build_command = M.build_deepseek_command, parse_response = M.parse_deepseek_response },
  }
  local handler = handlers[family_name]
  if not handler then
    error('vim-ai-autocomplete: unknown family "' .. family_name .. '"')
  end
  return handler
end

-- Previously any failure (exit != 0, or an error response from the API) meant
-- no suggestion appeared and NO warning was shown -- same finding as on the
-- Vim side. Returns nil when there is nothing wrong to report (a legitimately
-- empty response, e.g. the cursor at the end of a complete file).
function M.describe_completion_failure(provider, status, raw_output)
  local message = M.extract_api_error_message(raw_output)
  if message then
    return string.format('vim-ai-autocomplete (%s): %s', provider, message)
  end
  if status ~= 0 then
    return string.format('vim-ai-autocomplete (%s): request failed (exit %d), no detail in the response', provider, status)
  end
  return nil
end

return M
