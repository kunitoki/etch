# lambda.nim
# Lambda expression type checking and name resolution

import std/[tables, strformat, options]
import ../../common/[errors, types]
import ../frontend/ast
import types

type
  LambdaValidationError* = object of TypecheckError


proc inferExpressionTypes(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType {.importc.}


proc typecheckLambdaBodyStatements*(prog: Program; fd: FunctionDeclaration; sc: Scope;
                                    lambdaScope: Scope; body: seq[Statement];
                                    subst: var TySubst; expectedReturnType: EtchType): EtchType =
  ## Type check lambda body statements and return the inferred return type
  ## This function is designed to be called from expressions.nim without circular dependencies

  if body.len == 0:
    return tVoid()

  var bodyReturnType: EtchType = tVoid()  # Default return type if no return statement

  # Check each statement in the lambda body
  for i, stmt in body:
    let isLastStatement = (i == body.len - 1)

    if isLastStatement:
      # Last statement determines the return type
      if stmt.kind == skExpression:
        # Last statement is an expression - this is the return value
        bodyReturnType = inferExpressionTypes(prog, fd, lambdaScope, stmt.sexpr, subst, expectedReturnType)
      elif stmt.kind == skReturn:
        # Return statement - type check the returned expression
        if stmt.re.isSome:
          bodyReturnType = inferExpressionTypes(prog, fd, lambdaScope, stmt.re.get, subst, expectedReturnType)
        else:
          bodyReturnType = tVoid()
      else:
        # Other statement types (like declarations) - return void
        bodyReturnType = tVoid()
    else:
      # Non-final statements - type check them recursively
      # This creates a simplified version that only supports expressions for now
      case stmt.kind
      of skExpression:
        discard inferExpressionTypes(prog, fd, lambdaScope, stmt.sexpr, subst)
      of skVar:
        # Basic variable declaration support
        if stmt.vtype.kind == tkGeneric:
          raise newTypecheckError(stmt.pos, "generic variable type not allowed in lambda")

        # Handle deferred type inference
        if stmt.vtype.kind == tkInferred:
          if stmt.vinit.isNone():
            raise newTypecheckError(stmt.pos, &"variable '{stmt.vname}' with inferred type must have an initializer")

          var tempSubst = subst
          let inferredType = inferExpressionTypes(prog, fd, lambdaScope, stmt.vinit.get(), tempSubst)
          if inferredType == nil:
            raise newTypecheckError(stmt.pos, &"cannot infer type for variable '{stmt.vname}', please provide explicit type annotation")
          stmt.vtype = inferredType

        # Resolve user-defined types
        stmt.vtype = resolveNestedUserTypes(lambdaScope, stmt.vtype, stmt.pos)

        # Type check initialization if present
        if stmt.vinit.isSome():
          let initType = inferExpressionTypes(prog, fd, lambdaScope, stmt.vinit.get(), subst, stmt.vtype)
          if not canAssignDistinct(stmt.vtype, initType):
            raise newTypecheckError(stmt.pos, &"initialization type mismatch: {initType} vs {stmt.vtype}")

        # Add to lambda scope
        lambdaScope.types[stmt.vname] = stmt.vtype
        lambdaScope.flags[stmt.vname] = stmt.vflag

      of skAssign:
        # Basic assignment support
        if not lambdaScope.types.hasKey(stmt.aname):
          raise newTypecheckError(stmt.pos, "unknown variable '" & stmt.aname & "'")
        if lambdaScope.flags.hasKey(stmt.aname) and lambdaScope.flags[stmt.aname] == vfLet:
          raise newTypecheckError(stmt.pos, &"cannot assign to immutable variable '{stmt.aname}'")
        let varType = lambdaScope.types[stmt.aname]
        let t0 = inferExpressionTypes(prog, fd, lambdaScope, stmt.aval, subst, varType)
        if not canAssignDistinct(varType, t0):
          raise newTypecheckError(stmt.pos, &"assignment type mismatch: cannot assign '{t0}' to variable '{stmt.aname}' of type '{varType}'")
      of skCompoundAssign:
        if not lambdaScope.types.hasKey(stmt.caname):
          raise newTypecheckError(stmt.pos, "unknown variable '" & stmt.caname & "'")
        if lambdaScope.flags.hasKey(stmt.caname) and lambdaScope.flags[stmt.caname] == vfLet:
          raise newTypecheckError(stmt.pos, &"cannot assign to immutable variable '{stmt.caname}'")
        let varType = lambdaScope.types[stmt.caname]
        discard inferExpressionTypes(prog, fd, lambdaScope, stmt.crhs, subst, varType)
        let binExpr = compoundAssignExpression(stmt)
        let resultType = inferExpressionTypes(prog, fd, lambdaScope, binExpr, subst, varType)
        if not canAssignDistinct(varType, resultType):
          raise newTypecheckError(stmt.pos, &"compound assignment type mismatch: cannot assign '{resultType}' to variable '{stmt.caname}' of type '{varType}'")

      else:
        # Other statement types are not supported in lambda bodies yet
        raise newTypecheckError(stmt.pos, &"statement type '{stmt.kind}' not yet supported in lambda bodies (only expressions, variable declarations, and basic assignments are supported)")

  return bodyReturnType


proc resolveExpectedFunctionType(sc: Scope; expected: EtchType; pos: Pos): EtchType =
  ## Resolve the expected type and ensure it's a function if provided
  if expected == nil:
    return nil
  let resolved = resolveNestedUserTypes(sc, expected, pos)
  if resolved != nil and resolved.kind == tkFunction:
    return resolved
  else:
    return nil


proc inferLambdaExpression*(prog: Program; fd: FunctionDeclaration; sc: Scope;
                           e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  ## Type check lambda expression: [captures] |params| -> returnType { body }
  ## Implements proper name resolution for lambda captures and parameters

  let expectedFnType = resolveExpectedFunctionType(sc, expectedTy, e.pos)
  if expectedTy != nil and expectedFnType == nil:
    raise newTypecheckError(e.pos, &"lambda cannot be assigned to non-function type '{expectedTy}'")

  var expectedParamTypes: seq[EtchType] = @[]
  var expectedReturnType: EtchType = nil
  if expectedFnType != nil:
    expectedParamTypes = expectedFnType.funcParams
    expectedReturnType = expectedFnType.funcReturn
    if expectedParamTypes.len != e.lambdaParams.len:
      raise newTypecheckError(e.pos, &"lambda parameter count mismatch: expected {expectedParamTypes.len}, got {e.lambdaParams.len}")

  # Step 1: Validate capture list - check that captured variables exist in outer scope
  var capturedTypes = initTable[string, EtchType]()
  for captureName in e.lambdaCaptures:
    if not sc.types.hasKey(captureName):
      raise newTypecheckError(e.pos, &"lambda capture '{captureName}' not found in outer scope")
    capturedTypes[captureName] = resolveNestedUserTypes(sc, sc.types[captureName], e.pos)

  # Ensure captures don't conflict with parameter names
  for param in e.lambdaParams:
    if capturedTypes.hasKey(param.name):
      raise newTypecheckError(e.pos, &"lambda parameter '{param.name}' conflicts with captured variable of the same name")

  # Step 2: Create lambda-specific scope with captured variables and parameters
  var lambdaScope = Scope(
    types: initTable[string, EtchType](),
    flags: initTable[string, VarFlag](),
    userTypes: sc.userTypes,  # Inherit user types from outer scope
    prog: sc.prog
  )

  # Add captured variables to lambda scope (these become closure variables)
  for captureName, captureType in capturedTypes:
    lambdaScope.types[captureName] = captureType
    # Captured variables are read-only from the lambda's perspective
    lambdaScope.flags[captureName] = vfLet

  # Step 3: Add lambda parameters to scope
  var paramTypes: seq[EtchType] = @[]
  for i, param in e.lambdaParams:
    # Resolve parameter type if specified
    var paramType = if param.typ != nil: resolveNestedUserTypes(sc, param.typ, e.pos) else: nil
    let expectedParamType = if i < expectedParamTypes.len: expectedParamTypes[i] else: nil
    if paramType == nil and expectedParamType != nil:
      paramType = expectedParamType
    elif paramType != nil and expectedParamType != nil and not canAssignDistinct(expectedParamType, paramType):
      raise newTypecheckError(e.pos, &"parameter '{param.name}' type {paramType} incompatible with expected {expectedParamType}")

    # Handle default parameter values
    if param.defaultValue.isSome:
      let defaultType = inferExpressionTypes(prog, fd, lambdaScope, param.defaultValue.get, subst, paramType)
      if paramType != nil and not canAssignDistinct(paramType, defaultType):
        raise newTypecheckError(param.defaultValue.get.pos, &"default value for parameter '{param.name}' has type {defaultType}, expected {paramType}")
      if paramType == nil:
        paramType = defaultType

    # Parameter must have a type (either explicit or inferred from default)
    if paramType == nil:
      raise newTypecheckError(e.pos, &"parameter '{param.name}' requires explicit type annotation")

    # Add parameter to lambda scope (parameters shadow outer variables)
    lambdaScope.types[param.name] = paramType
    lambdaScope.flags[param.name] = vfLet
    e.lambdaParams[i].typ = paramType
    paramTypes.add(paramType)

  # Step 4: Determine lambda return type
  var explicitReturnType = e.lambdaReturnType
  let lambdaHasExplicitReturn = explicitReturnType != nil
  if explicitReturnType != nil:
    explicitReturnType = resolveNestedUserTypes(lambdaScope, explicitReturnType, e.pos)
  var finalReturnType = explicitReturnType
  if finalReturnType == nil and expectedReturnType != nil:
    finalReturnType = expectedReturnType

  # Step 5: Type check lambda body in the lambda scope
  if e.lambdaBody.len > 0:
    let expectedBodyReturn = if explicitReturnType != nil: explicitReturnType else: expectedReturnType
    let bodyReturnType = typecheckLambdaBodyStatements(prog, fd, sc, lambdaScope, e.lambdaBody, subst, expectedBodyReturn)

    if explicitReturnType != nil:
      if not canAssignDistinct(explicitReturnType, bodyReturnType):
        raise newTypecheckError(e.pos, &"lambda return type mismatch: expected {explicitReturnType}, got {bodyReturnType}")
      finalReturnType = explicitReturnType
    elif expectedReturnType != nil:
      if not canAssignDistinct(expectedReturnType, bodyReturnType):
        raise newTypecheckError(e.pos, &"lambda return type mismatch: expected {expectedReturnType}, got {bodyReturnType}")
      finalReturnType = expectedReturnType
    else:
      finalReturnType = bodyReturnType

  if finalReturnType == nil:
    finalReturnType = tVoid()

  # Record capture types for downstream stages
  var captureTypesSeq: seq[EtchType] = @[]
  for captureName in e.lambdaCaptures:
    captureTypesSeq.add(capturedTypes[captureName])
  e.lambdaCaptureTypes = captureTypesSeq

  # Assign a unique function name and register the lambda as a concrete function
  if e.lambdaFunctionName.len == 0:
    let lambdaName = "__lambda_" & $prog.lambdaCounter
    inc prog.lambdaCounter
    e.lambdaFunctionName = lambdaName

    # Normalize lambda body so final expression becomes an explicit return.
    var normalizedBody = e.lambdaBody
    if normalizedBody.len > 0:
      let lastIdx = normalizedBody.high
      if normalizedBody[lastIdx].kind == skExpression:
        let lastExpr = normalizedBody[lastIdx].sexpr
        normalizedBody[lastIdx] = Statement(
          kind: skReturn,
          pos: normalizedBody[lastIdx].pos,
          re: some(lastExpr)
        )

    var loweredParams: seq[Param] = @[]
    for captureName in e.lambdaCaptures:
      loweredParams.add(Param(name: captureName, typ: capturedTypes[captureName], defaultValue: none(Expression)))
    for i, param in e.lambdaParams:
      loweredParams.add(Param(name: param.name, typ: paramTypes[i], defaultValue: param.defaultValue))

    let lambdaDecl = FunctionDeclaration(
      pos: e.pos,
      name: lambdaName,
      typarams: @[],
      params: loweredParams,
      ret: finalReturnType,
      hasExplicitReturnType: lambdaHasExplicitReturn,
      body: normalizedBody,
      isExported: false,
      isCFFI: false,
      isHost: false,
      isAsync: false
    )

    if not prog.funInstances.hasKey(lambdaName):
      prog.funInstances[lambdaName] = lambdaDecl

  e.typ = tFunction(paramTypes, finalReturnType)
  return e.typ
