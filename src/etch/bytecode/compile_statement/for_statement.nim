proc compileForLoopStatement(c: var Compiler, s: Statement) =
  ## Compile optimized for loop

  if s.farray.isSome():
    # For-in loop over array/string
    let arrReg = c.compileExpression(s.farray.get())

    # Allocate registers for loop state
    let idxReg = c.allocator.allocReg()  # Loop index
    let lenReg = c.allocator.allocReg()  # Array length
    let elemReg = c.allocator.allocReg(s.fvar)  # Current element (loop variable)
    let debug = c.makeDebugInfo(s.pos)

    # Initialize index to 0 - has debug info so we stop at the for statement once
    let loopStartPC = c.prog.instructions.len
    c.prog.emitAsBx(opLoadK, idxReg, 0, debug)

    # Track loop variable lifetime - declare at loop start (in current scope)
    c.lifetimeTracker.declareVariable(s.fvar, elemReg, loopStartPC)

    # Get array length (internal operation after init - no debug info)
    c.prog.emitABC(opLen, lenReg, arrReg, 0)

    # Create loop info for break/continue
    var loopInfo = LoopInfo(
      startLabel: c.prog.instructions.len,
      continueLabel: -1,  # Will be set later
      breakJumps: @[]
    )

    # Loop start
    let loopStart = c.prog.instructions.len

    # Check if index < length - add debug info so we break here on each iteration
    # opLt with A=0: skip next if (B < C) is true
    # So when idx < len (should continue), skip the exit jump ✓
    # When idx >= len (should exit), execute the exit jump ✓
    c.prog.emitABC(opLt, 0, idxReg, lenReg, debug)  # Skip exit jump when idx < len
    let exitJmp = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0)  # Jump to exit if idx >= len

    # Get current element: elemReg = arrReg[idxReg] (internal operation - no debug info)
    let getIndexPC = c.prog.instructions.len
    c.prog.emitABC(opGetIndex, elemReg, arrReg, idxReg)

    # Mark loop variable as defined (gets its value from array)
    c.lifetimeTracker.defineVariable(s.fvar, getIndexPC)

    # Push loop info before compiling body
    c.loopStack.add(loopInfo)

    # Compile loop body
    for stmt in s.fbody:
      c.compileStatement(stmt)

    # Emit DecRef for any reference-typed registers allocated in loop body
    # Get the saved allocator state before loop
    let loopBodyStartReg = elemReg + 1  # First register after loop vars
    # Only emit for registers that are tracked in refVars (compile-time optimization)
    var loopBodyRefRegs: seq[uint8] = @[]
    for reg, typ in c.refVars:
      if reg >= loopBodyStartReg and reg < c.allocator.nextReg:
        loopBodyRefRegs.add(reg)

    # Emit in reverse order for proper destruction order
    loopBodyRefRegs.sort(system.cmp[uint8], order = Descending)
    for reg in loopBodyRefRegs:
      c.prog.emitABC(opDecRef, reg, 0, 0)
      c.refVars.del(reg)  # Remove from tracking to prevent double-decRef

    # Continue label - where continue statements jump to
    c.loopStack[^1].continueLabel = c.prog.instructions.len

    # Increment index (internal operation - no debug info)
    c.prog.emitABx(opAddI, idxReg, uint16(idxReg) or (1'u16 shl 8))  # idxReg += 1

    # Jump back to loop start (internal operation - no debug info)
    c.prog.emitAsBx(opJmp, 0, int16(loopStart - c.prog.instructions.len - 1))

    # Patch exit jump
    c.prog.instructions[exitJmp].sbx = int16(c.prog.instructions.len - exitJmp - 1)

    # Patch all break jumps to jump here
    let breakPos = c.prog.instructions.len
    for breakJmp in c.loopStack[^1].breakJumps:
      c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

    # Pop loop info
    discard c.loopStack.pop()

    # Free registers
    c.allocator.freeReg(elemReg)
    c.allocator.freeReg(lenReg)
    c.allocator.freeReg(idxReg)
    c.allocator.freeReg(arrReg)

    return

  # Numeric for loop using ForPrep/ForLoop instructions
  # Extract loop bounds
  let startExpression = s.fstart.get()
  let endExpression = s.fend.get()

  # Save current register state
  let savedNextReg = c.allocator.nextReg

  # ForLoop requires three consecutive registers: idx, limit, step
  # We need to ensure they are allocated consecutively
  # First, remove the loop variable from the map if it exists (from a previous loop)
  if c.allocator.regMap.hasKey(s.fvar):
    c.allocator.regMap.del(s.fvar)

  # Now allocate three consecutive registers
  let idxReg = c.allocator.allocReg(s.fvar)
  let limitReg = idxReg + 1
  let stepReg = idxReg + 2

  # Make sure we account for these registers in the allocator
  c.allocator.setNextReg(max(c.allocator.nextReg, stepReg + 1))

  # Initialize loop variables - first operation has debug info so we stop at for statement once
  let loopInitPC = c.prog.instructions.len
  let debugInfo = c.makeDebugInfo(s.pos)

  if startExpression.kind == ekInt:
    let constIdx = c.addConst(makeInt(startExpression.ival))
    c.prog.emitABx(opLoadK, idxReg, constIdx, debugInfo)
  else:
    let startReg = c.compileExpression(startExpression)
    c.prog.emitABC(opMove, idxReg, startReg, 0, debugInfo)
    if startReg != idxReg and startExpression.kind != ekVar:
      c.allocator.freeReg(startReg)

  # Track loop variable lifetime - declare and define at loop initialization (in current scope)
  c.lifetimeTracker.declareVariable(s.fvar, idxReg, loopInitPC)
  c.lifetimeTracker.defineVariable(s.fvar, loopInitPC)

  let endDebug = c.makeDebugInfo(endExpression.pos)
  if endExpression.kind == ekInt:
    let constIdx = c.addConst(makeInt(endExpression.ival))
    c.prog.emitABx(opLoadK, limitReg, constIdx, endDebug)
    if s.finclusive:
      c.prog.emitABx(opAddI, limitReg, uint16(limitReg) or (1'u16 shl 8))
  else:
    let endReg = c.compileExpression(endExpression)
    c.prog.emitABC(opMove, limitReg, endReg, 0, endDebug)
    if s.finclusive:
      c.prog.emitABx(opAddI, limitReg, uint16(limitReg) or (1'u16 shl 8))
    if endReg != limitReg and endExpression.kind != ekVar:
      c.allocator.freeReg(endReg)

  # Step is always 1 for now
  c.prog.emitAsBx(opLoadK, stepReg, 1)

  # Create loop info for break/continue
  var loopInfo = LoopInfo(
    startLabel: -1,  # Will be set at loop body start
    continueLabel: -1,  # Will be set later
    breakJumps: @[]
  )

  # Check if we can use specialized int loop
  let isIntLoop = (startExpression.kind == ekInt or (startExpression.typ != nil and startExpression.typ.kind == tkInt)) and
                  (endExpression.kind == ekInt or (endExpression.typ != nil and endExpression.typ.kind == tkInt))

  # ForPrep instruction - checks if loop should run at all (internal operation - no debug info)
  let prepPos = c.prog.instructions.len
  let prepOp = if isIntLoop: opForIntPrep else: opForPrep
  c.prog.emitAsBx(prepOp, idxReg, 0)  # Jump offset filled later

  # Mark loop start (where we'll jump back to)
  let loopStart = c.prog.instructions.len
  loopInfo.startLabel = loopStart

  # Save allocator state before loop body
  let loopSavedNextReg = c.allocator.nextReg

  # Push loop info before compiling body
  c.loopStack.add(loopInfo)

  # Compile loop body - DON'T reset allocator between statements!
  # Only reset at the start of each loop iteration (handled by runtime)
  for stmt in s.fbody:
    logCompiler(c.verbose, &"Loop body statement, nextReg = {c.allocator.nextReg}")
    c.compileStatement(stmt)

  # Emit DecRef for any reference-typed registers allocated in loop body
  # This must happen before jumping back to loop start
  # Only emit for registers that are tracked in refVars (compile-time optimization)
  var loopBodyRefRegs: seq[uint8] = @[]
  for reg, typ in c.refVars:
    if reg >= loopSavedNextReg and reg < c.allocator.nextReg:
      loopBodyRefRegs.add(reg)

  # Emit in reverse order for proper destruction order
  loopBodyRefRegs.sort(system.cmp[uint8], order = Descending)
  for reg in loopBodyRefRegs:
    c.prog.emitABC(opDecRef, reg, 0, 0)
    c.refVars.del(reg)  # Remove from tracking to prevent double-decRef

  # Restore allocator after loop body
  c.allocator.nextReg = loopSavedNextReg

  # Continue label - where continue statements jump to
  c.loopStack[^1].continueLabel = c.prog.instructions.len

  # ForLoop instruction (increment and test) - internal operation, no debug info
  # Jump back to loop start (body) if continuing
  let loopOp = if isIntLoop: opForIntLoop else: opForLoop
  c.prog.emitAsBx(loopOp, idxReg, int16(loopStart - c.prog.instructions.len - 1))

  # Patch ForPrep jump to skip to end if initial test fails
  # ForPrep should jump to the instruction AFTER ForLoop if the loop shouldn't run
  c.prog.instructions[prepPos].sbx =
    int16(c.prog.instructions.len - prepPos - 1)

  # Patch all break jumps to jump here
  let breakPos = c.prog.instructions.len
  for breakJmp in c.loopStack[^1].breakJumps:
    c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

  # Pop loop info
  discard c.loopStack.pop()

  # Restore register state (but keep loop variable if needed)
  # Only restore if loop variable is not used after loop
  c.allocator.setNextReg(savedNextReg + 3)  # Keep the 3 loop registers
