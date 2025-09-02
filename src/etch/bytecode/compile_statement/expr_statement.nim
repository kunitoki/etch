
proc compileExpressionStatement(c: var Compiler, s: Statement) =
  # Compile expression and free its register if not used
  logCompiler(c.verbose, &"Compiling expression statement at line {s.pos.line} expr kind = {s.sexpr.kind} expr pos = {s.sexpr.pos.line}")
  let reg = c.compileExpression(s.sexpr)
  c.allocator.freeReg(reg)
