proc inferComptimeExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  ## Type check comptime expression
  let innerType = inferExpressionTypes(prog, fd, sc, e.comptimeExpression, subst, expectedTy)
  e.comptimeExpression.typ = innerType
  e.typ = innerType
  return innerType


proc inferCompilesExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  ## Type check compiles expression
  # compiles{...} always returns a boolean indicating if the block compiles
  # Capture the current scope's type environment so outer variables are accessible
  e.compilesEnv = sc.types
  # The actual compilation check happens during constant folding
  e.typ = tBool()
  return tBool()
