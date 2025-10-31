# types.nim
# Type utilities and operations for the type checker

import std/[tables, strformat, options]
import ../frontend/ast, ../common/errors, ../common/types, ../common/builtins


type
  Scope* = ref object
    types*: Table[string, EtchType] # variables
    flags*: Table[string, VarFlag] # variable mutability
    userTypes*: Table[string, EtchType] # user-defined types
    prog*: Program  # Reference to the program for function lookups
  TySubst* = Table[string, EtchType] # generic var -> concrete type


proc typeEq*(a, b: EtchType): bool =
  # Special case: tkUserDefined can match tkObject with same name
  if a.kind != b.kind:
    if (a.kind == tkUserDefined and b.kind == tkObject) or
       (a.kind == tkObject and b.kind == tkUserDefined):
      return a.name == b.name
    return false

  case a.kind
  of tkRef: return typeEq(a.inner, b.inner)
  of tkWeak: return typeEq(a.inner, b.inner)
  of tkArray: return typeEq(a.inner, b.inner)
  of tkOption: return typeEq(a.inner, b.inner)
  of tkResult: return typeEq(a.inner, b.inner)
  of tkGeneric: return a.name == b.name
  of tkUserDefined, tkDistinct, tkObject:
    # For user-defined and object types, check name equality
    return a.name == b.name
  of tkUnion:
    if a.unionTypes.len != b.unionTypes.len: return false
    # Check if all types in a exist in b (order doesn't matter for union equality)
    for aType in a.unionTypes:
      var found = false
      for bType in b.unionTypes:
        if typeEq(aType, bType):
          found = true
          break
      if not found:
        return false
    # Check if all types in b exist in a (to ensure they have exactly the same types)
    for bType in b.unionTypes:
      var found = false
      for aType in a.unionTypes:
        if typeEq(aType, bType):
          found = true
          break
      if not found:
        return false
    return true
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
  of tkWeak: return tWeak(resolveTy(t.inner, subst))
  of tkArray: return tArray(resolveTy(t.inner, subst))
  of tkOption: return tOption(resolveTy(t.inner, subst))
  of tkResult: return tResult(resolveTy(t.inner, subst))
  of tkDistinct:
    let resolvedInner = if t.inner != nil: resolveTy(t.inner, subst) else: nil
    return tDistinct(t.name, resolvedInner)
  of tkUnion:
    var resolvedTypes: seq[EtchType] = @[]
    for ut in t.unionTypes:
      resolvedTypes.add(resolveTy(ut, subst))
    return tUnion(resolvedTypes)
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
  ## Check if we can assign sourceType to targetType for distinct types and unions
  ## Distinct types are only assignable from their base types, not other distinct types
  ## Union types can accept any of their component types
  if targetType.kind == tkUnion:
    # If source is also a union, they need to be equal
    if sourceType.kind == tkUnion:
      return typeEq(targetType, sourceType)
    # If source is not a union, check if it matches any type in the target union
    for unionType in targetType.unionTypes:
      # Direct recursive check
      if canAssignDistinct(unionType, sourceType):
        return true
      # Direct type equality check
      if typeEq(unionType, sourceType):
        return true
      # Special case: Check if a tkUserDefined matches a tkObject with the same name
      if (unionType.kind == tkUserDefined and sourceType.kind == tkObject and
          unionType.name == sourceType.name):
        return true
      # Also the reverse case
      if (unionType.kind == tkObject and sourceType.kind == tkUserDefined and
          unionType.name == sourceType.name):
        return true
    return false
  elif targetType.kind == tkDistinct:
    if sourceType.kind == tkDistinct:
      # Can't assign one distinct type to another, even if same base type
      return false
    else:
      # Can assign base type to distinct type
      return typeEq(targetType.inner, sourceType)
  elif sourceType.kind == tkDistinct:
    # Can't implicitly convert distinct type to base type
    return false
  # Allow ref[T] <-> weak[T] conversions
  elif targetType.kind == tkRef and sourceType.kind == tkWeak and typeEq(targetType.inner, sourceType.inner):
    return true  # weak to strong promotion
  elif targetType.kind == tkWeak and sourceType.kind == tkRef and typeEq(targetType.inner, sourceType.inner):
    return true  # strong to weak conversion
  # Allow nil (ref[void]) to be assigned to weak[T]
  elif sourceType.kind == tkRef and sourceType.inner.kind == tkVoid and targetType.kind == tkWeak:
    return true
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
  of tkWeak:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tWeak(resolvedInner)
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
  ## Function calls: handle builtin functions and imported functions

  # First check if it's a builtin with special inference rules
  if isBuiltin(expr.fname):
    let (_, returnType) = getBuiltinSignature(expr.fname)
    # For builtins with inferred return types, handle specially
    if returnType != nil and returnType.kind != tkInferred:
      return returnType

    # Special cases for builtins with generic returns
    case expr.fname
    of "new":
      # new(value) returns ref[typeof(value)]
      if expr.args.len == 1:
        let innerType = simpleInferTypeFromExpr(expr.args[0], sc)
        if innerType != nil:
          return tRef(innerType)
    of "deref":
      # deref(ref) returns the inner type of the reference
      if expr.args.len == 1:
        let refType = simpleInferTypeFromExpr(expr.args[0], sc)
        if refType != nil and refType.kind == tkRef:
          return refType.inner
      return nil
    else:
      return nil

  # Check if it's a function in the program (imported or defined)
  if sc != nil and sc.prog != nil:
    let overloads = sc.prog.getFunctionOverloads(expr.fname)
    if overloads.len > 0:
      # For simplicity, use the first overload's return type
      # A more sophisticated approach would do overload resolution
      return overloads[0].ret

    # Check if it's an FFI or CFFI import
    for stmt in sc.prog.globals:
      if stmt.kind == skImport and (stmt.importKind == "ffi" or stmt.importKind == "cffi"):
        for item in stmt.importItems:
          if item.itemKind == "function" and item.name == expr.fname:
            # Found the FFI/CFFI function, return its return type
            return item.signature.returnType
  elif sc != nil:
    # If we have scope but no prog, it means the scope wasn't properly initialized
    # Try to look up in global function table (this is a fallback)
    # This shouldn't happen if everything is set up correctly
    discard

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
    # String concatenation: string + string = string
    elif expr.bop == boAdd and leftType.kind == tkString and rightType.kind == tkString:
      return tString()
    # Array concatenation: array[T] + array[T] = array[T]
    elif expr.bop == boAdd and leftType.kind == tkArray and rightType.kind == tkArray:
      if typeEq(leftType.inner, rightType.inner):
        return leftType  # Return array[T] type
      else:
        return nil  # Element types don't match
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
  of boIn, boNotIn:
    # Membership operations: element in array/string = bool
    if rightType.kind == tkArray:
      # Check if left type matches array element type
      if typeEq(leftType, rightType.inner):
        return tBool()
      else:
        return nil
    elif rightType.kind == tkString and leftType.kind == tkString:
      # String in string (substring check)
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
  of ekIf: return nil  # If expressions need full type checker context
  of ekComptime: return simpleInferTypeFromExpr(expr.comptimeExpr, sc)  # Infer type from inner expression
  of ekCompiles: return tBool()  # compiles{...} always returns bool

# Backward compatibility alias
proc inferTypeFromExpr*(expr: Expr; sc: Scope = nil): EtchType =
  return simpleInferTypeFromExpr(expr, sc)
