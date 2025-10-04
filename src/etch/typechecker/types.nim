# types.nim
# Type utilities and operations for the type checker

import std/[tables, strformat, options]
import ../frontend/ast, ../common/errors, ../common/types


type
  Scope* = ref object
    types*: Table[string, EtchType] # variables
    flags*: Table[string, VarFlag] # variable mutability
    userTypes*: Table[string, EtchType] # user-defined types
  TySubst* = Table[string, EtchType] # generic var -> concrete type


proc typeEq*(a, b: EtchType): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tkRef: return typeEq(a.inner, b.inner)
  of tkArray: return typeEq(a.inner, b.inner)
  of tkOption: return typeEq(a.inner, b.inner)
  of tkResult: return typeEq(a.inner, b.inner)
  of tkGeneric: return a.name == b.name
  of tkUserDefined, tkDistinct, tkObject: return a.name == b.name
  of tkInferred: return false  # Inferred types should be resolved before comparison
  else: true


proc resolveTy*(t: EtchType, subst: var TySubst): EtchType =
  if t.isNil:
    # Handle nil type gracefully - likely due to function without explicit return type
    return tVoid()
  case t.kind
  of tkGeneric:
    if t.name in subst: return subst[t.name]
    else: return t
  of tkRef: return tRef(resolveTy(t.inner, subst))
  of tkArray: return tArray(resolveTy(t.inner, subst))
  of tkOption: return tOption(resolveTy(t.inner, subst))
  of tkResult: return tResult(resolveTy(t.inner, subst))
  of tkDistinct:
    let resolvedInner = if t.inner != nil: resolveTy(t.inner, subst) else: nil
    return tDistinct(t.name, resolvedInner)
  of tkInt, tkFloat, tkString, tkChar, tkBool, tkVoid, tkUserDefined, tkObject: return t
  of tkInferred:
    # Inferred types should have been resolved by the time we reach resolveTy
    raise newTypecheckError(Pos(), "unresolved inferred type encountered in resolveTy")


proc resolveUserType*(scope: Scope, typeName: string): EtchType =
  ## Resolve a user-defined type from scope
  if scope.userTypes.hasKey(typeName):
    return scope.userTypes[typeName]
  else:
    return nil


proc isDistinctType*(t: EtchType): bool =
  ## Check if a type is a distinct type
  return t.kind == tkDistinct


proc getDistinctBaseType*(t: EtchType): EtchType =
  ## Get the base type of a distinct type
  if t.kind == tkDistinct:
    return t.inner
  else:
    return t


proc canAssignDistinct*(targetType: EtchType, sourceType: EtchType): bool =
  ## Check if we can assign sourceType to targetType for distinct types
  ## Distinct types are only assignable from their base types, not other distinct types
  if targetType.kind == tkDistinct:
    if sourceType.kind == tkDistinct:
      # Can't assign one distinct type to another, even if same base type
      return false
    else:
      # Can assign base type to distinct type
      return typeEq(targetType.inner, sourceType)
  elif sourceType.kind == tkDistinct:
    # Can't implicitly convert distinct type to base type
    return false
  else:
    # Regular type equality
    return typeEq(targetType, sourceType)


proc resolveNestedUserTypes*(sc: Scope, typ: EtchType, pos: Pos): EtchType =
  ## Recursively resolve user-defined types in nested type structures
  ## like ref[Person], array[Person], etc.
  if typ == nil:
    return typ

  case typ.kind
  of tkUserDefined:
    # Resolve this user-defined type
    if not sc.userTypes.hasKey(typ.name):
      raise newTypecheckError(pos, &"unknown type '{typ.name}'")
    return sc.userTypes[typ.name]
  of tkRef:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tRef(resolvedInner)
  of tkArray:
    # Recursively resolve the element type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tArray(resolvedInner)
  of tkOption:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tOption(resolvedInner)
  of tkResult:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tResult(resolvedInner)
  else:
    # For primitive types and other types, no resolution needed
    return typ

# Helper functions for common type inference patterns
proc inferLiteralType*(kind: ExprKind): EtchType =
  ## Infer type for simple literal expressions
  case kind
  of ekInt: return tInt()
  of ekFloat: return tFloat()
  of ekString: return tString()
  of ekChar: return tChar()
  of ekBool: return tBool()
  of ekNil: return tRef(tVoid())
  else: return nil  # Not a simple literal

# Forward declaration
proc simpleInferTypeFromExpr*(expr: Expr; sc: Scope = nil): EtchType

# Simple type inference methods for different expression kinds
proc simpleInferTypeFromCast(expr: Expr; sc: Scope): EtchType =
  ## Cast expressions have the target cast type
  return expr.castType

proc simpleInferTypeFromArray(expr: Expr; sc: Scope): EtchType =
  ## Array literals: infer from first element type
  if expr.elements.len == 0:
    # Empty array, cannot infer element type
    return nil
  let elemType = simpleInferTypeFromExpr(expr.elements[0], sc)
  if elemType == nil:
    return nil
  return tArray(elemType)

proc simpleInferTypeFromNewRef(expr: Expr; sc: Scope): EtchType =
  ## NewRef expressions: infer from initialization type
  let innerType = simpleInferTypeFromExpr(expr.init, sc)
  if innerType == nil:
    return nil
  return tRef(innerType)

proc simpleInferTypeFromUnary(expr: Expr; sc: Scope): EtchType =
  ## Unary expressions: infer from operand type
  case expr.uop
  of uoNeg:
    # Unary negation: infer type from the operand
    let operandType = simpleInferTypeFromExpr(expr.ue, sc)
    if operandType != nil and operandType.kind == tkInt:
      return tInt()
    elif operandType != nil and operandType.kind == tkFloat:
      return tFloat()
    else:
      return nil
  of uoNot:
    # Logical not: should always return bool
    let operandType = simpleInferTypeFromExpr(expr.ue, sc)
    if operandType != nil and operandType.kind == tkBool:
      return tBool()
    else:
      return nil

proc simpleInferTypeFromCall(expr: Expr; sc: Scope): EtchType =
  ## Function calls: handle builtin functions with known return types
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
      let innerType = simpleInferTypeFromExpr(expr.args[0], sc)
      if innerType != nil:
        return tRef(innerType)
      else:
        return nil
    else:
      return nil
  of "deref":
    # deref(ref) returns the inner type of the reference
    if expr.args.len == 1:
      let refType = simpleInferTypeFromExpr(expr.args[0], sc)
      if refType != nil and refType.kind == tkRef:
        return refType.inner
      else:
        return nil
    else:
      return nil
  # Note: # is handled as ekArrayLen, not as a function call
  else:
    # Unknown function call - requires type annotation
    return nil

proc simpleInferTypeFromOptionSome(expr: Expr; sc: Scope): EtchType =
  ## some(value) has type option[T] where T is the type of value
  let innerType = simpleInferTypeFromExpr(expr.someExpr, sc)
  if innerType != nil:
    return tOption(innerType)
  else:
    return nil

proc simpleInferTypeFromResultOk(expr: Expr; sc: Scope): EtchType =
  ## ok(value) has type result[T] where T is the type of value
  let innerType = simpleInferTypeFromExpr(expr.okExpr, sc)
  if innerType != nil:
    return tResult(innerType)
  else:
    return nil

proc simpleInferTypeFromBinary(expr: Expr; sc: Scope): EtchType =
  ## Binary expressions: infer from operand types
  let leftType = simpleInferTypeFromExpr(expr.lhs, sc)
  let rightType = simpleInferTypeFromExpr(expr.rhs, sc)
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

proc simpleInferTypeFromNew(expr: Expr; sc: Scope): EtchType =
  ## new[Type] or new(value) returns ref[Type]
  if expr.newType != nil:
    return tRef(expr.newType)
  elif expr.initExpr.isSome():
    # Type inference from initialization: new(42) -> ref[int]
    let innerType = simpleInferTypeFromExpr(expr.initExpr.get, sc)
    if innerType != nil:
      return tRef(innerType)
    else:
      return nil
  else:
    return nil

proc simpleInferTypeFromDeref(expr: Expr; sc: Scope): EtchType =
  ## Dereference operations: if we can infer the ref type, we can infer the inner type
  let refType = simpleInferTypeFromExpr(expr.refExpr, sc)
  if refType != nil and refType.kind == tkRef:
    return refType.inner
  else:
    return nil

proc simpleInferTypeFromIndex(expr: Expr; sc: Scope): EtchType =
  ## Array/string indexing: arr[i] returns element type
  let arrayType = simpleInferTypeFromExpr(expr.arrayExpr, sc)
  if arrayType != nil:
    case arrayType.kind
    of tkArray:
      return arrayType.inner
    of tkString:
      return tChar()
    else:
      return nil
  else:
    return nil

proc simpleInferTypeFromSlice(expr: Expr; sc: Scope): EtchType =
  ## Slicing: arr[1:3] returns same type as original array/string
  let arrayType = simpleInferTypeFromExpr(expr.sliceExpr, sc)
  if arrayType != nil and arrayType.kind in {tkArray, tkString}:
    return arrayType
  else:
    return nil

proc simpleInferTypeFromVar(expr: Expr; sc: Scope): EtchType =
  ## Variable reference: can infer if scope is available
  if sc != nil and sc.types.hasKey(expr.vname):
    return sc.types[expr.vname]
  else:
    return nil

proc simpleInferTypeFromFieldAccess(expr: Expr; sc: Scope): EtchType =
  ## Field access: obj.field - try to infer if we can determine object type
  if sc != nil:
    let objType = simpleInferTypeFromExpr(expr.objectExpr, sc)
    if objType != nil:
      # Handle reference types - dereference automatically
      var actualObjType = objType
      if objType.kind == tkRef:
        actualObjType = objType.inner

      if actualObjType.kind == tkObject:
        # Look up field in object type
        for field in actualObjType.fields:
          if field.name == expr.fieldName:
            return field.fieldType
      return nil
    else:
      return nil
  else:
    return nil

# Unified type inference that can work in different contexts
proc simpleInferTypeFromExpr*(expr: Expr; sc: Scope = nil): EtchType =
  ## Simple type inference for parsing context - infer type with optional context
  ## This is used when no type annotation is provided in variable declarations
  ## If scope is provided, can resolve variables; otherwise returns nil for variables
  case expr.kind
  of ekInt, ekFloat, ekString, ekChar, ekBool, ekNil:
    return inferLiteralType(expr.kind)
  of ekCast: return simpleInferTypeFromCast(expr, sc)
  of ekArray: return simpleInferTypeFromArray(expr, sc)
  of ekNewRef: return simpleInferTypeFromNewRef(expr, sc)
  of ekUn: return simpleInferTypeFromUnary(expr, sc)
  of ekCall: return simpleInferTypeFromCall(expr, sc)
  of ekOptionSome: return simpleInferTypeFromOptionSome(expr, sc)
  of ekOptionNone: return nil  # Cannot be type-inferred without context
  of ekResultOk: return simpleInferTypeFromResultOk(expr, sc)
  of ekResultErr: return nil  # Cannot be type-inferred without context
  of ekBin: return simpleInferTypeFromBinary(expr, sc)
  of ekObjectLiteral: return nil  # Need type checking context
  of ekNew: return simpleInferTypeFromNew(expr, sc)
  of ekArrayLen: return tInt()  # Array length always returns int
  of ekDeref: return simpleInferTypeFromDeref(expr, sc)
  of ekIndex: return simpleInferTypeFromIndex(expr, sc)
  of ekSlice: return simpleInferTypeFromSlice(expr, sc)
  of ekVar: return simpleInferTypeFromVar(expr, sc)
  of ekFieldAccess: return simpleInferTypeFromFieldAccess(expr, sc)
  of ekMatch: return nil  # Match expressions need full type checker context

# Backward compatibility alias
proc inferTypeFromExpr*(expr: Expr; sc: Scope = nil): EtchType =
  return simpleInferTypeFromExpr(expr, sc)
