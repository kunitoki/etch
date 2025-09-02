proc compileDeferStatement(c: var Compiler, s: Statement) =
  # Defer statement - compile defer body and emit registration instruction
  c.hasDefers = true  # Mark that this function has defer statements
  c.deferCount += 1   # Increment defer count for scope tracking
  logCompiler(c.verbose, &"Compiling defer block with {s.deferBody.len} statements")

  # Emit jump over defer body (we'll patch this later)
  let jumpOverPos = c.prog.instructions.len
  c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(s.pos))

  # Mark the start of defer body
  let deferBodyStart = c.prog.instructions.len

  # Compile defer body statements
  for stmt in s.deferBody:
    c.compileStatement(stmt)

  # Emit defer end marker
  c.prog.emitABC(opDeferEnd, 0, 0, 0, c.makeDebugInfo(s.pos))

  # Patch the jump to skip over defer body
  let deferBodyEnd = c.prog.instructions.len
  c.prog.instructions[jumpOverPos].sbx = int16(deferBodyEnd - jumpOverPos - 1)

  # Emit PushDefer instruction to register this defer (at the skip location)
  # The offset points back to the defer body start
  let offsetToDefer = deferBodyStart - deferBodyEnd
  c.prog.emitAsBx(opPushDefer, 0, int16(offsetToDefer), c.makeDebugInfo(s.pos))

  logCompiler(c.verbose, &"Defer body at PC {deferBodyStart}..{deferBodyEnd - 1} registration at PC {deferBodyEnd}")
