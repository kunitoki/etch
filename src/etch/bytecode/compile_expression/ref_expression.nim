proc compileNewRefExpression(c: var Compiler, e: Expression): uint8 =
  # Handle new(value) for creating references
  logCompiler(c.verbose, "Compiling new ref expression")
  # Allocate result register
  result = c.allocator.allocReg()

  # Create debug info for the entire new() expression (including argument preparation)
  let newDebug = c.makeDebugInfo(e.pos)

  # Queue argument via opArg/opArgImm
  let literalIdx = literalArgConstIndex(c, e.init)
  if literalIdx.isSome:
    let constIdx = literalIdx.get()
    c.prog.emitABx(opArgImm, 0, constIdx, newDebug)
    logCompiler(c.verbose, &"  Queued literal init arg as const {constIdx}")
  else:
    let initReg = c.compileExpression(e.init)
    c.prog.emitABC(opArg, initReg, 0, 0, newDebug)
    logCompiler(c.verbose, &"  Queued init arg from reg {initReg}")
    if not isTrackedVar(c, e.init, initReg):
      c.allocator.freeReg(initReg)

  # Call new using the appropriate opcode (builtin)
  c.emitCallInstruction(result, "new", 1, 1, newDebug)


proc compileDerefExpression(c: var Compiler, e: Expression): uint8 =
  # Handle deref(ref) for dereferencing
  logCompiler(c.verbose, "Compiling deref expression")
  # Allocate result register
  result = c.allocator.allocReg()

  # Create debug info for the entire deref() expression (including argument preparation)
  let derefDebug = c.makeDebugInfo(e.pos)

  # Queue argument via opArg/opArgImm (deref currently only takes refs, so no literal path)
  let refReg = c.compileExpression(e.refExpression)
  c.prog.emitABC(opArg, refReg, 0, 0, derefDebug)
  logCompiler(c.verbose, &"  Queued deref arg from reg {refReg}")
  if not isTrackedVar(c, e.refExpression, refReg):
    c.allocator.freeReg(refReg)

  # Dispatch via builtin opcode
  c.emitCallInstruction(result, "deref", 1, 1, derefDebug)


proc compileNewExpression(c: var Compiler, e: Expression): uint8 =
  # Handle new for heap allocation using reference counting
  logCompiler(c.verbose, "Compiling new expression with heap allocation")
  result = c.allocator.allocReg()

  # Determine if we're creating a scalar ref, array ref, or object ref
  let innerType = if e.typ != nil and e.typ.kind == tkRef: e.typ.inner else: nil

  # Validate that the inner type is allowed for heap allocation
  # Allowed: scalars, arrays, monads (option/result), user-defined objects
  if innerType != nil:
    let allowedKinds = {tkBool, tkChar, tkInt, tkFloat, tkString, tkEnum, tkRef, tkWeak,
                        tkArray, tkOption, tkResult, tkObject, tkUserDefined}
    if innerType.kind notin allowedKinds:
      let msg = &"Cannot allocate ref to type {innerType.kind} on heap - only scalars, arrays, monads (option/result), and objects are allowed"
      logCompiler(c.verbose, &"  ERROR: {msg}")
      raise newCompileError(e.pos, msg)

  let isScalarRef = innerType != nil and innerType.kind in {tkBool, tkChar, tkInt, tkFloat, tkString, tkEnum, tkRef, tkWeak}
  let isArrayRef = innerType != nil and innerType.kind == tkArray
  let isMonadRef = innerType != nil and innerType.kind in {tkOption, tkResult}

  # Validate that non-object types require an init expression
  if (isScalarRef or isArrayRef or isMonadRef) and e.initExpression.isNone:
    let msg = &"new[{innerType.kind}] requires an initialization value"
    logCompiler(c.verbose, &"  ERROR: {msg}")
    raise newCompileError(e.pos, msg)

  if isArrayRef and e.initExpression.isSome:
    # Array reference: new[array[T]]([...]) -> compile array and wrap in heap
    logCompiler(c.verbose, "  Creating array heap reference")
    let arrayReg = c.compileExpression(e.initExpression.get)

    # opNewRef with C=2 as a flag for array heap allocation
    c.prog.emitABC(opNewRef, result, arrayReg, 2, c.makeDebugInfo(e.pos))
    logCompiler(c.verbose, &"  Emitted opNewRef for array from reg {arrayReg} to {result}")

    # Release the source array after copying elements to heap array
    # This is critical: the heap array retains its own references to the elements,
    # but the source stack array also holds references. We must release the source
    # array to decrement those references, otherwise element destructors won't be called.
    c.prog.emitABC(opDecRef, arrayReg, 0, 0, c.makeDebugInfo(e.pos))
    logCompiler(c.verbose, &"  Released source array in reg {arrayReg} after heap allocation")

    c.allocator.freeReg(arrayReg)
  elif isMonadRef and e.initExpression.isSome:
    # Monad reference (option/result): treat like scalar
    logCompiler(c.verbose, "  Creating monad (option/result) heap reference")
    let valueReg = c.compileExpression(e.initExpression.get)

    # opNewRef with C=1 for monad values (same as scalar)
    c.prog.emitABC(opNewRef, result, valueReg, 1, c.makeDebugInfo(e.pos))
    logCompiler(c.verbose, &"  Emitted opNewRef for monad from reg {valueReg} to {result}")

    c.allocator.freeReg(valueReg)
  elif isScalarRef and e.initExpression.isSome:
    # Scalar reference: new(42) -> compile value and use opNewRef with value
    logCompiler(c.verbose, "  Creating scalar heap reference")
    let valueReg = c.compileExpression(e.initExpression.get)

    # opNewRef with B=valueReg, C=1 means "allocate scalar with this value"
    # C=1 is used as a flag to distinguish scalar allocation from table allocation
    c.prog.emitABC(opNewRef, result, valueReg, 1, c.makeDebugInfo(e.pos))
    logCompiler(c.verbose, &"  Emitted opNewRef for scalar from reg {valueReg} to {result}")

    c.allocator.freeReg(valueReg)
  else:
    # Object reference: new[T](...) -> allocate table and initialize fields
    # Look up destructor function index for this type
    # Note: We encode as funcIdx+1, so 0 means "no destructor", 1 means funcIdx=0, etc.
    var destructorFuncIdx = 0'u8  # Default: no destructor (0 = none)
    if innerType != nil and innerType.destructor.isSome:
      let destructorName = innerType.destructor.get
      # Use addFunctionIndex to add destructor to functionTable if not already there
      let funcIdx = c.addFunctionIndex(destructorName)
      destructorFuncIdx = uint8(funcIdx + 1)  # Encode as index+1
      logCompiler(c.verbose, &"  Found destructor {destructorName} at function index {funcIdx}, encoded as {destructorFuncIdx}")

    # C=0 means table allocation, B=encoded destructor index (0 if none, funcIdx+1 otherwise)
    c.prog.emitABC(opNewRef, result, destructorFuncIdx, 0, c.makeDebugInfo(e.pos))
    logCompiler(c.verbose, &"  Emitted opNewRef for table at reg {result} with destructor encoded={destructorFuncIdx}")

    # If there's an init expression (object literal), initialize fields
    if e.initExpression.isSome:
      let initExpression = e.initExpression.get

      # The init expression should be an object literal
      if initExpression.kind == ekObjectLiteral:
        logCompiler(c.verbose, &"  Initializing {initExpression.fieldInits.len} fields for heap object")

        # Set each field on the heap object
        for fieldInit in initExpression.fieldInits:
          let fieldName = fieldInit.name
          let fieldExpression = fieldInit.value

          # Compile the field value
          let valueReg = c.compileExpression(fieldExpression)

          # Add field name to constants
          let fieldConstIdx = c.addStringConst(fieldName)

          # Set field: heap_object[fieldName] = value
          # opSetField: R[B][K[C]] = R[A]
          # So: B = result (heap ref), C = field name const, A = value reg
          c.prog.emitABC(opSetField, valueReg, result, fieldConstIdx.uint8, c.makeDebugInfo(fieldInit.value.pos))
          logCompiler(c.verbose, &"    Set field '{fieldName}' from reg {valueReg}")

          let valueTransfers = transfersOwnership(fieldExpression)
          if valueTransfers and fieldExpression.typ != nil and fieldExpression.typ.kind == tkRef:
            c.prog.emitABC(opDecRef, valueReg, 0, 0, c.makeDebugInfo(fieldInit.value.pos))
            logCompiler(c.verbose, &"    Released temporary ref in reg {valueReg} after storing in field")

          c.allocator.freeReg(valueReg)
      else:
        # Non-object-literal init
        logCompiler(c.verbose, "  WARNING: ekNew with non-object-literal init expression for object type")
    else:
      # No init expression - check if type has field defaults and initialize them
      logCompiler(c.verbose, "  No init expression provided")

      # Look up the type to see if it has fields with default values
      if innerType != nil and innerType.kind == tkObject and innerType.fields.len > 0:
        logCompiler(c.verbose, &"  Object type has {innerType.fields.len} fields, checking for defaults")

        for field in innerType.fields:
          if field.defaultValue.isSome:
            logCompiler(c.verbose, &"  Initializing field '{field.name}' with default value")

            # Compile the default value expression
            let defaultExpression = field.defaultValue.get
            let valueReg = c.compileExpression(defaultExpression)

            # Add field name to constants
            let fieldConstIdx = c.addStringConst(field.name)

            # Set field: heap_object[fieldName] = value
            c.prog.emitABC(opSetField, valueReg, result, fieldConstIdx.uint8, c.makeDebugInfo(defaultExpression.pos))
            logCompiler(c.verbose, &"    Set field '{field.name}' from reg {valueReg}")

            let valueTransfers = transfersOwnership(defaultExpression)
            if valueTransfers and field.fieldType.kind == tkRef:
              c.prog.emitABC(opDecRef, valueReg, 0, 0, c.makeDebugInfo(defaultExpression.pos))
              logCompiler(c.verbose, &"    Released temporary ref in reg {valueReg} after storing default")

            c.allocator.freeReg(valueReg)
      else:
        logCompiler(c.verbose, "  Created empty heap object")
