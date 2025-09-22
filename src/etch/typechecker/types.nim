# types.nim
# Type utilities and operations for the type checker

import std/[tables, strformat]
import ../frontend/ast, ../errors


type
  Scope* = ref object
    types*: Table[string, EtchType] # variables
    flags*: Table[string, VarFlag] # variable mutability
  TySubst* = Table[string, EtchType] # generic var -> concrete type


proc typeEq*(a, b: EtchType): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tkRef: return typeEq(a.inner, b.inner)
  of tkArray: return typeEq(a.inner, b.inner)
  of tkGeneric: return a.name == b.name
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
  of tkInt, tkFloat, tkString, tkChar, tkBool, tkVoid: return t
