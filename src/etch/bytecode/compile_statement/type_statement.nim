proc compileTypeDeclStatement(c: var Compiler, s: Statement) =
  # Type declarations are handled entirely during parsing/type checking.
  logCompiler(c.verbose, "Skipping type declaration (handled during type checking)")
