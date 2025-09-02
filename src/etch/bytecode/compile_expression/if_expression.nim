proc compileIfExpression(c: var Compiler, e: Expression): uint8 =
  # Handle if-expressions
  logCompiler(c.verbose, "Compiling ekIf expression")

  result = c.allocator.allocReg()
  var jumpToEndPositions: seq[int] = @[]

  # Compile condition
  let condReg = c.compileExpression(e.ifCond)
  let debug = c.makeDebugInfo(e.pos)

  # Test condition and jump if false
  c.prog.emitABC(opTest, condReg, 0, 0, debug)
  c.allocator.freeReg(condReg)

  let skipThenJmp = c.prog.instructions.len
  c.prog.emitAsBx(opJmp, 0, 0, debug)

  # Compile then branch - result goes to result register
  for i, stmt in e.ifThen:
    if i == e.ifThen.len - 1 and stmt.kind == skExpression:
      # Last statement is an expression - compile it to result register
      let thenReg = c.compileExpression(stmt.sexpr)
      if thenReg != result:
        c.prog.emitABC(opMove, result, thenReg, 0, debug)
        c.allocator.freeReg(thenReg)
    else:
      c.compileStatement(stmt)

  # Jump to end after then
  jumpToEndPositions.add(c.prog.instructions.len)
  c.prog.emitAsBx(opJmp, 0, 0)

  # Patch skip-then jump
  let afterThen = c.prog.instructions.len
  c.prog.instructions[skipThenJmp].sbx = int16(afterThen - skipThenJmp - 1)

  # Compile elif chain
  for elifCase in e.ifElifChain:
    let elifCondReg = c.compileExpression(elifCase.cond)
    c.prog.emitABC(opTest, elifCondReg, 0, 0, debug)
    c.allocator.freeReg(elifCondReg)

    let skipElifJmp = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0)

    for i, stmt in elifCase.body:
      if i == elifCase.body.len - 1 and stmt.kind == skExpression:
        let elifReg = c.compileExpression(stmt.sexpr)
        if elifReg != result:
          c.prog.emitABC(opMove, result, elifReg, 0)
          c.allocator.freeReg(elifReg)
      else:
        c.compileStatement(stmt)

    jumpToEndPositions.add(c.prog.instructions.len)
    c.prog.emitAsBx(opJmp, 0, 0)

    let afterElif = c.prog.instructions.len
    c.prog.instructions[skipElifJmp].sbx = int16(afterElif - skipElifJmp - 1)

  # Compile else branch
  for i, stmt in e.ifElse:
    if i == e.ifElse.len - 1 and stmt.kind == skExpression:
      let elseReg = c.compileExpression(stmt.sexpr)
      if elseReg != result:
        c.prog.emitABC(opMove, result, elseReg, 0)
        c.allocator.freeReg(elseReg)
    else:
      c.compileStatement(stmt)

  # Patch all jumps to end
  let endPos = c.prog.instructions.len
  for jmpPos in jumpToEndPositions:
    c.prog.instructions[jmpPos].sbx = int16(endPos - jmpPos - 1)
