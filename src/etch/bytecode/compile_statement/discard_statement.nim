proc compileDiscardStatement(c: var Compiler, s: Statement) =
  # Discard statement - compile expressions and free their registers
  # Note: For ref-typed variables, we do NOT emit DecRef here - they should
  # be cleaned up at scope exit (end of function or block) instead
  logCompiler(c.verbose, &"Compiling discard statement with {s.dexprs.len} expressions")
  for expr in s.dexprs:
    let reg = c.compileExpression(expr)
    # Don't free the register if it's a variable that needs to stay alive
    # Only free if it's a temporary expression result
    if expr.kind != ekVar:
      c.allocator.freeReg(reg)
