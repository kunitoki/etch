proc compileObjectLiteralExpression(c: var Compiler, e: Expression): uint8 =
  # Handle object literal creation
  logCompiler(c.verbose, &"Compiling ekObjectLiteral expression with {e.fieldInits.len} fields")
  result = c.allocator.allocReg()

  # Create a new table
  c.prog.emitABC(opNewTable, result, 0, 0, c.makeDebugInfo(e.pos))

  # Collect provided field names
  var providedFields: seq[string] = @[]
  for fieldInit in e.fieldInits:
    providedFields.add(fieldInit.name)

  # Set each provided field
  for fieldInit in e.fieldInits:
    let fieldName = fieldInit.name
    let fieldExpression = fieldInit.value
    # Compile the field value
    let valueReg = c.compileExpression(fieldExpression)

    # Add field name to constants if not already there
    let fieldConstIdx = c.addStringConst(fieldName)

    # If storing a ref value, increment its reference count
    if fieldExpression.typ != nil and fieldExpression.typ.kind == tkRef:
      c.prog.emitABC(opIncRef, valueReg, 0, 0)
      logCompiler(c.verbose, &"  Emitted opIncRef for ref value in reg {valueReg} before storing in field")

    # Emit opSetField: R[tableReg][K[fieldConstIdx]] = R[valueReg]
    c.prog.emitABC(opSetField, valueReg, result, uint8(fieldConstIdx))

    # Free the value register
    c.allocator.freeReg(valueReg)

    logCompiler(c.verbose, &"Set field '{fieldName}' (const[{fieldConstIdx}]) = reg {valueReg}")

  # Add default values for missing fields
  if e.objectType != nil and e.objectType.kind == tkObject:
    for field in e.objectType.fields:
      if field.name notin providedFields and field.defaultValue.isSome:
        logCompiler(c.verbose, &"Adding default value for field '{field.name}'")

        # Compile the default value expression
        let defaultExpression = field.defaultValue.get
        let valueReg = c.compileExpression(defaultExpression)

        # Add field name to constants
        let fieldConstIdx = c.addStringConst(field.name)

        # If storing a ref value, increment its reference count
        if defaultExpression.typ != nil and defaultExpression.typ.kind == tkRef:
          c.prog.emitABC(opIncRef, valueReg, 0, 0)
          logCompiler(c.verbose, &"  Emitted opIncRef for ref default value in reg {valueReg}")

        # Set the default value
        c.prog.emitABC(opSetField, valueReg, result, uint8(fieldConstIdx))

        # Free the value register
        c.allocator.freeReg(valueReg)

        logCompiler(c.verbose, &"Set default field '{field.name}' (const[{fieldConstIdx}]) = reg {valueReg}")


proc compileFieldAccessExpression(c: var Compiler, e: Expression): uint8 =
  # Handle field access on objects or enum member lookups
  logCompiler(c.verbose, &"Compiling ekFieldAccess expression: field '{e.fieldName}'")

  if e.enumTargetType != nil and e.enumResolvedMember.isSome:
    let debug = c.makeDebugInfo(e.pos)
    return loadEnumConstant(c, e.enumTargetType, e.enumResolvedMember.get(), debug)

  # Compile the object expression
  let objReg = c.compileExpression(e.objectExpression)
  result = c.allocator.allocReg()

  # Add field name to constants if not already there
  let fieldConstIdx = c.addStringConst(e.fieldName)

  # Emit opGetField: R[result] = R[objReg][K[fieldConstIdx]]
  c.prog.emitABC(opGetField, result, objReg, uint8(fieldConstIdx), c.makeDebugInfo(e.pos))

  # Free the object register
  c.allocator.freeReg(objReg)

  logCompiler(c.verbose, &"Get field '{e.fieldName}' (const[{fieldConstIdx}]) from reg {objReg} to reg {result}")
