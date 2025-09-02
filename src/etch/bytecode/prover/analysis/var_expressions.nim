proc analyzeVarExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  if env.vals.hasKey(e.vname):
    var info = env.vals[e.vname]
    if not info.initialized:
      raise newProveError(e.pos, &"use of uninitialized variable '{e.vname}' - variable may not be initialized in all control flow paths")
    # Mark variable as used (read) - must update the table entry explicitly
    if ctx.options.verbose:
      logProver(ctx.options.verbose, &"Marking variable '{e.vname}' as used")
    info.used = true
    env.vals[e.vname] = info  # Update the table entry
    return info

  # If this name is a top-level function, treat the function reference as a valid
  # expression (initialized) for the prover. We don't track function values in
  # `env.vals`, so accept it here instead of erroring.
  if ctx.prog != nil and ctx.prog.funs.hasKey(e.vname):
    return infoUnknown()

  raise newProveError(e.pos, &"use of undeclared variable '{e.vname}'")


proc analyzeVar(s: Statement; env: var Env, ctx: ProverContext) =
  logProver(ctx.options.verbose, "Declaring variable: " & s.vname)
  # Store declaration position for error reporting
  env.declPos[s.vname] = s.pos
  var declaredType = s.vtype
  if (declaredType.isNil) and s.vinit.isSome():
    let initExpr = s.vinit.get()
    if not initExpr.typ.isNil:
      declaredType = initExpr.typ
  if not declaredType.isNil:
    env.types[s.vname] = declaredType
  elif env.types.hasKey(s.vname):
    env.types.del(s.vname)
  if s.vinit.isSome():
    logProver(ctx.options.verbose, "Variable " & s.vname & " has initializer")
    var info = analyzeExpression(s.vinit.get(), env, ctx)
    info.used = false  # Freshly declared variable hasn't been read yet
    if isWeakVariable(env, s.vname):
      downgradeWeakInfo(info)
    env.vals[s.vname] = info
    env.nils[s.vname] = not info.nonNil
    env.exprs[s.vname] = s.vinit.get()  # Store original expression
    if info.known:
      logProver(ctx.options.verbose, "Variable " & s.vname & " initialized with constant value: " & $info.cval)
    elif info.isArray and info.arraySizeKnown:
      logProver(ctx.options.verbose, "Variable " & s.vname & " initialized with array of size: " & $info.arraySize)
    elif info.isArray:
      logProver(ctx.options.verbose, "Variable " & s.vname & " initialized with array of unknown size (min: " & $info.arraySize & ")")
    else:
      logProver(ctx.options.verbose, "Variable " & s.vname & " initialized with range [" & $info.minv & ".." & $info.maxv & "]")
  else:
    # Variable declared without initializer
    # For ref/weak types, they default to nil and are considered initialized
    let isRefType = s.vtype != nil and (s.vtype.kind == tkRef or s.vtype.kind == tkWeak)
    if isRefType:
      logProver(ctx.options.verbose, "Variable " & s.vname & " declared without initializer (defaults to nil)")
      # Ref types default to nil - mark as initialized with nil
      env.vals[s.vname] = infoRange(0, 0)  # nil is represented as 0
      env.vals[s.vname].initialized = true
      env.nils[s.vname] = true  # Is nil
    else:
      logProver(ctx.options.verbose, "Variable " & s.vname & " declared without initializer (uninitialized)")
      # Variable is declared but not initialized
      env.vals[s.vname] = infoUninitialized()
      env.nils[s.vname] = true
