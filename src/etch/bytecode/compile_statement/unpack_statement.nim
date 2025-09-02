
proc compileTupleUnpackStatement(c: var Compiler, s: Statement) =
  # Tuple unpacking: let [a, b, c] = tuple(1, 2, 3);
  logCompiler(c.verbose, &"Compiling tuple unpacking for variables: {s.tupNames.join(\", \")}")
  let currentPC = c.prog.instructions.len

  # Compile the tuple expression
  let tupleReg = c.compileExpression(s.tupInit)
  logCompiler(c.verbose, &"Tuple expression compiled to reg {tupleReg}")

  # Extract each element and assign to variables
  for i, varName in s.tupNames:
    # Create index constant
    let idxReg = c.allocator.allocReg()
    let constIdx = c.addConst(makeInt(int64(i)))
    c.prog.emitABx(opLoadK, idxReg, constIdx, c.makeDebugInfo(s.pos))

    # Extract element: resultReg = tupleReg[i]
    let elemReg = c.allocator.allocReg()
    c.prog.emitABC(opGetIndex, elemReg, tupleReg, idxReg, c.makeDebugInfo(s.pos))
    logCompiler(c.verbose, &"Extracted tuple element {i} to reg {elemReg}")

    # Free the index register
    c.allocator.freeReg(idxReg)

    # Assign to variable
    c.allocator.regMap[varName] = elemReg

    # Track ref/weak/coroutine types
    let varType = s.tupTypes[i]
    let needsTracking = varType != nil and (
      varType.kind == tkRef or
      varType.kind == tkWeak or
      varType.kind == tkCoroutine or
      varType.kind == tkFunction or
      (varType.kind == tkArray and needsArrayCleanup(varType))
    )
    if needsTracking:
      c.refVars[elemReg] = varType
      logCompiler(c.verbose, &"Tracked ref/weak/coroutine variable {varName} in reg {elemReg}")

    # Track variable lifetime
    c.lifetimeTracker.declareVariable(varName, elemReg, currentPC)
    c.lifetimeTracker.defineVariable(varName, currentPC)

    logCompiler(c.verbose, &"Variable {varName} allocated to reg {elemReg} from tuple element {i}")

  # Free the tuple register after extraction
  c.allocator.freeReg(tupleReg)


proc compileObjectUnpackStatement(c: var Compiler, s: Statement) =
  # Object unpacking: let {x, y} = obj or let {x: newX, y: newY} = obj
  var mappingsStr = ""
  for i, mapping in s.objFieldMappings:
    if i > 0: mappingsStr.add(", ")
    mappingsStr.add(mapping.fieldName & " -> " & mapping.varName)
  logCompiler(c.verbose, &"Compiling object unpacking for fields: {mappingsStr}")
  let currentPC = c.prog.instructions.len

  # Compile the object expression
  let objReg = c.compileExpression(s.objInit)
  logCompiler(c.verbose, &"Object expression compiled to reg {objReg}")

  # Extract each field and assign to variables
  for i, mapping in s.objFieldMappings:
    let fieldName = mapping.fieldName
    let varName = mapping.varName

    # Add field name to constants
    let fieldConstIdx = c.addStringConst(fieldName)

    # Extract field: elemReg = objReg.fieldName
    let elemReg = c.allocator.allocReg()
    c.prog.emitABC(opGetField, elemReg, objReg, uint8(fieldConstIdx), c.makeDebugInfo(s.pos))
    logCompiler(c.verbose, &"Extracted object field '{fieldName}' to reg {elemReg}")

    # Assign to variable
    c.allocator.regMap[varName] = elemReg

    # Track ref/weak/coroutine types
    let varType = s.objTypes[i]
    let needsTracking = varType != nil and (
      varType.kind == tkRef or
      varType.kind == tkWeak or
      varType.kind == tkCoroutine or
      varType.kind == tkFunction or
      (varType.kind == tkArray and needsArrayCleanup(varType))
    )
    if needsTracking:
      c.refVars[elemReg] = varType
      logCompiler(c.verbose, &"Tracked ref/weak/coroutine variable {varName} in reg {elemReg}")

    # Track variable lifetime
    c.lifetimeTracker.declareVariable(varName, elemReg, currentPC)
    c.lifetimeTracker.defineVariable(varName, currentPC)

    logCompiler(c.verbose, &"Variable {varName} allocated to reg {elemReg} from object field '{fieldName}'")

  # Free the object register after extraction
  c.allocator.freeReg(objReg)
