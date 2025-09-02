proc analyzePrintCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  for arg in e.args: discard analyzeExpression(arg, env, ctx)
  return infoUnknown()


proc analyzeRandCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  for arg in e.args: discard analyzeExpression(arg, env, ctx)

  # Track the range of rand(max) or rand(max, min)
  if e.args.len == 1:
    let maxInfo = analyzeExpression(e.args[0], env, ctx)
    if maxInfo.known:
      # rand(max) returns 0 to max inclusive
      let isNonZero = maxInfo.cval < 0  # Only non-zero if max is negative (then range is [0, max] where max < 0 means no valid values)
      var res = symUnknown(makeScalar(0'i64), maxInfo.cval)
      res.nonZero = isNonZero
      return res
    else:
      # max is in a range, use the maximum possible value as the upper bound
      # rand(max) where max is in range [a, b] returns values in range [0, max(0,b)]
      let upperBound = max(0, maxInfo.maxv)
      var res = symUnknown(makeScalar(0'i64), upperBound)
      return res
  elif e.args.len == 2:
    let minInfo = analyzeExpression(e.args[0], env, ctx)
    let maxInfo = analyzeExpression(e.args[1], env, ctx)
    if maxInfo.known and minInfo.known:
      # Both arguments are constants
      let actualMin = min(minInfo.cval, maxInfo.cval)
      let actualMax = max(minInfo.cval, maxInfo.cval)
      # Special case: if min == max, the result is deterministic
      if actualMin == actualMax:
        return infoConst(actualMin)
      else:
        # rand(max, min) returns a value in range [actualMin, actualMax]
        let isNonZero = actualMin > 0 or actualMax < 0
        return Info(known: false, minv: actualMin, maxv: actualMax, nonZero: isNonZero, initialized: true)
    else:
      # Use range information even when not constant
      let actualMin = min(minInfo.minv, maxInfo.minv)
      let actualMax = max(minInfo.maxv, maxInfo.maxv)
      return Info(known: false, minv: actualMin, maxv: actualMax, nonZero: actualMin > 0 or actualMax < 0, initialized: true)
  else:
    # Invalid rand call, return unknown
    return infoUnknown()


proc analyzeParseIntCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  if e.args.len > 0:
    discard analyzeExpression(e.args[0], env, ctx)
  # parseInt can return any valid integer that fits in a string representation
  # The actual range should be based on realistic string parsing limits
  return infoUnknown()


proc analyzeArrayNewCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  if e.args.len != 2:
    return infoUnknown()

  let sizeInfo = analyzeExpression(e.args[0], env, ctx)
  discard analyzeExpression(e.args[1], env, ctx)  # Analyze default value for safety

  # If size is known, we can track the exact array size
  if sizeInfo.known and not sizeInfo.cval.isFloat:
    return infoArray(sizeInfo.cval.toInt, sizeKnown = true)
  # If size is in a range, track the range
  elif sizeInfo.minv >= 0 and not sizeInfo.minv.isFloat and not sizeInfo.maxv.isFloat:
    # We store the size range in minv/maxv so that #array can extract it
    var info = infoArray(sizeInfo.minv.toInt, sizeKnown = false)
    info.minv = sizeInfo.minv
    info.maxv = sizeInfo.maxv
    return info
  else:
    return infoArray(-1, sizeKnown = false)


proc analyzeBuiltinCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # recognize trusted builtins affecting nonNil/nonZero
  if e.fname == "print": return analyzePrintCall(e, env, ctx)
  if e.fname == "rand": return analyzeRandCall(e, env, ctx)
  # TODO: if e.fname == "parseBool": return analyzeParseBoolCall(e, env, ctx)
  if e.fname == "parseInt": return analyzeParseIntCall(e, env, ctx)
  # TODO: if e.fname == "parseFloat": return analyzeParseFloatCall(e, env, ctx)
  if e.fname == "arrayNew": return analyzeArrayNewCall(e, env, ctx)
  # TODO - missing builtins
  # Unknown builtin or CFFI/host function - analyze arguments to mark them as used
  for arg in e.args:
    let argInfo = analyzeExpression(arg, env, ctx)
    if ctx.options.verbose:
      logProver(ctx.options.verbose, "Builtin/CFFI/Host function argument: " & (if argInfo.known: $argInfo.cval else: "[" & $argInfo.minv & ".." & $argInfo.maxv & "]"))
  return infoUnknown()


proc extractPreconditionsFromExpression*(expr: Expression, paramNames: seq[string], paramMap: Table[string, int], abstractEnv: var Env, ctx: ProverContext): seq[Constraint] =
  ## Extract weakest preconditions from an expression
  ## Returns constraints on parameters that must hold for the expression to be safe
  result = @[]

  case expr.kind
  of ekIndex:
    # Array access: requires index in bounds
    result.add extractPreconditionsFromExpression(expr.arrayExpression, paramNames, paramMap, abstractEnv, ctx)
    result.add extractPreconditionsFromExpression(expr.indexExpression, paramNames, paramMap, abstractEnv, ctx)

    # Check if index is a parameter
    if expr.indexExpression.kind == ekVar and paramMap.hasKey(expr.indexExpression.vname):
      let paramIdx = paramMap[expr.indexExpression.vname]
      let paramName = expr.indexExpression.vname

      # Get array size if known
      let arrayInfo = analyzeExpression(expr.arrayExpression, abstractEnv, ctx)
      if arrayInfo.isArray and arrayInfo.arraySizeKnown:
        # Require: 0 <= param < arraySize
        result.add(Constraint(
          kind: ckRange,
          paramIndex: paramIdx,
          paramName: paramName,
          minv: makeScalar(0'i64),
          maxv: makeScalar(arrayInfo.arraySize - 1)
        ))

  of ekBin:
    # Recursive extraction from operands
    result.add extractPreconditionsFromExpression(expr.lhs, paramNames, paramMap, abstractEnv, ctx)
    result.add extractPreconditionsFromExpression(expr.rhs, paramNames, paramMap, abstractEnv, ctx)

    # Division and modulo require non-zero divisor
    if expr.bop in {boDiv, boMod}:
      if expr.rhs.kind == ekVar and paramMap.hasKey(expr.rhs.vname):
        let paramIdx = paramMap[expr.rhs.vname]
        var needsConstraint = true
        if abstractEnv != nil and abstractEnv.vals.hasKey(expr.rhs.vname):
          let knownInfo = abstractEnv.vals[expr.rhs.vname]
          needsConstraint = not knownInfo.nonZero
        if needsConstraint:
          result.add(Constraint(
            kind: ckNonZero,
            paramIndex: paramIdx,
            paramName: expr.rhs.vname
          ))

  of ekDeref:
    # Dereference requires non-nil
    result.add extractPreconditionsFromExpression(expr.refExpression, paramNames, paramMap, abstractEnv, ctx)

    if expr.refExpression.kind == ekVar and paramMap.hasKey(expr.refExpression.vname):
      let paramIdx = paramMap[expr.refExpression.vname]
      result.add(Constraint(
        kind: ckNonNil,
        paramIndex: paramIdx,
        paramName: expr.refExpression.vname
      ))

  of ekCall:
    # Function call - extract preconditions from arguments
    for arg in expr.args:
      result.add extractPreconditionsFromExpression(arg, paramNames, paramMap, abstractEnv, ctx)

  of ekUn:
    result.add extractPreconditionsFromExpression(expr.ue, paramNames, paramMap, abstractEnv, ctx)

  of ekLambda:
    # Lambda expressions - extract preconditions from the lambda body
    for stmt in expr.lambdaBody:
      result.add extractPreconditions(stmt, paramNames, paramMap, abstractEnv, ctx)

  else:
    # Other expression types don't require special preconditions
    discard


proc extractPreconditions*(stmt: Statement, paramNames: seq[string], paramMap: Table[string, int], abstractEnv: var Env, ctx: ProverContext): seq[Constraint] =
  ## Extract weakest preconditions from a statement
  result = @[]

  case stmt.kind
  of skExpression:
    result.add extractPreconditionsFromExpression(stmt.sexpr, paramNames, paramMap, abstractEnv, ctx)

  of skReturn:
    if stmt.re.isSome:
      result.add extractPreconditionsFromExpression(stmt.re.get, paramNames, paramMap, abstractEnv, ctx)

  of skVar:
    if stmt.vinit.isSome:
      result.add extractPreconditionsFromExpression(stmt.vinit.get, paramNames, paramMap, abstractEnv, ctx)

  of skAssign:
    result.add extractPreconditionsFromExpression(stmt.aval, paramNames, paramMap, abstractEnv, ctx)
  of skCompoundAssign:
    result.add extractPreconditionsFromExpression(compoundAssignExpression(stmt), paramNames, paramMap, abstractEnv, ctx)

  of skIf:
    # Extract from condition
    result.add extractPreconditionsFromExpression(stmt.cond, paramNames, paramMap, abstractEnv, ctx)

    # Analyze then branch under condition constraints
    var thenEnv = copyEnv(abstractEnv)
    applyConstraints(thenEnv, stmt.cond, abstractEnv, ctx, negate = false)
    for s in stmt.thenBody:
      result.add extractPreconditions(s, paramNames, paramMap, thenEnv, ctx)

    # Analyze elif branches with their own constraints
    for elif_branch in stmt.elifChain:
      result.add extractPreconditionsFromExpression(elif_branch.cond, paramNames, paramMap, abstractEnv, ctx)
      var elifEnv = copyEnv(abstractEnv)
      applyConstraints(elifEnv, elif_branch.cond, abstractEnv, ctx, negate = false)
      for s in elif_branch.body:
        result.add extractPreconditions(s, paramNames, paramMap, elifEnv, ctx)

    if stmt.elseBody.len > 0:
      var elseEnv = copyEnv(abstractEnv)
      applyConstraints(elseEnv, stmt.cond, abstractEnv, ctx, negate = true)
      for s in stmt.elseBody:
        result.add extractPreconditions(s, paramNames, paramMap, elseEnv, ctx)

  of skWhile:
    result.add extractPreconditionsFromExpression(stmt.wcond, paramNames, paramMap, abstractEnv, ctx)
    for s in stmt.wbody:
      result.add extractPreconditions(s, paramNames, paramMap, abstractEnv, ctx)

  of skFor:
    for s in stmt.fbody:
      result.add extractPreconditions(s, paramNames, paramMap, abstractEnv, ctx)

  else:
    discard


proc inferFunctionContract*(fn: FunctionDeclaration, fname: string, ctx: ProverContext): FunctionContract =
  ## Infer preconditions and postconditions from a function body
  ## Uses weakest precondition calculation to determine parameter requirements
  logProver(ctx.options.verbose, &"Inferring contract for function: {fname}")

  result = FunctionContract(funcName: fname)

  # Create symbolic environment for abstract analysis
  # Parameters start with unknown but initialized values
  var abstractEnv = Env(
    vals: initTable[string, Info](),
    nils: initTable[string, bool](),
    exprs: initTable[string, Expression](),
    declPos: initTable[string, Pos](),
    types: initTable[string, EtchType]())

  # Build parameter mapping
  var paramNames: seq[string] = @[]
  var paramMap: Table[string, int] = initTable[string, int]()

  for i, param in fn.params:
    paramNames.add(param.name)
    paramMap[param.name] = i
    # Start with completely unknown values
    abstractEnv.vals[param.name] = infoUnknown()
    abstractEnv.nils[param.name] = false
    abstractEnv.types[param.name] = param.typ

  # Extract preconditions using weakest precondition calculation
  logProver(ctx.options.verbose, "Extracting preconditions from function body...")

  var allPreconditions: seq[Constraint] = @[]
  for stmt in fn.body:
    let stmtPreconditions = extractPreconditions(stmt, paramNames, paramMap, abstractEnv, ctx)
    allPreconditions.add stmtPreconditions

  # Merge and deduplicate constraints
  var constraintMap: Table[(int, ConstraintKind), Constraint] = initTable[(int, ConstraintKind), Constraint]()

  for constraint in allPreconditions:
    let key = (constraint.paramIndex, constraint.kind)

    if constraint.kind == ckRange:
      # For range constraints, take the intersection (most restrictive)
      if constraintMap.hasKey(key):
        var existing = constraintMap[key]
        existing.minv = max(existing.minv, constraint.minv)
        existing.maxv = min(existing.maxv, constraint.maxv)
        constraintMap[key] = existing
      else:
        constraintMap[key] = constraint
    else:
      # For other constraints, just keep one instance
      if not constraintMap.hasKey(key):
        constraintMap[key] = constraint

  # Convert to sequence
  for constraint in constraintMap.values:
    result.preconditions.add(constraint)

  logProver(ctx.options.verbose, &"Extracted {result.preconditions.len} preconditions")

  # Try to infer postconditions by analyzing return statements
  proc findReturnInfo(stmt: Statement): Option[Info] =
    case stmt.kind
    of skReturn:
      if stmt.re.isSome:
        let tmpCtx = newProverContext(&"function {fname}", ctx.options, ctx.prog)
        return some(analyzeExpression(stmt.re.get, abstractEnv, tmpCtx))
    of skIf:
      # Check both branches
      let thenResult = block:
        var found: Option[Info] = none(Info)
        for s in stmt.thenBody:
          let r = findReturnInfo(s)
          if r.isSome:
            found = r
            break
        found
      if thenResult.isSome:
        return thenResult
      if stmt.elseBody.len > 0:
        for s in stmt.elseBody:
          let r = findReturnInfo(s)
          if r.isSome:
            return r
    else:
      discard
    return none(Info)

  # Find return value info
  for stmt in fn.body:
    let returnInfo = findReturnInfo(stmt)
    if returnInfo.isSome:
      let info = returnInfo.get
      result.returnRange = (info.minv, info.maxv)
      # Infer postconditions about return value
      result.postconditions = inferConstraintFromInfo(info, -1, "return")
      break

  # If no return info found, assume unknown range
  if result.returnRange.minv == makeScalar(0'i64) and result.returnRange.maxv == makeScalar(0'i64):
    result.returnRange = (makeScalar(IMin), makeScalar(IMax))

  logProver(ctx.options.verbose, &"Inferred contract for {fname}: {result.preconditions.len} preconditions, {result.postconditions.len} postconditions")


proc analyzeUserDefinedCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # User-defined function call - can use contracts or full analysis
  let fn = ctx.prog.funInstances[e.fname]

  logProver(ctx.options.verbose, &"Analyzing user-defined function call: {e.fname}")

  # Analyze arguments first to get their safety information
  var argInfos: seq[Info] = @[]
  for i, arg in e.args:
    let argInfo = analyzeExpression(arg, env, ctx)
    argInfos.add argInfo
    logProver(ctx.options.verbose, "Argument " & $i & ": " & (if argInfo.known: $argInfo.cval else: "[" & $argInfo.minv & ".." & $argInfo.maxv & "]"))

  # Add default parameter information
  for i in e.args.len..<fn.params.len:
    if fn.params[i].defaultValue.isSome:
      let defaultInfo = analyzeExpression(fn.params[i].defaultValue.get, env, ctx)
      argInfos.add defaultInfo
      logProver(ctx.options.verbose, "Default param " & $i & ": " & (if defaultInfo.known: $defaultInfo.cval else: "[" & $defaultInfo.minv & ".." & $defaultInfo.maxv & "]"))
    else:
      argInfos.add infoUnknown()

  # Check for recursion - use contracts for recursive calls
  let isRecursive = e.fname in ctx.callStack
  if isRecursive:
    logProver(ctx.options.verbose, &"Recursive call detected for {e.fname}, using contract-based analysis")

    # Get or infer contract for this function
    var contract: FunctionContract
    if ctx.contracts.hasKey(e.fname):
      contract = ctx.contracts[e.fname]
      logProver(ctx.options.verbose, &"Using cached contract for {e.fname}")
    else:
      # Infer contract from function definition
      contract = inferFunctionContract(fn, e.fname, ctx)
      ctx.contracts[e.fname] = contract
      logProver(ctx.options.verbose, &"Inferred and cached contract for {e.fname}")

    # Check preconditions at call site
    for precond in contract.preconditions:
      if precond.paramIndex >= 0 and precond.paramIndex < argInfos.len:
        let argInfo = argInfos[precond.paramIndex]
        if not checkConstraint(precond, argInfo, fn.params[precond.paramIndex].name):
          logProver(ctx.options.verbose, &"Precondition failed for param '{precond.paramName}' (kind={precond.kind}) with arg info known={argInfo.known} cval={argInfo.cval} min={argInfo.minv} max={argInfo.maxv} nonZero={argInfo.nonZero}")
          raise newProveError(e.pos, &"precondition violated for parameter '{precond.paramName}' in call to {e.fname}")

    # Apply postconditions to get return value info
    var returnInfo = infoRange(contract.returnRange.minv, contract.returnRange.maxv)
    for postcond in contract.postconditions:
      returnInfo = applyConstraintToInfo(postcond, returnInfo)

    logProver(ctx.options.verbose, &"Contract-based analysis complete for {e.fname}, return: [{returnInfo.minv}..{returnInfo.maxv}]")
    return returnInfo

  # Check for recursion depth limit BEFORE any analysis
  if e.fname in ctx.callStack:
    logProver(ctx.options.verbose, &"Recursive call detected for {e.fname}, using conservative analysis")
    return infoUnknown()

  if ctx.callStack.len >= MAX_RECURSION_DEPTH:
    logProver(ctx.options.verbose, &"Maximum recursion depth reached, using conservative analysis for {e.fname}")
    return infoUnknown()

  # Add function to call stack BEFORE any analysis (including compile-time evaluation)
  # This prevents infinite recursion during constant folding
  var newCtx = ProverContext(
    fnContext: ctx.fnContext,
    options: ctx.options,
    prog: ctx.prog,
    callStack: ctx.callStack & @[e.fname]
  )

  # Check if all arguments are compile-time constants for potential constant folding
  # Do this AFTER adding to callStack to prevent infinite recursion
  var allArgsConstant = true
  var compileTimeConst: Option[Info] = none(Info)
  for argInfo in argInfos:
    if not argInfo.known:
      allArgsConstant = false
      break

  # If all arguments are constants, try to evaluate simple pure functions at compile time
  if allArgsConstant:
    logProver(newCtx.options.verbose, "All arguments are constants - attempting compile-time evaluation")
    let evalResult = tryEvaluatePureFunction(e, argInfos, fn, ctx.prog)
    if evalResult.isSome:
      logProver(newCtx.options.verbose, &"Function evaluated at compile-time to: {evalResult.get}")
      compileTimeConst = some(infoConst(evalResult.get))

  # Create function call environment with parameter mappings
  # Start with global environment but override with parameter mappings
  var callEnv = Env(
    vals: initTable[string, Info](),
    nils: initTable[string, bool](),
    exprs: initTable[string, Expression](),
    declPos: initTable[string, Pos](),
    types: initTable[string, EtchType]())

  # Copy global variables from calling environment
  # First collect parameter names
  var paramNames: seq[string] = @[]
  for param in fn.params:
    paramNames.add(param.name)

  for k, v in env.vals:
    if k notin paramNames:  # Don't copy if it's a parameter name
      callEnv.vals[k] = v
  for k, v in env.nils:
    if k notin paramNames:
      callEnv.nils[k] = v
  for k, v in env.exprs:
    if k notin paramNames:
      callEnv.exprs[k] = v
  for k, v in env.declPos:
    if k notin paramNames:
      callEnv.declPos[k] = v
  for k, v in env.types:
    if k notin paramNames:
      callEnv.types[k] = v

  # Set up parameter environment with actual call-site information
  for i in 0..<min(argInfos.len, fn.params.len):
    let paramName = fn.params[i].name
    var paramInfo = argInfos[i]
    if fn.params[i].typ != nil:
      callEnv.types[paramName] = fn.params[i].typ
      if fn.params[i].typ.kind == tkWeak:
        downgradeWeakInfo(paramInfo)
    callEnv.vals[paramName] = paramInfo
    callEnv.nils[paramName] = not paramInfo.nonNil
    # Store the original argument expression if it's simple enough
    if i < e.args.len:
      callEnv.exprs[paramName] = e.args[i]
    logProver(newCtx.options.verbose, "Parameter '" & paramName & "' mapped to: " & (if paramInfo.known: $paramInfo.cval else: "[" & $paramInfo.minv & ".." & $paramInfo.maxv & "]"))

  # Perform comprehensive safety analysis on function body
  let fnContext = &"function {functionNameFromSignature(e.fname)}"
  var initialNames: seq[string] = @[]
  for name in callEnv.vals.keys:
    initialNames.add(name)
  logProver(newCtx.options.verbose, &"Starting comprehensive analysis of function body with {fn.body.len} statements")

  var usageSnapshot = initTable[string, bool]()
  for name, info in callEnv.vals:
    usageSnapshot[name] = info.used

  proc logUsageChanges(stmtIndex: int) =
    if not newCtx.options.verbose:
      return
    for name, info in callEnv.vals:
      let prev = usageSnapshot.getOrDefault(name, false)
      if info.used and not prev:
        logProver(true, &"Variable '{name}' marked as used after statement {stmtIndex + 1}/{fn.body.len}")
      if info.used != prev:
        usageSnapshot[name] = info.used

  # Recursive helper to analyze expressions for all safety violations
  proc checkExpressionSafety(expr: Expression) =
    case expr.kind
    of ekBin:
      # Check both operands first
      checkExpressionSafety(expr.lhs)
      checkExpressionSafety(expr.rhs)

      # Then check the binary operation itself
      case expr.bop
      of boDiv, boMod:
        let divisorInfo = analyzeExpression(expr.rhs, callEnv, newCtx)
        if divisorInfo.known and divisorInfo.cval == 0:
          let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
          raise newProveError(expr.pos, &"division by zero in {fnCtx}")
        elif not divisorInfo.nonZero:
          let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
          raise newProveError(expr.pos, &"cannot prove divisor is non-zero in {fnCtx}")
      of boAdd, boSub, boMul:
        # Check for potential overflow/underflow
        # The binary operations module already does overflow checks
        # Use newCtx to preserve call stack
        var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
        discard analyzeBinaryExpression(expr, callEnv, tmpCtx)
      else:
        discard

    of ekIndex:
      # Array bounds checking
      checkExpressionSafety(expr.arrayExpression)
      checkExpressionSafety(expr.indexExpression)
      var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
      let indexInfo = analyzeExpression(expr.indexExpression, callEnv, tmpCtx)
      if indexInfo.known and indexInfo.cval < 0:
        let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
        raise newProveError(expr.pos, &"negative array index in {fnCtx}")
      # Additional bounds checking is done by the recursive call to analyzeExpression
      discard analyzeExpression(expr, callEnv, tmpCtx)

    of ekSlice:
      # Slice bounds checking
      if expr.startExpression.isSome:
        checkExpressionSafety(expr.startExpression.get)
      if expr.endExpression.isSome:
        checkExpressionSafety(expr.endExpression.get)
      checkExpressionSafety(expr.sliceExpression)
      var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
      discard analyzeExpression(expr, callEnv, tmpCtx)

    of ekDeref:
      # Nil dereference checking
      var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
      let refInfo = analyzeExpression(expr.refExpression, callEnv, tmpCtx)
      if not refInfo.nonNil:
        let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
        raise newProveError(expr.pos, &"cannot prove reference is non-nil before dereference in {fnCtx}")

    of ekVar:
      # Variable initialization checking
      if callEnv.vals.hasKey(expr.vname):
        let varInfo = callEnv.vals[expr.vname]
        if not varInfo.initialized:
          let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
          raise newProveError(expr.pos, &"use of uninitialized variable '{expr.vname}' in {fnCtx}")
      else:
        let fnCtx = if expr.pos.originalFunction != "": expr.pos.originalFunction else: fnContext
        raise newProveError(expr.pos, &"use of undeclared variable '{expr.vname}' in {fnCtx}")

    of ekCall:
      # Recursive function calls
      for arg in expr.args:
        checkExpressionSafety(arg)
      # Check the function call itself - preserve call stack
      var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
      discard analyzeExpression(expr, callEnv, tmpCtx)

    else:
      # For other expression types, just analyze normally
      var tmpCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack)
      discard analyzeExpression(expr, callEnv, tmpCtx)

  # Check all statements in the function body using full statement analysis
  # Use newCtx to preserve the call stack
  # Track ref-typed parameters for yield validation
  var refParamNames: seq[string] = @[]
  for param in fn.params:
    if param.typ != nil and param.typ.kind == tkRef:
      refParamNames.add(param.name)
      logProver(newCtx.options.verbose, &"Tracking ref parameter: {param.name}")

  var fnCtx = ProverContext(fnContext: fnContext, options: newCtx.options, prog: newCtx.prog, callStack: newCtx.callStack, hasYielded: false, refParams: refParamNames)
  for i, stmt in fn.body:
    # Check if previous statement made rest of function unreachable
    if callEnv.unreachable:
      logProver(newCtx.options.verbose, &"Skipping unreachable statement {i + 1}/{fn.body.len}: {stmt.kind}")
      break
    logProver(newCtx.options.verbose, &"Analyzing statement {i + 1}/{fn.body.len}: {stmt.kind}")
    analyzeStatement(stmt, callEnv, fnCtx)
    logUsageChanges(i)

  # Report unused locals declared within this function scope
  checkUnusedVariables(callEnv, newCtx, fnContext, excludeGlobals = true, excludeNames = initialNames)

  logProver(ctx.options.verbose, &"Function {fnContext} analysis completed successfully")

  # Copy back global variable usage information from function call environment
  for k, callInfo in callEnv.vals:
    if k notin paramNames and env.vals.hasKey(k):
      # This is a global variable - copy back usage information
      env.vals[k].used = env.vals[k].used or callInfo.used

  if compileTimeConst.isSome:
    let constInfo = compileTimeConst.get
    logProver(ctx.options.verbose, &"Using compile-time constant result for {fnContext}: {constInfo.cval}")
    return constInfo

  # Try to determine return value information by looking at return statements
  # This is a simplified approach - a more complete implementation would track
  # all possible return paths and merge their info
  for stmt in fn.body:
    if stmt.kind == skReturn and stmt.re.isSome:
      let tmpCtx = newProverContext(fnContext, ctx.options, ctx.prog)
      let returnInfo = analyzeExpression(stmt.re.get, callEnv, tmpCtx)
      if returnInfo.known:
        logProver(ctx.options.verbose, &"Function return value: {returnInfo.cval}")
      elif returnInfo.isArray and returnInfo.arraySizeKnown:
        logProver(ctx.options.verbose, &"Function return value: array of size {returnInfo.arraySize}")
      elif returnInfo.isArray:
        logProver(ctx.options.verbose, &"Function return value: array of unknown size (min: {returnInfo.arraySize})")
      else:
        logProver(ctx.options.verbose, &"Function return value: [{returnInfo.minv}..{returnInfo.maxv}]")
      return returnInfo

  # No return statement found or void return
  logProver(ctx.options.verbose, &"Function {fnContext} has no explicit return value")
  return infoUnknown()


proc analyzeHostFunctionCall*(e: Expression, env: var Env, ctx: ProverContext): Info =
  if not ctx.options.verbose:
    return infoUnknown()

  ## Analyze host function calls and mark arguments as used
  logProver(ctx.options.verbose, &"Analyzing host function call: {e.fname}")

  # Analyze arguments and mark them as used
  for i, arg in e.args:
    let argInfo = analyzeExpression(arg, env, ctx)
    logProver(true, "Host function argument " & $i & ": " & (if argInfo.known: $argInfo.cval else: "[" & $argInfo.minv & ".." & $argInfo.maxv & "]"))

  return infoUnknown()


proc analyzeCallExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Check if this is a closure/lambda call (callIsValue = true means calling a variable holding a function)
  # If so, we need to analyze the call target expression to mark the lambda variable as used
  if e.callIsValue and not e.callTarget.isNil:
    # Lambda/closure call: analyze the target to mark it as used
    discard analyzeExpression(e.callTarget, env, ctx)

  # Also check if the function name corresponds to a variable (for direct function references)
  # If so, mark it as used
  if env.vals.hasKey(e.fname):
    var info = env.vals[e.fname]
    if not info.initialized:
      raise newProveError(e.pos, &"use of uninitialized variable '{e.fname}' - variable may not be initialized in all control flow paths")
    info.used = true
    env.vals[e.fname] = info

  # User-defined function call - perform call-site safety analysis
  if ctx.prog != nil and ctx.prog.funInstances.hasKey(e.fname):
    return analyzeUserDefinedCall(e, env, ctx)
  else:
    return analyzeBuiltinCall(e, env, ctx)


proc analyzeFunctionBody*(statements: seq[Statement], env: var Env, ctx: ProverContext) =
  ## Analyze a sequence of statements in a function body with full control flow analysis
  for i, stmt in statements:
    logProver(ctx.options.verbose, &"Analyzing statement {i + 1}/{statements.len}: {stmt.kind}")
    analyzeStatement(stmt, env, ctx)
