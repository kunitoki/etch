proc inferTupleExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  # Tuple literal: tuple(elem1, elem2, ...) - infer type of each element independently

  # Try to get expected element types from expected tuple type
  var expectedElemTypes: seq[EtchType] = @[]
  if expectedTy != nil and expectedTy.kind == tkTuple:
    expectedElemTypes = expectedTy.tupleTypes
    # Resolve user-defined types
    for i, elemType in expectedElemTypes:
      if elemType != nil and elemType.kind == tkUserDefined:
        expectedElemTypes[i] = resolveUserType(sc, elemType.name)
        if expectedElemTypes[i] == nil:
          raise newTypecheckError(e.pos, &"unknown type in tuple")

  # Handle empty tuples
  if e.tupleElements.len == 0:
    e.typ = tTuple(@[])
    return e.typ

  # Check expected type arity if provided
  if expectedElemTypes.len > 0 and expectedElemTypes.len != e.tupleElements.len:
    raise newTypecheckError(e.pos, &"tuple arity mismatch: expected {expectedElemTypes.len} elements, got {e.tupleElements.len}")

  # Infer type of each element
  var elemTypes: seq[EtchType] = @[]
  for i, elem in e.tupleElements:
    let expectedElem = if i < expectedElemTypes.len: expectedElemTypes[i] else: nil
    let elemType = inferExpressionTypes(prog, fd, sc, elem, subst, expectedElem)
    elemTypes.add(elemType)

  e.typ = tTuple(elemTypes)
  return e.typ
