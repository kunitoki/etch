# types.nim
# Type utilities and operations for the type checker

import std/[tables, strformat]
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
