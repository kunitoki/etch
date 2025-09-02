proc inferYieldExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check yield expression
  if fd.isNil:
    raise newTypecheckError(e.pos, "yield can only be used inside a function")

  if fd.ret.isNil or fd.ret.kind != tkCoroutine:
    raise newTypecheckError(e.pos, "yield can only be used in functions returning coroutine[T]")

  if e.yieldValue.isSome:
    let yieldedType = inferExpressionTypes(prog, fd, sc, e.yieldValue.get, subst)
    e.typ = yieldedType
    return yieldedType
  else:
    e.typ = tVoid()
    return tVoid()


proc inferResumeExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check resume expression
  let coroType = inferExpressionTypes(prog, fd, sc, e.resumeValue, subst)

  # Ensure it's a coroutine type
  if coroType.kind != tkCoroutine:
    raise newTypecheckError(e.pos, "resume requires a coroutine[T] value, got " & $coroType)

  if coroType.inner.isNil:
    raise newTypecheckError(e.pos, "coroutine type missing inner type for resume")

  # Resume now returns result[T], where T is the coroutine's inner type
  let resumeType = tResult(coroType.inner)
  e.typ = resumeType
  return resumeType


proc inferSpawnExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check spawn expression
  let spawnedType = inferExpressionTypes(prog, fd, sc, e.spawnExpression, subst)

  if spawnedType.kind == tkCoroutine:
    e.typ = spawnedType
    return spawnedType
  else:
    e.typ = tCoroutine(spawnedType)
    return e.typ


proc inferSpawnBlockExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check spawn block expression
  var blockType = tVoid()
  for stmt in e.spawnBody:
    if stmt.kind == skExpression:
      blockType = inferExpressionTypes(prog, fd, sc, stmt.sexpr, subst)

  e.typ = tCoroutine(blockType)
  return e.typ


proc inferChannelNewExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check channel creation expression
  e.typ = tChannel(e.channelType)
  return e.typ


proc inferChannelSendExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check channel send expression
  let chanType = inferExpressionTypes(prog, fd, sc, e.sendChannel, subst)
  if chanType.kind != tkChannel:
    raise newTypecheckError(e.pos, &"channel send requires channel type, got {chanType}")

  let valueType = inferExpressionTypes(prog, fd, sc, e.sendValue, subst)
  if not typeEq(valueType, chanType.inner):
    raise newTypecheckError(e.pos, &"channel send type mismatch: expected {chanType.inner}, got {valueType}")

  e.typ = tVoid()
  return tVoid()


proc inferChannelRecvExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check channel receive expression
  let chanType = inferExpressionTypes(prog, fd, sc, e.recvChannel, subst)
  if chanType.kind != tkChannel:
    raise newTypecheckError(e.pos, &"channel receive requires channel type, got {chanType}")

  e.typ = chanType.inner
  return chanType.inner
