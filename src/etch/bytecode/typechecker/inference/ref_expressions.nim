proc inferNewExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # new(Type) or new(Type, initExpression) or new(value) with type inference - returns ref[Type]
  let targetType = e.newType
  var resolvedType: EtchType

  if targetType == nil:
    # Type inference from initialization expression: new(42) -> ref[int]
    if e.initExpression.isNone:
      raise newTypecheckError(e.pos, "new() requires either a type or initialization value for type inference")
    let initType = inferExpressionTypes(prog, fd, sc, e.initExpression.get, subst)
    resolvedType = initType
  else:
    # Explicit type provided: new[int] or new[int]{42}
    resolvedType = targetType
  # Resolve user-defined types
  if resolvedType.kind == tkUserDefined:
    let userType = resolveUserType(sc, resolvedType.name)
    if userType == nil:
      raise newTypecheckError(e.pos, &"unknown type '{resolvedType.name}'")
    resolvedType = userType

  # If there's an initialization expression, type check it
  if e.initExpression.isSome:
    let initType = inferExpressionTypes(prog, fd, sc, e.initExpression.get, subst, resolvedType)
    if not canAssignDistinct(resolvedType, initType):
      raise newTypecheckError(e.pos, &"cannot initialize '{resolvedType}' with '{initType}'")

  let refType = tRef(resolvedType)
  e.typ = refType
  return refType


proc inferNewRefExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let t0 = inferExpressionTypes(prog, fd, sc, e.init, subst)
  e.refInner = t0
  e.typ = tRef(t0)
  return e.typ


proc inferDerefExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let t0 = inferExpressionTypes(prog, fd, sc, e.refExpression, subst)
  # Resolve type aliases (e.g., StringRef = ref[string]) before checking kind
  let resolvedType = resolveNestedUserTypes(sc, t0, e.pos)
  if resolvedType.kind != tkRef: raise newTypecheckError(e.pos, "deref expects ref[...]")
  # Resolve user-defined types in the dereferenced result
  var innerType = resolvedType.inner
  if innerType.kind == tkUserDefined:
    let resolvedInner = resolveUserType(sc, innerType.name)
    if resolvedInner == nil:
      raise newTypecheckError(e.pos, &"unknown type '{innerType.name}'")
    innerType = resolvedInner
  e.typ = innerType
  return innerType
