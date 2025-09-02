proc compileComptimeStatement(c: var Compiler, s: Statement) =
  # Comptime blocks should contain injected variables after foldComptime
  logCompiler(c.verbose, &"Processing comptime block with {s.cbody.len} statements")
  for stmt in s.cbody:
    c.compileStatement(stmt)
