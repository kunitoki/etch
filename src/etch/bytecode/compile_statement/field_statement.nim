proc isSameFieldAccess(target, candidate: Expression): bool =
  if target.kind != ekFieldAccess or candidate.kind != ekFieldAccess:
    return false
  if target.fieldName != candidate.fieldName:
    return false
  if target.objectExpression.kind != ekVar or candidate.objectExpression.kind != ekVar:
    return false
  target.objectExpression.vname == candidate.objectExpression.vname

proc isSimpleIndexExpression(expr: Expression): bool =
  expr.kind == ekVar or expr.kind == ekInt

proc sameIndexExpression(a, b: Expression): bool =
  if not (isSimpleIndexExpression(a) and isSimpleIndexExpression(b)):
    return false
  case a.kind
  of ekVar:
    b.kind == ekVar and a.vname == b.vname
  of ekInt:
    b.kind == ekInt and a.ival == b.ival
  else:
    false

proc isSameArrayAccess(target, candidate: Expression): bool =
  if target.kind != ekIndex or candidate.kind != ekIndex:
    return false
  if target.arrayExpression.kind != ekVar or candidate.arrayExpression.kind != ekVar:
    return false
  if target.arrayExpression.vname != candidate.arrayExpression.vname:
    return false
  sameIndexExpression(target.indexExpression, candidate.indexExpression)

type FieldArithmeticOpcode = object
  binOp: BinOp
  opcode: OpCode

const fieldArithmeticOps = [
  FieldArithmeticOpcode(binOp: boAdd, opcode: opLoadAddStore),
  FieldArithmeticOpcode(binOp: boSub, opcode: opLoadSubStore),
  FieldArithmeticOpcode(binOp: boMul, opcode: opLoadMulStore),
  FieldArithmeticOpcode(binOp: boDiv, opcode: opLoadDivStore),
  FieldArithmeticOpcode(binOp: boMod, opcode: opLoadModStore),
]

proc tryFuseArrayArithmeticAssignment(c: var Compiler,
                                      s: Statement,
                                      arrayReg, indexReg: uint8,
                                      targetType: EtchType,
                                      debug: DebugInfo): bool =
  ## Try to fuse patterns like arr[idx] op= expr for numeric array elements.
  if s.faTarget.arrayExpression.kind != ekVar:
    return false
  if not isSimpleIndexExpression(s.faTarget.indexExpression):
    return false
  if targetType == nil or targetType.kind notin {tkInt, tkFloat}:
    return false

  let valueExpression = s.faValue
  if valueExpression.kind != ekBin:
    return false

  template matchesTarget(expr: Expression): bool =
    isSameArrayAccess(s.faTarget, expr)

  var opcode: OpCode
  var rhsExpression: Expression
  let lhsMatches = matchesTarget(valueExpression.lhs)
  let rhsMatches = matchesTarget(valueExpression.rhs)

  case valueExpression.bop
  of boAdd:
    if lhsMatches xor rhsMatches:
      rhsExpression = if lhsMatches: valueExpression.rhs else: valueExpression.lhs
      opcode = opGetAddSet
    else:
      return false
  of boMul:
    if lhsMatches xor rhsMatches:
      rhsExpression = if lhsMatches: valueExpression.rhs else: valueExpression.lhs
      opcode = opGetMulSet
    else:
      return false
  of boSub:
    if not lhsMatches or rhsMatches:
      return false
    rhsExpression = valueExpression.rhs
    opcode = opGetSubSet
  of boDiv:
    if not lhsMatches or rhsMatches:
      return false
    rhsExpression = valueExpression.rhs
    opcode = opGetDivSet
  of boMod:
    if not lhsMatches or rhsMatches:
      return false
    rhsExpression = valueExpression.rhs
    opcode = opGetModSet
  else:
    return false

  let rhsReg = c.compileExpression(rhsExpression)
  c.prog.emitABC(opcode, arrayReg, indexReg, rhsReg, debug)
  logCompiler(c.verbose, &"  [Fusion] Emitted {opcode} for array '{s.faTarget.arrayExpression.vname}' with idx reg {indexReg} and rhs reg {rhsReg}")
  c.allocator.freeReg(rhsReg)
  true

proc tryFuseFieldArithmeticAssignment(c: var Compiler,
                                      s: Statement,
                                      objReg: uint8,
                                      fieldConst: int,
                                      targetType: EtchType,
                                      debug: DebugInfo): bool =
  ## Try to fuse patterns like obj.field = obj.field (+,-,*,/) expr.
  if targetType == nil or targetType.kind notin {tkInt, tkFloat}:
    return false

  let valueExpression = s.faValue
  if valueExpression.kind != ekBin:
    return false

  var opcode: OpCode
  var rhsExpression: Expression

  for entry in fieldArithmeticOps:
    if valueExpression.bop == entry.binOp:
      opcode = entry.opcode
      break
  if opcode == OpCode(0):
    return false

  let lhsMatches = isSameFieldAccess(s.faTarget, valueExpression.lhs)
  let rhsMatches = isSameFieldAccess(s.faTarget, valueExpression.rhs)

  case valueExpression.bop
  of boAdd, boMul:
    if lhsMatches:
      rhsExpression = valueExpression.rhs
    elif rhsMatches:
      rhsExpression = valueExpression.lhs
    else:
      return false
  of boSub, boDiv:
    if not lhsMatches:
      return false
    rhsExpression = valueExpression.rhs
  else:
    return false

  let rhsReg = c.compileExpression(rhsExpression)
  c.prog.emitABC(opcode, objReg, rhsReg, uint8(fieldConst), debug)
  logCompiler(c.verbose, &"  [Fusion] Emitted {opcode} for field '{s.faTarget.fieldName}' with rhs reg {rhsReg}")

  if rhsReg != objReg:
    c.allocator.freeReg(rhsReg)

  true

proc compileFieldIndexAssignStatement(c: var Compiler, s: Statement) =
  # Field or array index assignment
  logCompiler(c.verbose, "Field/index assignment")

  case s.faTarget.kind:
  of ekFieldAccess:
    # Field assignment for objects
    # The object should be a simple variable for now
    if s.faTarget.objectExpression.kind != ekVar:
      raise newCompileError(s.pos, "field assignment object is not a variable")

    # Get the object register
    let objName = s.faTarget.objectExpression.vname
    if not c.allocator.regMap.hasKey(objName):
      raise newCompileError(s.pos, &"variable '{objName}' not found in register map")

    let objReg = c.allocator.regMap[objName]
    let targetType = s.faTarget.typ

    # Determine type/ref characteristics upfront
    let targetIsWeak = targetType != nil and targetType.kind == tkWeak
    let valueIsRef = s.faValue.typ != nil and s.faValue.typ.kind == tkRef
    let fieldConst = c.addStringConst(s.faTarget.fieldName)

    logCompiler(c.verbose, &"Field assignment target type: " &
      (if targetType != nil: $targetType.kind else: "nil"))

    # Attempt fused Load+Add+Store when dealing with numeric fields
    if not targetIsWeak and not valueIsRef:
      let debug = c.makeDebugInfo(s.pos)
      if tryFuseFieldArithmeticAssignment(c, s, objReg, int(fieldConst), targetType, debug):
        logCompiler(c.verbose, &"Fused field arithmetic for '{s.faTarget.fieldName}'")
        return

    # Compile the value to assign
    let valReg = c.compileExpression(s.faValue)
    let valueTransfers = transfersOwnership(s.faValue)

    # Check if target field is weak[T] and value is ref[T]
    var finalValReg = valReg

    if targetIsWeak and valueIsRef:
      # Need to wrap the ref in a weak wrapper
      let weakReg = c.allocator.allocReg()
      c.prog.emitABC(opNewWeak, weakReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"  Wrapping ref in reg {valReg} with weak wrapper in reg {weakReg}")
      finalValReg = weakReg

    # Get or add the field name to const pool
    # Emit opSetField to set object field: R[objReg][K[fieldConst]] = R[finalValReg]
    c.prog.emitABC(opSetField, finalValReg, objReg, uint8(fieldConst), c.makeDebugInfo(s.pos))

    logCompiler(c.verbose, &"Set field '{s.faTarget.fieldName}' (const[{fieldConst}]) in object at reg {objReg} to value at reg {finalValReg}")

    if valueTransfers and valueIsRef:
      c.prog.emitABC(opDecRef, valReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"  Released temporary ref in reg {valReg} after storing in field")

    if finalValReg != valReg:
      c.allocator.freeReg(finalValReg)
    c.allocator.freeReg(valReg)

  of ekIndex:
    # Array index assignment: arr[idx] = value
    # Handle implicit dereference for ref[array[T]] (like C pointer semantics)
    # arr[i] = val where arr: ref[array[T]] works directly without needing @arr[i] = val
    var arrayReg: uint8

    # Case 1: Explicit deref: @ref[i] = val where ref: ref[array[T]]
    if s.faTarget.arrayExpression.kind == ekDeref:
      let refExpr = s.faTarget.arrayExpression.refExpression
      if refExpr.typ != nil and refExpr.typ.kind == tkRef and
         refExpr.typ.inner != nil and refExpr.typ.inner.kind == tkArray:
        # Skip deref, compile just the ref (opSetIndex handles ref[array])
        arrayReg = c.compileExpression(refExpr)
        logCompiler(c.verbose, &"  Index assignment on @ref[array]: using ref directly (explicit deref)")
      else:
        arrayReg = c.compileExpression(s.faTarget.arrayExpression)
    # Case 2: Implicit deref: ref[i] = val where ref: ref[array[T]]
    elif s.faTarget.arrayExpression.typ != nil and s.faTarget.arrayExpression.typ.kind == tkRef and
         s.faTarget.arrayExpression.typ.inner != nil and s.faTarget.arrayExpression.typ.inner.kind == tkArray:
      # Implicit dereference: compile the ref directly (opSetIndex handles ref[array])
      arrayReg = c.compileExpression(s.faTarget.arrayExpression)
      logCompiler(c.verbose, &"  Index assignment on ref[array]: using ref directly (implicit deref)")
    else:
      arrayReg = c.compileExpression(s.faTarget.arrayExpression)

    # Compile the index expression
    let indexReg = c.compileExpression(s.faTarget.indexExpression)

    let arrayDebug = c.makeDebugInfo(s.pos)
    let targetType = s.faTarget.typ

    if tryFuseArrayArithmeticAssignment(c, s, arrayReg, indexReg, targetType, arrayDebug):
      c.allocator.freeReg(indexReg)
      c.allocator.freeReg(arrayReg)
      return

    # Compile the value to assign
    let valueReg = c.compileExpression(s.faValue)
    let valueTransfers = transfersOwnership(s.faValue)

    let valueIsRef = s.faValue.typ != nil and s.faValue.typ.kind == tkRef

    # Determine element type for type-specialized instruction
    var elemType: TypeKind = tkVoid
    if s.faTarget.arrayExpression.typ != nil and s.faTarget.arrayExpression.typ.kind == tkArray and s.faTarget.arrayExpression.typ.inner != nil:
      elemType = s.faTarget.arrayExpression.typ.inner.kind

    # Emit SETINDEX instruction: R[arrayReg][R[indexReg]] = R[valueReg]
    # Use type-specialized instruction when element type is known
    if elemType == tkInt:
      c.prog.emitABC(opSetIndexInt, arrayReg, indexReg, valueReg, arrayDebug)
    elif elemType == tkFloat:
      c.prog.emitABC(opSetIndexFloat, arrayReg, indexReg, valueReg, arrayDebug)
    else:
      c.prog.emitABC(opSetIndex, arrayReg, indexReg, valueReg, arrayDebug)

    if valueTransfers and valueIsRef:
      c.prog.emitABC(opDecRef, valueReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"  Released temporary ref in reg {valueReg} after storing in array")

    # Free temporary registers
    c.allocator.freeReg(valueReg)
    c.allocator.freeReg(indexReg)
    c.allocator.freeReg(arrayReg)

  of ekDeref:
    # Assignment through dereference: @refVar = value
    let refDebug = c.makeDebugInfo(s.pos)
    let refExpr = s.faTarget.refExpression
    let refReg = c.compileExpression(refExpr)
    let valueReg = c.compileExpression(s.faValue)
    let valueTransfers = transfersOwnership(s.faValue)
    let valueIsRef = s.faValue.typ != nil and s.faValue.typ.kind == tkRef

    # Emit opSetRef: R[A] (ref) receives new value from R[B]
    c.prog.emitABC(opSetRef, refReg, valueReg, 0, refDebug)
    logCompiler(c.verbose, &"Set deref target via opSetRef using ref reg {refReg} and value reg {valueReg}")

    if valueTransfers and valueIsRef:
      c.prog.emitABC(opDecRef, valueReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"  Released temporary ref in reg {valueReg} after assigning through deref")

    if not isTrackedVar(c, refExpr, refReg):
      c.allocator.freeReg(refReg)
    c.allocator.freeReg(valueReg)

  else:
    raise newCompileError(s.pos, "field assignment target must be field access, array index, or deref")
