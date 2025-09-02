proc analyzeIfExpression(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Analyze if-expression with control-flow-sensitive range refinement
  let condEval = evaluateCondition(e.ifCond, env, ctx)

  proc evalBranch(stmts: seq[Statement], branchEnv: var Env): Info =
    ## Analyze a branch block and return the info for its resulting expression.
    if stmts.len == 0:
      return Info(known: false, initialized: true)

    var resultInfo = Info(known: false, initialized: true)
    for idx, stmt in stmts:
      let isLastExpr = (idx == stmts.len - 1) and stmt.kind == skExpression
      if isLastExpr:
        resultInfo = analyzeExpression(stmt.sexpr, branchEnv, ctx)
      else:
        analyzeStatement(stmt, branchEnv, ctx)
    return resultInfo

  var branchInfos: seq[Info] = @[]

  let analyzeThen = condEval != crAlwaysFalse
  let analyzeElseChain = condEval != crAlwaysTrue

  if analyzeThen:
    var thenEnv = copyEnv(env)
    applyConstraints(thenEnv, e.ifCond, env, ctx, negate = false)
    branchInfos.add(evalBranch(e.ifThen, thenEnv))
    propagateUsage(env, thenEnv)
  else:
    markStatementsUsage(e.ifThen, env)

  if analyzeElseChain:
    for elifCase in e.ifElifChain:
      var elifEnv = copyEnv(env)
      applyConstraints(elifEnv, elifCase.cond, env, ctx, negate = false)
      branchInfos.add(evalBranch(elifCase.body, elifEnv))
      propagateUsage(env, elifEnv)

    var elseEnv = copyEnv(env)
    applyConstraints(elseEnv, e.ifCond, env, ctx, negate = true)
    branchInfos.add(evalBranch(e.ifElse, elseEnv))
    propagateUsage(env, elseEnv)
  else:
    markElifChainUsage(e.ifElifChain, env)
    markStatementsUsage(e.ifElse, env)

  if branchInfos.len == 0:
    return Info(known: false, initialized: true)

  var mergedInfo = branchInfos[0]
  for i in 1..<branchInfos.len:
    mergedInfo = union(mergedInfo, branchInfos[i])
  return mergedInfo


proc analyzeIf(s: Statement; env: var Env, ctx: ProverContext) =
  let condResult = evaluateCondition(s.cond, env, ctx)
  logProver(ctx.options.verbose, "If condition evaluation result: " & $condResult)

  case condResult
  of crAlwaysTrue:
    logProver(ctx.options.verbose, "Condition is always true - analyzing only then branch")
    # Elif/else branches are unreachable in this path but still count as usages
    markElifChainUsage(s.elifChain, env)
    markStatementsUsage(s.elseBody, env)
    # Only analyze then branch using independent environment
    var thenEnv = copyEnv(env)
    logProver(ctx.options.verbose, "Analyzing " & $s.thenBody.len & " statements in then branch")
    for st in s.thenBody: analyzeStatement(st, thenEnv, ctx)
    propagateUsage(env, thenEnv)

    # Check if this is an obvious constant condition that should trigger error
    # Do this AFTER analyzing the then branch to catch safety violations first
    if isObviousConstant(s.cond) and s.elseBody.len > 0:
      raise newProveError(s.pos, "unreachable code (condition is always true)")

    # If then branch has a return, the rest of the function is unreachable
    let thenReturns = hasReturn(s.thenBody)
    if thenReturns:
      logProver(ctx.options.verbose, "Then branch returns and condition is always true - any code after if is unreachable")
      env.vals = thenEnv.vals
      env.nils = thenEnv.nils
      env.exprs = thenEnv.exprs
      env.declPos = thenEnv.declPos
      env.types = thenEnv.types
      env.unreachable = true
      return

    # Copy then results back to main env
    for k, v in thenEnv.vals: env.vals[k] = v
    for k, v in thenEnv.exprs: env.exprs[k] = v
    for k, v in thenEnv.types: env.types[k] = v
    logProver(ctx.options.verbose, "Then branch analysis complete")
    return
  of crAlwaysFalse:
    logProver(ctx.options.verbose, "Condition is always false - skipping then branch")
    markStatementsUsage(s.thenBody, env)
    # Check if this is an obvious constant condition that should trigger error
    if isObviousConstant(s.cond) and s.thenBody.len > 0 and s.elseBody.len == 0:
      raise newProveError(s.pos, "unreachable code (condition is always false)")
    # Skip then branch, analyze elif/else branches and merge results

    var elifEnvs: seq[Env] = @[]
    # Process elif chain
    for i, elifBranch in s.elifChain:
      var elifEnv = copyEnv(env)
      let elifCondResult = evaluateCondition(elifBranch.cond, env, ctx)
      if elifCondResult != crAlwaysFalse:
        for st in elifBranch.body: analyzeStatement(st, elifEnv, ctx)
        propagateUsage(env, elifEnv)
        elifEnvs.add(elifEnv)
      else:
        markExpressionUsage(elifBranch.cond, env)
        markStatementsUsage(elifBranch.body, env)

    # Process else branch
    var elseEnv = copyEnv(env)
    for st in s.elseBody: analyzeStatement(st, elseEnv, ctx)
    propagateUsage(env, elseEnv)

    # Merge results from all executed branches
    if elifEnvs.len > 0:
      # Collect all variables from all environments
      var allVars: seq[string] = @[]
      for elifEnv in elifEnvs:
        for k in elifEnv.vals.keys:
          if k notin allVars: allVars.add(k)
      for k in elseEnv.vals.keys:
        if k notin allVars: allVars.add(k)

      # Merge each variable across all paths
      for varName in allVars:
        var infos: seq[Info] = @[]

        # Check elif branches
        for elifEnv in elifEnvs:
          if elifEnv.vals.hasKey(varName):
            infos.add(elifEnv.vals[varName])
          elif env.vals.hasKey(varName):
            infos.add(env.vals[varName])

        # Check else branch
        if elseEnv.vals.hasKey(varName):
          infos.add(elseEnv.vals[varName])
        elif env.vals.hasKey(varName):
          infos.add(env.vals[varName])

        # Compute union of all info states
        if infos.len > 0:
          var mergedInfo = infos[0]
          for i in 1..<infos.len:
            mergedInfo = union(mergedInfo, infos[i])
          env.vals[varName] = mergedInfo
    else:
      # Only else branch executed, copy its results
      for k, v in elseEnv.vals:
        env.vals[k] = v
      for k, v in elseEnv.exprs:
        env.exprs[k] = v
    return
  of crUnknown:
    logProver(ctx.options.verbose, "Condition result is unknown at compile time - analyzing all branches")
    discard # Continue with normal analysis

  # Normal case: condition is not known at compile time
  # Create independent copies of environment for each branch
  logProver(ctx.options.verbose, "Analyzing control flow with condition refinement")
  let condInfo = analyzeExpression(s.cond, env, ctx)

  # Process then branch (condition could be true)
  var thenEnv = copyEnv(env)
  if not (condInfo.known and condInfo.cval == 0):
    # Control flow sensitive analysis: refine environment based on condition
    # Apply constraint refinements recursively (handles compound conditions with AND/OR)
    logProver(ctx.options.verbose, "Applying condition constraints to then branch")
    applyConstraints(thenEnv, s.cond, env, ctx, negate = false)
    for st in s.thenBody: analyzeStatement(st, thenEnv, ctx)

  # Process elif chain
  var elifEnvs: seq[Env] = @[]
  for i, elifBranch in s.elifChain:
    # Create independent copy for elif branch
    var elifEnv = copyEnv(env)
    # Control flow analysis for elif condition
    logProver(ctx.options.verbose, "Applying condition constraints to elif branch")
    applyConstraints(elifEnv, elifBranch.cond, env, ctx, negate = false)
    for st in elifBranch.body: analyzeStatement(st, elifEnv, ctx)
    elifEnvs.add(elifEnv)

  # Process else branch
  var elseEnv = copyEnv(env)
  # Control flow sensitive analysis for else (condition is false)
  # Special case: Handle array/string length equality
  if s.cond.kind == ekBin and s.cond.bop == boNe and
     s.cond.lhs.kind == ekArrayLen and s.cond.rhs.kind == ekArrayLen:
    # Handle array/string length equality: if (#a != #b) is false, then #a == #b
    let lhsInfo = analyzeExpression(s.cond.lhs, env, ctx)
    let rhsInfo = analyzeExpression(s.cond.rhs, env, ctx)

    # If we know one size, constrain the other to match
    if lhsInfo.arraySizeKnown and (lhsInfo.isArray or lhsInfo.isString):
      # Constrain the rhs array to have the same size
      if s.cond.rhs.arrayExpression.kind == ekVar and elseEnv.vals.hasKey(s.cond.rhs.arrayExpression.vname):
        elseEnv.vals[s.cond.rhs.arrayExpression.vname].arraySize = lhsInfo.arraySize
        elseEnv.vals[s.cond.rhs.arrayExpression.vname].arraySizeKnown = true
        elseEnv.vals[s.cond.rhs.arrayExpression.vname].minv = makeScalar(lhsInfo.arraySize)
        elseEnv.vals[s.cond.rhs.arrayExpression.vname].maxv = makeScalar(lhsInfo.arraySize)
    elif rhsInfo.arraySizeKnown and (rhsInfo.isArray or rhsInfo.isString):
      # Constrain the lhs array to have the same size
      if s.cond.lhs.arrayExpression.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.arrayExpression.vname):
        elseEnv.vals[s.cond.lhs.arrayExpression.vname].arraySize = rhsInfo.arraySize
        elseEnv.vals[s.cond.lhs.arrayExpression.vname].arraySizeKnown = true
        elseEnv.vals[s.cond.lhs.arrayExpression.vname].minv = makeScalar(rhsInfo.arraySize)
        elseEnv.vals[s.cond.lhs.arrayExpression.vname].maxv = makeScalar(rhsInfo.arraySize)

  # Apply negated constraint refinements recursively (handles compound conditions with AND/OR)
  logProver(ctx.options.verbose, "Applying negated condition constraints to else branch")
  applyConstraints(elseEnv, s.cond, env, ctx, negate = true)

  for st in s.elseBody: analyzeStatement(st, elseEnv, ctx)

  # Check if then branch has early return
  let thenReturns = hasReturn(s.thenBody)
  let elseReturns = hasReturn(s.elseBody)

  logProver(ctx.options.verbose, &"Then branch returns: {thenReturns}, Else branch returns: {elseReturns}")

  # If then branch returns, use else environment for continuation
  if thenReturns and not elseReturns:
    logProver(ctx.options.verbose, "Then branch has early return - using else environment for continuation")
    # Log environment changes
    for k, v in elseEnv.vals:
      if env.vals.hasKey(k) and (v.arraySize != env.vals[k].arraySize or v.arraySizeKnown != env.vals[k].arraySizeKnown):
        logProver(ctx.options.verbose, &"Updating variable '{k}': arraySize {env.vals[k].arraySize} -> {v.arraySize}, arraySizeKnown {env.vals[k].arraySizeKnown} -> {v.arraySizeKnown}")
      env.vals[k] = v
    for k, v in elseEnv.nils:
      env.nils[k] = v
    for k, v in elseEnv.exprs:
      env.exprs[k] = v
    # Preserve usage information gathered in branches that returned early
    propagateUsage(env, thenEnv)
    for elifEnv in elifEnvs:
      propagateUsage(env, elifEnv)
    return

  # Join - merge variable states from all branches
  # For complete initialization analysis, we need to check all possible paths

  # Collect all variables that exist in any branch
  var allVars: seq[string] = @[]
  for k in thenEnv.vals.keys:
    if k notin allVars: allVars.add(k)
  for k in elseEnv.vals.keys:
    if k notin allVars: allVars.add(k)
  for elifEnv in elifEnvs:
    for k in elifEnv.vals.keys:
      if k notin allVars: allVars.add(k)

  # Merge each variable across all paths
  for varName in allVars:
    var infos: seq[Info] = @[]
    var branchCount = 0

    # Check then branch
    if thenEnv.vals.hasKey(varName):
      infos.add(thenEnv.vals[varName])
      branchCount += 1
    elif env.vals.hasKey(varName):
      infos.add(env.vals[varName])  # Use original state if not modified in this branch

    # Check elif branches
    for elifEnv in elifEnvs:
      if elifEnv.vals.hasKey(varName):
        infos.add(elifEnv.vals[varName])
      elif env.vals.hasKey(varName):
        infos.add(env.vals[varName])  # Use original state
      branchCount += 1

    # For if statements, we always need to consider the else branch (implicit or explicit)
    if elseEnv.vals.hasKey(varName):
      infos.add(elseEnv.vals[varName])
    elif env.vals.hasKey(varName):
      infos.add(env.vals[varName])  # Use original state
    branchCount += 1

    # Compute union of all info states for control flow merging
    if infos.len > 0:
      var mergedInfo = infos[0]
      for i in 1..<infos.len:
        mergedInfo = union(mergedInfo, infos[i])
      env.vals[varName] = mergedInfo
