# statements.nim
# Statement type checking

import std/[strformat, options, tables, strutils]
import ../common/[types, errors]
import ../frontend/ast
import types, expressions


proc typecheckStmt*(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst; isBlockResult: bool = false)
proc inferMatchExpr*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst): EtchType


proc typecheckVar(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if s.vtype.kind == tkGeneric:
    raise newTypecheckError(s.pos, "generic variable type not allowed at runtime scope")

  # Handle deferred type inference
  if s.vtype.kind == tkInferred:
    if s.vinit.isNone():
      raise newTypecheckError(s.pos, &"variable '{s.vname}' with inferred type must have an initializer")

    # Special handling for match expressions during deferred type inference
    if s.vinit.get().kind == ekMatch:
      # Infer match expression type directly using type checker
      var tempSubst = subst
      let inferredType = inferMatchExpr(prog, fd, sc, s.vinit.get(), tempSubst)
      s.vtype = inferredType
    else:
      # Try regular type inference for other expressions
      let inferredType = inferTypeFromExpr(s.vinit.get(), sc)
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
        # TODO: Pass expected type to inferMatchExpr when it supports it
        inferMatchExpr(prog, fd, tempScope, s.vinit.get(), tempSubst)
      else:
        inferExprTypes(prog, fd, tempScope, s.vinit.get(), tempSubst, resolvedVtype)
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

  sc.types[s.vname] = resolvedVtype
  sc.flags[s.vname] = s.vflag


proc typecheckAssign(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if not sc.types.hasKey(s.aname): raise newTypecheckError(s.pos, "unknown variable '" & s.aname & "'")
  if sc.flags.hasKey(s.aname) and sc.flags[s.aname] == vfLet:
    raise newTypecheckError(s.pos, &"cannot assign to immutable variable '{s.aname}'")
  let t0 = inferExprTypes(prog, fd, sc, s.aval, subst)
  let varType = sc.types[s.aname]

  # Allow nil (ref[void]) to be assigned to any reference type
  var typesCompatible = typeEq(t0, varType)
  if not typesCompatible and t0.kind == tkRef and t0.inner.kind == tkVoid and varType.kind == tkRef:
    typesCompatible = true  # nil can be assigned to any reference type

  if not typesCompatible:
    if t0.kind == tkVoid:
      raise newTypecheckError(s.pos, &"cannot assign void function result to variable '{s.aname}'")
    else:
      raise newTypecheckError(s.pos, "assignment type mismatch")


proc typecheckFieldAssign(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Typecheck the target expression (the field access)
  let targetType = inferExprTypes(prog, fd, sc, s.faTarget, subst)

  # The target must be a field access expression
  if s.faTarget.kind != ekFieldAccess:
    raise newTypecheckError(s.pos, &"invalid assignment target")

  # Typecheck the value expression
  let valueType = inferExprTypes(prog, fd, sc, s.faValue, subst)

  # Check type compatibility
  var typesCompatible = typeEq(valueType, targetType)
  if not typesCompatible and valueType.kind == tkRef and valueType.inner.kind == tkVoid and targetType.kind == tkRef:
    typesCompatible = true  # nil can be assigned to any reference type

  if not typesCompatible:
    if valueType.kind == tkVoid:
      raise newTypecheckError(s.pos, &"cannot assign void function result to field")
    else:
      raise newTypecheckError(s.pos, &"field assignment type mismatch")


proc typecheckIf(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  let ct = inferExprTypes(prog, fd, sc, s.cond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "if condition must be bool")
  var sThen = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog) # shallow copy ok
  for st in s.thenBody: typecheckStmt(prog, fd, sThen, st, subst)

  # Typecheck elif chain
  for elifBranch in s.elifChain:
    let elifCondType = inferExprTypes(prog, fd, sc, elifBranch.cond, subst)
    if elifCondType.kind != tkBool: raise newTypecheckError(s.pos, "elif condition must be bool")
    var sElif = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
    for st in elifBranch.body: typecheckStmt(prog, fd, sElif, st, subst)

  var sElse = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for st in s.elseBody: typecheckStmt(prog, fd, sElse, st, subst)


proc typecheckWhile(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  let ct = inferExprTypes(prog, fd, sc, s.wcond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "while condition must be bool")
  var sBody = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for st in s.wbody: typecheckStmt(prog, fd, sBody, st, subst)


proc typecheckReturn(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if fd == nil: return
  if fd.ret.kind == tkVoid:
    if s.re.isSome(): raise newTypecheckError(s.pos, "void function cannot return a value")
  else:
    if not s.re.isSome(): raise newTypecheckError(s.pos, "non-void function must return a value")
    # Special handling for match expressions in return statements
    var rt: EtchType
    if s.re.get().kind == ekMatch:
      rt = inferMatchExpr(prog, fd, sc, s.re.get(), subst)
    else:
      rt = inferExprTypes(prog, fd, sc, s.re.get(), subst, fd.ret)

    # Check if return type is compatible (including union compatibility)
    if not canAssignDistinct(fd.ret, rt):
      raise newTypecheckError(s.pos, &"return type mismatch: expected {fd.ret}, got {rt}")


proc typecheckComptime(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Typecheck comptime block statements and add injected variables to main scope
  var ctScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)
  for stmt in s.cbody:
    typecheckStmt(prog, fd, ctScope, stmt, subst)
    # If this is a variable declaration, add it to the main scope (injected variables)
    if stmt.kind == skVar:
      sc.types[stmt.vname] = stmt.vtype


proc typecheckFor(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Create new scope for loop body with loop variable
  var loopScope = Scope(types: sc.types, flags: sc.flags, userTypes: sc.userTypes, prog: sc.prog)

  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayType = inferExprTypes(prog, fd, sc, s.farray.get(), subst)

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
    let startType = inferExprTypes(prog, fd, sc, s.fstart.get(), subst)
    let endType = inferExprTypes(prog, fd, sc, s.fend.get(), subst)

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
    typecheckStmt(prog, fd, loopScope, stmt, subst)


proc typecheckBreak(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Break statements don't need special type checking, just verify they're valid
  # (validation that break is inside a loop is done at parse time or runtime)
  discard


proc typecheckStmtList*(prog: Program; fd: FunDecl; sc: Scope; stmts: seq[Stmt]; subst: var TySubst; blockResultUsed: bool = false): EtchType =
  ## Type check a list of statements and return the type of the last expression (or void)
  var resultType = tVoid()
  for j, stmt in stmts:
    let isLastStmt = (j == stmts.len - 1)
    let isBlockResult = isLastStmt and blockResultUsed and stmt.kind == skExpr
    typecheckStmt(prog, fd, sc, stmt, subst, isBlockResult)
    if isLastStmt and stmt.kind == skExpr:
      # Last statement is expression - this determines block type
      resultType = stmt.sexpr.typ
  return resultType


proc inferMatchExpr*(prog: Program; fd: FunDecl; sc: Scope; e: Expr; subst: var TySubst): EtchType =
  # Type check the matched expression
  let matchedType = inferExprTypes(prog, fd, sc, e.matchExpr, subst)

  # Verify matched expression is option, result, or union type
  if matchedType.kind notin [tkOption, tkResult, tkUnion]:
    raise newTypecheckError(e.pos, &"match can only be used with option[T], result[T], or union types, got {matchedType}")

  # Check all cases and determine result type
  if e.cases.len == 0:
    raise newTypecheckError(e.pos, "match expression must have at least one case")

  var resultType: EtchType = nil
  var hasRelevantCases = false

  for i, matchCase in e.cases:
    # Verify pattern matches the matched type
    case matchedType.kind:
    of tkOption:
      if matchCase.pattern.kind notin {pkSome, pkNone, pkWildcard}:
        raise newTypecheckError(e.pos, &"invalid pattern for option[T]: expected some(_), none, or _")
      hasRelevantCases = true
    of tkResult:
      if matchCase.pattern.kind notin {pkOk, pkErr, pkWildcard}:
        raise newTypecheckError(e.pos, &"invalid pattern for result[T]: expected ok(_), error(_), or _")
      hasRelevantCases = true
    of tkUnion:
      if matchCase.pattern.kind notin {pkType, pkWildcard}:
        raise newTypecheckError(e.pos, &"invalid pattern for union type: expected type pattern or _")
      # Verify the type pattern matches one of the union types
      if matchCase.pattern.kind == pkType:
        var validPattern = false
        for ut in matchedType.unionTypes:
          if typeEq(matchCase.pattern.typePattern, ut):
            validPattern = true
            break
        if not validPattern:
          raise newTypecheckError(e.pos, &"pattern type {matchCase.pattern.typePattern} is not part of union {matchedType}")
      hasRelevantCases = true
    else:
      discard

    # Create scope for pattern bindings
    var caseScope = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: sc.userTypes, prog: sc.prog)
    # Copy parent scope
    for k, v in sc.types: caseScope.types[k] = v
    for k, v in sc.flags: caseScope.flags[k] = v

    # Add pattern binding to scope
    case matchCase.pattern.kind:
    of pkSome, pkOk:
      caseScope.types[matchCase.pattern.bindName] = matchedType.inner
      caseScope.flags[matchCase.pattern.bindName] = vfLet
    of pkErr:
      # For error patterns, bind the error value (usually string)
      caseScope.types[matchCase.pattern.bindName] = tString()  # Assume error messages are strings
      caseScope.flags[matchCase.pattern.bindName] = vfLet
    of pkType:
      # For type patterns in unions, bind the value with the matched type
      if matchCase.pattern.typeBind.len > 0:
        caseScope.types[matchCase.pattern.typeBind] = matchCase.pattern.typePattern
        caseScope.flags[matchCase.pattern.typeBind] = vfLet
    else:
      discard

    # Type check all statements in case body
    # The block result is used (it becomes the value of this match arm)
    let caseType = typecheckStmtList(prog, fd, caseScope, matchCase.body, subst, blockResultUsed = true)

    # Use the type returned by typecheckStmtList, which correctly handles
    # the type of the last expression in the block
    var actualCaseType: EtchType = if caseType != nil: caseType else: tVoid()


    # Check type consistency across all match arms
    if resultType == nil:
      resultType = actualCaseType
    elif not typeEq(resultType, actualCaseType):
      raise newTypecheckError(e.pos, &"match arm {i+1} returns type {actualCaseType} but previous arms return {resultType}. All match arms must return the same type")

  if not hasRelevantCases:
    raise newTypecheckError(e.pos, "match expression must have at least one relevant case")

  if resultType == nil:
    resultType = tVoid()

  e.typ = resultType
  return resultType


proc typecheckStmt*(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst; isBlockResult: bool = false) =
  case s.kind
  of skVar: typecheckVar(prog, fd, sc, s, subst)
  of skAssign: typecheckAssign(prog, fd, sc, s, subst)
  of skFieldAssign: typecheckFieldAssign(prog, fd, sc, s, subst)
  of skIf: typecheckIf(prog, fd, sc, s, subst)
  of skWhile: typecheckWhile(prog, fd, sc, s, subst)
  of skFor: typecheckFor(prog, fd, sc, s, subst)
  of skBreak: typecheckBreak(prog, fd, sc, s, subst)
  of skExpr:
    if s.sexpr.kind == ekMatch:
      s.sexpr.typ = inferMatchExpr(prog, fd, sc, s.sexpr, subst)
      # Check if match expression result is non-void and not used
      if s.sexpr.typ.kind != tkVoid and not isBlockResult:
        raise newTypecheckError(s.pos, &"match expression returns '{s.sexpr.typ}' but result is not used; use 'discard' to explicitly ignore the return value")
    else:
      let exprType = inferExprTypes(prog, fd, sc, s.sexpr, subst)
      # Check if this is a function call with non-void return type
      # If so, it must be explicitly discarded
      # BUT: if this expression is the result of a block that's being used, then it IS being used
      if s.sexpr.kind == ekCall and exprType.kind != tkVoid and not isBlockResult:
        let unmangledName = demangleFunctionSignature(s.sexpr.fname)
        raise newTypecheckError(s.pos, &"function '{unmangledName}' returns '{exprType}' but result is not used; use 'discard' to explicitly ignore the return value")
  of skDiscard:
    # Type check all discarded expressions but ignore their results
    for expr in s.dexprs:
      let exprType = inferExprTypes(prog, fd, sc, expr, subst)
      # Emit a warning/error if discarding a void expression (it's redundant)
      if exprType.kind == tkVoid and expr.kind == ekCall:
        let unmangledName = demangleFunctionSignature(expr.fname)
        raise newTypecheckError(s.pos, &"cannot discard void function '{unmangledName}'; void results are automatically discarded")
  of skReturn: typecheckReturn(prog, fd, sc, s, subst)
  of skComptime: typecheckComptime(prog, fd, sc, s, subst)
  of skTypeDecl:
    # Type declarations are processed during program initialization
    # No runtime type checking needed here
    discard
  of skImport:
    # FFI imports are processed during program initialization
    # They register functions in the global FFI registry
    discard
