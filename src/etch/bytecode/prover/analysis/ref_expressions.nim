proc analyzeNewExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # new(value) or new[Type]{value} - analyze initialization expression if present
  var res = Info(known: false, nonNil: true, initialized: true)
  if e.initExpression.isSome:
    let initInfo = analyzeExpression(e.initExpression.get, env, ctx)
    copyRefValue(res.refValue, initInfo)
  return res


proc analyzeNewRefExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # newRef always non-nil
  let initInfo = analyzeExpression(e.init, env, ctx)  # Analyze the initialization expression
  var res = Info(known: false, nonNil: true, initialized: true)
  copyRefValue(res.refValue, initInfo)
  res


proc analyzeDerefExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Check if dereferencing ref parameter after yield (unsafe - value could have been modified)
  if ctx.hasYielded and e.refExpression.kind == ekVar:
    let varName = e.refExpression.vname
    if varName in ctx.refParams:
      raise newProveError(e.pos, &"dereferencing ref parameter '{varName}' after yield is unsafe - the caller may have modified it while the coroutine was suspended")

  let i0 = analyzeExpression(e.refExpression, env, ctx)

  # Check if dereferencing a variable that is tracked as nil
  if e.refExpression.kind == ekVar and env.nils.hasKey(e.refExpression.vname) and env.nils[e.refExpression.vname]:
    raise newProveError(e.pos, &"potential null dereference: dereferencing variable '{e.refExpression.vname}' that may be nil")

  # Check if this specific expression is tracked as non-nil in env.nils
  # This handles cases like: if @arr[0] != nil { use @arr[0] }
  proc serializeExpr(expr: Expression): string =
    case expr.kind
    of ekVar: return expr.vname
    of ekIndex:
      let baseStr = serializeExpr(expr.arrayExpression)
      if expr.indexExpression.kind == ekInt:
        return baseStr & "[" & $expr.indexExpression.ival & "]"
      else:
        return baseStr & "[?]"
    of ekDeref: return "@" & serializeExpr(expr.refExpression)
    of ekFieldAccess: return serializeExpr(expr.objectExpression) & "." & expr.fieldName
    else: return "?"

  let exprKey = "@" & serializeExpr(e.refExpression)
  if env.nils.hasKey(exprKey):
    # Expression-specific nil tracking found
    if env.nils[exprKey]:
      # Expression is known to be nil
      raise newProveError(e.pos, &"potential null dereference: dereferencing expression '{exprKey}' that may be nil")
    else:
      # Expression is known to be non-nil, allow the dereference
      logProver(ctx.options.verbose, &"Expression '{exprKey}' is known to be non-nil from constraint")
      if i0.refValue != nil:
        var stored = i0.refValue[]
        stored.initialized = true
        return stored
      return infoUnknown()

  # Original check for expressions that can't be proven non-nil
  if not i0.nonNil:
    raise newProveError(e.pos, "cannot prove reference is non-nil before dereferencing")

  if i0.refValue != nil:
    var stored = i0.refValue[]
    stored.initialized = true
    return stored

  infoUnknown()
