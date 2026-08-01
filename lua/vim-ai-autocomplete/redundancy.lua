local M = {}

local PAIRS = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local CLOSERS = ')]}"\'`'
local QUOTES = '"\'`'

-- g:AutoPairs (lado Vim) fecha (){}[] E aspas simples/duplas/crase --
-- brackets sao ASSIMETRICOS (empilha de verdade), aspas SIMETRICAS
-- (alternam: se o topo da pilha ja e essa mesma aspa, fecha; senao abre).
local function advance_bracket_stack(stack, text)
  for _, char in ipairs(vim.fn.split(text, '\\zs')) do
    if QUOTES:find(char, 1, true) then
      if #stack > 0 and stack[#stack] == char then
        table.remove(stack)
      else
        table.insert(stack, char)
      end
    elseif PAIRS[char] then
      table.insert(stack, char)
    elseif CLOSERS:find(char, 1, true) and #stack > 0 and PAIRS[stack[#stack]] == char then
      table.remove(stack)
    end
  end
  return stack
end

-- Cobre o caso em que o cursor esta ANTES do proprio abre-parenteses (nao
-- DENTRO do par ja aberto pelo auto-pairs) -- "antes" nao tem nenhum
-- bracket/aspa pendente (depth_before == 0), entao o calculo estrutural
-- nunca acha nada pra fechar, e o par vazio intacto em "depois" (ex: "()"
-- do auto-pairs) nao bate textualmente com o fim da sugestao. A sugestao,
-- sem saber que esse par vazio existe, escreve sua PROPRIA versao completa
-- do par -- o par vazio original fica orfao no final. So descarta se a
-- sugestao de fato USA esse mesmo tipo de bracket/aspa em algum lugar.
function M.count_leading_trivial_pair_redundancy(suggestion_text, after_text)
  if #after_text < 2 then
    return 0
  end
  local opener = after_text:sub(1, 1)
  local closer = PAIRS[opener]
  if not closer then
    if QUOTES:find(opener, 1, true) then
      closer = opener
    else
      return 0
    end
  end
  if after_text:sub(2, 2) ~= closer then
    return 0
  end
  if suggestion_text:find(opener, 1, true) then
    return 2
  end
  return 0
end

-- Cobre sobreposicao de ESTRUTURA: quando a sugestao fecha, com seu proprio
-- texto, um parenteses/colchete/chave/aspa que ja estava aberto ANTES do
-- cursor, o fechamento real que ja existe em "depois" fica orfao. Retorna
-- quantos caracteres do INICIO de "depois" devem ser descartados ao aceitar.
function M.count_redundant_after_chars(before_text, suggestion_text, after_text)
  local stack = advance_bracket_stack({}, before_text)
  local depth_before = #stack
  stack = advance_bracket_stack(stack, suggestion_text)
  local redundant = math.max(0, depth_before - #stack)
  if redundant > 0 then
    -- so descarta se "depois" realmente comecar com essa quantidade de
    -- fechamentos -- senao pode nao ser o mesmo bracket/aspa, melhor nao
    -- arriscar apagar algo que nao e obviamente redundante.
    local n = 0
    while n < redundant and n < #after_text do
      local char = after_text:sub(n + 1, n + 1)
      if CLOSERS:find(char, 1, true) or QUOTES:find(char, 1, true) then
        n = n + 1
      else
        break
      end
    end
    return n
  end
  return M.count_leading_trivial_pair_redundancy(suggestion_text, after_text)
end

-- Acha a maior sobreposicao entre o FIM da sugestao e o INICIO do texto
-- "depois" (o que sobra depois de ja descontar a redundancia estrutural --
-- ver request.lua). So CALCULA o tamanho -- NAO corta a sugestao (as duas
-- fontes de redundancia se SOMAM num so redundant_after, mesmo tratamento
-- visual pros dois).
function M.compute_text_overlap_length(lines, after_text)
  if #lines == 0 or after_text == '' then
    return 0
  end
  local suggestion_text = table.concat(lines, '\n')
  local max_check = math.min(#suggestion_text, #after_text)
  for n = max_check, 1, -1 do
    local suffix = suggestion_text:sub(-n)
    local prefix = after_text:sub(1, n)
    if suffix == prefix then
      return n
    end
  end
  return 0
end

-- Tira do FIM da sugestao EXIBIDA os caracteres que ja existem, identicos, no
-- buffer logo depois do cursor -- assim a tela mostra exatamente o texto final
-- (um ')' so) em vez de ')' da sugestao + ')' real riscado. O ghost text e'
-- virtual inline: cada caractere dele empurra o texto real da linha pra
-- direita, entao mostrar o fechamento duas vezes afastava o ')' real do cursor
-- e a linha "pulava" a cada tecla (relatado em markdown, onde a sugestao e'
-- longa e vem a cada tecla).
--
-- So corta quando a sugestao TERMINA com esses caracteres. Fechamento no MEIO
-- da sugestao (ex: 'x) { return; }' fechando um '(' anterior) continua sendo
-- resolvido descartando o caractere real, porque cortar a cauda ali produziria
-- texto errado. Retorna (lines, redundant_after) ajustados -- o texto final
-- apos aceitar e' identico ao de antes do corte, so muda o que aparece.
function M.split_display_tail(lines, after_text, redundant_after)
  redundant_after = redundant_after or 0
  if #lines == 0 or redundant_after <= 0 then
    return lines, redundant_after
  end
  local suggestion_text = table.concat(lines, '\n')
  -- keep = quantos caracteres reais continuam sendo descartados. Procura do
  -- corte maior (keep 0) pro menor, parando no primeiro que casa.
  for keep = 0, redundant_after - 1 do
    local tail = after_text:sub(keep + 1, redundant_after)
    if #tail <= #suggestion_text and suggestion_text:sub(-#tail) == tail then
      local cut = suggestion_text:sub(1, #suggestion_text - #tail)
      if cut == '' then
        return {}, keep
      end
      return vim.split(cut, '\n', { plain = true }), keep
    end
  end
  return lines, redundant_after
end

-- Alguns modelos tratam a resposta como continuacao literal de bytes: se o
-- contexto termina em ":" (abertura de bloco Python), a primeira linha da
-- sugestao vem sem quebra de linha nem indentacao propria -- mesmo achado
-- do lado Vim (confirmado com gemini-3.1-flash-lite).
function M.adjust_suggestion_lines(lines, current_line_before_cursor, filetype, shiftwidth, expandtab)
  if #lines == 0 or filetype ~= 'python' then
    return lines
  end
  local trimmed = current_line_before_cursor:gsub('%s*$', '')
  if not trimmed:match(':$') then
    return lines
  end
  if lines[1] == '' then
    -- ja veio com quebra de linha propria -- nao mexe
    return lines
  end
  local indent_str = expandtab and string.rep(' ', shiftwidth) or '\t'
  local first_line_stripped = lines[1]:gsub('^%s*', '')
  local result = { '', indent_str .. first_line_stripped }
  for i = 2, #lines do
    table.insert(result, lines[i])
  end
  return result
end

return M
