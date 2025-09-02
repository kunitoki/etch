proc convertBuiltinError(err: ref EtchError, pos: Pos): ref TypecheckError =
  newTypecheckError(pos, err.msg)


proc resolveOverload(prog: Program; sc: Scope; e: Expression; subst: var TySubst): FunctionDeclaration =
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
    let argType = inferExpressionTypes(prog, nil, sc, arg, subst)
    argTypes.add(argType)

  # Find exact matches first
  var exactMatches: seq[FunctionDeclaration] = @[]
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
    raise newTypecheckError(e.pos, "no matching overload for " & e.fname & " with arguments (" & argTypes.join(", ") & "). Available: " & availableSignatures)


proc inferCall(prog: Program; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let templ = resolveOverload(prog, sc, e, subst)
  # build local substitution mapping for typarams
  var localSubst: TySubst
  for p in templ.typarams:
    discard

  if templ.ret.isNil:
    var pendingErr: ReturnTypePendingError
    new(pendingErr)
    pendingErr.msg = &"return type for '{templ.name}' not inferred yet"
    pendingErr.missingFunction = templ.name
    raise pendingErr

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
    let ta = inferExpressionTypes(prog, templ, sc, a, subst)
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
        if got.kind != tkRef: raise newTypecheckError(e.pos, "expected ref[...]")
        unify(pat.inner, got.inner)
      of tkUserDefined:
        # Resolve user-defined type before comparison
        let resolvedPat = resolveUserType(sc, pat.name)
        if resolvedPat == nil:
          raise newTypecheckError(e.pos, &"unknown type '{pat.name}'")
        if not typeEq(resolvedPat, got):
          raise newTypecheckError(e.pos, &"type mismatch: expected {resolvedPat}, got {got}")
      else:
        # Use canAssignDistinct to handle union types and distinct types
        if not canAssignDistinct(pat, got): raise newTypecheckError(e.pos, &"type mismatch: expected {pat}, got {got}")
    unify(pt, ta)

  # ret type resolution
  let retT = resolveTy(templ.ret, localSubst)
  e.instTypes = templ.typarams.mapIt(localSubst.getOrDefault(it.name, tGeneric(it.name)))
  e.typ = retT

  # Check if templ is already an instantiated function (comes from funInstances)
  # If so, use its name directly to avoid double-mangling
  var key = ""
  var isAlreadyInstantiated = false
  for instanceName, instanceDecl in prog.funInstances:
    if instanceDecl == templ:
      key = instanceName
      isAlreadyInstantiated = true
      break

  if not isAlreadyInstantiated:
    # Create a monomorphized instance key: name<types> or overload signature for non-generic overloads
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
      let inst = FunctionDeclaration(
        name: key,
        typarams: @[],
        params: @[],
        ret: retT,
        hasExplicitReturnType: templ.hasExplicitReturnType,
        body: @[],
        isAsync: templ.isAsync,
        isExported: templ.isExported,
        isCFFI: templ.isCFFI,
        isHost: templ.isHost,
        isBuiltin: templ.isBuiltin,
        pos: templ.pos)
      for pr in templ.params:
        inst.params.add Param(name: pr.name, typ: resolveTy(pr.typ, localSubst), defaultValue: pr.defaultValue)
      # deep copy body references not needed for this MVP; reuse
      inst.body = templ.body
      prog.funInstances[key] = inst
  # mutate call to target the instance symbol (for codegen / VM)
  e.fname = key
  return retT


proc inferFunctionValueCall(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; calleeType: EtchType): EtchType =
  if calleeType == nil or calleeType.kind != tkFunction:
    raise newTypecheckError(e.pos, "attempted to call a non-function value")

  if e.args.len != calleeType.funcParams.len:
    raise newTypecheckError(e.pos, &"function value expects {calleeType.funcParams.len} arguments, got {e.args.len}")

  for i, arg in e.args:
    let expectedParam = calleeType.funcParams[i]
    let argType = inferExpressionTypes(prog, fd, sc, arg, subst, expectedParam)
    if not canAssignDistinct(expectedParam, argType):
      raise newTypecheckError(arg.pos, &"argument {i+1} type mismatch: expected {expectedParam}, got {argType}")

  e.instTypes = @[]
  e.typ = if calleeType.funcReturn != nil: calleeType.funcReturn else: tVoid()
  return e.typ


proc inferCallExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  var targetType: EtchType = nil
  var treatAsValueCall = false
  if e.callTarget != nil:
    # If parser produced a bare identifier as callTarget (e.g. `f()`), prefer
    # treating it as a direct function call when that identifier names a
    # top-level function. This distinguishes `f()` from `(varHoldingFn)()`.
    if e.callTarget.kind == ekVar and not sc.types.hasKey(e.callTarget.vname) and prog.funs.hasKey(e.callTarget.vname):
      # Convert to a normal call by moving the name into `e.fname` and clearing callTarget
      e.fname = e.callTarget.vname
      e.callTarget = nil
    else:
      try:
        targetType = inferExpressionTypes(prog, fd, sc, e.callTarget, subst)
        treatAsValueCall = (targetType != nil and targetType.kind == tkFunction)
      except TypecheckError as err:
        if err.msg.contains("use of undeclared variable"):
          treatAsValueCall = false
        else:
          raise

  if treatAsValueCall:
    let resultType = inferFunctionValueCall(prog, fd, sc, e, subst, targetType)
    e.callIsValue = true
    e.fname = "__invoke_closure"
    return resultType

  # Handle builtins first using unified registry
  if isBuiltin(e.fname):
    # Get argument types by inferring each argument
    var argTypes: seq[EtchType] = @[]
    for arg in e.args:
      let argType = inferExpressionTypes(prog, fd, sc, arg, subst)
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
