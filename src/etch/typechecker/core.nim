# core.nim
# Main type checker core functions and unified type inference

import std/[tables]
import ../frontend/ast
import types, statements


proc typecheck*(prog: Program) =
  var subst: TySubst
  # globals - first pass: collect all variable declarations for forward references
  var gscope = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag]())

  # First pass: add all global variable types to scope (without checking initializers)
  for g in prog.globals:
    if g.kind == skVar:
      gscope.types[g.vname] = g.vtype
      gscope.flags[g.vname] = g.vflag

  # Second pass: typecheck all global statements with complete scope
  for g in prog.globals:
    typecheckStmt(prog, nil, gscope, g, subst)


# Unified type inference that can work in different contexts
proc inferTypeFromExpr*(expr: Expr): EtchType =
  ## Simple type inference for parsing context - infer type without full context
  ## This is used when no type annotation is provided in variable declarations
  case expr.kind
  of ekInt: return tInt()
  of ekFloat: return tFloat()
  of ekString: return tString()
  of ekBool: return tBool()
  of ekNil: return tRef(tVoid())  # nil has type Ref[void]
  of ekCast: return expr.castType  # cast expression has the target cast type
  of ekArray:
    if expr.elements.len == 0:
      # Empty array, cannot infer element type
      return nil
    let elemType = inferTypeFromExpr(expr.elements[0])
    if elemType == nil:
      return nil
    return tArray(elemType)
  of ekNewRef:
    let innerType = inferTypeFromExpr(expr.init)
    if innerType == nil:
      return nil
    return tRef(innerType)
  of ekUn:
    # Handle unary expressions
    case expr.uop
    of uoNeg:
      # Unary negation: infer type from the operand
      let operandType = inferTypeFromExpr(expr.ue)
      if operandType != nil and operandType.kind == tkInt:
        return tInt()
      elif operandType != nil and operandType.kind == tkFloat:
        return tFloat()
      else:
        return nil
    of uoNot:
      # Logical not: should always return bool
      let operandType = inferTypeFromExpr(expr.ue)
      if operandType != nil and operandType.kind == tkBool:
        return tBool()
      else:
        return nil
  of ekCall:
    # Handle builtin function calls that have statically known return types
    case expr.fname
    of "rand":
      # rand(max) or rand(max, min) always returns int
      if expr.args.len >= 1 and expr.args.len <= 2:
        return tInt()
      else:
        return nil
    of "readFile":
      # readFile(path) always returns string
      if expr.args.len == 1:
        return tString()
      else:
        return nil
    of "print", "seed", "inject":
      # These functions return void
      return tVoid()
    of "new":
      # new(value) returns ref[typeof(value)]
      if expr.args.len == 1:
        let innerType = inferTypeFromExpr(expr.args[0])
        if innerType != nil:
          return tRef(innerType)
        else:
          return nil
      else:
        return nil
    of "deref":
      # deref(ref) returns the inner type of the reference
      # However, we can't easily determine this without type checking
      # the argument, so return nil for now
      return nil
    else:
      # Unknown function call - requires type annotation
      return nil
  else:
    # For other expressions (variables, etc.), we cannot infer the type
    # without a type checker - return nil to indicate type annotation is required
    return nil
