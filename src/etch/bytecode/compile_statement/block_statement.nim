proc compileBlockStatement(c: var Compiler, s: Statement) =
  # Unnamed scope block - compile all statements with proper scope management
  logCompiler(c.verbose, &"Compiling unnamed scope block with {s.blockBody.len} statements")
  let blockStartPC = c.prog.instructions.len
  c.lifetimeTracker.enterScope(blockStartPC)

  # Snapshot ref variables AND defer count before entering block
  var refVarsSnapshot: seq[uint8] = @[]
  for reg in c.refVars.keys:
    refVarsSnapshot.add(reg)
  let blockStartDeferCount = c.deferCount

  # Compile all statements in the block
  for stmt in s.blockBody:
    c.compileStatement(stmt)

  var hoistedRegs: seq[uint8] = @[]
  if s.blockHoistedVars.len > 0:
    logCompiler(c.verbose, &"Block hoisted vars: {s.blockHoistedVars}")
    for name in s.blockHoistedVars:
      if name in c.allocator.regMap:
        hoistedRegs.add(c.allocator.regMap[name])

  # If this block registered any defers, execute them BEFORE decreffing variables
  # (defers might use variables that are about to go out of scope)
  if c.deferCount > blockStartDeferCount:
    logCompiler(c.verbose, &"Block has {c.deferCount - blockStartDeferCount} defer(s), emitting opExecDefers before DecRefs")
    c.prog.emitABC(opExecDefers, 0, 0, 0)

  # Emit DecRefs only for ref variables declared in this block (not in parent scopes)
  var blockLocalRegs: seq[uint8] = @[]
  for reg, typ in c.refVars:
    if reg notin refVarsSnapshot and reg notin hoistedRegs:
      blockLocalRegs.add(reg)
    elif reg notin refVarsSnapshot and reg in hoistedRegs:
      logCompiler(c.verbose, &"Skipping block-local cleanup for hoisted var in reg {reg}")

  # Sort in REVERSE order and emit DecRefs
  blockLocalRegs.sort(system.cmp[uint8], order = Descending)
  for reg in blockLocalRegs:
    c.prog.emitABC(opDecRef, reg, 0, 0)
    logCompiler(c.verbose, &"Emitted opDecRef for block-local ref variable in reg {reg}")
    c.refVars.del(reg)  # Remove from tracking to prevent double-decRef at function exit

  # Exit the block scope
  let blockEndPC = c.prog.instructions.len
  c.lifetimeTracker.exitScope(blockEndPC)
  logCompiler(c.verbose, &"Exited unnamed scope block at PC {blockEndPC}")
