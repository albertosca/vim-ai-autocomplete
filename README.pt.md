# vim-ai-autocomplete

[Read in English](README.md)

Autocomplete de IA via ghost-text para Vim 9+ e Neovim, com round-robin plugável de múltiplos modelos (Gemini, Claude, ou qualquer modelo que você configurar).

## Instalação

Requer `curl` no `$PATH`. Configure pelo menos uma API key como variável de ambiente antes de abrir o Vim/Neovim (`GEMINI_API_KEY` e/ou `ANTHROPIC_API_KEY`, ou o `api_key_env` que você configurar por modelo — veja [Configuração](#configuração)).

### Pathogen (Vim)

```bash
git submodule add https://github.com/albertosca/vim-ai-autocomplete.git ~/.vim/bundle/vim-ai-autocomplete
```

### lazy.nvim (Neovim)

```lua
{
  'albertosca/vim-ai-autocomplete',
  config = function()
    require('vim-ai-autocomplete').setup()
  end,
}
```

### vim-plug

```vim
Plug 'albertosca/vim-ai-autocomplete'
```

No Neovim, chame `require('vim-ai-autocomplete').setup()` em algum ponto do seu `init.lua`, depois do plug carregar. No Vim, não precisa de nenhuma chamada extra — o `plugin/vim-ai-autocomplete.vim` já se carrega sozinho.

### mini.deps

```lua
local add = MiniDeps.add
add({
  source = 'albertosca/vim-ai-autocomplete',
})
require('vim-ai-autocomplete').setup()
```

### Pacotes nativos (`:packadd`, sem gerenciador)

```bash
# Vim
git clone https://github.com/albertosca/vim-ai-autocomplete ~/.vim/pack/plugins/start/vim-ai-autocomplete
# Neovim
git clone https://github.com/albertosca/vim-ai-autocomplete ~/.local/share/nvim/site/pack/plugins/start/vim-ai-autocomplete
```

## Configuração

Os dois lados leem as mesmas globals — globals do Vimscript ficam visíveis no Lua via `vim.g`, então existe uma única fonte de verdade mesmo no Neovim.

```vim
" Vim (~/.vimrc) ou Neovim (init.vim, ou antes do require(...).setup() no init.lua)
let g:vim_ai_autocomplete_models = [
      \ {'name': 'gemini-flash', 'family': 'gemini', 'model_id': 'gemini-3.1-flash-lite', 'api_key_env': 'GEMINI_API_KEY'},
      \ {'name': 'claude-sonnet', 'family': 'anthropic', 'model_id': 'claude-sonnet-5', 'api_key_env': 'ANTHROPIC_API_KEY'},
      \ ]
```

Ou, no Neovim, o equivalente via o facilitador `setup(opts)` (açúcar sintático sobre as mesmas globals acima — escolha um estilo ou outro, nunca os dois):

```lua
require('vim-ai-autocomplete').setup({
  models = {
    { name = 'gemini-flash', family = 'gemini', model_id = 'gemini-3.1-flash-lite', api_key_env = 'GEMINI_API_KEY' },
    { name = 'claude-sonnet', family = 'anthropic', model_id = 'claude-sonnet-5', api_key_env = 'ANTHROPIC_API_KEY' },
  },
  auto_trigger = true, -- opcional, default true
})
```

| Campo | Significado |
|---|---|
| `name` | O nome que você quiser dar a esse modelo em `,pr`/`,pm`/`:VimAiAutocompleteModel` |
| `family` | `'gemini'` ou `'anthropic'` — determina o formato da requisição/resposta |
| `model_id` | O ID real do modelo enviado pra API do provedor |
| `api_key_env` | Nome da variável de ambiente que guarda a API key daquele provedor |

Se você não configurar nada, o default é um modelo Gemini e um Claude. Um modelo só fica "ativo" (elegível pro ciclo do `,pr`) se o `api_key_env` dele estiver de fato setado e não-vazio no ambiente.

## Uso

| Tecla | Ação |
|---|---|
| `Tab` | Aceita a sugestão visível (cai pro seu mapping original de `Tab` caso contrário) |
| `Esc` | Descarta a sugestão visível (cai pro seu mapping original de `Esc` caso contrário) |
| `,pt` | Liga/desliga o auto-trigger |
| `,pr` | Cicla pro próximo modelo ativo (só registrado com 2+ modelos ativos) |
| `,pm` | Escolhe um modelo via `vim.ui.select` (só Neovim, só registrado com 2+ modelos ativos) |
| `:VimAiAutocompleteModel <nome>` | Troca direto pra um modelo pelo nome, com completion |

## Arquitetura

- **Prompting FIM (fill-in-the-middle)**: o buffer ao redor do cursor é dividido numa seção "antes" e "depois" (nunca enviando a linha atual inteira pra nenhum dos dois lados), pra o modelo saber exatamente onde o cursor está e o que já existe depois dele.
- **Detecção de redundância**: dois mecanismos, somados numa única contagem de "caracteres a descartar" do texto real do buffer depois do cursor — uma comparação estrutural de pilha de parênteses/aspas (pega o caso em que a sugestão fecha algo que já estava aberto antes do cursor) e uma checagem textual de overlap de sufixo/prefixo (pega o caso em que o modelo literalmente repete o que já está ali). O trecho descartado é sempre mostrado em vermelho/riscado antes de ser removido no accept, nunca cortado silenciosamente.
- **Renderização do ghost text**: no Vim usa `prop_add`/textprop (Vim 9+); no Neovim usa extmarks (`nvim_buf_set_extmark` com `virt_text`/`virt_lines`).
- **Enriquecimento de contexto (só Neovim)**: o corte do buffer é sensível ao escopo do Treesitter (usa a função/classe que envolve o cursor em vez de uma contagem ingênua de linhas) quando há um parser disponível, caindo pro corte ingênuo caso contrário; uma consulta LSP `textDocument/definition` com timeout curto (150ms) opcionalmente acrescenta definições reais entre arquivos para símbolos em escopo.

## Contribuindo

```bash
bash test/run.sh
```

Roda a suite completa (vader pro lado Vim, plenary pro lado Neovim) — veja o [CI](.github/workflows/test.yml) pra ver como isso roda no GitHub Actions. Não precisa de API key nem acesso à rede; todo teste ou é lógica pura ou mocka a chamada de API.

## Créditos

- [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim) inspirou uma decisão de design específica — a ponderação 75/25 do `context_ratio` no prompt FIM (mais peso pro texto antes do cursor). Nenhum código foi copiado.
- [copilot.vim](https://github.com/github/copilot.vim) inspirou a *técnica* do ghost text (as APIs `prop_add`/textprop do Vim 9, com debounce via `timer_start`) — não o código dele. `copilot.vim` é "All Rights Reserved", não é open-source, então só as APIs do Vim publicamente documentadas foram reaproveitadas, implementadas de forma independente.

## Licença

MIT — veja [LICENSE](LICENSE).
