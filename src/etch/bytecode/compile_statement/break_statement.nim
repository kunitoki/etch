proc compileBreakStatement(c: var Compiler, s: Statement) =
  # Break statement - jump out of current loop
  if c.loopStack.len > 0:
    # Add a jump that will be patched later
    let jmpPos = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(s.pos))
    c.loopStack[^1].breakJumps.add(jmpPos)
  else:
    raise newCompileError(s.pos, "break statement outside of loop")
