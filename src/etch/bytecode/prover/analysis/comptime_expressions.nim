proc analyzeComptime(s: Statement; env: var Env, ctx: ProverContext) =
  # Comptime blocks may contain injected statements after folding
  for injectedStatement in s.cbody:
    analyzeStatement(injectedStatement, env, ctx)
