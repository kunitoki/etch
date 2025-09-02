proc compileReturnStatement(c: var Compiler, s: Statement) =
  # Execute all registered defers before returning (only if function has defers)
  let debug = c.makeDebugInfo(s.pos)

  # Always emit an instruction to keep jump offsets consistent
  if c.hasDefers:
    c.prog.emitABC(opExecDefers, 0, 0, 0, debug)
  else:
    c.prog.emitABC(opNoOp, 0, 0, 0, debug)

  if s.re.isSome():
    let retReg = c.compileExpression(s.re.get())

    # Emit decRefs for all ref variables EXCEPT the one being returned
    # If returning a ref, don't decRef it (ownership transfers to caller)
    let returningRef = s.re.get().typ != nil and s.re.get().typ.kind == tkRef
    if returningRef:
      c.emitDecRefsForScope(excludeReg = int(retReg))
    else:
      c.emitDecRefsForScope()

    c.prog.emitABC(opReturn, 1, retReg, 0, debug)  # 1 result, in retReg
  else:
    # Emit decRefs for all ref variables AFTER defers (defers might use the refs)
    c.emitDecRefsForScope()
    c.prog.emitABC(opReturn, 0, 0, 0, debug)  # 0 results
