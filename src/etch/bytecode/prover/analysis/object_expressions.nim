proc analyzeObjectLiteralExpression(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Object literals are properly initialized values
  # Analyze all field initializations for safety
  for field in e.fieldInits:
    discard analyzeExpression(field.value, env, ctx)
  return Info(known: false, initialized: true, nonNil: true)


proc analyzeFieldAccessExpression(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Check if this is an enum type member access (e.g., Color.Red)
  if e.objectExpression.kind == ekVar and ctx.prog != nil:
    let typeName = e.objectExpression.vname
    # Check if this is an enum type in the program
    if ctx.prog.types.hasKey(typeName):
      let enumType = ctx.prog.types[typeName]
      if enumType.kind == tkEnum and enumType.enumMembers.len > 0:
        # This is an enum type member access like Color.Red
        # The result is an initialized enum value
        logProver(ctx.options.verbose, &"Enum type member access: {typeName}.{e.fieldName}")
        return Info(known: false, initialized: true, nonNil: true)

      # Note: scope types are already covered by ctx.prog.types check above
      discard

  # Check if accessing ref parameter after yield (unsafe - value could have been modified)
  if ctx.hasYielded and e.objectExpression.kind == ekVar:
    let varName = e.objectExpression.vname
    if varName in ctx.refParams:
      raise newProveError(e.pos, &"accessing ref parameter '{varName}' after yield is unsafe - the caller may have modified it while the coroutine was suspended")

  # Analyze the object being accessed for safety (normal field access)
  discard analyzeExpression(e.objectExpression, env, ctx)

  # Check if accessing field on a potentially nil reference
  if e.objectExpression.kind == ekVar and env.nils.hasKey(e.objectExpression.vname) and env.nils[e.objectExpression.vname]:
    raise newProveError(e.pos, &"potential null dereference: field access on variable '{e.objectExpression.vname}' that may be nil")
  elif e.objectExpression.kind == ekDeref:
    # Check dereferencing of potentially nil reference
    if e.objectExpression.refExpression.kind == ekVar and env.nils.hasKey(e.objectExpression.refExpression.vname) and env.nils[e.objectExpression.refExpression.vname]:
      raise newProveError(e.pos, &"potential null dereference: dereferencing variable '{e.objectExpression.refExpression.vname}' that may be nil")

  # Field access result is unknown for now but considered initialized
  return Info(known: false, cval: makeScalar(0'i64), initialized: true)

