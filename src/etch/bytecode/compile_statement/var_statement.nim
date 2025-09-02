proc compileVarStatement(c: var Compiler, s: Statement) =
  # Variable declaration (let or var) - allocate register for the new variable
  let stmtType = if s.vflag == vfLet: "let" else: "var"
  logCompiler(c.verbose, &"Compiling {stmtType} statement for variable: {s.vname} at line {s.pos.line}")

  # Track variable declaration in lifetime tracker
  let currentPC = c.prog.instructions.len

  if s.vinit.isSome:
    let initExpr = s.vinit.get
    logCompiler(c.verbose, &"Compiling init expression for {s.vname} expr kind: {initExpr.kind}")
    let valReg = c.compileExpression(initExpr)
    var finalReg = valReg

    # If we are initializing from another tracked variable, allocate a fresh register
    # so the two variables do not alias the same storage.
    if initExpr.kind == ekVar and c.allocator.regMap.hasKey(initExpr.vname) and
       c.allocator.regMap[initExpr.vname] == valReg:
      let aliasReg = c.allocator.allocReg()
      c.prog.emitABC(opMove, aliasReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Aliased init detected for {s.vname}, moved value from reg {valReg} to new reg {aliasReg}")
      finalReg = aliasReg

    # Check if we need weak-to-strong or strong-to-weak conversion
    let varIsRef = s.vtype != nil and s.vtype.kind == tkRef
    let varIsWeak = s.vtype != nil and s.vtype.kind == tkWeak
    let initIsWeak = initExpr.typ != nil and initExpr.typ.kind == tkWeak
    let initIsRef = initExpr.typ != nil and initExpr.typ.kind == tkRef

    if varIsRef and initIsWeak:
      # Promote weak to strong
      let strongReg = c.allocator.allocReg()
      c.prog.emitABC(opWeakToStrong, strongReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Promoting weak ref in reg {valReg} to strong ref in reg {strongReg} for {s.vname}")
      # Don't free valReg - it might be a variable's register that's still in use
      finalReg = strongReg
    elif varIsWeak and initIsRef:
      # Convert strong to weak
      let weakReg = c.allocator.allocReg()
      c.prog.emitABC(opNewWeak, weakReg, valReg, 0, c.makeDebugInfo(s.pos))
      logCompiler(c.verbose, &"Converting strong ref in reg {valReg} to weak ref in reg {weakReg} for {s.vname}")
      # Don't free valReg - it might be a variable's register that's still in use
      finalReg = weakReg
    elif varIsRef:
      # If initializing a ref variable from an existing ref (not a new allocation),
      # we must increment the refcount because the new variable owns a reference.
      # New allocations (ekNew, ekObjectLiteral, etc.) already have refcount=1.
      # Function calls should return owned references (refcount=1).
      let initKind = s.vinit.get.kind
      if initKind in {ekVar, ekFieldAccess, ekIndex, ekDeref}:
         c.prog.emitABC(opIncRef, finalReg, 0, 0, c.makeDebugInfo(s.pos))
         logCompiler(c.verbose, &"Emitted opIncRef for aliased ref variable {s.vname}")

    c.allocator.regMap[s.vname] = finalReg

    # Track ref-typed, weak-typed, and arrays containing refs/weaks for reference counting
    let needsTracking = s.vtype != nil and (
      s.vtype.kind == tkRef or
      s.vtype.kind == tkWeak or
      s.vtype.kind == tkCoroutine or
      s.vtype.kind == tkFunction or
      (s.vtype.kind == tkArray and needsArrayCleanup(s.vtype))
    )
    if needsTracking:
      c.refVars[finalReg] = s.vtype
      let typeName = case s.vtype.kind
        of tkRef: "ref"
        of tkWeak: "weak"
        of tkCoroutine: "coroutine"
        of tkFunction: "closure"
        of tkArray: "array[ref]"
        else: "unknown"
      logCompiler(c.verbose, &"Tracked {typeName} variable {s.vname} in reg {finalReg}")

    # Variable is declared and defined at this point
    c.lifetimeTracker.declareVariable(s.vname, finalReg, currentPC)
    c.lifetimeTracker.defineVariable(s.vname, currentPC)

    logCompiler(c.verbose, &"Variable {s.vname} allocated to reg {finalReg} with initialization")
  else:
    # Uninitialized variable - allocate register with nil
    let reg = c.allocator.allocReg(s.vname)
    c.prog.emitABC(opLoadNil, reg, 0, 0, c.makeDebugInfo(s.pos))

    # Track ref-typed, weak-typed, coroutines, and arrays containing refs/weaks even if uninitialized
    let needsTracking = s.vtype != nil and (
      s.vtype.kind == tkRef or
      s.vtype.kind == tkWeak or
      s.vtype.kind == tkCoroutine or
      s.vtype.kind == tkFunction or
      (s.vtype.kind == tkArray and needsArrayCleanup(s.vtype))
    )
    if needsTracking:
      c.refVars[reg] = s.vtype
      let typeName = case s.vtype.kind
        of tkRef: "ref"
        of tkWeak: "weak"
        of tkCoroutine: "coroutine"
        of tkFunction: "closure"
        of tkArray: "array[ref]"
        else: "unknown"
      logCompiler(c.verbose, &"Tracked {typeName} variable {s.vname} in reg {reg} (uninitialized)")

    # Variable is declared but not yet defined (holds nil)
    c.lifetimeTracker.declareVariable(s.vname, reg, currentPC)

    logCompiler(c.verbose, &"Variable {s.vname} allocated to reg {reg} (uninitialized)")
