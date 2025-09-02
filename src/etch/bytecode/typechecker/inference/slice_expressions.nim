proc inferSliceExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let arrayType = inferExpressionTypes(prog, fd, sc, e.sliceExpression, subst)
  if arrayType.kind notin {tkArray, tkString, tkTuple}:
    raise newTypecheckError(e.pos, &"slicing requires array, string, or tuple type, got {arrayType}")

  # Handle tuple slicing with compile-time constant check
  if arrayType.kind == tkTuple:
    # If start is specified, it must be a compile-time constant
    let startIdx = if e.startExpression.isSome:
      if e.startExpression.get.kind != ekInt:
        raise newTypecheckError(e.startExpression.get.pos, "tuple slice start must be a compile-time constant integer")
      let idx = e.startExpression.get.ival
      if idx < 0 or idx >= arrayType.tupleTypes.len:
        raise newTypecheckError(e.startExpression.get.pos, &"tuple slice start {idx} out of bounds (tuple has {arrayType.tupleTypes.len} elements)")
      idx
    else:
      0  # Default to 0 if not specified

    # If end is specified, it must be a compile-time constant
    let endIdx = if e.endExpression.isSome:
      if e.endExpression.get.kind != ekInt:
        raise newTypecheckError(e.endExpression.get.pos, "tuple slice end must be a compile-time constant integer")
      let idx = e.endExpression.get.ival
      if idx < 0 or idx > arrayType.tupleTypes.len:
        raise newTypecheckError(e.endExpression.get.pos, &"tuple slice end {idx} out of bounds (tuple has {arrayType.tupleTypes.len} elements)")
      idx
    else:
      arrayType.tupleTypes.len  # Default to tuple length if not specified

    # Validate slice bounds
    if startIdx > endIdx:
      raise newTypecheckError(e.pos, &"tuple slice start {startIdx} must be <= end {endIdx}")

    # Create new tuple type with sliced elements
    var slicedTypes: seq[EtchType] = @[]
    for i in startIdx..<endIdx:
      slicedTypes.add(arrayType.tupleTypes[i])

    e.typ = tTuple(slicedTypes)
    return e.typ

  # Check start expression if present (for arrays/strings)
  if e.startExpression.isSome:
    let startType = inferExpressionTypes(prog, fd, sc, e.startExpression.get, subst)
    if startType.kind != tkInt:
      raise newTypecheckError(e.startExpression.get.pos, &"slice start must be int, got {startType}")
  # Check end expression if present (for arrays/strings)
  if e.endExpression.isSome:
    let endType = inferExpressionTypes(prog, fd, sc, e.endExpression.get, subst)
    if endType.kind != tkInt:
      raise newTypecheckError(e.endExpression.get.pos, &"slice end must be int, got {endType}")
  # Slicing returns the same array type
  e.typ = arrayType
  return e.typ
