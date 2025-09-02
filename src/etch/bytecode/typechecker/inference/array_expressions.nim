proc inferArrayLenExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Array/String length operator: #array/#string -> int
  let arrayType = inferExpressionTypes(prog, fd, sc, e.lenExpression, subst)
  if arrayType.kind notin {tkArray, tkString}:
    raise newTypecheckError(e.pos, &"length operator # requires array or string type, got {arrayType}")
  e.typ = tInt()
  return e.typ


proc inferIndexExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let arrayType = inferExpressionTypes(prog, fd, sc, e.arrayExpression, subst)
  let indexType = inferExpressionTypes(prog, fd, sc, e.indexExpression, subst)

  # Allow implicit dereference for ref[array[T]] (C pointer semantics)
  let isRefArray = arrayType.kind == tkRef and arrayType.inner != nil and arrayType.inner.kind == tkArray

  if not isRefArray and arrayType.kind notin {tkArray, tkString, tkTuple}:
    raise newTypecheckError(e.pos, &"indexing requires array, string, tuple, or ref[array] type, got {arrayType}")

  if indexType.kind != tkInt:
    raise newTypecheckError(e.indexExpression.pos, &"index must be int, got {indexType}")

  # Handle tuple indexing with compile-time constant check
  if arrayType.kind == tkTuple:
    # Index must be a compile-time constant for tuples
    if e.indexExpression.kind != ekInt:
      raise newTypecheckError(e.indexExpression.pos, "tuple index must be a compile-time constant integer")

    let index = e.indexExpression.ival
    if index < 0 or index >= arrayType.tupleTypes.len:
      raise newTypecheckError(e.indexExpression.pos, &"tuple index {index} out of bounds (tuple has {arrayType.tupleTypes.len} elements)")

    e.typ = arrayType.tupleTypes[index]
    return e.typ

  if arrayType.kind == tkString:
    e.typ = tChar()
  elif isRefArray:
    # Indexing ref[array[T]] returns T (implicit dereference)
    e.typ = arrayType.inner.inner
  else:
    e.typ = arrayType.inner
  return e.typ


proc inferArrayExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  # Array literal: [elem1, elem2, ...] - infer element type from first element

  # Try to get expected element type from expected array type
  var expectedElemType: EtchType = nil
  if expectedTy != nil and expectedTy.kind == tkArray:
    expectedElemType = expectedTy.inner
    # Resolve user-defined types
    if expectedElemType != nil and expectedElemType.kind == tkUserDefined:
      expectedElemType = resolveUserType(sc, expectedElemType.name)
      if expectedElemType == nil:
        raise newTypecheckError(e.pos, &"unknown type in array")

  # Handle empty arrays
  if e.elements.len == 0:
    # Empty arrays are allowed if we have an explicit type annotation
    if expectedElemType != nil:
      e.typ = tArray(expectedElemType)
      return e.typ
    else:
      raise newTypecheckError(e.pos, "empty arrays not supported - cannot infer element type")

  # Infer type of first element with expected type if available
  let elemType = inferExpressionTypes(prog, fd, sc, e.elements[0], subst, expectedElemType)

  # Verify all elements have compatible types
  for i in 1..<e.elements.len:
    let t = inferExpressionTypes(prog, fd, sc, e.elements[i], subst, expectedElemType)
    if not typeEq(elemType, t):
      raise newTypecheckError(e.elements[i].pos, &"array element type mismatch: expected {elemType}, got {t}")
  e.typ = tArray(elemType)
  return e.typ
