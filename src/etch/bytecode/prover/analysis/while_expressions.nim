proc analyzeWhile(s: Statement; env: var Env, ctx: ProverContext) =
  # Enhanced while loop analysis using symbolic execution
  let condResult = evaluateCondition(s.wcond, env, ctx)

  case condResult
  of crAlwaysFalse:
    if s.wbody.len > 0:
      let fnCtx = getFunctionContext(s.pos, ctx)
      if fnCtx.len > 0 and '<' in fnCtx and '>' in fnCtx and "<>" notin fnCtx:
        raise newProveError(s.pos, &"unreachable code (while condition is always false) in {fnCtx}")
      else:
        raise newProveError(s.pos, "unreachable code (while condition is always false)")
    # Skip loop body analysis since it's never executed
    return
  of crAlwaysTrue:
    discard
  of crUnknown:
    discard

  # Try symbolic execution for precise loop analysis
  var symState = newSymbolicState()

  # Convert current environment to symbolic state
  for varName, info in env.vals:
    symState.setVariable(varName, info)  # Direct assignment since using unified Info type

  # Try to execute the loop symbolically
  let loopResult = symbolicExecuteWhile(s, symState, ctx.prog)

  case loopResult
  of erContinue:
    # Loop executed completely with known values - use precise results
    for varName, info in symState.variables:
      var mergedInfo = info  # Preserve usage information tracked before symbolic run
      if env.vals.hasKey(varName):
        mergedInfo.used = mergedInfo.used or env.vals[varName].used
      env.vals[varName] = mergedInfo
    registerStatementsDecls(s.wbody, env)
    markStatementsUsage(s.wbody, env)
  of erRuntimeHit, erIterationLimit:
    # Fell back to conservative analysis - but we may have learned something
    # from the initial iterations that executed symbolically

    # Use hybrid approach: variables that were definitely initialized
    # in the symbolic portion are marked as initialized
    var originalVars = initTable[string, Info]()
    for k, v in env.vals:
      originalVars[k] = v

    # Create loop body environment for remaining analysis
    var loopEnv = copyEnv(env)

    # Apply loop condition constraints as invariants
    # Inside the loop, the condition must be true
    logProver(ctx.options.verbose, "Applying while loop condition as invariant")
    applyConstraints(loopEnv, s.wcond, env, ctx, negate = false)

    # Analyze loop body with traditional method
    for st in s.wbody:
      analyzeStatement(st, loopEnv, ctx)

    # Enhanced merge: if symbolic execution determined a variable was initialized,
    # trust that result even if traditional analysis is conservative
    for varName in loopEnv.vals.keys:
      if originalVars.hasKey(varName) and symState.hasVariable(varName):
        let originalInfo = originalVars[varName]
        let loopInfo = loopEnv.vals[varName]
        let symInfo = symState.getVariable(varName).get()

        # If symbolic execution shows variable is initialized, trust it
        if symInfo.initialized and not originalInfo.initialized:
          var enhancedInfo = loopInfo
          enhancedInfo.initialized = true
          enhancedInfo.used = enhancedInfo.used or originalInfo.used
          env.vals[varName] = enhancedInfo
        elif not originalInfo.initialized:
          # Fall back to conservative approach
          var conservativeInfo = loopInfo
          conservativeInfo.initialized = false
          conservativeInfo.used = conservativeInfo.used or originalInfo.used
          env.vals[varName] = conservativeInfo
        else:
          # Variable was already initialized, merge normally
          env.vals[varName] = union(originalInfo, loopInfo)
      elif originalVars.hasKey(varName):
        # Handle variables without symbolic info conservatively
        let originalInfo = originalVars[varName]
        let loopInfo = loopEnv.vals[varName]
        if not originalInfo.initialized:
          var conservativeInfo = loopInfo
          conservativeInfo.initialized = false
          conservativeInfo.used = conservativeInfo.used or originalInfo.used
          env.vals[varName] = conservativeInfo
        else:
          env.vals[varName] = union(originalInfo, loopInfo)
      else:
        # New variable declared in loop - conservative approach
        var conservativeInfo = loopEnv.vals[varName]
        conservativeInfo.initialized = false
        env.vals[varName] = conservativeInfo
  of erComplete:
    # Loop completed (shouldn't happen for while loops, but handle gracefully)
    discard
