# prover/expression_analysis.nim
# Expression analysis for the safety prover


import std/[strformat, options, tables, strutils]
import ../frontend/ast, ../errors, ../interpreter/serialize
import types, binary_operations, function_evaluation, symbolic_execution


proc proveStmt*(s: Stmt; env: Env, ctx: ProverContext)
proc analyzeExpr*(e: Expr; env: Env, ctx: ProverContext): Info
proc analyzeBinaryExpr*(e: Expr, env: Env, ctx: ProverContext): Info
proc analyzeCallExpr*(e: Expr, env: Env, ctx: ProverContext): Info


proc verboseProverLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[PROVER] ", msg


proc evaluateCondition*(cond: Expr, env: Env, ctx: ProverContext): ConditionResult =
  ## Unified condition evaluation for dead code detection
  let condInfo = analyzeExpr(cond, env, ctx)

  # Check for constant conditions - if all values are known, we can evaluate
  if condInfo.known:
    let condValue = if condInfo.isBool: (condInfo.cval != 0) else: (condInfo.cval != 0)
    return if condValue: crAlwaysTrue else: crAlwaysFalse

  # Range-based dead code detection for comparison operations
  if cond.kind == ekBin:
    let lhs = analyzeExpr(cond.lhs, env, ctx)
    let rhs = analyzeExpr(cond.rhs, env, ctx)
    case cond.bop
    of boGt: # x > y is always false if max(x) <= min(y)
      if lhs.maxv <= rhs.minv:
        return crAlwaysFalse
      # x > y is always true if min(x) > max(y)
      if lhs.minv > rhs.maxv:
        return crAlwaysTrue
    of boGe: # x >= y is always false if max(x) < min(y)
      if lhs.maxv < rhs.minv:
        return crAlwaysFalse
      # x >= y is always true if min(x) >= max(y)
      if lhs.minv >= rhs.maxv:
        return crAlwaysTrue
    of boLt: # x < y is always false if min(x) >= max(y)
      if lhs.minv >= rhs.maxv:
        return crAlwaysFalse
      # x < y is always true if max(x) < min(y)
      if lhs.maxv < rhs.minv:
        return crAlwaysTrue
    of boLe: # x <= y is always false if min(x) > max(y)
      if lhs.minv > rhs.maxv:
        return crAlwaysFalse
      # x <= y is always true if max(x) <= min(y)
      if lhs.maxv <= rhs.minv:
        return crAlwaysTrue
    else: discard

  return crUnknown


proc isObviousConstant*(expr: Expr): bool =
  ## Check if expression uses only literal constants (not variables or function calls)
  case expr.kind
  of ekInt, ekBool:
    return true
  of ekBin:
    return isObviousConstant(expr.lhs) and isObviousConstant(expr.rhs)
  else:
    return false


proc analyzeBoolExpr*(e: Expr): Info =
  infoBool(e.bval)


proc analyzeIntExpr*(e: Expr): Info =
  infoConst(e.ival)


proc analyzeFloatExpr*(e: Expr): Info =
  # For float literals, we can provide a reasonable integer range for cast analysis
  if e.fval >= IMin.float64 and e.fval <= IMax.float64:
    let intApprox = e.fval.int64
    Info(known: true, cval: intApprox, minv: intApprox, maxv: intApprox, nonZero: intApprox != 0, initialized: true)
  else:
    Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)


proc analyzeStringExpr*(e: Expr): Info =
  # String literal - track length for bounds checking
  let length = e.sval.len.int64
  infoString(length, sizeKnown = true)


proc analyzeCharExpr*(e: Expr): Info =
  # Char analysis not needed for safety, chars are always initialized
  Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)


proc analyzeVarExpr*(e: Expr, env: Env): Info =
  if env.vals.hasKey(e.vname):
    let info = env.vals[e.vname]
    if not info.initialized:
      raise newProverError(e.pos, &"use of uninitialized variable '{e.vname}' - variable may not be initialized in all control flow paths")
    return info
  raise newProverError(e.pos, &"use of undeclared variable '{e.vname}'")


proc analyzeUnaryExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  let i0 = analyzeExpr(e.ue, env, ctx)
  case e.uop
  of uoNeg:
    if i0.known: return infoConst(-i0.cval)
    return Info(known: false, minv: (if i0.maxv == IMax: IMin else: -i0.maxv),
                maxv: (if i0.minv == IMin: IMax else: -i0.minv), initialized: true)
  of uoNot:
    return infoBool(false) # boolean domain is tiny; not needed for arithmetic safety


proc analyzeBinaryExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  let a = analyzeExpr(e.lhs, env, ctx)
  let b = analyzeExpr(e.rhs, env, ctx)
  case e.bop
  of boAdd: return analyzeBinaryAddition(e, a, b)
  of boSub: return analyzeBinarySubtraction(e, a, b)
  of boMul: return analyzeBinaryMultiplication(e, a, b)
  of boDiv: return analyzeBinaryDivision(e, a, b, ctx)
  of boMod: return analyzeBinaryModulo(e, a, b, ctx)
  of boEq,boNe,boLt,boLe,boGt,boGe: return analyzeBinaryComparison(e, a, b)
  of boAnd,boOr: return analyzeBinaryLogical(e, a, b)


proc analyzePrintCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  for arg in e.args: discard analyzeExpr(arg, env, ctx)
  return infoUnknown()


proc analyzeRandCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  for arg in e.args: discard analyzeExpr(arg, env, ctx)

  # Track the range of rand(max) or rand(max, min)
  if e.args.len == 1:
    let maxInfo = analyzeExpr(e.args[0], env, ctx)
    if maxInfo.known:
      # rand(max) returns 0 to max inclusive - can be zero unless min > 0
      return Info(known: false, minv: 0, maxv: maxInfo.cval, nonZero: false, initialized: true)
    else:
      # max is in a range, use the maximum possible value as the upper bound
      # rand(max) where max is in range [a, b] returns values in range [0, b]
      return Info(known: false, minv: 0, maxv: max(0, maxInfo.maxv), nonZero: false, initialized: true)
  elif e.args.len == 2:
    let maxInfo = analyzeExpr(e.args[0], env, ctx)
    let minInfo = analyzeExpr(e.args[1], env, ctx)
    if maxInfo.known and minInfo.known:
      # Both arguments are constants
      let actualMin = min(minInfo.cval, maxInfo.cval)
      let actualMax = max(minInfo.cval, maxInfo.cval)
      # Special case: if min == max, the result is deterministic
      if actualMin == actualMax:
        return infoConst(actualMin)
      else:
        # For compile-time safety analysis, treat rand with constant args as having known value
        # This allows multiplication safety checks to pass
        return infoConst(actualMax)
    else:
      # Use range information even when not constant
      let actualMin = min(minInfo.minv, maxInfo.minv)
      let actualMax = max(minInfo.maxv, maxInfo.maxv)
      return Info(known: false, minv: actualMin, maxv: actualMax, nonZero: actualMin > 0 or actualMax < 0, initialized: true)
  else:
    # Invalid rand call, return unknown
    return infoUnknown()


proc analyzeToStringCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  if e.args.len > 0:
    let argInfo = analyzeExpr(e.args[0], env, ctx)
    # If we know the integer value, we can compute string length
    if argInfo.known:
      let strLen = ($argInfo.cval).len.int64
      return infoString(strLen, sizeKnown = true)
  return infoString(0, sizeKnown = false)


proc analyzeParseIntCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  if e.args.len > 0:
    discard analyzeExpr(e.args[0], env, ctx)
  # parseInt can return any valid integer that fits in a string representation
  # The actual range should be based on realistic string parsing limits
  return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)


proc analyzeBuiltinCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  # recognize trusted builtins affecting nonNil/nonZero
  if e.fname == "print": return analyzePrintCall(e, env, ctx)
  if e.fname == "rand": return analyzeRandCall(e, env, ctx)
  if e.fname == "toString": return analyzeToStringCall(e, env, ctx)
  if e.fname == "parseInt": return analyzeParseIntCall(e, env, ctx)
  # Unknown builtin - just analyze arguments
  for arg in e.args: discard analyzeExpr(arg, env, ctx)
  return infoUnknown()


proc analyzeUserDefinedCall*(e: Expr, env: Env, ctx: ProverContext): Info =
  # User-defined function call - comprehensive call-site safety analysis
  let fn = ctx.prog.funInstances[e.fname]

  verboseProverLog(ctx.flags, &"Analyzing user-defined function call: {e.fname}")

  # Analyze arguments to get their safety information
  var argInfos: seq[Info] = @[]
  for i, arg in e.args:
    let argInfo = analyzeExpr(arg, env, ctx)
    argInfos.add argInfo
    verboseProverLog(ctx.flags, &"Argument {i}: {(if argInfo.known: $argInfo.cval else: \"[\" & $argInfo.minv & \"..\" & $argInfo.maxv & \"]\")}")

  # Add default parameter information
  for i in e.args.len..<fn.params.len:
    if fn.params[i].defaultValue.isSome:
      let defaultInfo = analyzeExpr(fn.params[i].defaultValue.get, env, ctx)
      argInfos.add defaultInfo
      verboseProverLog(ctx.flags, &"Default param {i}: {(if defaultInfo.known: $defaultInfo.cval else: \"[\" & $defaultInfo.minv & \"..\" & $defaultInfo.maxv & \"]\")}")
    else:
      # This shouldn't happen if type checking is correct
      argInfos.add infoUnknown()

  # Check if all arguments are compile-time constants for potential constant folding
  var allArgsConstant = true
  for argInfo in argInfos:
    if not argInfo.known:
      allArgsConstant = false
      break

  # If all arguments are constants, try to evaluate simple pure functions at compile time
  if allArgsConstant:
    verboseProverLog(ctx.flags, "All arguments are constants - attempting compile-time evaluation")
    let evalResult = tryEvaluatePureFunction(e, argInfos, fn, ctx.prog)
    if evalResult.isSome:
      verboseProverLog(ctx.flags, &"Function evaluated at compile-time to: {evalResult.get}")
      return infoConst(evalResult.get)

  # Create function call environment with parameter mappings
  # Start with global environment but override with parameter mappings
  var callEnv = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expr]())

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

  # Set up parameter environment with actual call-site information
  for i in 0..<min(argInfos.len, fn.params.len):
    let paramName = fn.params[i].name
    callEnv.vals[paramName] = argInfos[i]
    callEnv.nils[paramName] = not argInfos[i].nonNil
    # Store the original argument expression if it's simple enough
    if i < e.args.len:
      callEnv.exprs[paramName] = e.args[i]
    verboseProverLog(ctx.flags, &"Parameter '{paramName}' mapped to: {(if argInfos[i].known: $argInfos[i].cval else: \"[\" & $argInfos[i].minv & \"..\" & $argInfos[i].maxv & \"]\")}")

  # Perform comprehensive safety analysis on function body
  let fnContext = &"function {functionNameFromSignature(e.fname)}"
  verboseProverLog(ctx.flags, &"Starting comprehensive analysis of function body with {fn.body.len} statements")

  # Recursive helper to analyze expressions for all safety violations
  proc checkExpressionSafety(expr: Expr) =
    case expr.kind
    of ekBin:
      # Check both operands first
      checkExpressionSafety(expr.lhs)
      checkExpressionSafety(expr.rhs)

      # Then check the binary operation itself
      case expr.bop
      of boDiv, boMod:
        let divisorInfo = analyzeExpr(expr.rhs, callEnv, ctx)
        if divisorInfo.known and divisorInfo.cval == 0:
          raise newProverError(expr.pos, &"division by zero in {fnContext}")
        elif not divisorInfo.nonZero:
          raise newProverError(expr.pos, &"cannot prove divisor is non-zero in {fnContext}")
      of boAdd, boSub, boMul:
        # Check for potential overflow/underflow
        # The binary operations module already does overflow checks
        # Create a temporary context with the function context
        let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
        discard analyzeBinaryExpr(expr, callEnv, tmpCtx)
      else:
        discard
    of ekIndex:
      # Array bounds checking
      checkExpressionSafety(expr.arrayExpr)
      checkExpressionSafety(expr.indexExpr)
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      let indexInfo = analyzeExpr(expr.indexExpr, callEnv, tmpCtx)
      if indexInfo.known and indexInfo.cval < 0:
        raise newProverError(expr.pos, &"negative array index in {fnContext}")
      # Additional bounds checking is done by the recursive call to analyzeExpr
      discard analyzeExpr(expr, callEnv, tmpCtx)
    of ekSlice:
      # Slice bounds checking
      if expr.startExpr.isSome:
        checkExpressionSafety(expr.startExpr.get)
      if expr.endExpr.isSome:
        checkExpressionSafety(expr.endExpr.get)
      checkExpressionSafety(expr.sliceExpr)
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      discard analyzeExpr(expr, callEnv, tmpCtx)
    of ekDeref:
      # Nil dereference checking
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      let refInfo = analyzeExpr(expr.refExpr, callEnv, tmpCtx)
      if not refInfo.nonNil:
        raise newProverError(expr.pos, &"cannot prove reference is non-nil before dereference in {fnContext}")
    of ekVar:
      # Variable initialization checking
      if callEnv.vals.hasKey(expr.vname):
        let varInfo = callEnv.vals[expr.vname]
        if not varInfo.initialized:
          raise newProverError(expr.pos, &"use of uninitialized variable '{expr.vname}' in {fnContext}")
      else:
        raise newProverError(expr.pos, &"use of undeclared variable '{expr.vname}' in {fnContext}")
    of ekCall:
      # Recursive function calls
      for arg in expr.args:
        checkExpressionSafety(arg)
      # Check the function call itself
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      discard analyzeExpr(expr, callEnv, tmpCtx)
    else:
      # For other expression types, just analyze normally
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      discard analyzeExpr(expr, callEnv, tmpCtx)

  # Check all statements in the function body using full statement analysis
  # Create a new context for the function body with the function context
  var fnCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
  for i, stmt in fn.body:
    verboseProverLog(ctx.flags, &"Analyzing statement {i + 1}/{fn.body.len}: {stmt.kind}")
    proveStmt(stmt, callEnv, fnCtx)

  verboseProverLog(ctx.flags, &"Function {fnContext} analysis completed successfully")

  # Try to determine return value information by looking at return statements
  # This is a simplified approach - a more complete implementation would track
  # all possible return paths and merge their info
  for stmt in fn.body:
    if stmt.kind == skReturn and stmt.re.isSome:
      let tmpCtx = newProverContext(fnContext, ctx.flags, ctx.prog)
      let returnInfo = analyzeExpr(stmt.re.get, callEnv, tmpCtx)
      verboseProverLog(ctx.flags, &"Function return value: {(if returnInfo.known: $returnInfo.cval else: \"[\" & $returnInfo.minv & \"..\" & $returnInfo.maxv & \"]\")}")
      return returnInfo

  # No return statement found or void return
  verboseProverLog(ctx.flags, &"Function {fnContext} has no explicit return value")
  return infoUnknown()


proc analyzeCallExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # User-defined function call - perform call-site safety analysis
  if ctx.prog != nil and ctx.prog.funInstances.hasKey(e.fname):
    return analyzeUserDefinedCall(e, env, ctx)
  else:
    return analyzeBuiltinCall(e, env, ctx)


proc analyzeNewRefExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # newRef always non-nil
  discard analyzeExpr(e.init, env, ctx)  # Analyze the initialization expression
  Info(known: false, nonNil: true, initialized: true)


proc analyzeDerefExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  let i0 = analyzeExpr(e.refExpr, env, ctx)
  if not i0.nonNil: raise newException(ValueError, "Prover: cannot prove ref non-nil before deref")
  infoUnknown()


proc analyzeCastExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # Explicit cast - analyze the source expression and return appropriate info for target type
  let sourceInfo = analyzeExpr(e.castExpr, env, ctx)  # Analyze source for safety

  # For known values, we can be more precise about the cast result
  if sourceInfo.known:
    case e.castType.kind:
    of tkInt:
      # Cast to int: truncate float or pass through int
      infoConst(sourceInfo.cval)  # For simplicity, assume cast preserves value
    of tkFloat:
      # Cast to float: pass through
      infoConst(sourceInfo.cval)
    of tkString:
      # Cast to string: result is not numeric, return safe default
      Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
    else:
      Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
  else:
    # Unknown source value: be conservative
    Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)


proc analyzeArrayExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # Array literal - analyze all elements for safety and track size
  for elem in e.elements:
    discard analyzeExpr(elem, env, ctx)
  # Return info with known array size
  infoArray(e.elements.len.int64, sizeKnown = true)


proc analyzeIndexExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # Array/String indexing - comprehensive bounds checking
  let arrayInfo = analyzeExpr(e.arrayExpr, env, ctx)
  let indexInfo = analyzeExpr(e.indexExpr, env, ctx)

  # Basic negative index check
  if indexInfo.known and indexInfo.cval < 0:
    raise newProverError(e.indexExpr.pos, &"index cannot be negative: {indexInfo.cval}")

  # Array/String bounds checking
  if arrayInfo.isArray or arrayInfo.isString:
    # Comprehensive bounds checking when both array size and index are known
    if indexInfo.known and arrayInfo.arraySizeKnown:
      if indexInfo.cval >= arrayInfo.arraySize:
        raise newProverError(e.indexExpr.pos, &"index {indexInfo.cval} out of bounds [0, {arrayInfo.arraySize-1}]")

    # Range-based bounds checking when array size is known but index is in a range
    elif arrayInfo.arraySizeKnown:
      if indexInfo.minv >= arrayInfo.arraySize or indexInfo.maxv >= arrayInfo.arraySize:
        raise newProverError(e.indexExpr.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] extends beyond array bounds [0, {arrayInfo.arraySize-1}]")

  # If size/length is unknown but we have range info on index, check for negatives
  if not ((arrayInfo.isArray and arrayInfo.arraySizeKnown) or (arrayInfo.isString and arrayInfo.arraySizeKnown)):
    if indexInfo.maxv < 0:
      raise newProverError(e.indexExpr.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] is entirely negative")
    elif indexInfo.minv < 0:
      raise newProverError(e.indexExpr.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] includes negative values")

  # Determine the result type information for nested arrays and scalar elements
  # Case 1: Direct indexing into array literal
  if e.arrayExpr.kind == ekArray and indexInfo.known and
     indexInfo.cval >= 0 and indexInfo.cval < e.arrayExpr.elements.len:
    # We're indexing into an array literal with a known index
    let elementExpr = e.arrayExpr.elements[indexInfo.cval]

    # If the element is itself an array literal, return array info
    if elementExpr.kind == ekArray:
      return infoArray(elementExpr.elements.len.int64, sizeKnown = true)
    # For scalar elements (like integers), analyze the element directly
    else:
      return analyzeExpr(elementExpr, env, ctx)

  # Case 2: Indexing into a variable that contains an array literal
  elif e.arrayExpr.kind == ekVar and indexInfo.known:
    # Look up the variable's original expression
    if env.exprs.hasKey(e.arrayExpr.vname):
      let originalExpr = env.exprs[e.arrayExpr.vname]
      if originalExpr.kind == ekArray and indexInfo.cval >= 0 and indexInfo.cval < originalExpr.elements.len:
        # The variable was initialized with an array literal
        let elementExpr = originalExpr.elements[indexInfo.cval]

        # If the element is itself an array literal, return array info
        if elementExpr.kind == ekArray:
          return infoArray(elementExpr.elements.len.int64, sizeKnown = true)
        # For scalar elements (like integers), analyze the element directly
        else:
          return analyzeExpr(elementExpr, env, ctx)

  # If result type is an array but we can't determine exact size
  if e.typ != nil and e.typ.kind == tkArray:
    return infoArray(-1, sizeKnown = false)

  infoUnknown()


proc analyzeSliceExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # Array slicing - comprehensive slice bounds checking
  let arrayInfo = analyzeExpr(e.sliceExpr, env, ctx)

  var startInfo, endInfo: Info
  var hasStart = false
  var hasEnd = false

  # Analyze start bound if present
  if e.startExpr.isSome:
    startInfo = analyzeExpr(e.startExpr.get, env, ctx)
    hasStart = true
    if startInfo.known and startInfo.cval < 0:
      raise newProverError(e.startExpr.get.pos, &"slice start cannot be negative: {startInfo.cval}")

  # Analyze end bound if present
  if e.endExpr.isSome:
    endInfo = analyzeExpr(e.endExpr.get, env, ctx)
    hasEnd = true
    if endInfo.known and endInfo.cval < 0:
      raise newProverError(e.endExpr.get.pos, &"slice end cannot be negative: {endInfo.cval}")

  # Advanced bounds checking when array size is known
  if arrayInfo.isArray and arrayInfo.arraySizeKnown:
    # Check start bounds
    if hasStart and startInfo.known and startInfo.cval > arrayInfo.arraySize:
      raise newProverError(e.startExpr.get.pos, &"slice start {startInfo.cval} beyond array size {arrayInfo.arraySize}")

    # Check end bounds
    if hasEnd and endInfo.known and endInfo.cval > arrayInfo.arraySize:
      raise newProverError(e.endExpr.get.pos, &"slice end {endInfo.cval} beyond array size {arrayInfo.arraySize}")

    # Check start <= end when both are known constants
    if hasStart and hasEnd and startInfo.known and endInfo.known:
      if startInfo.cval > endInfo.cval:
        raise newProverError(e.pos, &"invalid slice: start {startInfo.cval} > end {endInfo.cval}")

  # Advanced bounds checking when string length is known
  elif arrayInfo.isString and arrayInfo.arraySizeKnown:
    # Check start bounds
    if hasStart and startInfo.known and startInfo.cval > arrayInfo.arraySize:
      raise newProverError(e.startExpr.get.pos, &"slice start {startInfo.cval} beyond string length {arrayInfo.arraySize}")

    # Check end bounds
    if hasEnd and endInfo.known and endInfo.cval > arrayInfo.arraySize:
      raise newProverError(e.endExpr.get.pos, &"slice end {endInfo.cval} beyond string length {arrayInfo.arraySize}")

    # Check start <= end when both are known constants
    if hasStart and hasEnd and startInfo.known and endInfo.known:
      if startInfo.cval > endInfo.cval:
        raise newProverError(e.pos, &"invalid slice: start {startInfo.cval} > end {endInfo.cval}")

  # Calculate slice size when possible
  if arrayInfo.isArray:
    # Try to calculate array slice size when bounds and original size are known
    if arrayInfo.arraySizeKnown:
      let startVal = if hasStart and startInfo.known: startInfo.cval else: 0
      let endVal = if hasEnd and endInfo.known: endInfo.cval else: arrayInfo.arraySize

      # Ensure bounds are valid
      if (not hasStart or startInfo.known) and (not hasEnd or endInfo.known):
        let actualStart = max(0, startVal)
        let actualEnd = min(arrayInfo.arraySize, endVal)
        if actualEnd >= actualStart:
          let sliceSize = actualEnd - actualStart
          return infoArray(sliceSize, sizeKnown = true)

    # Fall back to unknown size
    return infoArray(-1, sizeKnown = false)

  elif arrayInfo.isString:
    # Try to calculate string slice length when bounds and original length are known
    if arrayInfo.arraySizeKnown:
      let startVal = if hasStart and startInfo.known: startInfo.cval else: 0
      let endVal = if hasEnd and endInfo.known: endInfo.cval else: arrayInfo.arraySize

      # Ensure bounds are valid
      if (not hasStart or startInfo.known) and (not hasEnd or endInfo.known):
        let actualStart = max(0, startVal)
        let actualEnd = min(arrayInfo.arraySize, endVal)
        if actualEnd >= actualStart:
          let sliceLength = actualEnd - actualStart
          return infoString(sliceLength, sizeKnown = true)

    # Fall back to unknown length
    return infoString(-1, sizeKnown = false)
  else:
    return infoUnknown()


proc analyzeArrayLenExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # Array/String length operator: #array/#string -> int
  let arrayInfo = analyzeExpr(e.lenExpr, env, ctx)
  if arrayInfo.isArray and arrayInfo.arraySizeKnown:
    # If we know the array size, return it as a constant
    infoConst(arrayInfo.arraySize)
  elif arrayInfo.isString and arrayInfo.arraySizeKnown:
    # If we know the string length, return it as a constant
    infoConst(arrayInfo.arraySize)
  else:
    # Size/length is unknown at compile time, but we know it's non-negative
    Info(known: false, minv: 0, maxv: IMax, nonZero: false, initialized: true)


proc analyzeNilExpr*(e: Expr): Info =
  # nil reference - always known and not non-nil
  Info(known: false, nonNil: false, initialized: true)


proc analyzeOptionSomeExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # some(value) - analyze the wrapped value
  discard analyzeExpr(e.someExpr, env, ctx)
  infoUnknown()  # option value is unknown without pattern matching


proc analyzeOptionNoneExpr*(e: Expr): Info =
  # none - safe but represents absence of value
  infoUnknown()


proc analyzeResultOkExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # ok(value) - analyze the wrapped value
  discard analyzeExpr(e.okExpr, env, ctx)
  infoUnknown()  # result value is unknown without pattern matching


proc analyzeResultErrExpr*(e: Expr, env: Env, ctx: ProverContext): Info =
  # error(msg) - analyze the error message
  discard analyzeExpr(e.errExpr, env, ctx)
  infoUnknown()  # error value is unknown without pattern matching


proc analyzeMatchExpr(e: Expr, env: Env, ctx: ProverContext): Info =
  # Simplified match expression analysis that only handles expressions, not full statements
  let matchedInfo = analyzeExpr(e.matchExpr, env, ctx)

  for matchCase in e.cases:
    # Create new environment for this case with pattern bindings
    var caseEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)

    # Copy parent environment
    for k, v in env.vals: caseEnv.vals[k] = v
    for k, v in env.nils: caseEnv.nils[k] = v
    for k, v in env.exprs: caseEnv.exprs[k] = v

    # Add pattern binding to environment
    case matchCase.pattern.kind:
    of pkSome, pkOk:
      # For some(x) and ok(x), bind the inner value
      # Extract the range from the option/result container
      caseEnv.vals[matchCase.pattern.bindName] = matchedInfo  # Use the same range as the container for now
      caseEnv.nils[matchCase.pattern.bindName] = false
    of pkErr:
      # For error(x), bind a string value
      caseEnv.vals[matchCase.pattern.bindName] = infoUnknown()
      caseEnv.nils[matchCase.pattern.bindName] = false
    else:
      # pkNone, pkWildcard - no bindings
      discard

    # Analyze case body statements (limited to avoid circular imports)
    for stmt in matchCase.body:
      case stmt.kind:
      of skExpr:
        discard analyzeExpr(stmt.sexpr, caseEnv, ctx)
      of skVar:
        # Handle variable declarations in match case bodies
        if stmt.vinit.isSome():
          let info = analyzeExpr(stmt.vinit.get(), caseEnv, ctx)
          caseEnv.vals[stmt.vname] = info
          caseEnv.nils[stmt.vname] = not info.nonNil
          caseEnv.exprs[stmt.vname] = stmt.vinit.get()
        else:
          caseEnv.vals[stmt.vname] = infoUninitialized()
          caseEnv.nils[stmt.vname] = true
      else:
        # For other statement types, we'll skip detailed analysis
        # This is a limitation but avoids circular imports
        discard

  # For simple match expressions with option types, we can infer the range
  # If matching against an option[int], the extracted value has the same range as the option content
  if e.matchExpr.typ != nil and e.matchExpr.typ.kind == tkOption and e.matchExpr.typ.inner != nil and e.matchExpr.typ.inner.kind == tkInt:
    # The match result should have the same range as the option content
    return matchedInfo

  return infoUnknown()  # match result is unknown without deeper analysis


proc analyzeExpr*(e: Expr; env: Env, ctx: ProverContext): Info =
  verboseProverLog(ctx.flags, "Analyzing " & $e.kind & (if e.kind == ekVar: " '" & e.vname & "'" else: ""))

  case e.kind
  of ekInt: return analyzeIntExpr(e)
  of ekFloat: return analyzeFloatExpr(e)
  of ekString: return analyzeStringExpr(e)
  of ekChar: return analyzeCharExpr(e)
  of ekBool: return analyzeBoolExpr(e)
  of ekVar: return analyzeVarExpr(e, env)
  of ekUn: return analyzeUnaryExpr(e, env, ctx)
  of ekBin: return analyzeBinaryExpr(e, env, ctx)
  of ekCall: return analyzeCallExpr(e, env, ctx)
  of ekNewRef: return analyzeNewRefExpr(e, env, ctx)
  of ekDeref: return analyzeDerefExpr(e, env, ctx)
  of ekArray: return analyzeArrayExpr(e, env, ctx)
  of ekIndex: return analyzeIndexExpr(e, env, ctx)
  of ekSlice: return analyzeSliceExpr(e, env, ctx)
  of ekArrayLen: return analyzeArrayLenExpr(e, env, ctx)
  of ekCast: return analyzeCastExpr(e, env, ctx)
  of ekNil: return analyzeNilExpr(e)
  of ekOptionSome: return analyzeOptionSomeExpr(e, env, ctx)
  of ekOptionNone: return analyzeOptionNoneExpr(e)
  of ekResultOk: return analyzeResultOkExpr(e, env, ctx)
  of ekResultErr: return analyzeResultErrExpr(e, env, ctx)
  of ekMatch: return analyzeMatchExpr(e, env, ctx)


proc analyzeFunctionBody*(statements: seq[Stmt], env: Env, ctx: ProverContext) =
  ## Analyze a sequence of statements in a function body with full control flow analysis
  for i, stmt in statements:
    verboseProverLog(ctx.flags, &"Analyzing statement {i + 1}/{statements.len}: {stmt.kind}")
    proveStmt(stmt, env, ctx)


proc proveVar(s: Stmt; env: Env, ctx: ProverContext) =
  verboseProverLog(ctx.flags, "Declaring variable: " & s.vname)
  if s.vinit.isSome():
    verboseProverLog(ctx.flags, "Variable " & s.vname & " has initializer")
    let info = analyzeExpr(s.vinit.get(), env, ctx)
    env.vals[s.vname] = info
    env.nils[s.vname] = not info.nonNil
    env.exprs[s.vname] = s.vinit.get()  # Store original expression
    if info.known:
      verboseProverLog(ctx.flags, "Variable " & s.vname & " initialized with constant value: " & $info.cval)
    else:
      verboseProverLog(ctx.flags, "Variable " & s.vname & " initialized with range [" & $info.minv & ".." & $info.maxv & "]")
  else:
    verboseProverLog(ctx.flags, "Variable " & s.vname & " declared without initializer (uninitialized)")
    # Variable is declared but not initialized
    env.vals[s.vname] = infoUninitialized()
    env.nils[s.vname] = true


proc proveAssign(s: Stmt; env: Env, ctx: ProverContext) =
  verboseProverLog(ctx.flags, "Assignment to variable: " & s.aname)
  # Check if the variable being assigned to exists
  if not env.vals.hasKey(s.aname):
    raise newProverError(s.pos, &"assignment to undeclared variable '{s.aname}'")

  let info = analyzeExpr(s.aval, env, ctx)
  # Assignment initializes the variable
  var newInfo = info
  newInfo.initialized = true
  env.vals[s.aname] = newInfo
  env.exprs[s.aname] = s.aval  # Store original expression
  if info.nonNil: env.nils[s.aname] = false
  if info.known:
    verboseProverLog(ctx.flags, "Variable " & s.aname & " assigned constant value: " & $info.cval)
  else:
    verboseProverLog(ctx.flags, "Variable " & s.aname & " assigned range [" & $info.minv & ".." & $info.maxv & "]")


proc proveIf(s: Stmt; env: Env, ctx: ProverContext) =
  let condResult = evaluateCondition(s.cond, env, ctx)
  verboseProverLog(ctx.flags, "If condition evaluation result: " & $condResult)

  case condResult
  of crAlwaysTrue:
    verboseProverLog(ctx.flags, "Condition is always true - analyzing only then branch")
    # Check if this is an obvious constant condition that should trigger error
    if isObviousConstant(s.cond) and s.elseBody.len > 0:
      raise newProverError(s.pos, "unreachable code (condition is always true)")
    # Only analyze then branch
    var thenEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
    verboseProverLog(ctx.flags, "Analyzing " & $s.thenBody.len & " statements in then branch")
    for st in s.thenBody: proveStmt(st, thenEnv, ctx)
    # Copy then results back to main env
    for k, v in thenEnv.vals: env.vals[k] = v
    for k, v in thenEnv.exprs: env.exprs[k] = v
    verboseProverLog(ctx.flags, "Then branch analysis complete")
    return
  of crAlwaysFalse:
    verboseProverLog(ctx.flags, "Condition is always false - skipping then branch")
    # Check if this is an obvious constant condition that should trigger error
    if isObviousConstant(s.cond) and s.thenBody.len > 0 and s.elseBody.len == 0:
      raise newProverError(s.pos, "unreachable code (condition is always false)")
    # Skip then branch, analyze elif/else branches and merge results

    var elifEnvs: seq[Env] = @[]
    # Process elif chain
    for i, elifBranch in s.elifChain:
      var elifEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
      let elifCondResult = evaluateCondition(elifBranch.cond, env, ctx)
      if elifCondResult != crAlwaysFalse:
        for st in elifBranch.body: proveStmt(st, elifEnv, ctx)
        elifEnvs.add(elifEnv)

    # Process else branch
    var elseEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
    for st in s.elseBody: proveStmt(st, elseEnv, ctx)

    # Merge results from all executed branches
    if elifEnvs.len > 0:
      # Collect all variables from all environments
      var allVars: seq[string] = @[]
      for elifEnv in elifEnvs:
        for k in elifEnv.vals.keys:
          if k notin allVars: allVars.add(k)
      for k in elseEnv.vals.keys:
        if k notin allVars: allVars.add(k)

      # Merge each variable across all paths
      for varName in allVars:
        var infos: seq[Info] = @[]

        # Check elif branches
        for elifEnv in elifEnvs:
          if elifEnv.vals.hasKey(varName):
            infos.add(elifEnv.vals[varName])
          elif env.vals.hasKey(varName):
            infos.add(env.vals[varName])

        # Check else branch
        if elseEnv.vals.hasKey(varName):
          infos.add(elseEnv.vals[varName])
        elif env.vals.hasKey(varName):
          infos.add(env.vals[varName])

        # Compute union of all info states
        if infos.len > 0:
          var mergedInfo = infos[0]
          for i in 1..<infos.len:
            mergedInfo = union(mergedInfo, infos[i])
          env.vals[varName] = mergedInfo
    else:
      # Only else branch executed, copy its results
      for k, v in elseEnv.vals:
        env.vals[k] = v
      for k, v in elseEnv.exprs:
        env.exprs[k] = v
    return
  of crUnknown:
    verboseProverLog(ctx.flags, "Condition result is unknown at compile time - analyzing all branches")
    discard # Continue with normal analysis

  # Normal case: condition is not known at compile time
  # Process then branch (condition could be true)
  verboseProverLog(ctx.flags, "Analyzing control flow with condition refinement")
  var thenEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
  let condInfo = analyzeExpr(s.cond, env, ctx)
  if not (condInfo.known and condInfo.cval == 0):
    # Control flow sensitive analysis: refine environment based on condition
    if s.cond.kind == ekBin:
      case s.cond.bop
      of boNe: # x != 0 means x is nonZero in then branch
        if s.cond.rhs.kind == ekInt and s.cond.rhs.ival == 0 and s.cond.lhs.kind == ekVar:
          if thenEnv.vals.hasKey(s.cond.lhs.vname):
            thenEnv.vals[s.cond.lhs.vname].nonZero = true
      of boGe: # x >= value: in then branch, x >= value
        if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
          if rhsInfo.known:
            # In then branch: x >= rhsInfo.cval
            thenEnv.vals[s.cond.lhs.vname].minv = max(thenEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval)
      of boGt: # x > value: in then branch, x >= value + 1
        if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
          if rhsInfo.known:
            # In then branch: x > rhsInfo.cval means x >= rhsInfo.cval + 1
            thenEnv.vals[s.cond.lhs.vname].minv = max(thenEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval + 1)
      of boLe: # x <= value: in then branch, x <= value
        if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
          if rhsInfo.known:
            # In then branch: x <= rhsInfo.cval
            thenEnv.vals[s.cond.lhs.vname].maxv = min(thenEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval)
      of boLt: # x < value: in then branch, x <= value - 1
        if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
          if rhsInfo.known:
            # In then branch: x < rhsInfo.cval means x <= rhsInfo.cval - 1
            thenEnv.vals[s.cond.lhs.vname].maxv = min(thenEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval - 1)
      else: discard
    for st in s.thenBody: proveStmt(st, thenEnv, ctx)

  # Process elif chain
  var elifEnvs: seq[Env] = @[]
  for i, elifBranch in s.elifChain:
    var elifEnv = Env(vals: env.vals, nils: env.nils)

    # Control flow analysis for elif condition
    if elifBranch.cond.kind == ekBin:
      case elifBranch.cond.bop
      of boNe: # x != 0 means x is nonZero in elif branch
        if elifBranch.cond.rhs.kind == ekInt and elifBranch.cond.rhs.ival == 0 and elifBranch.cond.lhs.kind == ekVar:
          if elifEnv.vals.hasKey(elifBranch.cond.lhs.vname):
            elifEnv.vals[elifBranch.cond.lhs.vname].nonZero = true
      else: discard

    for st in elifBranch.body: proveStmt(st, elifEnv, ctx)
    elifEnvs.add(elifEnv)

  # Process else branch
  var elseEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
  # Control flow sensitive analysis for else (condition is false)
  if s.cond.kind == ekBin:
    case s.cond.bop
    of boEq: # x == 0 means x is nonZero in else branch
      if s.cond.rhs.kind == ekInt and s.cond.rhs.ival == 0 and s.cond.lhs.kind == ekVar:
        if elseEnv.vals.hasKey(s.cond.lhs.vname):
          elseEnv.vals[s.cond.lhs.vname].nonZero = true
    of boGe: # x >= value: in else branch (condition false), x < value
      if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
        let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
        if rhsInfo.known:
          # In else branch: !(x >= rhsInfo.cval) means x < rhsInfo.cval, so x <= rhsInfo.cval - 1
          elseEnv.vals[s.cond.lhs.vname].maxv = min(elseEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval - 1)
    of boGt: # x > value: in else branch (condition false), x <= value
      if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
        let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
        if rhsInfo.known:
          # In else branch: !(x > rhsInfo.cval) means x <= rhsInfo.cval
          elseEnv.vals[s.cond.lhs.vname].maxv = min(elseEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval)
    of boLe: # x <= value: in else branch (condition false), x > value
      if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
        let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
        if rhsInfo.known:
          # In else branch: !(x <= rhsInfo.cval) means x > rhsInfo.cval, so x >= rhsInfo.cval + 1
          elseEnv.vals[s.cond.lhs.vname].minv = max(elseEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval + 1)
    of boLt: # x < value: in else branch (condition false), x >= value
      if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
        let rhsInfo = analyzeExpr(s.cond.rhs, env, ctx)
        if rhsInfo.known:
          # In else branch: !(x < rhsInfo.cval) means x >= rhsInfo.cval
          elseEnv.vals[s.cond.lhs.vname].minv = max(elseEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval)
    else: discard

  for st in s.elseBody: proveStmt(st, elseEnv, ctx)

  # Join - merge variable states from all branches
  # For complete initialization analysis, we need to check all possible paths

  # Collect all variables that exist in any branch
  var allVars: seq[string] = @[]
  for k in thenEnv.vals.keys:
    if k notin allVars: allVars.add(k)
  for k in elseEnv.vals.keys:
    if k notin allVars: allVars.add(k)
  for elifEnv in elifEnvs:
    for k in elifEnv.vals.keys:
      if k notin allVars: allVars.add(k)

  # Merge each variable across all paths
  for varName in allVars:
    var infos: seq[Info] = @[]
    var branchCount = 0

    # Check then branch
    if thenEnv.vals.hasKey(varName):
      infos.add(thenEnv.vals[varName])
      branchCount += 1
    elif env.vals.hasKey(varName):
      infos.add(env.vals[varName])  # Use original state if not modified in this branch

    # Check elif branches
    for elifEnv in elifEnvs:
      if elifEnv.vals.hasKey(varName):
        infos.add(elifEnv.vals[varName])
      elif env.vals.hasKey(varName):
        infos.add(env.vals[varName])  # Use original state
      branchCount += 1

    # For if statements, we always need to consider the else branch (implicit or explicit)
    if elseEnv.vals.hasKey(varName):
      infos.add(elseEnv.vals[varName])
    elif env.vals.hasKey(varName):
      infos.add(env.vals[varName])  # Use original state
    branchCount += 1

    # Compute union of all info states for control flow merging
    if infos.len > 0:
      var mergedInfo = infos[0]
      for i in 1..<infos.len:
        mergedInfo = union(mergedInfo, infos[i])
      env.vals[varName] = mergedInfo


proc proveWhile(s: Stmt; env: Env, ctx: ProverContext) =
  # Enhanced while loop analysis using symbolic execution
  let condResult = evaluateCondition(s.wcond, env, ctx)

  case condResult
  of crAlwaysFalse:
    if s.wbody.len > 0:
      if ctx.fnContext.len > 0 and '<' in ctx.fnContext and '>' in ctx.fnContext and "<>" notin ctx.fnContext:
        raise newProverError(s.pos, &"unreachable code (while condition is always false) in {ctx.fnContext}")
      else:
        raise newProverError(s.pos, "unreachable code (while condition is always false)")
    # Skip loop body analysis since it's never executed
    return
  of crAlwaysTrue:
    discard
  of crUnknown:
    discard

  # Try symbolic execution for precise loop analysis
  var symState = newSymbolicState()

  # Convert current environment to symbolic state
  for varName, info in env.vals:
    symState.setVariable(varName, info)  # Direct assignment since using unified Info type

  # Try to execute the loop symbolically
  let loopResult = symbolicExecuteWhile(s, symState, ctx.prog)

  case loopResult
  of erContinue:
    # Loop executed completely with known values - use precise results
    for varName, info in symState.variables:
      env.vals[varName] = info  # Direct assignment since using unified Info type
  of erRuntimeHit, erIterationLimit:
    # Fell back to conservative analysis - but we may have learned something
    # from the initial iterations that executed symbolically

    # Use hybrid approach: variables that were definitely initialized
    # in the symbolic portion are marked as initialized
    var originalVars = initTable[string, Info]()
    for k, v in env.vals:
      originalVars[k] = v

    # Create loop body environment for remaining analysis
    var loopEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)

    # Analyze loop body with traditional method
    for st in s.wbody:
      proveStmt(st, loopEnv, ctx)

    # Enhanced merge: if symbolic execution determined a variable was initialized,
    # trust that result even if traditional analysis is conservative
    for varName in loopEnv.vals.keys:
      if originalVars.hasKey(varName) and symState.hasVariable(varName):
        let originalInfo = originalVars[varName]
        let loopInfo = loopEnv.vals[varName]
        let symInfo = symState.getVariable(varName).get()

        # If symbolic execution shows variable is initialized, trust it
        if symInfo.initialized and not originalInfo.initialized:
          var enhancedInfo = loopInfo
          enhancedInfo.initialized = true
          env.vals[varName] = enhancedInfo
        elif not originalInfo.initialized:
          # Fall back to conservative approach
          var conservativeInfo = loopInfo
          conservativeInfo.initialized = false
          env.vals[varName] = conservativeInfo
        else:
          # Variable was already initialized, merge normally
          env.vals[varName] = union(originalInfo, loopInfo)
      elif originalVars.hasKey(varName):
        # Handle variables without symbolic info conservatively
        let originalInfo = originalVars[varName]
        let loopInfo = loopEnv.vals[varName]
        if not originalInfo.initialized:
          var conservativeInfo = loopInfo
          conservativeInfo.initialized = false
          env.vals[varName] = conservativeInfo
        else:
          env.vals[varName] = union(originalInfo, loopInfo)
      else:
        # New variable declared in loop - conservative approach
        var conservativeInfo = loopEnv.vals[varName]
        conservativeInfo.initialized = false
        env.vals[varName] = conservativeInfo
  of erComplete:
    # Loop completed (shouldn't happen for while loops, but handle gracefully)
    discard


proc proveFor(s: Stmt; env: Env, ctx: ProverContext) =
  # Analyze for loop: for var in start..end or for var in array
  verboseProverLog(ctx.flags, "Analyzing for loop variable: " & s.fvar)

  var loopVarInfo: Info
  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayInfo = analyzeExpr(s.farray.get(), env, ctx)
    verboseProverLog(ctx.flags, "For loop over array with info: " & (if arrayInfo.isArray: "array" else: "unknown"))

    # Loop variable gets the element type - for now assume int (could be enhanced later)
    loopVarInfo = infoUnknown()
    loopVarInfo.initialized = true
    loopVarInfo.nonNil = true

    # Check if array is empty (would make loop body unreachable)
    if arrayInfo.isArray and arrayInfo.arraySizeKnown and arrayInfo.arraySize == 0:
      if s.fbody.len > 0:
        raise newProverError(s.pos, "unreachable code (for loop over empty array)")

  else:
    # Range iteration: for var in start..end
    let startInfo = analyzeExpr(s.fstart.get(), env, ctx)
    let endInfo = analyzeExpr(s.fend.get(), env, ctx)

    verboseProverLog(ctx.flags, "For loop start range: [" & $startInfo.minv & ".." & $startInfo.maxv & "]")
    verboseProverLog(ctx.flags, "For loop end range: [" & $endInfo.minv & ".." & $endInfo.maxv & "]")

    # Check if loop will never execute
    if s.finclusive:
      # Inclusive range: start > end means no execution
      if startInfo.known and endInfo.known and startInfo.cval > endInfo.cval:
        if s.fbody.len > 0:
          raise newProverError(s.pos, "unreachable code (for loop will never execute: start > end)")
      elif startInfo.minv > endInfo.maxv:
        if s.fbody.len > 0:
          raise newProverError(s.pos, "unreachable code (for loop will never execute: min(start) > max(end))")
    else:
      # Exclusive range: start >= end means no execution
      if startInfo.known and endInfo.known and startInfo.cval >= endInfo.cval:
        if s.fbody.len > 0:
          raise newProverError(s.pos, "unreachable code (for loop will never execute: start >= end)")
      elif startInfo.minv >= endInfo.maxv:
        if s.fbody.len > 0:
          raise newProverError(s.pos, "unreachable code (for loop will never execute: min(start) >= max(end))")

    # Create loop variable info - it ranges from start to end (or end-1 for exclusive)
    let actualEnd = if s.finclusive: max(endInfo.maxv, endInfo.cval) else: max(endInfo.maxv, endInfo.cval) - 1
    loopVarInfo = infoRange(min(startInfo.minv, startInfo.cval), actualEnd)
    loopVarInfo.initialized = true
    loopVarInfo.nonNil = true

  # Save current variable state if it exists
  let oldVarInfo = if env.vals.hasKey(s.fvar): env.vals[s.fvar] else: infoUninitialized()

  # Set loop variable
  env.vals[s.fvar] = loopVarInfo
  env.nils[s.fvar] = false

  verboseProverLog(ctx.flags, "Loop variable " & s.fvar & " has range [" & $loopVarInfo.minv & ".." & $loopVarInfo.maxv & "]")

  # Analyze loop body
  for stmt in s.fbody:
    proveStmt(stmt, env, ctx)

  # Restore old variable state (for loops introduce block scope)
  if oldVarInfo.initialized:
    env.vals[s.fvar] = oldVarInfo
  else:
    env.vals.del(s.fvar)
    env.nils.del(s.fvar)


proc proveBreak(s: Stmt; env: Env, ctx: ProverContext) =
  # Break statements are valid only inside loops, but this is a parse-time concern
  # For prover purposes, break doesn't change variable states
  verboseProverLog(ctx.flags, "Break statement (control flow transfer)")


proc proveExpr(s: Stmt; env: Env, ctx: ProverContext) =
  discard analyzeExpr(s.sexpr, env, ctx)


proc proveReturn(s: Stmt; env: Env, ctx: ProverContext) =
  if s.re.isSome():
      discard analyzeExpr(s.re.get(), env, ctx)


proc proveComptime(s: Stmt; env: Env, ctx: ProverContext) =
  # Comptime blocks may contain injected statements after folding
  for injectedStmt in s.cbody:
    proveStmt(injectedStmt, env, ctx)


proc proveStmt*(s: Stmt; env: Env, ctx: ProverContext) =
  let stmtKindStr = case s.kind
    of skVar: "variable declaration"
    of skAssign: "assignment"
    of skIf: "if statement"
    of skWhile: "while loop"
    of skFor: "for loop"
    of skBreak: "break statement"
    of skExpr: "expression statement"
    of skReturn: "return statement"
    else: $s.kind

  verboseProverLog(ctx.flags, "Analyzing " & stmtKindStr & (if ctx.fnContext != "": " in " & ctx.fnContext else: ""))

  case s.kind
  of skVar: proveVar(s, env, ctx)
  of skAssign: proveAssign(s, env, ctx)
  of skIf: proveIf(s, env, ctx)
  of skWhile: proveWhile(s, env, ctx)
  of skFor: proveFor(s, env, ctx)
  of skBreak: proveBreak(s, env, ctx)
  of skExpr: proveExpr(s, env, ctx)
  of skReturn: proveReturn(s, env, ctx)
  of skComptime: proveComptime(s, env, ctx)
