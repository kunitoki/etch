# statements.nim
# Statement type checking

import std/[strformat, options, tables, strutils]
import ../../common/[types, errors]
import ../frontend/ast
import ./[types, inference]


proc typecheckStatement*(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst; isBlockResult: bool = false; expectedExprType: EtchType = nil)
proc inferMatchExpression*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType {.exportc.}


proc wrapReturnExpressionAsOk(s: Statement; innerExpr: Expression; resultType: EtchType) =
  ## Wrap a bare return expression into ok(...) to implement return value lifting
  let wrapped = Expression(kind: ekResultOk, okExpression: innerExpr, pos: innerExpr.pos)
  wrapped.okExpression.typ = innerExpr.typ
  wrapped.typ = resultType
  s.re = some(wrapped)


proc typecheckVar(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  if s.vtype.kind == tkGeneric:
    raise newTypecheckError(s.pos, "generic variable type not allowed at runtime scope")

  # Handle deferred type inference
  if s.vtype.kind == tkInferred:
    if s.vinit.isNone():
      raise newTypecheckError(s.pos, &"variable '{s.vname}' with inferred type must have an initializer")

    # Special handling for match and if expressions during deferred type inference
    if s.vinit.get().kind == ekMatch:
      # Infer match expression type directly using type checker
      var tempSubst = subst
      let inferredType = inferMatchExpression(prog, fd, sc, s.vinit.get(), tempSubst)
      s.vtype = inferredType
    elif s.vinit.get().kind == ekIf:
      # Infer if expression type directly using type checker
      var tempSubst = subst
      let inferredType = inferIfExpression(prog, fd, sc, s.vinit.get(), tempSubst)
      s.vtype = inferredType
    else:
      # Try regular type inference for other expressions
      var tempSubst = subst
      let inferredType = inferExpressionTypes(prog, fd, sc, s.vinit.get(), tempSubst)
      if inferredType == nil:
        raise newTypecheckError(s.pos, &"cannot infer type for variable '{s.vname}', please provide explicit type annotation")
      s.vtype = inferredType

  # Resolve user-defined types (including nested ones in references, arrays, etc.)
  var resolvedVtype = s.vtype
  resolvedVtype = resolveNestedUserTypes(sc, resolvedVtype, s.pos)
  # Update the statement's type to the resolved type for later use
  s.vtype = resolvedVtype
  if s.vinit.isSome():
    # Two-phase approach: First check type compatibility assuming all variables exist,
    # then check for undeclared variables if type check passes

    # Phase 1: Create temporary scope with self-reference to check type compatibility
    var tempScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
    tempScope.types[s.vname] = resolvedVtype  # Allow self-reference for type checking

    var tempSubst = subst
    let t0 = try:
      if s.vinit.get().kind == ekMatch:
        # Handle match expressions directly to avoid circular import issues
        inferMatchExpression(prog, fd, tempScope, s.vinit.get(), tempSubst, resolvedVtype)
      elif s.vinit.get().kind == ekIf:
        # Handle if expressions directly to avoid circular import issues
        inferIfExpression(prog, fd, tempScope, s.vinit.get(), tempSubst)
      else:
        inferExpressionTypes(prog, fd, tempScope, s.vinit.get(), tempSubst, resolvedVtype)
    except EtchError as e:
      # If we get an error during type inference, check if it's specifically about
      # the variable being initialized (circular reference) vs other issues
      if e.msg.contains(&"undeclared variable '{s.vname}'"):
        raise newTypecheckError(s.pos, &"circular reference: variable '{s.vname}' cannot be used in its own initialization")
      else:
        # Re-raise the original error (could be other undeclared variable or other issue)
        raise

    # Phase 2: Check type compatibility
    if not canAssignDistinct(resolvedVtype, t0):
      if t0.kind == tkVoid:
        raise newTypecheckError(s.pos, &"cannot assign void function result to variable '{s.vname}' of type {resolvedVtype}")
      else:
        raise newTypecheckError(s.pos, &"initialization type mismatch: {t0} vs {resolvedVtype}")

  if fd != nil:
    if sc.types.hasKey(s.vname):
      raise newTypecheckError(s.pos, &"variable '{s.vname}' is already declared in this scope")

    sc.types[s.vname] = resolvedVtype
    sc.flags[s.vname] = s.vflag


proc typecheckTupleUnpack(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Type check the tuple expression
  let tupleType = inferExpressionTypes(prog, fd, sc, s.tupInit, subst)

  # Verify it's a tuple type
  if tupleType.kind != tkTuple:
    raise newTypecheckError(s.pos, &"tuple unpacking requires a tuple expression, got {tupleType}")

  # Verify arity matches
  if s.tupNames.len != tupleType.tupleTypes.len:
    raise newTypecheckError(s.pos, &"tuple unpacking arity mismatch: expected {s.tupNames.len} variables, tuple has {tupleType.tupleTypes.len} elements")

  # Assign types to each variable and add to scope
  for i, name in s.tupNames:
    let elemType = tupleType.tupleTypes[i]

    # Resolve user-defined types
    let resolvedType = resolveNestedUserTypes(sc, elemType, s.pos)

    # Update the type in the statement for later use
    s.tupTypes[i] = resolvedType

    # Check for redeclaration
    if fd != nil and sc.types.hasKey(name):
      raise newTypecheckError(s.pos, &"variable '{name}' is already declared in this scope")

    # Add to scope
    sc.types[name] = resolvedType
    sc.flags[name] = s.tupFlag


proc typecheckObjectUnpack(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Type check the object expression
  var objectType = inferExpressionTypes(prog, fd, sc, s.objInit, subst)

  # If it's a ref type, unwrap it
  if objectType.kind == tkRef:
    objectType = objectType.inner

  # Verify it's an object type
  if objectType.kind != tkObject:
    raise newTypecheckError(s.pos, &"object unpacking requires an object expression, got {objectType}")

  # Process each field mapping
  for i, mapping in s.objFieldMappings:
    let fieldName = mapping.fieldName
    let varName = mapping.varName

    # Find the field in the object type
    var fieldType: EtchType = nil
    var fieldFound = false

    for field in objectType.fields:
      if field.name == fieldName:
        fieldType = field.fieldType
        fieldFound = true
        break

    if not fieldFound:
      raise newTypecheckError(s.pos, &"object type {objectType.name} has no field '{fieldName}'")

    # Resolve user-defined types
    let resolvedType = resolveNestedUserTypes(sc, fieldType, s.pos)

    # Update the type in the statement for later use
    s.objTypes[i] = resolvedType

    # Check for redeclaration
    if fd != nil and sc.types.hasKey(varName):
      raise newTypecheckError(s.pos, &"variable '{varName}' is already declared in this scope")

    # Add to scope
    sc.types[varName] = resolvedType
    sc.flags[varName] = s.objFlag


proc typecheckAssign(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  if not sc.types.hasKey(s.aname): raise newTypecheckError(s.pos, "unknown variable '" & s.aname & "'")
  if sc.flags.hasKey(s.aname) and sc.flags[s.aname] == vfLet:
    raise newTypecheckError(s.pos, &"cannot assign to immutable variable '{s.aname}'")
  let varType = sc.types[s.aname]
  # Pass the variable's type as expected type to enable type inference for empty arrays
  let t0 = inferExpressionTypes(prog, fd, sc, s.aval, subst, varType)

  # Use canAssignDistinct to handle union types, distinct types, and reference conversions
  var typesCompatible = canAssignDistinct(varType, t0)

  if not typesCompatible:
    if t0.kind == tkVoid:
      raise newTypecheckError(s.pos, &"cannot assign void function result to variable '{s.aname}'")
    else:
      raise newTypecheckError(s.pos, &"assignment type mismatch: cannot assign '{t0}' to variable '{s.aname}' of type '{varType}'")


proc typecheckCompoundAssign(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  if not sc.types.hasKey(s.caname):
    raise newTypecheckError(s.pos, &"unknown variable '{s.caname}'")
  if sc.flags.hasKey(s.caname) and sc.flags[s.caname] == vfLet:
    raise newTypecheckError(s.pos, &"cannot assign to immutable variable '{s.caname}'")

  let varType = sc.types[s.caname]
  discard inferExpressionTypes(prog, fd, sc, s.crhs, subst, varType)
  let binExpr = compoundAssignExpression(s)
  let resultType = inferExpressionTypes(prog, fd, sc, binExpr, subst, varType)
  if not canAssignDistinct(varType, resultType):
    raise newTypecheckError(s.pos, &"compound assignment type mismatch: '{resultType}' cannot be assigned to '{s.caname}' of type '{varType}'")


proc typecheckFieldAssign(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Typecheck the target expression (field access, array index, or deref)
  let targetType = inferExpressionTypes(prog, fd, sc, s.faTarget, subst)

  # The target must be a field access, array index, or dereference expression
  if s.faTarget.kind notin {ekFieldAccess, ekIndex, ekDeref}:
    raise newTypecheckError(s.pos, &"invalid assignment target")

  if s.faTarget.kind == ekDeref:
    var refExprType = s.faTarget.refExpression.typ
    if refExprType.isNil:
      refExprType = inferExpressionTypes(prog, fd, sc, s.faTarget.refExpression, subst)
    # Resolve type aliases before checking kind
    if not refExprType.isNil:
      refExprType = resolveNestedUserTypes(sc, refExprType, s.pos)
    if refExprType.isNil or refExprType.kind != tkRef:
      raise newTypecheckError(s.pos, &"deref assignment requires a ref[T] target")

  # Typecheck the value expression, passing target type as expected type for inference
  let valueType = inferExpressionTypes(prog, fd, sc, s.faValue, subst, targetType)

  # Check type compatibility
  var typesCompatible = typeEq(valueType, targetType)
  if not typesCompatible and valueType.kind == tkRef and valueType.inner.kind == tkVoid and targetType.kind in {tkRef, tkWeak}:
    typesCompatible = true  # nil can be assigned to any reference type

  # Allow ref[T] -> weak[T] conversion
  if not typesCompatible and valueType.kind == tkRef and targetType.kind == tkWeak and typeEq(valueType.inner, targetType.inner):
    typesCompatible = true

  # Allow weak[T] -> ref[T] conversion
  if not typesCompatible and valueType.kind == tkWeak and targetType.kind == tkRef and typeEq(valueType.inner, targetType.inner):
    typesCompatible = true

  if not typesCompatible:
    if valueType.kind == tkVoid:
      raise newTypecheckError(s.pos, &"cannot assign void function result to field")
    else:
      raise newTypecheckError(s.pos, &"field assignment type mismatch")


proc typecheckIf(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  let ct = inferExpressionTypes(prog, fd, sc, s.cond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "if condition must be bool")
  var sThen = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog) # shallow copy ok
  for st in s.thenBody: typecheckStatement(prog, fd, sThen, st, subst)

  # Typecheck elif chain
  for elifBranch in s.elifChain:
    let elifCondType = inferExpressionTypes(prog, fd, sc, elifBranch.cond, subst)
    if elifCondType.kind != tkBool: raise newTypecheckError(s.pos, "elif condition must be bool")
    var sElif = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
    for st in elifBranch.body: typecheckStatement(prog, fd, sElif, st, subst)

  var sElse = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for st in s.elseBody: typecheckStatement(prog, fd, sElse, st, subst)


proc typecheckWhile(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  let ct = inferExpressionTypes(prog, fd, sc, s.wcond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "while condition must be bool")
  var sBody = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for st in s.wbody: typecheckStatement(prog, fd, sBody, st, subst)


proc typecheckReturn(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  if fd == nil: return
  if fd.ret.isNil:
    if s.re.isSome():
      let expr = s.re.get()
      discard inferExpressionTypes(prog, fd, sc, expr, subst)
    return

  let retType = if fd.ret.isNil: tVoid() else: fd.ret
  if retType.kind == tkVoid:
    if s.re.isSome(): raise newTypecheckError(s.pos, "void function cannot return a value")
  elif fd.isAsync:
    # Coroutine returns must eventually be consistent with the inner type once known.
    let expectedType = if retType.kind == tkCoroutine: retType.inner else: retType
    if not s.re.isSome():
      if expectedType != nil and expectedType.kind != tkVoid:
        raise newTypecheckError(s.pos, &"coroutine returning {expectedType} must return a value")
      return

    let expr = s.re.get()
    var rt = inferExpressionTypes(prog, fd, sc, expr, subst)

    # Only enforce type checking if the expected type is not void
    # (void indicates we're still inferring the type from yields and returns)
    if expectedType != nil and expectedType.kind != tkVoid:
      if expectedType.kind == tkResult and rt.kind != tkResult:
        # Allow returning bare T by implicitly wrapping in ok(...)
        if not canAssignDistinct(expectedType.inner, rt):
          raise newTypecheckError(s.pos, &"return type mismatch: expected {expectedType}, got {rt}")
        wrapReturnExpressionAsOk(s, expr, expectedType)
        rt = expectedType
      elif not canAssignDistinct(expectedType, rt):
        raise newTypecheckError(s.pos, &"return type mismatch: expected {expectedType}, got {rt}")
  else:
    if not s.re.isSome(): raise newTypecheckError(s.pos, "non-void function must return a value")
    # Special handling for match and if expressions in return statements
    var rt: EtchType
    if s.re.get().kind == ekMatch:
      rt = inferMatchExpression(prog, fd, sc, s.re.get(), subst, fd.ret)
    elif s.re.get().kind == ekIf:
      rt = inferIfExpression(prog, fd, sc, s.re.get(), subst)
    else:
      rt = inferExpressionTypes(prog, fd, sc, s.re.get(), subst, fd.ret)

    # Implement return value lifting for result[T]
    if retType.kind == tkResult and rt.kind != tkResult:
      if not canAssignDistinct(retType.inner, rt):
        raise newTypecheckError(s.pos, &"return type mismatch: expected {retType}, got {rt}")
      wrapReturnExpressionAsOk(s, s.re.get(), retType)
      rt = retType

    # Check if return type is compatible (including union compatibility)
    if not canAssignDistinct(retType, rt):
      raise newTypecheckError(s.pos, &"return type mismatch: expected {retType}, got {rt}")


proc typecheckComptime(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Typecheck comptime block statements and add injected variables to main scope
  var ctScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for stmt in s.cbody:
    typecheckStatement(prog, fd, ctScope, stmt, subst)
    # If this is a variable declaration, add it to the main scope (injected variables)
    if stmt.kind == skVar:
      sc.types[stmt.vname] = stmt.vtype


proc typecheckFor(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Create new scope for loop body with loop variable
  var loopScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)

  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayType = inferExpressionTypes(prog, fd, sc, s.farray.get(), subst)

    if arrayType.kind == tkArray:
      # Loop variable has the array element type
      # Resolve nested user types (e.g., Person from array[Person])
      var elementType = arrayType.inner
      if elementType.kind == tkUserDefined:
        elementType = resolveUserType(sc, elementType.name)
        if elementType == nil:
          raise newTypecheckError(s.pos, &"unknown type '{arrayType.inner.name}'")
      loopScope.types[s.fvar] = elementType
    elif arrayType.kind == tkString:
      # String iteration - loop variable is char
      loopScope.types[s.fvar] = tChar()
    else:
      raise newTypecheckError(s.farray.get().pos, "for loop can only iterate over arrays or strings, got " & $arrayType)
  else:
    # Range iteration: for x in start..end
    let startType = inferExpressionTypes(prog, fd, sc, s.fstart.get(), subst)
    let endType = inferExpressionTypes(prog, fd, sc, s.fend.get(), subst)

    # Both start and end must be integers
    if startType.kind != tkInt:
      raise newTypecheckError(s.fstart.get().pos, "for loop start expression must be int, got " & $startType)
    if endType.kind != tkInt:
      raise newTypecheckError(s.fend.get().pos, "for loop end expression must be int, got " & $endType)

    # Loop variable is int
    loopScope.types[s.fvar] = tInt()

  loopScope.flags[s.fvar] = vfLet  # Loop variable is immutable within loop body

  # Type check loop body
  for stmt in s.fbody:
    typecheckStatement(prog, fd, loopScope, stmt, subst)


proc typecheckBreak(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Break statements don't need special type checking, just verify they're valid
  # (validation that break is inside a loop is done at parse time or runtime)
  discard


proc typecheckDefer(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst) =
  # Type check the deferred statements
  # Deferred statements execute at the end of the enclosing scope
  for stmt in s.deferBody:
    typecheckStatement(prog, fd, sc, stmt, subst)


proc typecheckStatementList*(prog: Program; fd: FunctionDeclaration; sc: Scope; stmts: seq[Statement]; subst: var TySubst; blockResultUsed: bool = false; expectedResultType: EtchType = nil): EtchType {.exportc.} =
  ## Type check a list of statements and return the type of the last expression (or void)
  var resultType = tVoid()
  for j, stmt in stmts:
    let isLastStatement = (j == stmts.len - 1)
    let isBlockResult = isLastStatement and blockResultUsed and stmt.kind == skExpression
    let stmtExpectedType = if isBlockResult: expectedResultType else: nil
    typecheckStatement(prog, fd, sc, stmt, subst, isBlockResult, stmtExpectedType)
    if isLastStatement and stmt.kind == skExpression:
      # Last statement is expression - this determines block type
      resultType = stmt.sexpr.typ
  return resultType


proc literalKindName(lit: PatternLiteral): string =
  case lit.kind
  of plInt: "int"
  of plFloat: "float"
  of plString: "string"
  of plChar: "char"
  of plBool: "bool"


proc literalMatchesType(lit: PatternLiteral; typ: EtchType): bool =
  if typ.isNil:
    return false
  case typ.kind
  of tkUnion:
    for ut in typ.unionTypes:
      if literalMatchesType(lit, ut):
        return true
    return false
  of tkDistinct:
    if typ.inner == nil:
      return false
    return literalMatchesType(lit, typ.inner)
  of tkInt:
    lit.kind == plInt
  of tkFloat:
    lit.kind == plFloat
  of tkString:
    lit.kind == plString
  of tkChar:
    lit.kind == plChar
  of tkBool:
    lit.kind == plBool
  else:
    false


proc ensureLiteralCompatible(lit: PatternLiteral; typ: EtchType; pos: Pos) =
  if not literalMatchesType(lit, typ):
    raise newTypecheckError(pos, &"literal of type '{literalKindName(lit)}' does not match '{typ}'")


proc rangeLiteralValue(lit: PatternLiteral): int64 =
  case lit.kind
  of plInt: lit.ival
  of plChar: int64(ord(lit.cval))
  else:
    raise newException(ValueError, "range bounds must be int or char literals")


proc supportsRangeForType(litKind: PatternLiteralKind; typ: EtchType): bool =
  if typ.isNil:
    return false
  case typ.kind
  of tkUnion:
    for ut in typ.unionTypes:
      if supportsRangeForType(litKind, ut):
        return true
    return false
  of tkDistinct:
    if typ.inner == nil:
      return false
    return supportsRangeForType(litKind, typ.inner)
  of tkInt:
    litKind == plInt
  of tkChar:
    litKind == plChar
  else:
    false


proc ensureRangeCompatible(p: Pattern; typ: EtchType) =
  let startKind = p.rangeStart.kind
  let endKind = p.rangeEnd.kind
  if startKind notin {plInt, plChar} or endKind != startKind:
    raise newTypecheckError(p.pos, "range patterns require both bounds to be int or char literals")
  if not supportsRangeForType(startKind, typ):
    raise newTypecheckError(p.pos, &"range pattern of type '{literalKindName(p.rangeStart)}' does not match '{typ}'")
  let startVal = rangeLiteralValue(p.rangeStart)
  let endVal = rangeLiteralValue(p.rangeEnd)
  if startVal > endVal:
    raise newTypecheckError(p.pos, "range pattern start must be <= end")


proc mergePatternBindings(target: var Table[string, EtchType]; source: Table[string, EtchType]; pos: Pos) =
  for name, typ in source:
    if target.hasKey(name):
      raise newTypecheckError(pos, &"duplicate binding name '{name}' in pattern")
    target[name] = typ


proc typecheckPatternBindings(pat: Pattern; matchedType: EtchType): Table[string, EtchType] =
  result = initTable[string, EtchType]()
  if pat.isNil:
    return

  case pat.kind
  of pkWildcard, pkNone:
    discard

  of pkIdentifier:
    if pat.bindName.len == 0:
      return
    if result.hasKey(pat.bindName):
      raise newTypecheckError(pat.pos, &"duplicate binding name '{pat.bindName}' in pattern")
    result[pat.bindName] = matchedType

  of pkLiteral:
    ensureLiteralCompatible(pat.literal, matchedType, pat.pos)

  of pkRange:
    ensureRangeCompatible(pat, matchedType)

  of pkEnum:
    # Enum pattern: TypeName.MemberName
    if matchedType.kind != tkEnum:
      raise newTypecheckError(pat.pos, &"enum pattern requires enum type, got {matchedType}")

    # Parse the enum pattern to get type name and member name
    let parts = pat.enumPattern.split(".")
    if parts.len != 2:
      raise newTypecheckError(pat.pos, &"invalid enum pattern '{pat.enumPattern}' - expected 'TypeName.MemberName'")

    let enumTypeName = parts[0]
    let memberName = parts[1]

    # Verify the enum type name matches
    if enumTypeName != matchedType.name:
      raise newTypecheckError(pat.pos, &"enum pattern '{pat.enumPattern}' does not match type '{matchedType.name}'")

    # Verify the member exists in this enum and populate the enumMember field
    let memberOpt = findEnumMember(matchedType, memberName)
    if memberOpt.isNone:
      raise newTypecheckError(pat.pos, &"enum '{matchedType.name}' has no member '{memberName}'")
    pat.enumType = matchedType
    pat.enumMember = memberOpt

  of pkSome:
    if matchedType.kind != tkOption:
      raise newTypecheckError(pat.pos, &"'some' pattern requires option type, got {matchedType}")
    if pat.innerPattern.isSome:
      let innerBindings = typecheckPatternBindings(pat.innerPattern.get(), matchedType.inner)
      mergePatternBindings(result, innerBindings, pat.pos)

  of pkOk:
    if matchedType.kind != tkResult:
      raise newTypecheckError(pat.pos, &"'ok' pattern requires result type, got {matchedType}")
    if pat.innerPattern.isSome:
      let innerBindings = typecheckPatternBindings(pat.innerPattern.get(), matchedType.inner)
      mergePatternBindings(result, innerBindings, pat.pos)

  of pkErr:
    if matchedType.kind != tkResult:
      raise newTypecheckError(pat.pos, &"'error' pattern requires result type, got {matchedType}")
    if pat.innerPattern.isSome:
      let innerBindings = typecheckPatternBindings(pat.innerPattern.get(), tString())
      mergePatternBindings(result, innerBindings, pat.pos)

  of pkType:
    # Type annotated pattern - check type compatibility
    var compatible = false
    if matchedType.kind == tkUnion:
      # For union types, check if the pattern type matches one of the union members
      for ut in matchedType.unionTypes:
        if typeEq(ut, pat.typePattern):
          compatible = true
          break
    else:
      # For non-union types, check direct type compatibility
      compatible = typeEq(matchedType, pat.typePattern) or isCompatibleWith(matchedType, pat.typePattern) or isCompatibleWith(pat.typePattern, matchedType)

    if not compatible:
      raise newTypecheckError(pat.pos, &"type pattern '{pat.typePattern}' is not compatible with '{matchedType}'")

    # Create binding for the variable with the pattern type
    if pat.typeBind.len > 0:
      result[pat.typeBind] = pat.typePattern

  of pkTuple:
    if matchedType.kind != tkTuple:
      raise newTypecheckError(pat.pos, &"tuple pattern requires tuple type, got {matchedType}")
    if matchedType.tupleTypes.len != pat.tuplePatterns.len:
      raise newTypecheckError(pat.pos, &"tuple pattern expects {pat.tuplePatterns.len} elements but type has {matchedType.tupleTypes.len}")
    for idx, subPat in pat.tuplePatterns:
      let elemType = matchedType.tupleTypes[idx]
      let subBindings = typecheckPatternBindings(subPat, elemType)
      mergePatternBindings(result, subBindings, subPat.pos)

  of pkArray:
    if matchedType.kind != tkArray:
      raise newTypecheckError(pat.pos, &"array pattern requires array type, got {matchedType}")
    let elemType = matchedType.inner
    for subPat in pat.arrayPatterns:
      let subBindings = typecheckPatternBindings(subPat, elemType)
      mergePatternBindings(result, subBindings, subPat.pos)
    if pat.hasSpread and pat.spreadName.len > 0:
      if result.hasKey(pat.spreadName):
        raise newTypecheckError(pat.pos, &"duplicate binding name '{pat.spreadName}' in pattern")
      result[pat.spreadName] = matchedType

  of pkAs:
    let innerBindings = typecheckPatternBindings(pat.innerAsPattern, matchedType)
    mergePatternBindings(result, innerBindings, pat.pos)
    if pat.asBind.len > 0:
      if result.hasKey(pat.asBind):
        raise newTypecheckError(pat.pos, &"duplicate binding name '{pat.asBind}' in pattern")
      result[pat.asBind] = matchedType

  of pkOr:
    if pat.orPatterns.len == 0:
      raise newTypecheckError(pat.pos, "or-pattern requires at least one alternative")
    let baseline = typecheckPatternBindings(pat.orPatterns[0], matchedType)
    for j in 1..<pat.orPatterns.len:
      let altBindings = typecheckPatternBindings(pat.orPatterns[j], matchedType)
      if altBindings.len != baseline.len:
        raise newTypecheckError(pat.pos, "all alternatives in an or-pattern must bind the same names")
      for name, typ in baseline:
        if not (altBindings.hasKey(name) and typeEq(altBindings[name], typ)):
          raise newTypecheckError(pat.pos, "all alternatives in an or-pattern must bind the same names with the same types")
    mergePatternBindings(result, baseline, pat.pos)


proc patternHasWildcard(pat: Pattern): bool =
  case pat.kind
  of pkWildcard:
    true
  of pkIdentifier:
    true
  of pkAs:
    patternHasWildcard(pat.innerAsPattern)
  of pkOr:
    for option in pat.orPatterns:
      if patternHasWildcard(option):
        return true
    false
  else:
    false


proc collectEnumPatternMembers(pat: Pattern; covered: var seq[string]) =
  case pat.kind
  of pkEnum:
    if pat.enumMember.isSome:
      covered.add(pat.enumMember.get().name)
  of pkAs:
    collectEnumPatternMembers(pat.innerAsPattern, covered)
  of pkOr:
    for option in pat.orPatterns:
      collectEnumPatternMembers(option, covered)
  else:
    discard


proc patternIsCatchAll(pat: Pattern): bool =
  ## Returns true when the pattern matches any value (wildcard or identifier)
  case pat.kind
  of pkWildcard, pkIdentifier:
    true
  of pkAs:
    patternIsCatchAll(pat.innerAsPattern)
  of pkOr:
    for option in pat.orPatterns:
      if not patternIsCatchAll(option):
        return false
    return pat.orPatterns.len > 0
  else:
    false


proc patternCoversResultVariant(pat: Pattern; variant: PatternKind): bool =
  ## Determine if a pattern explicitly covers ok(...) or error(...)
  case pat.kind
  of pkOk:
    variant == pkOk
  of pkErr:
    variant == pkErr
  of pkAs:
    patternCoversResultVariant(pat.innerAsPattern, variant)
  of pkOr:
    for option in pat.orPatterns:
      if patternCoversResultVariant(option, variant):
        return true
    false
  else:
    false


proc inferMatchExpression*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  # Type check the matched expression
  let matchedType = inferExpressionTypes(prog, fd, sc, e.matchExpression, subst)

  # Check all cases and determine result type
  if e.cases.len == 0:
    raise newTypecheckError(e.pos, "match expression must have at least one case")

  var resultType: EtchType = nil
  var enumCoveredCases: seq[string] = @[]
  var enumHasWildcard = false
  var resultCoveredOk = false
  var resultCoveredErr = false
  var resultHasCatchAll = false

  for i, matchCase in e.cases:
    let patternBindings = typecheckPatternBindings(matchCase.pattern, matchedType)
    if matchedType.kind == tkEnum:
      if patternHasWildcard(matchCase.pattern):
        enumHasWildcard = true
      collectEnumPatternMembers(matchCase.pattern, enumCoveredCases)
    elif matchedType.kind == tkResult:
      if patternIsCatchAll(matchCase.pattern):
        resultHasCatchAll = true
      if patternCoversResultVariant(matchCase.pattern, pkOk):
        resultCoveredOk = true
      if patternCoversResultVariant(matchCase.pattern, pkErr):
        resultCoveredErr = true

    # Create scope for pattern bindings (copy parent scope)
    var caseScope = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: sc.userTypes, prog: sc.prog)
    for k, v in sc.types: caseScope.types[k] = v
    for k, v in sc.flags: caseScope.flags[k] = v

    # Register pattern bindings in the new scope
    for name, typ in patternBindings:
      caseScope.types[name] = typ
      caseScope.flags[name] = vfLet

    # Type check all statements in case body
    # The block result is used (it becomes the value of this match arm)
    let caseExpectedType = if resultType != nil: resultType else: expectedTy
    let caseType = typecheckStatementList(
      prog,
      fd,
      caseScope,
      matchCase.body,
      subst,
      blockResultUsed = true,
      expectedResultType = caseExpectedType
    )

    # Use the type returned by typecheckStatementList, which correctly handles
    # the type of the last expression in the block
    var actualCaseType: EtchType = if caseType != nil: caseType else: tVoid()


    # Check type consistency across all match arms
    if resultType == nil:
      resultType = actualCaseType
    elif not typeEq(resultType, actualCaseType):
      raise newTypecheckError(e.pos, &"match arm {i+1} returns type {actualCaseType} but previous arms return {resultType}. All match arms must return the same type")

  if resultType == nil:
    resultType = tVoid()

  e.typ = resultType

  if matchedType.kind == tkEnum and not enumHasWildcard and matchedType.enumMembers.len > 0:
    var missingCases: seq[string] = @[]
    for member in matchedType.enumMembers:
      if member.name notin enumCoveredCases:
        missingCases.add(member.name)
    if missingCases.len > 0:
      let missingStr = missingCases.join(", ")
      raise newTypecheckError(e.pos, &"match expression on enum '{matchedType.name}' is not exhaustive. Missing cases: {missingStr}. Add these cases or use '_' wildcard")

  if matchedType.kind == tkResult and not resultHasCatchAll:
    var missing: seq[string] = @[]
    if not resultCoveredOk:
      missing.add("ok(...)")
    if not resultCoveredErr:
      missing.add("error(...)")
    if missing.len > 0:
      let missingStr = missing.join(" and ")
      raise newTypecheckError(e.pos, &"match expression on result type is not exhaustive. Missing {missingStr} branch")

  return resultType


#[
proc inferIfExpression*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst): EtchType =
  # Type check the condition
  let condType = inferExpressionTypes(prog, fd, sc, e.ifCond, subst)
  if condType.kind != tkBool:
    raise newTypecheckError(e.pos, &"if condition must be bool, got {condType}")

  # Type check then body
  let thenType = typecheckStatementList(prog, fd, sc, e.ifThen, subst, blockResultUsed = true)

  # Type check elif chain and verify types match
  var resultType = thenType
  for elifCase in e.ifElifChain:
    let elifCondType = inferExpressionTypes(prog, fd, sc, elifCase.cond, subst)
    if elifCondType.kind != tkBool:
      raise newTypecheckError(e.pos, &"elif condition must be bool, got {elifCondType}")

    let elifType = typecheckStatementList(prog, fd, sc, elifCase.body, subst, blockResultUsed = true)
    if not typeEq(resultType, elifType):
      raise newTypecheckError(e.pos, &"if expression branches must return the same type: then returns {resultType}, elif returns {elifType}")

  # Type check else body and verify type matches
  let elseType = typecheckStatementList(prog, fd, sc, e.ifElse, subst, blockResultUsed = true)
  if not typeEq(resultType, elseType):
    raise newTypecheckError(e.pos, &"if expression branches must return the same type: then returns {resultType}, else returns {elseType}")

  e.typ = resultType
  return resultType
]#


proc typecheckStatement*(prog: Program; fd: FunctionDeclaration; sc: Scope; s: Statement; subst: var TySubst; isBlockResult: bool = false; expectedExprType: EtchType = nil) =
  case s.kind
  of skVar: typecheckVar(prog, fd, sc, s, subst)
  of skTupleUnpack: typecheckTupleUnpack(prog, fd, sc, s, subst)
  of skObjectUnpack: typecheckObjectUnpack(prog, fd, sc, s, subst)
  of skAssign: typecheckAssign(prog, fd, sc, s, subst)
  of skCompoundAssign: typecheckCompoundAssign(prog, fd, sc, s, subst)
  of skFieldAssign: typecheckFieldAssign(prog, fd, sc, s, subst)
  of skIf: typecheckIf(prog, fd, sc, s, subst)
  of skWhile: typecheckWhile(prog, fd, sc, s, subst)
  of skFor: typecheckFor(prog, fd, sc, s, subst)
  of skBreak: typecheckBreak(prog, fd, sc, s, subst)
  of skExpression:
    let exprExpected = if isBlockResult: expectedExprType else: nil
    if s.sexpr.kind == ekMatch:
      s.sexpr.typ = inferMatchExpression(prog, fd, sc, s.sexpr, subst, exprExpected)
      # Check if match expression result is non-void and not used
      if s.sexpr.typ.kind != tkVoid and not isBlockResult:
        raise newTypecheckError(s.pos, &"match expression returns '{s.sexpr.typ}' but result is not used; use 'discard' to explicitly ignore the return value")
    elif s.sexpr.kind == ekIf:
      s.sexpr.typ = inferIfExpression(prog, fd, sc, s.sexpr, subst)
      # Check if if expression result is non-void and not used
      if s.sexpr.typ.kind != tkVoid and not isBlockResult:
        raise newTypecheckError(s.pos, &"if expression returns '{s.sexpr.typ}' but result is not used; use 'discard' to explicitly ignore the return value")
    else:
      let exprType = inferExpressionTypes(prog, fd, sc, s.sexpr, subst, exprExpected)
      s.sexpr.typ = exprType
      # Check if this is a function call with non-void return type
      # If so, it must be explicitly discarded
      # BUT: if this expression is the result of a block that's being used, then it IS being used
      if s.sexpr.kind == ekCall and exprType.kind != tkVoid and not isBlockResult:
        let unmangledName = demangleFunctionSignature(s.sexpr.fname)
        raise newTypecheckError(s.pos, &"function '{unmangledName}' returns '{exprType}' but result is not used; use 'discard' to explicitly ignore the return value")
  of skDiscard:
    # Type check all discarded expressions but ignore their results
    for expr in s.dexprs:
      let exprType = inferExpressionTypes(prog, fd, sc, expr, subst)
      # Emit a warning/error if discarding a void expression (it's redundant)
      if exprType.kind == tkVoid and expr.kind == ekCall:
        let unmangledName = demangleFunctionSignature(expr.fname)
        raise newTypecheckError(s.pos, &"cannot discard void function '{unmangledName}'; void results are automatically discarded")
  of skReturn: typecheckReturn(prog, fd, sc, s, subst)
  of skComptime: typecheckComptime(prog, fd, sc, s, subst)
  of skDefer: typecheckDefer(prog, fd, sc, s, subst)
  of skBlock:
    # Unnamed scope blocks - type check all statements in the block
    var blockScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
    for stmt in s.blockBody:
      typecheckStatement(prog, fd, blockScope, stmt, subst, isBlockResult)
  of skTypeDecl:
    # Type declarations are processed during program initialization
    # No runtime type checking needed here
    discard
  of skImport:
    # FFI imports are processed during program initialization
    # They register functions in the global FFI registry
    discard
