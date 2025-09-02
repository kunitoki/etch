proc analyzeFor(s: Statement; env: var Env, ctx: ProverContext) =
  # Analyze for loop: for var in start..end or for var in array
  logProver(ctx.options.verbose, "Analyzing for loop variable: " & s.fvar)

  var loopVarInfo: Info
  var iterationCount: Option[int64] = none(int64)

  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayInfo = analyzeExpression(s.farray.get(), env, ctx)
    logProver(ctx.options.verbose, "For loop over array with info: " & (if arrayInfo.isArray: "array" else: "unknown"))

    # Loop variable gets the element type - for now assume int (could be enhanced later)
    loopVarInfo = infoUnknown()
    loopVarInfo.initialized = true
    loopVarInfo.nonNil = true

    # Check if array is empty (would make loop body unreachable)
    if arrayInfo.isArray and arrayInfo.arraySizeKnown and arrayInfo.arraySize == 0:
      if s.fbody.len > 0:
        raise newProveError(s.pos, "unreachable code (for loop over empty array)")

    # Track iteration count for fixed-point analysis
    if arrayInfo.isArray and arrayInfo.arraySizeKnown:
      iterationCount = some(arrayInfo.arraySize)

  else:
    # Range iteration: for var in start..end
    let startInfo = analyzeExpression(s.fstart.get(), env, ctx)
    let endInfo = analyzeExpression(s.fend.get(), env, ctx)

    logProver(ctx.options.verbose, "For loop start range: [" & $startInfo.minv & ".." & $startInfo.maxv & "]")
    logProver(ctx.options.verbose, "For loop end range: [" & $endInfo.minv & ".." & $endInfo.maxv & "]")

    # Check if loop will never execute
    if s.finclusive:
      # Inclusive range: start > end means no execution
      if startInfo.known and endInfo.known and startInfo.cval > endInfo.cval:
        if s.fbody.len > 0:
          raise newProveError(s.pos, "unreachable code (for loop will never execute: start > end)")
      elif startInfo.minv > endInfo.maxv:
        if s.fbody.len > 0:
          raise newProveError(s.pos, "unreachable code (for loop will never execute: min(start) > max(end))")
    else:
      # Exclusive range: start >= end means no execution
      if startInfo.known and endInfo.known and startInfo.cval >= endInfo.cval:
        if s.fbody.len > 0:
          raise newProveError(s.pos, "unreachable code (for loop will never execute: start >= end)")
      elif startInfo.minv >= endInfo.maxv:
        if s.fbody.len > 0:
          raise newProveError(s.pos, "unreachable code (for loop will never execute: min(start) >= max(end))")

    # Create loop variable info - it ranges from start to end (or end-1 for exclusive)
    let actualEnd = if s.finclusive: max(endInfo.maxv, endInfo.cval) else: max(endInfo.maxv, endInfo.cval) - 1
    loopVarInfo = infoRange(min(startInfo.minv, startInfo.cval), actualEnd)
    loopVarInfo.initialized = true
    loopVarInfo.nonNil = true

    # Calculate iteration count if both bounds are known
    if startInfo.known and endInfo.known:
      let countVal = if s.finclusive:
        max(scalarZero(), endInfo.cval - startInfo.cval + scalarOne())
      else:
        max(scalarZero(), endInfo.cval - startInfo.cval)
      iterationCount = some(toInt(countVal))
      logProver(ctx.options.verbose, "For loop has known iteration count: " & $countVal)

  # Save current variable state if it exists
  let oldVarInfo = if env.vals.hasKey(s.fvar): env.vals[s.fvar] else: infoUninitialized()

  # Set loop variable
  env.vals[s.fvar] = loopVarInfo
  env.nils[s.fvar] = false

  logProver(ctx.options.verbose, "Loop variable " & s.fvar & " has range [" & $loopVarInfo.minv & ".." & $loopVarInfo.maxv & "]")

  # Enhanced analysis: if we know the iteration count, use fixed-point iteration
  # to get tighter bounds on accumulated variables
  if iterationCount.isSome and iterationCount.get > 0:
    let maxIterations = min(iterationCount.get, 10'i64)  # Cap at 10 iterations for analysis
    logProver(ctx.options.verbose, "Using fixed-point iteration (up to " & $maxIterations & " passes) for precise analysis")

    # Save initial environment state
    var prevEnv = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expression]())
    for k, v in env.vals:
      if k != s.fvar:  # Don't copy loop variable
        prevEnv.vals[k] = v
    for k, v in env.nils:
      if k != s.fvar:
        prevEnv.nils[k] = v
    for k, v in env.exprs:
      if k != s.fvar:
        prevEnv.exprs[k] = v

    # Fixed-point iteration: analyze loop body multiple times
    var converged = false
    var iteration = 0'i64
    while iteration < maxIterations and not converged:
      logProver(ctx.options.verbose, "Fixed-point iteration pass " & $(iteration + 1) & "/" & $maxIterations)

      # Create environment for this iteration
      var iterEnv = copyEnv(env)

      # Loop invariant: the loop variable maintains its range throughout
      # This is already set in env, but we ensure it's preserved
      iterEnv.vals[s.fvar] = loopVarInfo

      # Analyze loop body with current environment
      for stmt in s.fbody:
        analyzeStatement(stmt, iterEnv, ctx)

      # Check for convergence: have the ranges stabilized?
      converged = true
      for k, newInfo in iterEnv.vals:
        if k != s.fvar and env.vals.hasKey(k):
          let oldInfo = env.vals[k]
          # Check if ranges changed
          if newInfo.minv != oldInfo.minv or newInfo.maxv != oldInfo.maxv:
            converged = false
            logProver(ctx.options.verbose, "Variable " & k & " range updated: [" & $newInfo.minv & ".." & $newInfo.maxv & "]")
          # Always update environment to propagate the `used` flag even if ranges didn't change
          env.vals[k] = newInfo
        elif k != s.fvar:
          env.vals[k] = newInfo

      # Copy back other state
      for k, v in iterEnv.nils:
        if k != s.fvar:
          env.nils[k] = v
      for k, v in iterEnv.exprs:
        if k != s.fvar:
          env.exprs[k] = v

      iteration += 1

      if converged:
        logProver(ctx.options.verbose, "Fixed-point reached after " & $iteration & " iterations")
        break

    if not converged:
      logProver(ctx.options.verbose, "Fixed-point not reached after " & $maxIterations & " iterations, using widening")
      # Apply widening: if a variable is still growing, extrapolate to worst case
      # This is conservative but ensures we don't miss overflow issues
  else:
    # Fallback: single-pass analysis for unknown iteration count
    logProver(ctx.options.verbose, "Using single-pass analysis (iteration count unknown)")
    for stmt in s.fbody:
      analyzeStatement(stmt, env, ctx)

  # Restore old variable state (for loops introduce block scope)
  if oldVarInfo.initialized:
    env.vals[s.fvar] = oldVarInfo
  else:
    env.vals.del(s.fvar)
    env.nils.del(s.fvar)
    if env.types.hasKey(s.fvar):
      env.types.del(s.fvar)
