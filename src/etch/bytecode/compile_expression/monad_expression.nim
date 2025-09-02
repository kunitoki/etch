proc compileOptionSomeExpression(c: var Compiler, e: Expression): uint8 =
  # Handle some(value) for option types
  logCompiler(c.verbose, "Compiling ekOptionSome expression")
  # Compile the inner value first
  let innerReg = c.compileExpression(e.someExpression)
  result = c.allocator.allocReg()
  # Wrap it as some
  c.prog.emitABC(opWrapSome, result, innerReg, 0, c.makeDebugInfo(e.pos))
  if innerReg != result:
    c.allocator.freeReg(innerReg)


proc compileOptionNoneExpression(c: var Compiler, e: Expression): uint8 =
  # Handle none for option types
  logCompiler(c.verbose, "Compiling ekOptionNone expression")
  result = c.allocator.allocReg()
  # Create a none value
  c.prog.emitABC(opLoadNone, result, 0, 0, c.makeDebugInfo(e.pos))


proc compileResultOkExpression(c: var Compiler, e: Expression): uint8 =
  # Handle ok(value) for result types
  logCompiler(c.verbose, "Compiling ekResultOk expression")
  # Compile the inner value first
  let innerReg = c.compileExpression(e.okExpression)
  result = c.allocator.allocReg()
  # Wrap it as ok
  c.prog.emitABC(opWrapOk, result, innerReg, 0, c.makeDebugInfo(e.pos))
  if innerReg != result:
    c.allocator.freeReg(innerReg)


proc compileResultErrorExpression(c: var Compiler, e: Expression): uint8 =
  # Handle error(msg) for result types
  logCompiler(c.verbose, "Compiling ekResultErr expression")
  # Compile the error message first
  let innerReg = c.compileExpression(e.errExpression)
  result = c.allocator.allocReg()
  # Wrap it as error
  c.prog.emitABC(opWrapErr, result, innerReg, 0, c.makeDebugInfo(e.pos))
  if innerReg != result:
    c.allocator.freeReg(innerReg)


proc compileResultPropagateExpression(c: var Compiler, e: Expression): uint8 =
  ## Lower postfix ? operator over result[T]
  let resultReg = c.compileExpression(e.propagateExpression)
  let debug = c.makeDebugInfo(e.pos)

  # Jump over error block when the value is ok
  c.prog.emitABC(opTestTag, resultReg, uint8(vkErr), 0, debug)
  let skipErrJmpPos = c.prog.instructions.len
  c.prog.emitAsBx(opJmp, 0, 0, debug)

  # Error path: release locals, then immediately return the error result
  c.emitDecRefsForScope(excludeReg = int(resultReg))
  c.prog.emitABC(opReturn, 1, resultReg, 0, debug)

  # Patch jump to land after the error-return sequence
  let okBlockPos = c.prog.instructions.len
  var skipInstr = c.prog.instructions[skipErrJmpPos]
  skipInstr.sbx = int16(okBlockPos - skipErrJmpPos - 1)
  c.prog.instructions[skipErrJmpPos] = skipInstr

  # Success path: unwrap the ok value in-place
  c.prog.emitABC(opUnwrapResult, resultReg, resultReg, 0, debug)
  return resultReg
