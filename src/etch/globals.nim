# globals.nim
# Global variable evaluation and management for Etch

import std/[tables, options]
import ast, vm, bytecode

proc evaluateGlobalVariables*(prog: Program): Table[string, V] =
  ## Evaluate global variable initialization expressions using full VM
  ## Returns a table of evaluated global values for bytecode compilation
  # Create temporary VM with all functions available
  var vm = VM(heap: @[], funs: initTable[string, FunDecl](), injectedStmts: @[])
  for k, f in pairs(prog.funs): vm.funs[k] = f
  for k, f in pairs(prog.funInstances): vm.funs[k] = f

  # Create frame for global evaluation with dependency support
  var globalFrame = Frame(vars: initTable[string, V]())

  # Evaluate each global variable in order (supports dependencies)
  for g in prog.globals:
    if g.kind == skVar and g.vinit.isSome():
      try:
        # Evaluate the initialization expression with access to previous globals
        let res = vm.evalExpr(globalFrame, g.vinit.get())
        # Store the evaluated value in the frame for subsequent globals
        globalFrame.vars[g.vname] = res
      except:
        # If evaluation fails, store default value
        globalFrame.vars[g.vname] = V(kind: tkInt, ival: 0)
    elif g.kind == skVar:
      # Default initialization for variables without initializers
      globalFrame.vars[g.vname] = V(kind: tkInt, ival: 0)

  return globalFrame.vars

proc convertVMValueToGlobalValue*(val: V): GlobalValue =
  ## Convert a VM value to a GlobalValue for bytecode storage
  case val.kind
  of tkInt:
    GlobalValue(kind: tkInt, ival: val.ival)
  of tkFloat:
    GlobalValue(kind: tkFloat, fval: val.fval)
  of tkBool:
    GlobalValue(kind: tkBool, bval: val.bval)
  of tkString:
    GlobalValue(kind: tkString, sval: val.sval)
  else:
    # Default for unsupported types
    GlobalValue(kind: tkInt, ival: 0)