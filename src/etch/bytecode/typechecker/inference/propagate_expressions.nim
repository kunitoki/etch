proc inferResultPropagateExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check the postfix ? operator before lowering is implemented
  if fd.isNil:
    raise newTypecheckError(e.pos, "? operator requires a function context returning result[T]")

  fd.usesResultPropagation = true
  if fd.resultPropagationPos.isNone:
    fd.resultPropagationPos = some(e.pos)

  if fd.name == MAIN_FUNCTION_NAME:
    raise newTypecheckError(e.pos, &"? operator cannot be used inside {MAIN_FUNCTION_NAME}")

  let operandType = inferExpressionTypes(prog, fd, sc, e.propagateExpression, subst)
  if operandType.isNil or operandType.kind != tkResult:
    raise newTypecheckError(e.pos, "? operator requires expression of type result[T]")

  if operandType.inner.isNil:
    raise newTypecheckError(e.pos, "result operand for ? has no inner type")

  var inResultContext = false

  if fd.ret.isNil:
    inResultContext = true
    if fd.resultPropagationInner.isNil:
      fd.resultPropagationInner = operandType.inner
    elif not typeEq(fd.resultPropagationInner, operandType.inner):
      raise newTypecheckError(e.pos, &"? operator requires a consistent result type, expected {$fd.resultPropagationInner} but got {$operandType.inner}")
  elif fd.ret.kind == tkResult:
    inResultContext = true
    if not canAssignDistinct(fd.ret.inner, operandType.inner):
      raise newTypecheckError(e.pos, &"? operator result type mismatch: expected {$fd.ret.inner}, got {$operandType.inner}")
  elif fd.ret.kind == tkCoroutine:
    if fd.ret.inner.isNil:
      inResultContext = true
      if fd.resultPropagationInner.isNil:
        fd.resultPropagationInner = operandType.inner
      elif not typeEq(fd.resultPropagationInner, operandType.inner):
        raise newTypecheckError(e.pos, &"? operator requires a consistent result type, expected {$fd.resultPropagationInner} but got {$operandType.inner}")
    elif fd.ret.inner.kind == tkResult:
      inResultContext = true
      let coroutineInner = fd.ret.inner.inner
      if not coroutineInner.isNil and not canAssignDistinct(coroutineInner, operandType.inner):
        raise newTypecheckError(e.pos, &"? operator result type mismatch: expected {$coroutineInner}, got {$operandType.inner}")

  if not inResultContext:
    raise newTypecheckError(e.pos, "? operator can only be used inside functions returning result[T]")

  e.typ = operandType.inner
  return e.typ
