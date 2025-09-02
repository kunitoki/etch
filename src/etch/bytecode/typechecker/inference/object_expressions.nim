proc inferObjectLiteralExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType): EtchType =
  # Object literal: try to infer type from expected type, or from the object's own type if set during parsing
  var objType: EtchType = nil

  # If the object literal has a type set during parsing (e.g., Container(...)), use it
  if expectedTy == nil and e.objectType != nil:
    # Resolve the type if it's a user-defined type
    objType = resolveNestedUserTypes(sc, e.objectType, e.pos)
  elif expectedTy == nil:
    raise newTypecheckError(e.pos, "object literal requires explicit type annotation (no expected type)")
  elif expectedTy != nil:
    # Continue with expected type logic below
    discard

  # Handle union types - find the object type in the union (only if we don't already have objType)
  if objType == nil and expectedTy != nil:
    if expectedTy.kind == tkUnion:
      # Look for an object type in the union
      for unionType in expectedTy.unionTypes:
        if unionType.kind == tkObject:
          objType = unionType
          break
        elif unionType.kind == tkUserDefined:
          # Resolve user-defined type to check if it's an object
          let resolvedType = resolveUserType(sc, unionType.name)
          if resolvedType != nil and resolvedType.kind == tkObject:
            objType = resolvedType
            break
      if objType == nil:
        raise newTypecheckError(e.pos, "union type does not contain an object type for object literal")
    elif expectedTy.kind == tkObject:
      objType = expectedTy
    else:
      raise newTypecheckError(e.pos, &"object literal requires explicit type annotation (expected type is {expectedTy.kind}, not object)")

  # Verify all required fields are provided and types match
  var providedFields: seq[string] = @[]
  for fieldInit in e.fieldInits:
    providedFields.add(fieldInit.name)

    # Find field in object type
    var fieldType: EtchType = nil
    for objField in objType.fields:
      if objField.name == fieldInit.name:
        fieldType = objField.fieldType
        break

    if fieldType == nil:
      raise newTypecheckError(e.pos, &"object type '{objType.name}' has no field '{fieldInit.name}'")

    # Resolve nested user types in the field type (e.g., array[Person] -> array[<resolved Person>])
    fieldType = resolveNestedUserTypes(sc, fieldType, e.pos)

    # Type check the field value
    let valueType = inferExpressionTypes(prog, fd, sc, fieldInit.value, subst, fieldType)
    if not canAssignDistinct(fieldType, valueType):
      raise newTypecheckError(e.pos, &"field '{fieldInit.name}' expects type '{fieldType}', got '{valueType}'")

  # Check that all required fields are provided (those without defaults)
  for objField in objType.fields:
    if objField.defaultValue.isNone and objField.name notin providedFields:
      raise newTypecheckError(e.pos, &"missing required field '{objField.name}' in object literal")

  e.typ = objType
  e.objectType = objType
  return objType


proc inferFieldAccessExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Special handling for enum type member access: TypeName.MemberName
  if e.objectExpression.kind == ekVar:
    let typeName = e.objectExpression.vname
    var enumType: EtchType = nil

    if sc.userTypes.hasKey(typeName):
      enumType = sc.userTypes[typeName]
    elif prog.types.hasKey(typeName):
      enumType = prog.types[typeName]

    if enumType != nil and enumType.kind == tkEnum:
      let memberOpt = findEnumMember(enumType, e.fieldName)
      if memberOpt.isNone:
        raise newTypecheckError(e.pos, &"enum type '{typeName}' has no member '{e.fieldName}'")
      e.enumTargetType = enumType
      e.enumResolvedMember = memberOpt
      e.typ = enumType
      return enumType

  # General field access for variables and other expressions
  let objType = inferExpressionTypes(prog, fd, sc, e.objectExpression, subst)

  # Handle reference types - dereference automatically
  var actualObjType = objType
  if objType.kind == tkRef:
    actualObjType = objType.inner

  # Resolve user-defined types to get the actual object type
  if actualObjType.kind == tkUserDefined:
    actualObjType = resolveUserType(sc, actualObjType.name)
    if actualObjType == nil:
      raise newTypecheckError(e.pos, &"unknown type '{objType.name}'")

  if actualObjType.kind == tkObject:
    # Look up field in object type
    for field in actualObjType.fields:
      if field.name == e.fieldName:
        e.typ = field.fieldType
        return field.fieldType
    raise newTypecheckError(e.pos, &"object type '{actualObjType.name}' has no field '{e.fieldName}'")
  elif actualObjType.kind == tkEnum:
    raise newTypecheckError(e.pos, &"cannot access member '{e.fieldName}' on enum value of type '{actualObjType.name}'. Use enum type access like '{actualObjType.name}.{e.fieldName}' instead")
  else:
    raise newTypecheckError(e.pos, &"field access requires object or enum type, got '{objType}'")

