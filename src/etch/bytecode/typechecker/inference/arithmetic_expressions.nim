proc isOperatorFunction(name: string): bool =
  let baseName = if FUNCTION_NAME_SEPARATOR_STRING in name: name.split(FUNCTION_NAME_SEPARATOR_STRING)[0] else: name
  baseName in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">="]


proc inferUnOp(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let t0 = inferExpressionTypes(prog, fd, sc, e.ue, subst)
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


proc inferBinOp(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  let lt = inferExpressionTypes(prog, fd, sc, e.lhs, subst)
  let rt = inferExpressionTypes(prog, fd, sc, e.rhs, subst)

  # Try user-defined operator overload first (except for logical operators and in/not in)
  # Skip operator overloading if we're currently inside an operator function to avoid infinite recursion
  if e.bop notin {boAnd, boOr, boIn, boNotIn} and (fd == nil or not isOperatorFunction(fd.name)):
    let opName = $e.bop
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
              let calleeExpr = Expression(kind: ekVar, vname: opName, pos: e.pos)
              let callExpression = Expression(
                kind: ekCall,
                fname: opName,
                args: @[e.lhs, e.rhs],
                callTarget: calleeExpr,
                callIsValue: false,
                pos: e.pos
              )

              let resultType = inferCall(prog, sc, callExpression, subst)
              # Replace this binary expression with a function call
              e[] = Expression(
                kind: ekCall,
                fname: callExpression.fname,  # Use the mangled name from inferCall
                args: @[e.lhs, e.rhs],
                instTypes: callExpression.instTypes,
                callTarget: callExpression.callTarget,
                callIsValue: false,
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
    elif lt.kind == tkTuple and rt.kind == tkTuple:
      # Tuple concatenation - combine element types
      var combinedTypes: seq[EtchType] = @[]
      for elemType in lt.tupleTypes:
        combinedTypes.add(elemType)
      for elemType in rt.tupleTypes:
        combinedTypes.add(elemType)
      e.typ = tTuple(combinedTypes); return e.typ
    else:
      raise newTypecheckError(e.pos, &"+ operator requires matching types, got {lt} and {rt}. Use explicit casts like int(x) or float(x)")
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
    elif (lt.kind == tkWeak and rt.kind == tkRef and rt.inner.kind == tkVoid) or
         (lt.kind == tkRef and lt.inner.kind == tkVoid and rt.kind == tkWeak):
      # Allow comparison between weak reference and nil (Ref[void])
      if e.bop notin {boEq, boNe}:
        raise newTypecheckError(e.pos, &"only == and != are allowed for weak reference comparisons with nil")
      e.typ = tBool(); return e.typ
    elif lt.kind != rt.kind:
      raise newTypecheckError(e.pos, &"comparison type mismatch: {lt} vs {rt}")
    else:
      # Only allow comparison operators on comparable types
      if lt.kind notin {tkInt, tkFloat, tkString, tkChar, tkBool, tkRef, tkWeak, tkTuple, tkEnum, tkTypeDesc}:
        raise newTypecheckError(e.pos, &"comparison not supported for type {lt}")
      # Only equality operators allowed for references, weak references, tuples, enums, and typedesc
      if lt.kind in {tkRef, tkWeak, tkEnum, tkTypeDesc} and e.bop notin {boEq, boNe}:
        var kindStr = case lt.kind
          of tkRef: "reference"
          of tkWeak: "weak reference"
          of tkEnum: "enum"
          of tkTypeDesc: "typedesc"
          else: "unknown"
        raise newTypecheckError(e.pos, &"only == and != are allowed for {kindStr} comparisons")
      if lt.kind == tkTuple:
        # Tuple comparison: only == and != are supported
        if e.bop notin {boEq, boNe}:
          raise newTypecheckError(e.pos, &"only == and != are allowed for tuple comparisons")
        # Verify tuples have the same structure
        if not typeEq(lt, rt):
          raise newTypecheckError(e.pos, &"tuple comparison requires identical tuple types")
      elif lt.kind == tkEnum:
        # Enum comparison: only == and != are supported
        if e.bop notin {boEq, boNe}:
          raise newTypecheckError(e.pos, &"only == and != are allowed for enum comparisons")
        # Verify enums are the same type
        if not typeEq(lt, rt):
          raise newTypecheckError(e.pos, &"enum comparison requires identical enum types")
      e.typ = tBool(); return e.typ
  of boAnd, boOr:
    if lt.kind != tkBool or rt.kind != tkBool: raise newTypecheckError(e.pos, "and/or expects bool")
    e.typ = tBool(); return e.typ
  of boIn, boNotIn:
    # Check if left type can be contained in right type
    # For arrays: check if element type matches array element type
    # For strings: check if left is a string (substring check)
    if rt.kind == tkArray:
      # Check if left type matches array element type
      if not typeEq(lt, rt.inner):
        raise newTypecheckError(e.pos, &"'in' operator: cannot check if '{lt}' is in array[{rt.inner}] - types must match")
      e.typ = tBool(); return e.typ
    elif rt.kind == tkString:
      # For strings, allow string in string (substring check)
      if lt.kind != tkString:
        raise newTypecheckError(e.pos, &"'in' operator: cannot check if '{lt}' is in string - left operand must be string")
      e.typ = tBool(); return e.typ
    else:
      raise newTypecheckError(e.pos, &"'in' operator requires array or string on right side, got {rt}")
