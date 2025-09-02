proc compileBinOpExpression(c: var Compiler, op: BinOp, dest, left, right: uint8,
                            debug: DebugInfo = DebugInfo(), leftTyp: EtchType = nil,
                            rightTyp: EtchType = nil, exprTyp: EtchType = nil) =
  # Use type-specialized instructions when the expression is statically typed
  let exprIsInt = exprTyp != nil and exprTyp.kind == tkInt
  let exprIsFloat = exprTyp != nil and exprTyp.kind == tkFloat
  let useIntOps = (exprIsInt or (leftTyp != nil and rightTyp != nil and leftTyp.kind == tkInt and rightTyp.kind == tkInt))
  let useFloatOps = (exprIsFloat or (leftTyp != nil and rightTyp != nil and leftTyp.kind == tkFloat and rightTyp.kind == tkFloat))

  if c.verbose:
    logCompiler(c.verbose, &"compileBinOp: op={op}, useIntOps={useIntOps}, useFloatOps={useFloatOps}, optimizeLevel={c.optimizeLevel}")
    if leftTyp != nil and rightTyp != nil:
      logCompiler(c.verbose, &"  leftTyp.kind={leftTyp.kind}, rightTyp.kind={rightTyp.kind}")

  case op:
  of boAdd:
    if useIntOps:
      c.prog.emitABC(opAddInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opAddFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opAdd, dest, left, right, debug)

  of boSub:
    if useIntOps:
      c.prog.emitABC(opSubInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opSubFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opSub, dest, left, right, debug)

  of boMul:
    if useIntOps:
      c.prog.emitABC(opMulInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opMulFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opMul, dest, left, right, debug)

  of boDiv:
    if useIntOps:
      c.prog.emitABC(opDivInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opDivFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opDiv, dest, left, right, debug)

  of boMod:
    if useIntOps:
      c.prog.emitABC(opModInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opModFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opMod, dest, left, right, debug)

  of boEq:
    if useIntOps:
      c.prog.emitABC(opEqStoreInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opEqStoreFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opEqStore, dest, left, right, debug)

  of boNe: c.prog.emitABC(opNeStore, dest, left, right, debug)

  of boLt:
    if useIntOps:
      c.prog.emitABC(opLtStoreInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opLtStoreFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opLtStore, dest, left, right, debug)

  of boLe:
    if useIntOps:
      c.prog.emitABC(opLeStoreInt, dest, left, right, debug)
    elif useFloatOps:
      c.prog.emitABC(opLeStoreFloat, dest, left, right, debug)
    else:
      c.prog.emitABC(opLeStore, dest, left, right, debug)

  of boGt:
    if useIntOps:
      c.prog.emitABC(opLtStoreInt, dest, right, left, debug)
    elif useFloatOps:
      c.prog.emitABC(opLtStoreFloat, dest, right, left, debug)
    else:
      c.prog.emitABC(opLtStore, dest, right, left, debug)

  of boGe:
    if useIntOps:
      c.prog.emitABC(opLeStoreInt, dest, right, left, debug)
    elif useFloatOps:
      c.prog.emitABC(opLeStoreFloat, dest, right, left, debug)
    else:
      c.prog.emitABC(opLeStore, dest, right, left, debug)

  of boAnd: c.prog.emitABC(opAnd, dest, left, right, debug)
  of boOr: c.prog.emitABC(opOr, dest, left, right, debug)
  of boIn: c.prog.emitABC(opIn, dest, left, right, debug)
  of boNotIn: c.prog.emitABC(opNotIn, dest, left, right, debug)


proc compileBinExpression(c: var Compiler, e: Expression): uint8 =
  let debug = c.makeDebugInfo(e.pos)

  let leftReg = c.compileExpression(e.lhs)
  result = c.allocator.allocReg()

  # Special case: tuple concatenation with +
  if e.bop == boAdd and e.lhs.typ != nil and e.rhs.typ != nil and
     e.lhs.typ.kind == tkTuple and e.rhs.typ.kind == tkTuple:
    logCompiler(c.verbose, "Compiling tuple concatenation")

    let rightReg = c.compileExpression(e.rhs)

    # Use efficient opConcatArray instruction instead of element-by-element copying
    c.prog.emitABC(opConcatArray, result, leftReg, rightReg, debug)

    logCompiler(c.verbose,
      &"Creating concatenated tuple with opConcatArray ({e.lhs.typ.tupleTypes.len} + {e.rhs.typ.tupleTypes.len} = {e.lhs.typ.tupleTypes.len + e.rhs.typ.tupleTypes.len} elements)")

    c.allocator.freeReg(rightReg)
    c.allocator.freeReg(leftReg)

    logCompiler(c.verbose, &"Tuple concatenation compiled to reg {result}")
    return result

  # Immediate opcodes are only safe when the left operand is statically typed as an int
  let lhsIsInt = e.lhs.typ != nil and e.lhs.typ.kind == tkInt
  var rhsCompiled = false

  if lhsIsInt and e.rhs.kind == ekInt and e.rhs.ival >= -128 and e.rhs.ival <= 127:
    let immValue = if e.rhs.ival < 0: 256 + e.rhs.ival else: e.rhs.ival
    let imm8 = uint8(immValue)
    let encoded = uint16(leftReg) or (uint16(imm8) shl 8)

    case e.bop:
    of boAdd: c.prog.emitABx(opAddI, result, encoded, debug)
    of boSub: c.prog.emitABx(opSubI, result, encoded, debug)
    of boMul: c.prog.emitABx(opMulI, result, encoded, debug)
    of boDiv: c.prog.emitABx(opDivI, result, encoded, debug)
    of boMod: c.prog.emitABx(opModI, result, encoded, debug)
    else: rhsCompiled = true

  elif e.lhs.typ != nil and e.lhs.typ.kind == tkBool and e.rhs.kind == ekBool:
    let encoded = uint16(leftReg) or (uint16(if e.rhs.bval: 1 else: 0) shl 8)
    case e.bop:
    of boAnd: c.prog.emitABx(opAndI, result, encoded, debug)
    of boOr: c.prog.emitABx(opOrI, result, encoded, debug)
    else: rhsCompiled = true
  else:
    rhsCompiled = true

  if rhsCompiled:
    let rightReg = c.compileExpression(e.rhs)
    logCompiler(c.verbose, &"Binary op: leftReg={leftReg} rightReg={rightReg} resultReg={result}")
    if c.verbose and e.lhs.typ != nil and e.rhs.typ != nil:
      logCompiler(c.verbose, &"  lhs.typ={e.lhs.typ.kind}, rhs.typ={e.rhs.typ.kind}")
    c.compileBinOpExpression(e.bop, result, leftReg, rightReg, debug, e.lhs.typ, e.rhs.typ, e.typ)
    if e.rhs.kind != ekVar:
      c.allocator.freeReg(rightReg)

  if e.lhs.kind != ekVar:
    c.allocator.freeReg(leftReg)


proc compileUnExpression(c: var Compiler, e: Expression): uint8 =
  let operandReg = c.compileExpression(e.ue)
  result = c.allocator.allocReg()

  let debug = c.makeDebugInfo(e.pos)
  case e.uop:
  of uoNeg: c.prog.emitABC(opUnm, result, operandReg, 0, debug)
  of uoNot: c.prog.emitABC(opNot, result, operandReg, 0, debug)

  # Free the operand register after use
  c.allocator.freeReg(operandReg)
