proc inferTypeofExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check typeof expression
  discard inferExpressionTypes(prog, fd, sc, e.typeofExpression, subst)
  e.typ = tTypeDesc()
  return e.typ