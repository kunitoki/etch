proc compileImportStatement(c: var Compiler, s: Statement) =
  # Import statements - these are handled during parsing
  logCompiler(c.verbose, "Skipping import statement (handled during parsing)")
