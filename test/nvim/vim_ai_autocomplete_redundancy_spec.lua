local redundancy = require('vim-ai-autocomplete.redundancy')

describe("vim-ai-autocomplete.redundancy.count_redundant_after_chars", function()
  it("sugestao fecha o parenteses aberto antes -> ')' real fica redundante", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars('def soma(', 'a, b):\n    return a + b', ')'))
  end)

  it("sugestao nao fecha nada aberto antes -> nada redundante", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo', 'bar', ')'))
  end)

  it('"depois" nao comeca com fechamento -> nao arrisca, retorna 0', function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def soma(', 'a, b)', 'algo_que_nao_e_fechamento'))
  end)

  it("multiplos niveis fechados pela sugestao", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('foo([', '])', '])'))
  end)

  it("sugestao abre e fecha o proprio parenteses -> nao mexe no que ja existia antes", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo(', 'bar(1, 2)', ')'))
  end)

  it("sugestao fecha a aspa dupla aberta antes -> aspa real fica redundante", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars('name = "', 'John"', '"'))
  end)

  it("sugestao fecha a aspa simples aberta antes", function()
    assert.are.equal(1, redundancy.count_redundant_after_chars("name = '", "John'", "'"))
  end)

  it('mistura parenteses e aspas -- print("|") com sugestao que fecha os dois', function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('print("', 'ola")', '")'))
  end)

  it("aspa dentro da sugestao que NAO fecha nada aberto antes -> nao mexe", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('foo(', '"bar"', ')'))
  end)

  -- Cursor ANTES do proprio abre-parenteses (fix 2026-07-21, commit a435b21
  -- do lado Vim): depth_before == 0, o par vazio intacto em "depois" fica
  -- orfao se a sugestao escreve sua propria versao completa do par.
  it("cursor antes do abre-parenteses, sugestao escreve o proprio par -> par vazio original fica redundante", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('def quicksort', '(arr):', '()'))
  end)

  it("mesmo caso com colchete", function()
    assert.are.equal(2, redundancy.count_redundant_after_chars('items', '[x, y]', '[]'))
  end)

  it('"depois" nao e um par vazio de verdade (tem conteudo entre os dois) -> nao mexe', function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def quicksort', '(arr):', '(x)'))
  end)

  it("sugestao nao usa esse tipo de bracket -> nao arrisca, retorna 0", function()
    assert.are.equal(0, redundancy.count_redundant_after_chars('def quicksort', 'pass', '()'))
  end)
end)

describe("vim-ai-autocomplete.redundancy.compute_text_overlap_length", function()
  it("acha a maior sobreposicao entre o fim da sugestao e o inicio de 'depois'", function()
    assert.are.equal(2, redundancy.compute_text_overlap_length({ 'foo()' }, '()bar'))
  end)

  it("sem sobreposicao -> 0", function()
    assert.are.equal(0, redundancy.compute_text_overlap_length({ 'foo' }, 'bar'))
  end)

  it("lines vazio -> 0", function()
    assert.are.equal(0, redundancy.compute_text_overlap_length({}, 'bar'))
  end)
end)

describe("vim-ai-autocomplete.redundancy.adjust_suggestion_lines", function()
  it("filetype python, contexto termina em ':' -> quebra de linha + indentacao na primeira linha", function()
    local lines = redundancy.adjust_suggestion_lines({ 'if x:', '    pass' }, 'def foo():', 'python', 4, true)
    assert.are.same({ '', '    if x:', '    pass' }, lines)
  end)

  it("nao-python -> nao mexe", function()
    local lines = redundancy.adjust_suggestion_lines({ 'if x:' }, 'def foo():', 'javascript', 4, true)
    assert.are.same({ 'if x:' }, lines)
  end)

  it("contexto nao termina em ':' -> nao mexe", function()
    local lines = redundancy.adjust_suggestion_lines({ 'x = 1' }, 'foo', 'python', 4, true)
    assert.are.same({ 'x = 1' }, lines)
  end)

  it("ja vem com quebra de linha propria -> nao mexe", function()
    local lines = redundancy.adjust_suggestion_lines({ '', 'pass' }, 'def foo():', 'python', 4, true)
    assert.are.same({ '', 'pass' }, lines)
  end)
end)

describe("vim-ai-autocomplete.redundancy.split_display_tail", function()
  -- Texto final ao aceitar, do jeito que ghost_text.insert_accepted_lines
  -- monta: sugestao + o que sobra de "depois" apos descartar os redundantes.
  local function accepted(lines, after, ra)
    return table.concat(lines, '\n') .. after:sub(ra + 1)
  end

  it("sugestao termina exatamente com o ')' real -> corta a cauda, nao descarta nada", function()
    local lines, ra = redundancy.split_display_tail({ 'Continuous Integration)' }, ')', 1)
    assert.are.same({ 'Continuous Integration' }, lines)
    assert.are.equal(0, ra)
  end)

  it('print("|") -- corta o \'")\' da sugestao e mantem os reais', function()
    local lines, ra = redundancy.split_display_tail({ 'ola")' }, '")', 2)
    assert.are.same({ 'ola' }, lines)
    assert.are.equal(0, ra)
  end)

  it("fechamento no MEIO da sugestao -> NAO corta (cortar a cauda produziria texto errado)", function()
    local lines, ra = redundancy.split_display_tail({ 'x) { return; }' }, ')', 1)
    assert.are.same({ 'x) { return; }' }, lines)
    assert.are.equal(1, ra)
  end)

  it("corte parcial: casa so parte do que seria descartado", function()
    local lines, ra = redundancy.split_display_tail({ 'x)' }, '")', 2)
    assert.are.same({ 'x' }, lines)
    assert.are.equal(1, ra)
  end)

  it("redundant_after zero -> nao mexe", function()
    local lines, ra = redundancy.split_display_tail({ 'foo' }, ')', 0)
    assert.are.same({ 'foo' }, lines)
    assert.are.equal(0, ra)
  end)

  it("sugestao multi-linha -> corta so a ultima linha", function()
    local lines, ra = redundancy.split_display_tail({ 'a,', '    b)' }, ')', 1)
    assert.are.same({ 'a,', '    b' }, lines)
    assert.are.equal(0, ra)
  end)

  it("lines vazio -> nao mexe", function()
    local lines, ra = redundancy.split_display_tail({}, ')', 1)
    assert.are.same({}, lines)
    assert.are.equal(1, ra)
  end)

  it("sugestao inteira e' so o redundante -> nada a mostrar", function()
    local lines, ra = redundancy.split_display_tail({ ')' }, ')', 1)
    assert.are.same({}, lines)
    assert.are.equal(0, ra)
  end)

  it("cauda maior que a sugestao nao casa, mas a cauda menor ainda casa", function()
    -- keep=0 pediria a cauda '")' (2 chars) contra uma sugestao de 1 char --
    -- nao casa. keep=1 pede so ')', que casa: sobra descartar o '" ' real e a
    -- sugestao inteira vira redundante, nada a exibir.
    local lines, ra = redundancy.split_display_tail({ ')' }, '")', 2)
    assert.are.same({}, lines)
    assert.are.equal(1, ra)
  end)

  it("sugestao nao termina com nenhum sufixo do que seria descartado -> nao corta", function()
    local lines, ra = redundancy.split_display_tail({ 'x' }, '")', 2)
    assert.are.same({ 'x' }, lines)
    assert.are.equal(2, ra)
  end)

  it("INVARIANTE: o texto final aceito e' identico com e sem o corte", function()
    local cases = {
      { { 'Continuous Integration)' }, ')', 1 },
      { { 'ola")' }, '")', 2 },
      { { 'x) { return; }' }, ')', 1 },
      { { 'x)' }, '")', 2 },
      { { 'a,', '    b)' }, ')', 1 },
      { { ')' }, ')', 1 },
      { { ')' }, '")', 2 },
      { { 'foo' }, ')', 0 },
    }
    for _, c in ipairs(cases) do
      local lines, ra = redundancy.split_display_tail(c[1], c[2], c[3])
      assert.are.equal(accepted(c[1], c[2], c[3]), accepted(lines, c[2], ra))
    end
  end)
end)
