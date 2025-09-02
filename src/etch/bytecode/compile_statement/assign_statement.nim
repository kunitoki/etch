proc compileAssignStatement(c: var Compiler, s: Statement) =
  # Check if variable already has a register
  let currentPC = c.prog.instructions.len

  if c.allocator.regMap.hasKey(s.aname):
    # Update existing register
    let destReg = c.allocator.regMap[s.aname]
    let valReg = c.compileExpression(s.aval, destReg)

    # Check if we need to handle type conversions
    let destIsWeak = c.refVars.hasKey(destReg) and c.refVars[destReg].kind == tkWeak
    let destIsRef = c.refVars.hasKey(destReg) and c.refVars[destReg].kind == tkRef
    let valueIsRef = s.aval.typ != nil and s.aval.typ.kind == tkRef
    let valueIsWeak = s.aval.typ != nil and s.aval.typ.kind == tkWeak

    # If assigning a weak value to a ref variable, promote weak to strong
    if destIsRef and valueIsWeak:
      # Promote weak to strong
      let strongReg = c.allocator.allocReg()
      c.prog.emitABC(opWeakToStrong, strongReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Promoting weak ref in reg {valReg} to strong ref in reg {strongReg} for {s.aname}")

      # Decrement ref count of old value (if not nil)
      c.prog.emitABC(opDecRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Emitted opDecRef for old value in {s.aname} (reg {destReg})")

      # Move promoted value
      if strongReg != destReg:
        c.prog.emitABC(opMove, destReg, strongReg, 0, c.makeDebugInfo(s.pos))
        c.allocator.freeReg(strongReg)

      # strongReg now contains the promoted ref, which already has correct refcount from weakToStrong
      logCompiler(c.verbose, &"Completed weak-to-strong promotion for {s.aname}")
    elif destIsWeak and valueIsRef:
      # If assigning a ref value to a weak variable, create weak wrapper
      # Create weak wrapper
      let weakReg = c.allocator.allocReg()
      c.prog.emitABC(opNewWeak, weakReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Wrapping ref in reg {valReg} with weak wrapper in reg {weakReg} for {s.aname}")

      # Move weak wrapper to destination
      if weakReg != destReg:
        c.prog.emitABC(opMove, destReg, weakReg, 0, c.makeDebugInfo(s.pos))
        c.allocator.freeReg(weakReg)
    elif destIsRef and valueIsRef:
      # Assigning ref to ref variable - handle reference counting
      # Decrement ref count of old value (if not nil)
      c.prog.emitABC(opDecRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Emitted opDecRef for old value in {s.aname} (reg {destReg})")

      # Move new value
      if valReg != destReg:
        c.prog.emitABC(opMove, destReg, valReg, 0, c.makeDebugInfo(s.pos))

      # Increment ref count of new value
      c.prog.emitABC(opIncRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Emitted opIncRef for new value in {s.aname} (reg {destReg})")
    else:
      # Normal non-ref assignment
      if valReg != destReg:
        c.prog.emitABC(opMove, destReg, valReg, 0, c.makeDebugInfo(s.pos))

    # Clean up source register (only if it's not a variable's register)
    if valReg != destReg:
      # Check if this register belongs to a variable - if so, don't free/clear it
      var isVariableReg = false
      for varName, varReg in c.allocator.regMap:
        if varReg == valReg:
          isVariableReg = true
          break

      if not isVariableReg:
        if c.debug:
          c.prog.emitABC(opLoadNil, valReg, 0, 0)
        c.allocator.freeReg(valReg)

    # Mark variable as defined (if it wasn't already)
    c.lifetimeTracker.defineVariable(s.aname, currentPC)
  elif s.aname in c.globalVars:
    # Assignment to global variable
    logCompiler(c.verbose, &"Assignment to global variable '{s.aname}'")
    let valReg = c.compileExpression(s.aval)
    let nameIdx = c.addStringConst(s.aname)
    c.prog.emitABx(opSetGlobal, valReg, nameIdx, c.makeDebugInfo(s.pos))
    c.allocator.freeReg(valReg)
  else:
    # New local variable - allocate register
    let valReg = c.compileExpression(s.aval)
    c.allocator.regMap[s.aname] = valReg

    # Declare and define variable (implicit declaration through assignment)
    c.lifetimeTracker.declareVariable(s.aname, valReg, currentPC)
    c.lifetimeTracker.defineVariable(s.aname, currentPC)

proc compileCompoundAssignStatement(c: var Compiler, s: Statement) =
  let debug = c.makeDebugInfo(s.pos)

  if not c.allocator.regMap.hasKey(s.caname):
    if s.caname notin c.globalVars:
      raise newCompileError(s.pos, &"unknown variable '{s.caname}' in compound assignment")

    # Global variable: load, apply op, store back
    let nameIdx = c.addStringConst(s.caname)
    let currentValueReg = c.allocator.allocReg()
    c.prog.emitABx(opGetGlobal, currentValueReg, nameIdx, debug)
    let rhsReg = c.compileExpression(s.crhs)
    c.compileBinOpExpression(s.cop, currentValueReg, currentValueReg, rhsReg, debug, nil, nil)
    c.prog.emitABx(opSetGlobal, currentValueReg, nameIdx, debug)
    if s.crhs.kind != ekVar:
      c.allocator.freeReg(rhsReg)
    c.allocator.freeReg(currentValueReg)
    return

  let destReg = c.allocator.regMap[s.caname]
  let rhsReg = c.compileExpression(s.crhs)
  c.compileBinOpExpression(s.cop, destReg, destReg, rhsReg, debug, s.crhs.typ, s.crhs.typ)
  if s.crhs.kind != ekVar:
    c.allocator.freeReg(rhsReg)
