# types.nim
# Type utilities and operations for the type checker

import std/[tables, strformat, options]
import ../../common/[errors, types, builtins]
import ../frontend/ast


type
  Scope* = ref object
    types*: Table[string, EtchType] # variables
    flags*: Table[string, VarFlag] # variable mutability
    userTypes*: Table[string, EtchType] # user-defined types
    prog*: Program  # Reference to the program for function lookups

  TySubst* = Table[string, EtchType] # generic var -> concrete type

  ReturnTypePendingError* = ref object of CatchableError
    missingFunction*: string

  ReturnInfo* = object
    typ*: EtchType
    pos*: Pos
    hasValue*: bool


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
  of tkTypeDesc: return true
  of tkOption: return typeEq(a.inner, b.inner)
  of tkResult: return typeEq(a.inner, b.inner)
  of tkCoroutine: return typeEq(a.inner, b.inner)
  of tkChannel: return typeEq(a.inner, b.inner)
  of tkGeneric: return a.name == b.name
  of tkUserDefined, tkDistinct, tkObject, tkEnum:
    # For user-defined, object, and enum types, check name equality
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
  of tkTuple:
    if a.tupleTypes.len != b.tupleTypes.len: return false
    # For tuples, order matters
    for i in 0..<a.tupleTypes.len:
      if not typeEq(a.tupleTypes[i], b.tupleTypes[i]):
        return false
    return true
  of tkFunction:
    if a.funcParams.len != b.funcParams.len:
      return false
    for i in 0..<a.funcParams.len:
      if not typeEq(a.funcParams[i], b.funcParams[i]):
        return false
    return typeEq(a.funcReturn, b.funcReturn)
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
  of tkTypeDesc: return tTypeDesc()
  of tkOption: return tOption(resolveTy(t.inner, subst))
  of tkResult: return tResult(resolveTy(t.inner, subst))
  of tkCoroutine: return tCoroutine(resolveTy(t.inner, subst))
  of tkChannel: return tChannel(resolveTy(t.inner, subst))
  of tkDistinct:
    let resolvedInner = if t.inner != nil: resolveTy(t.inner, subst) else: nil
    return tDistinct(t.name, resolvedInner)
  of tkUnion:
    var resolvedTypes: seq[EtchType] = @[]
    for ut in t.unionTypes:
      resolvedTypes.add(resolveTy(ut, subst))
    return tUnion(resolvedTypes)
  of tkTuple:
    var resolvedTypes: seq[EtchType] = @[]
    for tt in t.tupleTypes:
      resolvedTypes.add(resolveTy(tt, subst))
    return tTuple(resolvedTypes)
  of tkFunction:
    var resolvedParams: seq[EtchType] = @[]
    for pt in t.funcParams:
      resolvedParams.add(resolveTy(pt, subst))
    let resolvedRet = if t.funcReturn != nil: resolveTy(t.funcReturn, subst) else: tVoid()
    return tFunction(resolvedParams, resolvedRet)
  of tkInt, tkFloat, tkString, tkChar, tkBool, tkVoid, tkUserDefined, tkObject, tkEnum: return t
  of tkInferred:
    # Inferred types should have been resolved by the time we reach resolveTy
    raise newTypecheckError(Pos(), "unresolved inferred type encountered in resolveTy")


proc resolveUserType*(scope: Scope, typeName: string): EtchType =
  ## Resolve a user-defined type from scope
  if scope.userTypes.hasKey(typeName):
    return scope.userTypes[typeName]
  else:
    return nil


proc findEnumMember*(enumType: EtchType, memberName: string): Option[EnumMember] =
  ## Locate an enum member by name.
  if enumType.isNil or enumType.kind != tkEnum:
    return none(EnumMember)
  for member in enumType.enumMembers:
    if member.name == memberName:
      return some(member)
  return none(EnumMember)


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
  elif targetType.kind == tkFunction and sourceType.kind == tkFunction:
    if targetType.funcParams.len != sourceType.funcParams.len:
      return false
    for i in 0..<targetType.funcParams.len:
      if not canAssignDistinct(targetType.funcParams[i], sourceType.funcParams[i]):
        return false
    return canAssignDistinct(targetType.funcReturn, sourceType.funcReturn)
  elif targetType.kind == tkTypeDesc and sourceType.kind == tkTypeDesc:
    # All typedesc types are assignable to each other
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
  of tkCoroutine:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tCoroutine(resolvedInner)
  of tkChannel:
    # Recursively resolve the inner type
    let resolvedInner = resolveNestedUserTypes(sc, typ.inner, pos)
    return tChannel(resolvedInner)
  of tkTuple:
    # Recursively resolve all tuple element types
    var resolvedTypes: seq[EtchType] = @[]
    for tt in typ.tupleTypes:
      resolvedTypes.add(resolveNestedUserTypes(sc, tt, pos))
    return tTuple(resolvedTypes)
  of tkFunction:
    var resolvedParams: seq[EtchType] = @[]
    for pt in typ.funcParams:
      resolvedParams.add(resolveNestedUserTypes(sc, pt, pos))
    let resolvedRet = if typ.funcReturn != nil: resolveNestedUserTypes(sc, typ.funcReturn, pos) else: tVoid()
    return tFunction(resolvedParams, resolvedRet)
  else:
    # For primitive types and other types, no resolution needed
    return typ


# Forward declaration
proc inferTypeFromExpression*(expr: Expression; sc: Scope = nil): EtchType


# Helper functions for common type inference patterns
proc inferLiteralType*(kind: ExpressionKind): EtchType =
  ## Infer type for simple literal expressions
  case kind
  of ekInt: return tInt()
  of ekFloat: return tFloat()
  of ekString: return tString()
  of ekChar: return tChar()
  of ekBool: return tBool()
  of ekNil: return tRef(tVoid())
  else: return nil  # Not a simple literal


# Simple type inference methods for different expression kinds
proc inferTypeFromCast(expr: Expression; sc: Scope): EtchType =
  ## Cast expressions have the target cast type
  return expr.castType


proc inferTypeFromArray(expr: Expression; sc: Scope): EtchType =
  ## Array literals: infer from first element type
  if expr.elements.len == 0:
    # Empty array, cannot infer element type
    return nil
  let elemType = inferTypeFromExpression(expr.elements[0], sc)
  if elemType == nil:
    return nil
  return tArray(elemType)


proc inferTypeFromTuple(expr: Expression; sc: Scope): EtchType =
  ## Tuple literals: infer from all element types
  var elemTypes: seq[EtchType] = @[]
  for elem in expr.tupleElements:
    let elemType = inferTypeFromExpression(elem, sc)
    if elemType == nil:
      return nil
    elemTypes.add(elemType)
  return tTuple(elemTypes)


proc inferTypeFromNewRef(expr: Expression; sc: Scope): EtchType =
  ## NewRef expressions: infer from initialization type
  let innerType = inferTypeFromExpression(expr.init, sc)
  if innerType == nil:
    return nil
  return tRef(innerType)


proc inferTypeFromUnary(expr: Expression; sc: Scope): EtchType =
  ## Unary expressions: infer from operand type
  case expr.uop
  of uoNeg:
    # Unary negation: infer type from the operand
    let operandType = inferTypeFromExpression(expr.ue, sc)
    if operandType != nil and operandType.kind == tkInt:
      return tInt()
    elif operandType != nil and operandType.kind == tkFloat:
      return tFloat()
    else:
      return nil
  of uoNot:
    # Logical not: should always return bool
    let operandType = inferTypeFromExpression(expr.ue, sc)
    if operandType != nil and operandType.kind == tkBool:
      return tBool()
    else:
      return nil


proc inferTypeFromCall(expr: Expression; sc: Scope): EtchType =
  ## Function calls: handle builtin functions and imported functions

  if expr.callTarget != nil:
    let calleeType = inferTypeFromExpression(expr.callTarget, sc)
    if calleeType != nil and calleeType.kind == tkFunction:
      return calleeType.funcReturn

  # First check if it's a builtin with special inference rules
  if isBuiltin(expr.fname):
    # For builtins with inferred return types, handle specially
    let (_, returnType) = getBuiltinSignature(expr.fname)
    if returnType != nil and returnType.kind != tkInferred:
      return returnType

    # Special cases for builtins with generic returns
    case expr.fname
    of "new":
      # new(value) returns ref[typeof(value)]
      if expr.args.len == 1:
        let innerType = inferTypeFromExpression(expr.args[0], sc)
        if innerType != nil:
          return tRef(innerType)
    of "deref":
      # deref(ref) returns the inner type of the reference
      if expr.args.len == 1:
        let refType = inferTypeFromExpression(expr.args[0], sc)
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

    # Check if it's an C FFI import
    for stmt in sc.prog.globals:
      if stmt.kind == skImport and stmt.importKind == "cffi":
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


proc inferTypeFromOptionSome(expr: Expression; sc: Scope): EtchType =
  ## some(value) has type option[T] where T is the type of value
  let innerType = inferTypeFromExpression(expr.someExpression, sc)
  if innerType != nil:
    return tOption(innerType)
  else:
    return nil


proc inferTypeFromResultOk(expr: Expression; sc: Scope): EtchType =
  ## ok(value) has type result[T] where T is the type of value
  let innerType = inferTypeFromExpression(expr.okExpression, sc)
  if innerType != nil:
    return tResult(innerType)
  else:
    return nil


proc inferTypeFromBinary(expr: Expression; sc: Scope): EtchType =
  ## Binary expressions: infer from operand types
  let leftType = inferTypeFromExpression(expr.lhs, sc)
  let rightType = inferTypeFromExpression(expr.rhs, sc)
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
    # Tuple concatenation: tuple[T1, T2] + tuple[T3, T4] = tuple[T1, T2, T3, T4]
    elif expr.bop == boAdd and leftType.kind == tkTuple and rightType.kind == tkTuple:
      var combinedTypes: seq[EtchType] = @[]
      for elemType in leftType.tupleTypes:
        combinedTypes.add(elemType)
      for elemType in rightType.tupleTypes:
        combinedTypes.add(elemType)
      return tTuple(combinedTypes)
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


proc inferTypeFromNew(expr: Expression; sc: Scope): EtchType =
  ## new[Type] or new(value) returns ref[Type]
  if expr.newType != nil:
    return tRef(expr.newType)
  elif expr.initExpression.isSome():
    # Type inference from initialization: new(42) -> ref[int]
    let innerType = inferTypeFromExpression(expr.initExpression.get, sc)
    if innerType != nil:
      return tRef(innerType)
    else:
      return nil
  else:
    return nil


proc inferTypeFromDeref(expr: Expression; sc: Scope): EtchType =
  ## Dereference operations: if we can infer the ref type, we can infer the inner type
  let refType = inferTypeFromExpression(expr.refExpression, sc)
  if refType != nil and refType.kind == tkRef:
    return refType.inner
  else:
    return nil


proc inferTypeFromIndex(expr: Expression; sc: Scope): EtchType =
  ## Array/string/tuple indexing: arr[i] returns element type
  let arrayType = inferTypeFromExpression(expr.arrayExpression, sc)
  if arrayType != nil:
    case arrayType.kind
    of tkArray:
      return arrayType.inner
    of tkString:
      return tChar()
    of tkTuple:
      # For tuples, we need a compile-time constant index
      if expr.indexExpression.kind == ekInt:
        let index = expr.indexExpression.ival
        if index >= 0 and index < arrayType.tupleTypes.len:
          return arrayType.tupleTypes[index]
      return nil
    else:
      return nil
  else:
    return nil


proc inferTypeFromSlice(expr: Expression; sc: Scope): EtchType =
  ## Slicing: arr[1:3] returns same type as original array/string
  ## For tuples, returns a new tuple type with the sliced elements

  # If the expression already has a type set (from type checking), use it
  if expr.typ != nil:
    return expr.typ

  let arrayType = inferTypeFromExpression(expr.sliceExpression, sc)
  if arrayType != nil and arrayType.kind in {tkArray, tkString}:
    return arrayType
  elif arrayType != nil and arrayType.kind == tkTuple:
    # For tuple slicing, we need compile-time indices to determine the result type
    # If both start and end are literal integers, we can infer the sliced tuple type
    if (expr.startExpression.isNone or expr.startExpression.get.kind == ekInt) and (expr.endExpression.isNone or expr.endExpression.get.kind == ekInt):
      let startIdx = if expr.startExpression.isSome: expr.startExpression.get.ival else: 0
      let endIdx = if expr.endExpression.isSome: expr.endExpression.get.ival else: arrayType.tupleTypes.len

      if startIdx >= 0 and endIdx <= arrayType.tupleTypes.len and startIdx <= endIdx:
        var slicedTypes: seq[EtchType] = @[]
        for i in startIdx..<endIdx:
          slicedTypes.add(arrayType.tupleTypes[i])
        return tTuple(slicedTypes)

  return nil


proc inferTypeFromVar(expr: Expression; sc: Scope): EtchType =
  ## Variable reference: can infer if scope is available
  if sc != nil and sc.types.hasKey(expr.vname):
    return sc.types[expr.vname]
  else:
    return nil


proc inferTypeFromFieldAccess(expr: Expression; sc: Scope): EtchType =
  ## Field access: obj.field - try to infer if we can determine object type
  if sc != nil:
    # Special handling for enum type member access: TypeName.MemberName
    if expr.objectExpression.kind == ekVar:
      let typeName = expr.objectExpression.vname
      # Check if this looks like an enum type name in program types
      if sc.prog != nil and sc.prog.types.hasKey(typeName):
        let typeDef = sc.prog.types[typeName]
        if typeDef.kind == tkEnum:
          let memberOpt = findEnumMember(typeDef, expr.fieldName)
          if memberOpt.isSome:
            expr.enumTargetType = typeDef
            expr.enumResolvedMember = memberOpt
            return typeDef
        return nil
      # Also check scope userTypes
      elif sc.userTypes.hasKey(typeName):
        let typeDef = sc.userTypes[typeName]
        if typeDef.kind == tkEnum:
          let memberOpt = findEnumMember(typeDef, expr.fieldName)
          if memberOpt.isSome:
            expr.enumTargetType = typeDef
            expr.enumResolvedMember = memberOpt
            return typeDef
        return nil

    let objType = inferTypeFromExpression(expr.objectExpression, sc)
    if objType != nil:
      # Handle reference types - dereference automatically
      # TODO: is this a good idea? What about weak refs?
      var actualObjType = objType
      if objType.kind == tkRef:
        actualObjType = objType.inner

      if actualObjType.kind == tkObject:
        # Look up field in object type
        for field in actualObjType.fields:
          if field.name == expr.fieldName:
            return field.fieldType
      elif actualObjType.kind == tkEnum:
        raise newTypecheckError(expr.pos, &"cannot access member '{expr.fieldName}' on enum value of type '{actualObjType.name}'. Use enum type access like '{actualObjType.name}.{expr.fieldName}' instead")

  return nil


# Unified type inference that can work in different contexts
proc inferTypeFromExpression*(expr: Expression; sc: Scope = nil): EtchType =
  ## Simple type inference for parsing context - infer type with optional context
  ## This is used when no type annotation is provided in variable declarations
  ## If scope is provided, can resolve variables; otherwise returns nil for variables
  case expr.kind
  of ekInt, ekFloat, ekString, ekChar, ekBool, ekNil: return inferLiteralType(expr.kind)
  of ekCast: return inferTypeFromCast(expr, sc)
  of ekArray: return inferTypeFromArray(expr, sc)
  of ekNewRef: return inferTypeFromNewRef(expr, sc)
  of ekUn: return inferTypeFromUnary(expr, sc)
  of ekCall: return inferTypeFromCall(expr, sc)
  of ekOptionSome: return inferTypeFromOptionSome(expr, sc)
  of ekOptionNone: return nil  # Cannot be type-inferred without context
  of ekResultOk: return inferTypeFromResultOk(expr, sc)
  of ekResultErr: return nil  # Cannot be type-inferred without context
  of ekResultPropagate: return nil  # Requires surrounding result context
  of ekTypeof: return tTypeDesc()
  of ekBin: return inferTypeFromBinary(expr, sc)
  of ekObjectLiteral: return nil  # Need type checking context
  of ekNew: return inferTypeFromNew(expr, sc)
  of ekArrayLen: return tInt()  # Array length always returns int
  of ekDeref: return inferTypeFromDeref(expr, sc)
  of ekIndex: return inferTypeFromIndex(expr, sc)
  of ekSlice: return inferTypeFromSlice(expr, sc)
  of ekVar: return inferTypeFromVar(expr, sc)
  of ekFieldAccess: return inferTypeFromFieldAccess(expr, sc)
  of ekMatch: return nil  # Match expressions need full type checker context
  of ekIf: return nil  # If expressions need full type checker context
  of ekComptime: return inferTypeFromExpression(expr.comptimeExpression, sc)  # Infer type from inner expression
  of ekCompiles: return tBool()  # compiles{...} always returns bool
  of ekTuple: return inferTypeFromTuple(expr, sc)
  of ekYield: return nil  # Yield type depends on function context
  of ekResume:
    # Resume returns result[T] from coroutine[T]
    let coroType = inferTypeFromExpression(expr.resumeValue, sc)
    if coroType != nil and coroType.kind == tkCoroutine and coroType.inner != nil:
      return tResult(coroType.inner)
    else:
      return nil  # Type error will be caught by full type checker
  of ekSpawn:
    # Spawn returns coroutine[T] where T is the return type of the spawned expression
    let innerType = inferTypeFromExpression(expr.spawnExpression, sc)
    if innerType != nil and innerType.kind == tkCoroutine:
      return innerType  # Already async, return as-is
    elif innerType != nil:
      return tCoroutine(innerType)  # Wrap in async
    else:
      return nil
  of ekSpawnBlock: return nil  # Spawn block type needs full type checker context
  of ekChannelNew: return tChannel(expr.channelType)
  of ekChannelSend: return tVoid()  # Send operations return void
  of ekChannelRecv:
    # Receive returns the channel's element type
    let chanType = inferTypeFromExpression(expr.recvChannel, sc)
    if chanType != nil and chanType.kind == tkChannel:
      return chanType.inner
    else:
      return nil
  of ekLambda:
    # Lambda expressions need full type checker context to resolve parameter and return types
    return nil
