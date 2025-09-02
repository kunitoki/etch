proc analyzeAssign(s: Statement; env: var Env, ctx: ProverContext) =
  logProver(ctx.options.verbose, "Assignment to variable: " & s.aname)
  # Check if the variable being assigned to exists
  if not env.vals.hasKey(s.aname):
    raise newProveError(s.pos, &"assignment to undeclared variable '{s.aname}'")

  let info = analyzeExpression(s.aval, env, ctx)
  # Assignment initializes the variable
  var newInfo = info
  newInfo.initialized = true
  if isWeakVariable(env, s.aname):
    downgradeWeakInfo(newInfo)
  # Preserve the 'used' flag from the existing variable (assignment doesn't reset usage tracking)
  newInfo.used = env.vals[s.aname].used
  env.vals[s.aname] = newInfo
  env.exprs[s.aname] = s.aval  # Store original expression
  # Track nil status: true if assigning nil, false if assigning non-nil
  env.nils[s.aname] = not newInfo.nonNil
  if info.known:
    logProver(ctx.options.verbose, "Variable " & s.aname & " assigned constant value: " & $info.cval)
  else:
    logProver(ctx.options.verbose, "Variable " & s.aname & " assigned range [" & $info.minv & ".." & $info.maxv & "]")


proc analyzeFieldAssign(s: Statement; env: var Env, ctx: ProverContext) =
  logProver(ctx.options.verbose, "Field assignment")
  # Analyze the target expression to check initialization
  discard analyzeExpression(s.faTarget, env, ctx)
  # Analyze the value expression
  let valueInfo = analyzeExpression(s.faValue, env, ctx)
  # For now we don't track field-level initialization
  # This would require more sophisticated tracking of object fields
  logProver(ctx.options.verbose, "Field assigned value with range [" & $valueInfo.minv & ".." & $valueInfo.maxv & "]")
  if s.faTarget.kind == ekDeref:
    assignRefValue(s.faTarget.refExpression, valueInfo, env)
