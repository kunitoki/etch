
proc compileCastExpression(c: var Compiler, e: Expression): uint8 =
  # Compile the expression to cast
  let exprReg = c.compileExpression(e.castExpression)
  result = c.allocator.allocReg()

  # Determine cast type code - map TypeKind to VKind ordinals
  let castTypeCode = case e.castType.kind:
    of tkBool: ord(vkBool)
    of tkChar: ord(vkChar)
    of tkInt: ord(vkInt)
    of tkFloat: ord(vkFloat)
    of tkString: ord(vkString)
    else: 0

  # Emit cast instruction (using opCast - we'll need to implement this)
  c.prog.emitABC(opCast, result, exprReg, uint8(castTypeCode), c.makeDebugInfo(e.pos))
  c.allocator.freeReg(exprReg)
