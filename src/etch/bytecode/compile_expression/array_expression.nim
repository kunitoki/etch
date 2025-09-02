proc transfersOwnership(e: Expression): bool =
  ## Detect expressions that yield a freshly-owned heap value
  if e == nil:
    return false

  case e.kind
  of ekNew, ekNewRef, ekLambda, ekSpawn, ekSpawnBlock:
    return true
  of ekCall:
    if e.typ != nil and e.typ.kind in {tkRef, tkFunction, tkCoroutine}:
      return true
  else:
    discard

  false


proc compileArrayExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Array expression allocated reg {result}")
  let debug = c.makeDebugInfo(e.pos)
  c.prog.emitABx(opNewArray, result, uint16(e.elements.len), debug)

  # Determine element type for type-specialized instructions
  var elemType: TypeKind = tkVoid
  if e.typ != nil and e.typ.kind == tkArray and e.typ.inner != nil:
    elemType = e.typ.inner.kind

  # Set array elements
  for i, elem in e.elements:
    let elemReg = c.compileExpression(elem)
    let idxReg = c.allocator.allocReg()
    let constIdx = c.addConst(makeInt(int64(i)))
    c.prog.emitABx(opLoadK, idxReg, constIdx, debug)
    # Use type-specialized instruction when element type is known
    if elemType == tkInt:
      c.prog.emitABC(opSetIndexInt, result, idxReg, elemReg, debug)
    elif elemType == tkFloat:
      c.prog.emitABC(opSetIndexFloat, result, idxReg, elemReg, debug)
    else:
      c.prog.emitABC(opSetIndex, result, idxReg, elemReg, debug)
    c.allocator.freeReg(idxReg)

    let elemTransfers = transfersOwnership(elem)
    let elemFullType = elem.typ
    let elemNeedsRef = elemFullType != nil and (
      elemFullType.kind == tkRef or
      elemFullType.kind == tkWeak or
      elemFullType.kind == tkCoroutine or
      elemFullType.kind == tkFunction
    )

    if elemTransfers and elemNeedsRef:
      c.prog.emitABC(opDecRef, elemReg, 0, 0, debug)
      logCompiler(c.verbose, &"  Released temporary ref in reg {elemReg} after storing in array")

    c.allocator.freeReg(elemReg)


proc compileTupleExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Tuple expression allocated reg {result}")
  let debug = c.makeDebugInfo(e.pos)
  # Compile tuple as an array at bytecode level (tuples are heterogeneous arrays)
  c.prog.emitABx(opNewArray, result, uint16(e.tupleElements.len), debug)

  # Set tuple elements
  for i, elem in e.tupleElements:
    let elemReg = c.compileExpression(elem)
    let idxReg = c.allocator.allocReg()
    let constIdx = c.addConst(makeInt(int64(i)))
    c.prog.emitABx(opLoadK, idxReg, constIdx, debug)
    # Use type-specialized instruction when element type is known
    var elemType: TypeKind = tkVoid
    if e.typ != nil and e.typ.kind == tkTuple and i < e.typ.tupleTypes.len and e.typ.tupleTypes[i] != nil:
      elemType = e.typ.tupleTypes[i].kind
    if elemType == tkInt:
      c.prog.emitABC(opSetIndexInt, result, idxReg, elemReg, debug)
    elif elemType == tkFloat:
      c.prog.emitABC(opSetIndexFloat, result, idxReg, elemReg, debug)
    else:
      c.prog.emitABC(opSetIndex, result, idxReg, elemReg, debug)
    c.allocator.freeReg(idxReg)

    let elemTransfers = transfersOwnership(elem)
    let tupleElemType = if elem.typ != nil and elem.typ.kind == tkTuple and i < elem.typ.tupleTypes.len: elem.typ.tupleTypes[i] else: elem.typ
    let elemNeedsRef = tupleElemType != nil and (
      tupleElemType.kind == tkRef or
      tupleElemType.kind == tkWeak or
      tupleElemType.kind == tkCoroutine or
      tupleElemType.kind == tkFunction
    )

    if elemTransfers and elemNeedsRef:
      c.prog.emitABC(opDecRef, elemReg, 0, 0, debug)
      logCompiler(c.verbose, &"  Released temporary ref in reg {elemReg} after storing in tuple")

    c.allocator.freeReg(elemReg)


proc compileIndexExpression(c: var Compiler, e: Expression): uint8 =
  # Handle implicit dereference for ref[array[T]] (like C pointer semantics)
  # arr[i] where arr: ref[array[T]] works directly without needing @arr[i]
  var arrReg: uint8

  # Case 1: Explicit deref: @ref[i] where ref: ref[array[T]]
  if e.arrayExpression.kind == ekDeref:
    let refExpr = e.arrayExpression.refExpression
    if refExpr.typ != nil and refExpr.typ.kind == tkRef and
       refExpr.typ.inner != nil and refExpr.typ.inner.kind == tkArray:
      # Skip deref, compile just the ref (opGetIndex handles ref[array])
      arrReg = c.compileExpression(refExpr)
      logCompiler(c.verbose, &"  Index on @ref[array]: using ref directly (explicit deref)")
    else:
      arrReg = c.compileExpression(e.arrayExpression)
  # Case 2: Implicit deref: ref[i] where ref: ref[array[T]]
  elif e.arrayExpression.typ != nil and e.arrayExpression.typ.kind == tkRef and
       e.arrayExpression.typ.inner != nil and e.arrayExpression.typ.inner.kind == tkArray:
    # Implicit dereference: compile the ref directly (opGetIndex handles ref[array])
    arrReg = c.compileExpression(e.arrayExpression)
    logCompiler(c.verbose, &"  Index on ref[array]: using ref directly (implicit deref)")
  else:
    arrReg = c.compileExpression(e.arrayExpression)

  result = c.allocator.allocReg()

  let debug = c.makeDebugInfo(e.pos)

  # Determine element type for type-specialized instructions
  var elemType: TypeKind = tkVoid
  if e.arrayExpression.typ != nil:
    if e.arrayExpression.typ.kind == tkArray and e.arrayExpression.typ.inner != nil:
      elemType = e.arrayExpression.typ.inner.kind
    elif e.arrayExpression.typ.kind == tkTuple and e.indexExpression.kind == ekInt and
         e.indexExpression.ival >= 0 and e.indexExpression.ival < e.arrayExpression.typ.tupleTypes.len:
      elemType = e.arrayExpression.typ.tupleTypes[e.indexExpression.ival].kind

  # Optimize for constant integer indices
  if e.indexExpression.kind == ekInt and e.indexExpression.ival >= 0 and e.indexExpression.ival < 256:
    # Emit type-specialized immediate index instruction when element type is known
    if elemType == tkInt:
      c.prog.emitABx(opGetIndexIInt, result, uint16(arrReg) or (uint16(e.indexExpression.ival) shl 8), debug)
    elif elemType == tkFloat:
      c.prog.emitABx(opGetIndexIFloat, result, uint16(arrReg) or (uint16(e.indexExpression.ival) shl 8), debug)
    else:
      c.prog.emitABx(opGetIndexI, result, uint16(arrReg) or (uint16(e.indexExpression.ival) shl 8), debug)
  else:
    let idxReg = c.compileExpression(e.indexExpression)
    # Emit type-specialized index instruction when element type is known
    if elemType == tkInt:
      c.prog.emitABC(opGetIndexInt, result, arrReg, idxReg, debug)
    elif elemType == tkFloat:
      c.prog.emitABC(opGetIndexFloat, result, arrReg, idxReg, debug)
    else:
      c.prog.emitABC(opGetIndex, result, arrReg, idxReg, debug)
    c.allocator.freeReg(idxReg)

  # Free array register after use
  c.allocator.freeReg(arrReg)


proc compileSliceExpression(c: var Compiler, e: Expression): uint8 =
  # Handle array/string/tuple slicing: arr[start:end]
  logCompiler(c.verbose, "Compiling slice expression")

  let debug = c.makeDebugInfo(e.pos);

  # Check if this is a tuple slice (compile-time extraction)
  if e.typ != nil and e.typ.kind == tkTuple:
    # Tuple slicing: create a new tuple with only the sliced elements
    logCompiler(c.verbose, "Compiling tuple slice")

    let tupleReg = c.compileExpression(e.sliceExpression)

    # Get the tuple type from the sliceExpression to determine length
    let tupleType = e.sliceExpression.typ
    let tupleLen = tupleType.tupleTypes.len

    # Get start (default to 0 if not specified) and end (default to tuple length if not specified) indices
    let startIdx = if e.startExpression.isSome: e.startExpression.get.ival else: 0
    let endIdx = if e.endExpression.isSome: e.endExpression.get.ival else: tupleLen

    # Allocate result register for the new tuple
    result = c.allocator.allocReg()

    # Create a new array to hold the sliced tuple elements
    let numElements = uint16(endIdx - startIdx)
    c.prog.emitABx(opNewArray, result, numElements, debug)
    logCompiler(c.verbose, &"Creating tuple slice with {numElements} elements")

    # Extract and copy each element from the original tuple
    for i in 0..<int(numElements):
      let origIdx = startIdx + i

      # Create index constant for source
      let idxReg = c.allocator.allocReg()
      let constIdx = c.addConst(makeInt(int64(origIdx)))
      c.prog.emitABx(opLoadK, idxReg, constIdx, debug)

      # Extract element from source tuple
      let elemReg = c.allocator.allocReg()
      # TODO - emit opGetIndexInt, opGetIndexFloat for type-specialized tuple access
      c.prog.emitABC(opGetIndex, elemReg, tupleReg, idxReg, debug)

      # Create index constant for destination
      let destIdxReg = c.allocator.allocReg()
      let destConstIdx = c.addConst(makeInt(int64(i)))
      c.prog.emitABx(opLoadK, destIdxReg, destConstIdx, debug)

      # Set element in result tuple
      # TODO - emit opSetIndexInt, opSetIndexFloat for type-specialized tuple access
      c.prog.emitABC(opSetIndex, result, destIdxReg, elemReg, debug)

      # Free temporary registers
      c.allocator.freeReg(destIdxReg)
      c.allocator.freeReg(elemReg)
      c.allocator.freeReg(idxReg)

    c.allocator.freeReg(tupleReg)
    logCompiler(c.verbose, &"Tuple slice compiled to reg {result}")
    return result

  let arrReg = c.compileExpression(e.sliceExpression)

  # Handle optional start index
  let startReg = if e.startExpression.isSome():
    c.compileExpression(e.startExpression.get())
  else:
    # No start index specified, use 0
    let reg = c.allocator.allocReg()
    c.prog.emitAsBx(opLoadK, reg, 0, debug)
    reg

  # The opSlice instruction expects the end index in the register right after start
  # So we need to ensure proper register allocation
  let endReg = c.allocator.allocReg()

  # Compile the end expression into the allocated register
  if e.endExpression.isSome():
    let tempEndReg = c.compileExpression(e.endExpression.get())
    if tempEndReg != endReg:
      # Move to the expected position if necessary
      c.prog.emitABC(opMove, endReg, tempEndReg, 0, debug)
      c.allocator.freeReg(tempEndReg)
  else:
    # No end index specified, use -1 to indicate "until end"
    c.prog.emitAsBx(opLoadK, endReg, -1, debug)

  result = c.allocator.allocReg()
  # opSlice expects: R[A] = R[B][R[C]:R[C+1]]
  c.prog.emitABC(opSlice, result, arrReg, startReg, debug)

  # Clean up registers
  c.allocator.freeReg(endReg)
  c.allocator.freeReg(startReg)
  c.allocator.freeReg(arrReg)


proc compileArrayLenExpression(c: var Compiler, e: Expression): uint8 =
  # Handle array/string length: #arr
  let arrReg = c.compileExpression(e.lenExpression)
  result = c.allocator.allocReg()
  c.prog.emitABC(opLen, result, arrReg, 0, c.makeDebugInfo(e.pos))
  c.allocator.freeReg(arrReg)
