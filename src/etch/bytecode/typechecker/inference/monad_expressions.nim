proc inferResultOkExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let innerType = inferExpressionTypes(prog, fd, sc, e.okExpression, subst)
  e.typ = tResult(innerType)
  return e.typ


proc inferResultErrExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType): EtchType =
  # Try to use expected type if available
  if expectedTy != nil and expectedTy.kind == tkResult:
    let errTy = inferExpressionTypes(prog, fd, sc, e.errExpression, subst)
    if errTy.kind != tkString:
      raise newTypecheckError(e.pos, "error constructor requires string argument")
    return expectedTy
  else:
    # error requires explicit type annotation to determine result type
    raise newTypecheckError(e.pos, "error requires explicit type annotation")


proc inferOptionSomeExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let innerType = inferExpressionTypes(prog, fd, sc, e.someExpression, subst)
  e.typ = tOption(innerType)
  return e.typ


proc inferOptionNoneExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType): EtchType =
  # Try to use expected type if available
  if expectedTy != nil and expectedTy.kind == tkOption:
    e.typ = expectedTy
    return expectedTy
  else:
    # none requires explicit type annotation to determine option type
    raise newTypecheckError(e.pos, "none requires explicit type annotation")
