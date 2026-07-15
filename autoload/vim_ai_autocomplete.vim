function! vim_ai_autocomplete#ResolveProvider(has_gemini, has_claude) abort
  if !a:has_gemini && !a:has_claude
    return [v:null, 'error', 'nenhuma API key encontrada (GEMINI_API_KEY nem ANTHROPIC_API_KEY) -- configure pelo menos uma em ~/.zsh_secrets']
  endif
  if a:has_gemini && a:has_claude
    return ['gemini', v:null, v:null]
  endif
  let provider = a:has_gemini ? 'gemini' : 'claude'
  let message = printf('só %s disponível (falta a outra API key) -- toggle ,ap desabilitado', provider)
  return [provider, 'warn', message]
endfunction
