# core.nim
# Main type checker core functions and unified type inference

import std/[tables, options]
import ../frontend/ast
import types, statements


proc typecheck*(prog: Program) =
  var subst: TySubst
  # globals - first pass: collect all variable declarations for forward references
  var gscope = Scope(
    types: initTable[string, EtchType](),
    flags: initTable[string, VarFlag](),
    userTypes: initTable[string, EtchType]()
  )

  # First pass: add all user-defined types to scope
  for typeName, typeDecl in prog.types:
    gscope.userTypes[typeName] = typeDecl

  # Second pass: add all global variable types to scope (without checking initializers)
  for g in prog.globals:
    if g.kind == skVar:
      gscope.types[g.vname] = g.vtype
      gscope.flags[g.vname] = g.vflag

  # Third pass: typecheck all global statements with complete scope
  for g in prog.globals:
    typecheckStmt(prog, nil, gscope, g, subst)


# Unified type inference that can work in different contexts
proc inferTypeFromExpr*(expr: Expr): EtchType =
  ## Simple type inference for parsing context - infer type without full context
  ## This is used when no type annotation is provided in variable declarations
  case expr.kind
  of ekInt, ekFloat, ekString, ekChar, ekBool, ekNil:
    return inferLiteralType(expr.kind)
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
  of ekOptionSome:
    # some(value) has type option[T] where T is the type of value
    let innerType = inferTypeFromExpr(expr.someExpr)
    if innerType != nil:
      return tOption(innerType)
    else:
      return nil
  of ekOptionNone:
    # none cannot be type-inferred without context - requires type annotation
    return nil
  of ekResultOk:
    # ok(value) has type result[T] where T is the type of value
    let innerType = inferTypeFromExpr(expr.okExpr)
    if innerType != nil:
      return tResult(innerType)
    else:
      return nil
  of ekResultErr:
    # error(msg) cannot be type-inferred without context - requires type annotation
    return nil
  of ekBin:
    # Handle binary expressions
    let leftType = inferTypeFromExpr(expr.lhs)
    let rightType = inferTypeFromExpr(expr.rhs)
    if leftType == nil or rightType == nil:
      return nil

    case expr.bop
    of boAdd, boSub, boMul, boDiv, boMod:
      # Arithmetic operations: int + int = int, float + float = float
      if leftType.kind == tkInt and rightType.kind == tkInt:
        return tInt()
      elif leftType.kind == tkFloat and rightType.kind == tkFloat:
        return tFloat()
      # Mixed operations (int + float) would require promotion, but for simplicity return nil
      else:
        return nil
    of boEq, boNe, boLt, boLe, boGt, boGe:
      # Comparison operations always return bool
      if typeEq(leftType, rightType):
        return tBool()
      else:
        return nil
    of boAnd, boOr:
      # Logical operations: bool && bool = bool
      if leftType.kind == tkBool and rightType.kind == tkBool:
        return tBool()
      else:
        return nil
  of ekObjectLiteral:
    # Object literals need type checking context to resolve their type
    return nil
  of ekFieldAccess:
    # Field access needs context to determine object type
    return nil
  of ekNew:
    # new[Type] or new(value) returns ref[Type]
    if expr.newType != nil:
      return tRef(expr.newType)
    elif expr.initExpr.isSome:
      # Type inference from initialization: new(42) -> ref[int]
      let innerType = inferTypeFromExpr(expr.initExpr.get)
      if innerType != nil:
        return tRef(innerType)
      else:
        return nil
    else:
      return nil
  of ekArrayLen:
    # Array length always returns int
    return tInt()
  else:
    # For other expressions (variables, etc.), we cannot infer the type
    # without a type checker - return nil to indicate type annotation is required
    return nil
