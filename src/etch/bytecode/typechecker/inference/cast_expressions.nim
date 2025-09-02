proc inferCastExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Explicit type cast: type(expr)
  let fromType = inferExpressionTypes(prog, fd, sc, e.castExpression, subst)
  let toType = e.castType

  # Define allowed conversions
  var castAllowed = false
  if fromType.kind == tkInt and toType.kind in {tkInt, tkFloat, tkString}:
    castAllowed = true
  elif fromType.kind == tkFloat and toType.kind in {tkInt, tkFloat, tkString}:
    castAllowed = true
  elif fromType.kind == tkChar and toType.kind in {tkString}:
    castAllowed = true
  elif fromType.kind == tkBool and toType.kind in {tkString}:
    castAllowed = true
  # Allow casting from enum to int/string
  elif fromType.kind == tkEnum and toType.kind in {tkInt, tkString}:
    castAllowed = true
  # Allow casting from enum to enum (same enum type)
  elif fromType.kind == tkEnum and toType.kind == tkEnum and typeEq(fromType, toType):
    castAllowed = true
  # Allow casting from distinct types to their base type
  elif fromType.kind == tkDistinct and typeEq(fromType.inner, toType):
    castAllowed = true
  # Allow casting from base type to distinct type
  elif toType.kind == tkDistinct and typeEq(fromType, toType.inner):
    castAllowed = true
  # Allow casting from typedesc to string or int
  elif fromType.kind == tkTypeDesc and toType.kind in {tkString, tkInt}:
    castAllowed = true

  if not castAllowed:
    raise newTypecheckError(e.pos, &"invalid cast from {fromType} to {toType}")

  e.typ = toType
  return e.typ
