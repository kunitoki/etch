# globals.nim
# Global variable evaluation and management for Etch

import std/[tables, options]
import ast, vm

proc evaluateGlobalVariables*(prog: Program): Table[string, V] =
  ## Evaluate global variable initialization expressions using bytecode
  ## Returns a table of evaluated global values for bytecode compilation
  var globalVars = initTable[string, V]()

  # Evaluate each global variable in order (supports dependencies)
  for g in prog.globals:
    if g.kind == skVar and g.vinit.isSome():
      try:
        # Evaluate the initialization expression with access to previous globals
        let res = evalExprWithBytecode(prog, g.vinit.get(), globalVars)
        # Store the evaluated value for subsequent globals
        globalVars[g.vname] = res
      except Exception as e:
        # If evaluation fails, store default value (silently)
        # The actual error will be caught by the compiler's type checker
        globalVars[g.vname] = V(kind: tkInt, ival: 0)
    elif g.kind == skVar:
      # Default initialization for variables without initializers
      globalVars[g.vname] = V(kind: tkInt, ival: 0)

  return globalVars
