proc analyzeBreak(s: Statement; env: var Env, ctx: ProverContext) =
  # Break statements are valid only inside loops, but this is a parse-time concern
  # For prover purposes, break doesn't change variable states
  logProver(ctx.options.verbose, "Break statement (control flow transfer)")


proc analyzeReturn(s: Statement; env: var Env, ctx: ProverContext) =
  if s.re.isSome():
      let returnInfo = analyzeExpression(s.re.get(), env, ctx)
      # Check if the returned expression is initialized
      if not returnInfo.initialized:
        raise newProveError(s.pos, "returning uninitialized value")
