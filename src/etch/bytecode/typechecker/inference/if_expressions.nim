proc inferIfExpression*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Type check the condition
  let condType = inferExpressionTypes(prog, fd, sc, e.ifCond, subst)
  if condType.kind != tkBool:
    raise newTypecheckError(e.pos, &"if condition must be bool, got {condType}")

  # Helper to get type of a statement block (simplified version)
  # Type check then body
  let thenType = if e.ifThen.len == 0:
    tVoid()
  elif e.ifThen[^1].kind == skExpression:
    inferExpressionTypes(prog, fd, sc, e.ifThen[^1].sexpr, subst)
  else:
    tVoid()

  # Type check elif chain and verify types match
  var resultType = thenType
  for elifCase in e.ifElifChain:
    let elifCondType = inferExpressionTypes(prog, fd, sc, elifCase.cond, subst)
    if elifCondType.kind != tkBool:
      raise newTypecheckError(e.pos, &"elif condition must be bool, got {elifCondType}")

    let elifType = if elifCase.body.len == 0:
      tVoid()
    elif elifCase.body[^1].kind == skExpression:
      inferExpressionTypes(prog, fd, sc, elifCase.body[^1].sexpr, subst)
    else:
      typecheckStatementList(prog, fd, sc, elifCase.body, subst, blockResultUsed = true)

    if not typeEq(resultType, elifType):
      raise newTypecheckError(e.pos, &"if expression branches must return the same type: then returns {resultType}, elif returns {elifType}")

  # Type check else body and verify type matches
  let elseType = if e.ifElse.len == 0:
    tVoid()
  elif e.ifElse[^1].kind == skExpression:
    inferExpressionTypes(prog, fd, sc, e.ifElse[^1].sexpr, subst)
  else:
    typecheckStatementList(prog, fd, sc, e.ifElse, subst, blockResultUsed = true)

  if not typeEq(resultType, elseType):
    raise newTypecheckError(e.pos, &"if expression branches must return the same type: then returns {resultType}, else returns {elseType}")

  e.typ = resultType
  return resultType
