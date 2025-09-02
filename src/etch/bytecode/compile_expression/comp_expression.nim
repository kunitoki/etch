proc compileComptimeExpression(c: var Compiler, e: Expression): uint8 =
  # Compile-time expression should have been folded during comptime pass
  # If we reach here, just compile the inner expression (it should be a constant now)
  logCompiler(c.verbose, "Compiling ekComptime expression (should have been folded)")
  result = c.compileExpression(e.comptimeExpression)


proc compileCompilesExpression(c: var Compiler, e: Expression): uint8 =
  # compiles{...} should have been folded to a boolean during comptime pass
  # If we reach here, something went wrong - return false as a fallback
  logCompiler(c.verbose, "Warning: ekCompiles reached bytecode compiler (should have been folded)")
  result = c.allocator.allocReg()
  c.prog.emitAsBx(opLoadK, result, 0, c.makeDebugInfo(e.pos))  # Load false
