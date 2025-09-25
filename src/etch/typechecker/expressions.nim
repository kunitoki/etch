# expressions.nim
# Expression type inference for the type checker

import std/[strformat, options, sequtils, tables, strutils]
import ../frontend/ast, ../common/[errors, types as commonTypes]
import ../common/builtins
import types



# Convert BinOp to operator symbol string for user-defined operator lookup
proc binOpToString(bop: BinOp): string =
  case bop
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDiv: "/"
  of boMod: "%"
  of boEq: "=="
  of boNe: "!="
  of boLt: "<"
  of boLe: "<="
  of boGt: ">"
  of boGe: ">="
  of boAnd: "and"  # These remain keywords, not symbols
  of boOr: "or"


# Check if a function name represents an operator function (including mangled names)
proc isOperatorFunction(name: string): bool =
  let baseName = if "_" in name: name.split("_")[0] else: name
  baseName in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">="]

# Helper to convert EtchError to TypecheckError for built-in type checking
proc convertBuiltinError(err: ref EtchError, pos: Pos): ref TypecheckError =
  newTypecheckError(pos, err.msg)

proc inferExprTypes*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst; expectedTy: EtchType = nil): EtchType


# All built-in function type checking is now handled by the unified registry in common/builtins.nim


# Function call type checking and monomorphization
# Overload resolution helper
proc resolveOverload(prog: Program; sc: Scope; e: Expr; subst: var TySubst): FunDecl =
  ## Resolve function overload based on argument types

  # Check if this is already a mangled function instance name
  if prog.funInstances.hasKey(e.fname):
    return prog.funInstances[e.fname]

  let overloads = prog.getFunctionOverloads(e.fname)
  if overloads.len == 0:
    raise newTypecheckError(e.pos, "unknown function: " & e.fname)

  # First pass: infer argument types
  var argTypes: seq[EtchType] = @[]
  for arg in e.args:
    let argType = inferExprTypes(prog, nil, sc, arg, subst)
    argTypes.add(argType)

  # Find exact matches first
  var exactMatches: seq[FunDecl] = @[]
  for overload in overloads:
    # Check parameter count considering default parameters
    var requiredParams = 0
    for p in overload.params:
      if p.defaultValue.isNone:
        requiredParams += 1

    if argTypes.len >= requiredParams and argTypes.len <= overload.params.len:
      # Check if argument types match exactly
      var isExactMatch = true
      for i, argType in argTypes:
        let paramType = overload.params[i].typ
        if paramType.kind != tkGeneric and not typeEq(argType, paramType):
          isExactMatch = false
          break
      if isExactMatch:
        exactMatches.add(overload)

  if exactMatches.len == 1:
    return exactMatches[0]
  elif exactMatches.len > 1:
    raise newTypecheckError(e.pos, &"ambiguous function call: multiple exact matches for {e.fname}")
  else:
    # If no exact matches, try generic matches (for now, just take the first one)
    # TODO: Implement more sophisticated overload resolution with generics
    for overload in overloads:
      var requiredParams = 0
      for p in overload.params:
        if p.defaultValue.isNone:
          requiredParams += 1
      if argTypes.len >= requiredParams and argTypes.len <= overload.params.len:
        return overload

    # No suitable overload found
    var availableSignatures = ""
    for i, overload in overloads:
      if i > 0: availableSignatures.add("; ")
      availableSignatures.add(overload.name & "(")
      for j, param in overload.params:
        if j > 0: availableSignatures.add(", ")
        availableSignatures.add($param.typ)
      availableSignatures.add(")")
    raise newTypecheckError(e.pos, &"no matching overload for {e.fname} with arguments ({argTypes.join(\", \")}). Available: {availableSignatures}")


proc inferCall(prog: Program; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  let templ = resolveOverload(prog, sc, e, subst)
  # build local substitution mapping for typarams
  var localSubst: TySubst
  for p in templ.typarams:
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

  # ret type resolution
  let retT = resolveTy(templ.ret, localSubst)
  e.instTypes = templ.typarams.mapIt(localSubst.getOrDefault(it.name, tGeneric(it.name)))
  e.typ = retT

  # Create a monomorphized instance key: name<types> or overload signature for non-generic overloads
  var key = ""
  if templ.typarams.len == 0:
    # Non-generic function - use overload signature for uniqueness
    key = generateOverloadSignature(templ)
  else:
    # Generic function - use traditional generic signature: name<types>
    key = templ.name & "<"
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


proc inferExprTypes*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  case e.kind
  of ekInt: e.typ = tInt(); return e.typ
  of ekFloat: e.typ = tFloat(); return e.typ
  of ekString: e.typ = tString(); return e.typ
  of ekChar: e.typ = tChar(); return e.typ
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

    # Try user-defined operator overload first (except for logical operators)
    # Skip operator overloading if we're currently inside an operator function to avoid infinite recursion
    if e.bop notin {boAnd, boOr} and (fd == nil or not isOperatorFunction(fd.name)):
      let opName = binOpToString(e.bop)
      # Check if a user-defined operator exists for these argument types
      for fname, fdecls in prog.funs:
        if fname == opName:
          for fdecl in fdecls:
            if fdecl.params.len == 2:
              # Try to match parameter types with our argument types
              let param1Type = fdecl.params[0].typ
              let param2Type = fdecl.params[1].typ

              # Check if types match (simplified matching for now)
              if param1Type.kind == lt.kind and param2Type.kind == rt.kind:
                # Create function call expression
                let callExpr = Expr(
                  kind: ekCall,
                  fname: opName,
                  args: @[e.lhs, e.rhs],
                  pos: e.pos
                )

                let resultType = inferCall(prog, sc, callExpr, subst)
                # Replace this binary expression with a function call
                e[] = Expr(
                  kind: ekCall,
                  fname: callExpr.fname,  # Use the mangled name from inferCall
                  args: @[e.lhs, e.rhs],
                  instTypes: callExpr.instTypes,
                  typ: resultType,
                  pos: e.pos
                )[]
                return resultType

    # Built-in operator handling
    case e.bop
    of boAdd:
      if lt.kind == tkInt and rt.kind == tkInt:
        e.typ = tInt(); return e.typ
      elif lt.kind == tkFloat and rt.kind == tkFloat:
        e.typ = tFloat(); return e.typ
      elif lt.kind == tkString and rt.kind == tkString:
        # String concatenation (strings are array[char])
        e.typ = tString(); return e.typ
      elif lt.kind == tkArray and rt.kind == tkArray:
        # Array concatenation - types must match
        if not typeEq(lt.inner, rt.inner):
          raise newTypecheckError(e.pos, &"array concatenation requires matching element types, got array[{lt.inner}] + array[{rt.inner}]")
        e.typ = tArray(lt.inner); return e.typ
      else:
        raise newTypecheckError(e.pos, &"+ operator requires matching types (int, float, string, or array), got {lt} and {rt}. Use explicit casts like int(x) or float(x)")
    of boSub, boMul, boDiv, boMod:
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
        if lt.kind notin {tkInt, tkFloat, tkString, tkChar, tkBool, tkRef}:
          raise newTypecheckError(e.pos, &"comparison not supported for type {lt}")
        # Only equality operators allowed for references
        if lt.kind == tkRef and e.bop notin {boEq, boNe}:
          raise newTypecheckError(e.pos, &"only == and != are allowed for reference comparisons")
        e.typ = tBool(); return e.typ
    of boAnd, boOr:
      if lt.kind != tkBool or rt.kind != tkBool: raise newTypecheckError(e.pos, "and/or expects bool")
      e.typ = tBool(); return e.typ
  of ekCall:
    # Handle builtins first using unified registry
    if isBuiltin(e.fname):
      # Get argument types by inferring each argument
      var argTypes: seq[EtchType] = @[]
      for arg in e.args:
        let argType = inferExprTypes(prog, fd, sc, arg, subst)
        argTypes.add(argType)

      # Perform built-in type checking using unified registry
      try:
        let resultType = performBuiltinTypeCheck(e.fname, argTypes, e.pos)
        e.instTypes = @[]
        e.typ = resultType
        return resultType
      except EtchError as err:
        raise convertBuiltinError(err, e.pos)
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
    if arrayType.kind notin {tkArray, tkString}:
      raise newTypecheckError(e.pos, &"indexing requires array or string type, got {arrayType}")
    if indexType.kind != tkInt:
      raise newTypecheckError(e.indexExpr.pos, &"index must be int, got {indexType}")
    if arrayType.kind == tkString:
      e.typ = tChar()
    else:
      e.typ = arrayType.inner
    return e.typ
  of ekSlice:
    let arrayType = inferExprTypes(prog, fd, sc, e.sliceExpr, subst)
    if arrayType.kind notin {tkArray, tkString}:
      raise newTypecheckError(e.pos, &"slicing requires array or string type, got {arrayType}")
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
    # Array/String length operator: #array/#string -> int
    let arrayType = inferExprTypes(prog, fd, sc, e.lenExpr, subst)
    if arrayType.kind notin {tkArray, tkString}:
      raise newTypecheckError(e.pos, &"length operator # requires array or string type, got {arrayType}")
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
  of ekOptionSome:
    let innerType = inferExprTypes(prog, fd, sc, e.someExpr, subst)
    e.typ = tOption(innerType)
    return e.typ
  of ekOptionNone:
    # Try to use expected type if available
    if expectedTy != nil and expectedTy.kind == tkOption:
      return expectedTy
    else:
      # none requires explicit type annotation to determine option type
      raise newTypecheckError(e.pos, "none requires explicit type annotation")
  of ekResultOk:
    let innerType = inferExprTypes(prog, fd, sc, e.okExpr, subst)
    e.typ = tResult(innerType)
    return e.typ
  of ekResultErr:
    # Try to use expected type if available
    if expectedTy != nil and expectedTy.kind == tkResult:
      let errTy = inferExprTypes(prog, fd, sc, e.errExpr, subst)
      if errTy.kind != tkString:
        raise newTypecheckError(e.pos, "error constructor requires string argument")
      return expectedTy
    else:
      # error requires explicit type annotation to determine result type
      raise newTypecheckError(e.pos, "error requires explicit type annotation")
  of ekMatch:
    # Match expressions need special handling - implemented in statements due to circular import
    # Return a default type for now - the real type will be set by inferMatchExpr
    if e.typ == nil:
      return tVoid()  # Placeholder
    else:
      return e.typ
