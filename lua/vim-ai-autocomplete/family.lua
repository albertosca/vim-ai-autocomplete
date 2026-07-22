local M = {}

local PROMPT_TEMPLATE = 'Complete o codigo a seguir. O cursor esta entre o texto ANTES e o texto DEPOIS, que ja existem no buffer. Responda SOMENTE com o texto que deve ser inserido ENTRE eles -- nao repita nada que ja aparece em ANTES ou DEPOIS. Sem explicacao, sem markdown.\n\nANTES DO CURSOR:\n%s\n\nDEPOIS DO CURSOR:\n%s'

-- Extrai a mensagem de erro de uma resposta JSON de erro da API (formato
-- comum entre Gemini e Claude: {"error": {"message": ...}}). Retorna nil se
-- nao for JSON, ou nao tiver esse formato.
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

-- `ant` (CLI oficial da Anthropic) foi descartado do lado Vim 2026-07-20 --
-- sem vantagem de billing pro caso de uso deste plugin. So key estatica.
function M.build_claude_command(context, model, api_key)
  local body = M.build_claude_request(context, model)
  return {
    'curl', '-s', '-X', 'POST', 'https://api.anthropic.com/v1/messages',
    '-H', 'x-api-key: ' .. api_key,
    '-H', 'anthropic-version: 2023-06-01',
    '-H', 'Content-Type: application/json', '-d', body,
  }
end

function M.parse_gemini_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or type(data.candidates) ~= 'table' or #data.candidates == 0 then
    return {}
  end
  local text = data.candidates[1].content.parts[1].text
  return vim.split(text, '\n', { plain = true, trimempty = false })
end

function M.parse_claude_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' or type(data.content) ~= 'table' or #data.content == 0 then
    return {}
  end
  local text = data.content[1].text
  return vim.split(text, '\n', { plain = true, trimempty = false })
end

-- Cada familia de API implementa duas operacoes com assinatura uniforme:
-- build_command(context, model_id, api_key) -> lista de argv pro vim.system
-- parse_response(body) -> lista de linhas da sugestao
-- Adicionar uma familia nova (ex: OpenAI) exige implementar essas duas
-- funcoes e registrar aqui -- mesmo "escape hatch" do lado Vim.
function M.family_handler(family_name)
  local handlers = {
    gemini = { build_command = M.build_gemini_command, parse_response = M.parse_gemini_response },
    anthropic = { build_command = M.build_claude_command, parse_response = M.parse_claude_response },
  }
  local handler = handlers[family_name]
  if not handler then
    error('vim-ai-autocomplete: familia desconhecida "' .. family_name .. '"')
  end
  return handler
end

-- Antes, qualquer falha (exit != 0, ou resposta de erro da API) resultava
-- em nenhuma sugestao aparecer e NENHUM aviso -- mesmo achado do lado Vim.
-- Retorna nil quando nao ha nada de errado pra reportar (resposta vazia
-- legitima, ex: cursor no fim de um arquivo completo).
function M.describe_completion_failure(provider, status, raw_output)
  local message = M.extract_api_error_message(raw_output)
  if message then
    return string.format('vim-ai-autocomplete (%s): %s', provider, message)
  end
  if status ~= 0 then
    return string.format('vim-ai-autocomplete (%s): request falhou (exit %d), sem detalhe na resposta', provider, status)
  end
  return nil
end

return M
