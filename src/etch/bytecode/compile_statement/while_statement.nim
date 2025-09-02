proc compileWhileStatement(c: var Compiler, s: Statement) =
  # Save current allocator state
  let savedNextReg = c.allocator.nextReg

  # Push loop info to stack for break/continue support
  c.loopStack.add(LoopInfo(
    startLabel: c.prog.instructions.len,
    continueLabel: 0,  # Will be set later
    breakJumps: @[]
  ))

  # Mark the loop start - this is where we jump back to
  let loopStart = c.prog.instructions.len

  # Compile the condition fresh each iteration
  # Special handling for comparison conditions
  if s.wcond.kind == ekBin and s.wcond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
    let leftReg = c.compileExpression(s.wcond.lhs)
    let rightReg = c.compileExpression(s.wcond.rhs)

    # Check types for specialization
    let leftTyp = s.wcond.lhs.typ
    let rightTyp = s.wcond.rhs.typ
    let useIntOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkInt and rightTyp.kind == tkInt
    let useFloatOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkFloat and rightTyp.kind == tkFloat

    # Emit comparison that jumps if condition is FALSE
    # Use s.pos (while statement) not s.wcond.pos (condition expression) for debugging
    let debugInfo = c.makeDebugInfo(s.pos)
    case s.wcond.bop:
    of boLt:
      if useIntOps: c.prog.emitABC(opLtInt, 0, leftReg, rightReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opLtFloat, 0, leftReg, rightReg, debugInfo)
      else: c.prog.emitABC(opLt, 0, leftReg, rightReg, debugInfo)
    of boLe:
      if useIntOps: c.prog.emitABC(opLeInt, 0, leftReg, rightReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opLeFloat, 0, leftReg, rightReg, debugInfo)
      else: c.prog.emitABC(opLe, 0, leftReg, rightReg, debugInfo)
    of boGt:
      if useIntOps: c.prog.emitABC(opLtInt, 0, rightReg, leftReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opLtFloat, 0, rightReg, leftReg, debugInfo)
      else: c.prog.emitABC(opLt, 0, rightReg, leftReg, debugInfo)
    of boGe:
      if useIntOps: c.prog.emitABC(opLeInt, 0, rightReg, leftReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opLeFloat, 0, rightReg, leftReg, debugInfo)
      else: c.prog.emitABC(opLe, 0, rightReg, leftReg, debugInfo)
    of boEq:
      if useIntOps: c.prog.emitABC(opEqInt, 0, leftReg, rightReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opEqFloat, 0, leftReg, rightReg, debugInfo)
      else: c.prog.emitABC(opEq, 0, leftReg, rightReg, debugInfo)
    of boNe:
      if useIntOps: c.prog.emitABC(opEqInt, 1, leftReg, rightReg, debugInfo)
      elif useFloatOps: c.prog.emitABC(opEqFloat, 1, leftReg, rightReg, debugInfo)
      else: c.prog.emitABC(opEq, 1, leftReg, rightReg, debugInfo)
    else:
      discard

    # Free comparison registers
    c.allocator.freeReg(leftReg)
    c.allocator.freeReg(rightReg)
  else:
    # General expression condition
    let condReg = c.compileExpression(s.wcond)
    c.prog.emitABC(opTest, condReg, 0, 0, c.makeDebugInfo(s.pos))
    c.allocator.freeReg(condReg)

  # Jump to exit if condition is false
  let exitJmpPos = c.prog.instructions.len
  c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(s.wcond.pos))

  # Restore allocator state for body compilation
  c.allocator.nextReg = savedNextReg

  # Body
  for stmt in s.wbody:
    c.compileStatement(stmt)

  # Continue label - where continue statements jump to
  c.loopStack[^1].continueLabel = c.prog.instructions.len

  # Jump back to start to re-evaluate condition
  c.prog.emitAsBx(opJmp, 0, int16(loopStart - c.prog.instructions.len - 1))

  # Patch exit jump
  c.prog.instructions[exitJmpPos].sbx = int16(c.prog.instructions.len - exitJmpPos - 1)

  # Patch all break jumps to jump here
  let breakPos = c.prog.instructions.len
  for breakJmp in c.loopStack[^1].breakJumps:
    c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

  # Pop loop info
  discard c.loopStack.pop()
