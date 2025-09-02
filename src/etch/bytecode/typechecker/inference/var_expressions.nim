proc inferLiteralExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  # Special handling for nil - adopt expected type if it's a reference or weak reference
  if e.kind == ekNil and expectedTy != nil and expectedTy.kind in {tkRef, tkWeak}:
    e.typ = expectedTy
    return e.typ

  e.typ = inferLiteralType(e.kind)
  return e.typ


proc inferVarExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Debug entry (disabled)

  # First try local/global variables in scope
  if sc.types.hasKey(e.vname):
    e.typ = sc.types[e.vname]
    return e.typ

  # If not a variable, allow referencing a top-level function by name
  if prog.funs.hasKey(e.vname) and not isBuiltin(e.vname):
    let overloads = prog.getFunctionOverloads(e.vname)
    if overloads.len == 0:
      raise newTypecheckError(e.pos, &"use of undeclared variable '{e.vname}'")

    # If there's a single overload, construct a function type from its signature
    if overloads.len == 1:
      let f = overloads[0]
      var paramTypes: seq[EtchType] = @[]
      for p in f.params:
        paramTypes.add(resolveNestedUserTypes(sc, p.typ, e.pos))
      let ret = if f.ret == nil: tVoid() else: resolveNestedUserTypes(sc, f.ret, e.pos)
      e.typ = tFunction(paramTypes, ret)
      return e.typ
    else:
      # Multiple overloads: try to see if they all have identical signatures, otherwise ambiguous
      var firstSig: EtchType = nil
      var allSame = true
      for f in overloads:
        var ptypes: seq[EtchType] = @[]
        for p in f.params: ptypes.add(resolveNestedUserTypes(sc, p.typ, e.pos))
        let rett = if f.ret == nil: tVoid() else: resolveNestedUserTypes(sc, f.ret, e.pos)
        let sig = tFunction(ptypes, rett)
        if firstSig.isNil:
          firstSig = sig
        else:
          if not typeEq(firstSig, sig):
            allSame = false
            break
      if allSame and not firstSig.isNil:
        e.typ = firstSig
        return e.typ
      raise newTypecheckError(e.pos, &"ambiguous function reference '{e.vname}': multiple overloads, please disambiguate")

  # Not found as variable nor function
  raise newTypecheckError(e.pos, &"use of undeclared variable '{e.vname}'")
