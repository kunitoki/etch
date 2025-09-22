# expressions.nim
# Expression type inference for the type checker

import std/[strformat, options, sequtils, tables]
import ../frontend/ast, ../errors
import types

proc inferExprTypes*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst): EtchType

# Builtin function type inference
proc inferCallBuiltinPrint(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len != 1: raise newTypecheckError(e.pos, "print expects 1 argument")
  let t0 = inferExprTypes(prog, nil, sc, e.args[0], subst)
  if not (t0.kind in {tkBool, tkInt, tkFloat, tkString}): raise newTypecheckError(e.pos, "print supports bool/int/float/string")
  e.instTypes = @[]
  e.typ = tVoid()
  return e.typ

proc inferCallBuiltinNew(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len != 1: raise newTypecheckError(e.pos, "new expects 1 argument")
  let t0 = inferExprTypes(prog, nil, sc, e.args[0], subst)
  let rt = tRef(t0)
  e.typ = rt
  return rt

proc inferCallBuiltinDeref(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len != 1: raise newTypecheckError(e.pos, "deref expects 1 argument")
  let t0 = inferExprTypes(prog, nil, sc, e.args[0], subst)
  if t0.kind != tkRef: raise newTypecheckError(e.pos, "deref expects Ref[...]")
  e.typ = t0.inner
  return e.typ

proc inferCallBuiltinRand(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len < 1 or e.args.len > 2:
    raise newTypecheckError(e.pos, "rand expects 1 or 2 arguments")
  # First arg is max (required)
  let maxType = inferExprTypes(prog, nil, sc, e.args[0], subst)
  if maxType.kind != tkInt:
    raise newTypecheckError(e.pos, "rand max argument must be int")
  # Second arg is min (optional, defaults to 0)
  if e.args.len == 2:
    let minType = inferExprTypes(prog, nil, sc, e.args[1], subst)
    if minType.kind != tkInt:
      raise newTypecheckError(e.pos, "rand min argument must be int")
  e.instTypes = @[]
  e.typ = tInt()
  return e.typ

proc inferCallBuiltinReadFile(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len != 1: raise newTypecheckError(e.pos, "readFile expects 1 argument")
  let pathType = inferExprTypes(prog, nil, sc, e.args[0], subst)
  if pathType.kind != tkString:
    raise newTypecheckError(e.pos, "readFile expects string path")
  e.instTypes = @[]
  e.typ = tString()
  return e.typ

proc inferCallBuiltinInject(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len != 3: raise newTypecheckError(e.pos, "inject expects 3 arguments: name, type, value")
  let nameType = inferExprTypes(prog, nil, sc, e.args[0], subst)
  let typeType = inferExprTypes(prog, nil, sc, e.args[1], subst)
  discard inferExprTypes(prog, nil, sc, e.args[2], subst)  # value can be any type
  if nameType.kind != tkString or typeType.kind != tkString:
    raise newTypecheckError(e.pos, "inject name and type arguments must be strings")
  e.instTypes = @[]
  e.typ = tVoid()
  return e.typ

proc inferCallBuiltinSeed(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if e.args.len > 1: raise newTypecheckError(e.pos, "seed expects 0 or 1 argument")
  if e.args.len == 1:
    let seedType = inferExprTypes(prog, nil, sc, e.args[0], subst)
    if seedType.kind != tkInt:
      raise newTypecheckError(e.pos, "seed expects int argument")
  e.instTypes = @[]
  e.typ = tVoid()
  return e.typ

# Function call type checking and monomorphization
proc inferCall(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  if not prog.funs.hasKey(e.fname):
    raise newTypecheckError(e.pos, "unknown function: " & e.fname)

  let templ = prog.funs[e.fname]
  # build local substitution mapping for typarams
  var localSubst: TySubst
  for p in templ.typarams:
    # if concept specified, we will verify after inference binds a concrete type
    discard

  # Count required parameters (those without defaults)
  var requiredParams = 0
  for p in templ.params:
    if p.defaultValue.isNone:
      requiredParams += 1

  # Validate argument count considering defaults
  if e.args.len < requiredParams or e.args.len > templ.params.len:
    raise newTypecheckError(e.pos, &"function {templ.name} expected {requiredParams}-{templ.params.len} arguments, got {e.args.len}")

  var argTypes: seq[EtchType] = @[]
  for i, a in e.args:
    let ta = inferExprTypes(prog, templ, sc, a, subst)
    argTypes.add ta
    let pt = templ.params[i].typ
    # unify pt (may include generics) with ta
    proc unify(pat, got: EtchType) =
      case pat.kind
      of tkGeneric:
        if pat.name in localSubst:
          if not typeEq(localSubst[pat.name], got):
            raise newTypecheckError(e.pos, &"type mismatch for {pat.name}: {localSubst[pat.name]} vs {got}")
        else:
          localSubst[pat.name] = got
      of tkRef:
        if got.kind != tkRef: raise newTypecheckError(e.pos, "expected Ref[...]")
        unify(pat.inner, got.inner)
      else:
        if not typeEq(pat, got): raise newTypecheckError(e.pos, &"type mismatch: expected {pat}, got {got}")
    unify(pt, ta)

  # check concept constraints
  for p in templ.typarams:
    if p.koncept.isSome():
      let c = p.koncept.get()
      if not localSubst.hasKey(p.name):
        raise newTypecheckError(e.pos, &"cannot resolve type parameter {p.name} for concept {c}")
      requireConcept(prog.concepts, localSubst[p.name], c)

  # ret type resolution
  let retT = resolveTy(templ.ret, localSubst)
  e.instTypes = templ.typarams.mapIt(localSubst.getOrDefault(it.name, tGeneric(it.name)))
  e.typ = retT

  # Create a monomorphized instance key: name<types>
  var key = templ.name & "<"
  for i, tv in templ.typarams:
    if i>0: key.add ","
    key.add $resolveTy(tGeneric(tv.name), localSubst)
  key.add ">"
  if not prog.funInstances.hasKey(key):
    # clone templ with all types resolved
    let inst = FunDecl(name: key, typarams: @[], params: @[], ret: retT, body: @[])
    for pr in templ.params:
      inst.params.add Param(name: pr.name, typ: resolveTy(pr.typ, localSubst), defaultValue: pr.defaultValue)
    # deep copy body references not needed for this MVP; reuse
    inst.body = templ.body
    prog.funInstances[key] = inst
  # mutate call to target the instance symbol (for codegen / VM)
  e.fname = key
  return retT

proc inferExprTypes*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  case e.kind
  of ekInt: e.typ = tInt(); return e.typ
  of ekFloat: e.typ = tFloat(); return e.typ
  of ekString: e.typ = tString(); return e.typ
  of ekBool: e.typ = tBool(); return e.typ
  of ekNil:
    # nil has a special type that can be compared to any reference type
    e.typ = tRef(tVoid()); return e.typ  # Use Ref[void] as the nil type
  of ekVar:
    if not sc.types.hasKey(e.vname):
      raise newTypecheckError(e.pos, &"use of undeclared variable '{e.vname}'")
    e.typ = sc.types[e.vname]; return e.typ
  of ekUn:
    let t0 = inferExprTypes(prog, fd, sc, e.ue, subst)
    case e.uop
    of uoNeg:
      if t0.kind == tkInt:
        e.typ = tInt(); return e.typ
      elif t0.kind == tkFloat:
        e.typ = tFloat(); return e.typ
      else:
        raise newTypecheckError(e.pos, "unary - requires int or float")
    of uoNot:
      if t0.kind != tkBool: raise newTypecheckError(e.pos, "not on non-bool")
      e.typ = tBool(); return e.typ
  of ekBin:
    let lt = inferExprTypes(prog, fd, sc, e.lhs, subst)
    let rt = inferExprTypes(prog, fd, sc, e.rhs, subst)
    case e.bop
    of boAdd, boSub, boMul, boDiv, boMod:
      if lt.kind == tkInt and rt.kind == tkInt:
        e.typ = tInt(); return e.typ
      elif lt.kind == tkFloat and rt.kind == tkFloat:
        e.typ = tFloat(); return e.typ
      else:
        raise newTypecheckError(e.pos, &"arithmetic operation requires matching types, got {lt} and {rt}. Use explicit casts like int(x) or float(x)")
    of boEq, boNe, boLt, boLe, boGt, boGe:
      # Special handling for nil comparisons
      if (lt.kind == tkRef and rt.kind == tkRef) and
         (lt.inner.kind == tkVoid or rt.inner.kind == tkVoid):
        # Allow comparison between any reference type and nil (Ref[void])
        if e.bop notin {boEq, boNe}:
          raise newTypecheckError(e.pos, &"only == and != are allowed for reference comparisons")
        e.typ = tBool(); return e.typ
      elif lt.kind != rt.kind:
        raise newTypecheckError(e.pos, &"comparison type mismatch: {lt} vs {rt}")
      else:
        # Only allow comparison operators on comparable types
        if lt.kind notin {tkInt, tkFloat, tkString, tkBool, tkRef}:
          raise newTypecheckError(e.pos, &"comparison not supported for type {lt}")
        # Only equality operators allowed for references
        if lt.kind == tkRef and e.bop notin {boEq, boNe}:
          raise newTypecheckError(e.pos, &"only == and != are allowed for reference comparisons")
        e.typ = tBool(); return e.typ
    of boAnd, boOr:
      if lt.kind != tkBool or rt.kind != tkBool: raise newTypecheckError(e.pos, "and/or expects bool")
      e.typ = tBool(); return e.typ
  of ekCall:
    # Handle builtins first
    case e.fname
      of "print": return inferCallBuiltinPrint(prog, sc, e, subst)
      of "new": return inferCallBuiltinNew(prog, sc, e, subst)
      of "deref": return inferCallBuiltinDeref(prog, sc, e, subst)
      of "rand": return inferCallBuiltinRand(prog, sc, e, subst)
      of "readFile": return inferCallBuiltinReadFile(prog, sc, e, subst)
      of "inject": return inferCallBuiltinInject(prog, sc, e, subst)
      of "seed": return inferCallBuiltinSeed(prog, sc, e, subst)
      else:
        # Regular function call - handle monomorphization
        return inferCall(prog, sc, e, subst)
  of ekNewRef:
    let t0 = inferExprTypes(prog, fd, sc, e.init, subst)
    e.refInner = t0
    e.typ = tRef(t0)
    return e.typ
  of ekDeref:
    let t0 = inferExprTypes(prog, fd, sc, e.refExpr, subst)
    if t0.kind != tkRef: raise newTypecheckError(e.pos, "deref expects Ref[...]")
    e.typ = t0.inner
    return e.typ
  of ekArray:
    # Array literal: [elem1, elem2, ...] - infer element type from first element
    if e.elements.len == 0:
      raise newTypecheckError(e.pos, "empty arrays not supported - cannot infer element type")
    let elemType = inferExprTypes(prog, fd, sc, e.elements[0], subst)
    # Verify all elements have the same type
    for i in 1..<e.elements.len:
      let t = inferExprTypes(prog, fd, sc, e.elements[i], subst)
      if not typeEq(elemType, t):
        raise newTypecheckError(e.elements[i].pos, &"array element type mismatch: expected {elemType}, got {t}")
    e.typ = tArray(elemType)
    return e.typ
  of ekIndex:
    let arrayType = inferExprTypes(prog, fd, sc, e.arrayExpr, subst)
    let indexType = inferExprTypes(prog, fd, sc, e.indexExpr, subst)
    if arrayType.kind != tkArray:
      raise newTypecheckError(e.pos, &"indexing requires array type, got {arrayType}")
    if indexType.kind != tkInt:
      raise newTypecheckError(e.indexExpr.pos, &"array index must be int, got {indexType}")
    e.typ = arrayType.inner
    return e.typ
  of ekSlice:
    let arrayType = inferExprTypes(prog, fd, sc, e.sliceExpr, subst)
    if arrayType.kind != tkArray:
      raise newTypecheckError(e.pos, &"slicing requires array type, got {arrayType}")
    # Check start expression if present
    if e.startExpr.isSome:
      let startType = inferExprTypes(prog, fd, sc, e.startExpr.get, subst)
      if startType.kind != tkInt:
        raise newTypecheckError(e.startExpr.get.pos, &"slice start must be int, got {startType}")
    # Check end expression if present
    if e.endExpr.isSome:
      let endType = inferExprTypes(prog, fd, sc, e.endExpr.get, subst)
      if endType.kind != tkInt:
        raise newTypecheckError(e.endExpr.get.pos, &"slice end must be int, got {endType}")
    # Slicing returns the same array type
    e.typ = arrayType
    return e.typ
  of ekArrayLen:
    # Array length operator: #array -> int
    let arrayType = inferExprTypes(prog, fd, sc, e.lenExpr, subst)
    if arrayType.kind != tkArray:
      raise newTypecheckError(e.pos, &"length operator # requires array type, got {arrayType}")
    e.typ = tInt()
    return e.typ
  of ekCast:
    # Explicit type cast: type(expr)
    let fromType = inferExprTypes(prog, fd, sc, e.castExpr, subst)
    let toType = e.castType

    # Define allowed conversions
    var castAllowed = false
    if (fromType.kind == tkInt and toType.kind == tkFloat) or
       (fromType.kind == tkFloat and toType.kind == tkInt) or
       (fromType.kind == tkInt and toType.kind == tkString) or
       (fromType.kind == tkFloat and toType.kind == tkString):
      castAllowed = true

    if not castAllowed:
      raise newTypecheckError(e.pos, &"invalid cast from {fromType} to {toType}")

    e.typ = toType
    return e.typ