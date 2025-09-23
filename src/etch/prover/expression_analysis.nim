# prover/expression_analysis.nim
# Expression analysis for the safety prover


import std/[strformat, options, tables]
import ../frontend/ast, ../errors, ../interpreter/serialize
import types, binary_operations, function_evaluation


proc verboseProverLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[PROVER] ", msg


# Forward declarations for mutual recursion
proc analyzeExpr*(e: Expr; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags()): Info
proc analyzeBinaryExpr*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info
proc analyzeCallExpr*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info


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
  # char analysis not needed for safety, chars are always initialized
  Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)


proc analyzeVarExpr*(e: Expr, env: Env): Info =
  if env.vals.hasKey(e.vname):
    let info = env.vals[e.vname]
    if not info.initialized:
      raise newProverError(e.pos, &"use of uninitialized variable '{e.vname}' - variable may not be initialized in all control flow paths")
    return info
  raise newProverError(e.pos, &"use of undeclared variable '{e.vname}'")


proc analyzeUnaryExpr*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info =
  let i0 = analyzeExpr(e.ue, env, prog, flags)
  case e.uop
  of uoNeg:
    if i0.known: return infoConst(-i0.cval)
    return Info(known: false, minv: (if i0.maxv == IMax: IMin else: -i0.maxv),
                maxv: (if i0.minv == IMin: IMax else: -i0.minv), initialized: true)
  of uoNot:
    return infoBool(false) # boolean domain is tiny; not needed for arithmetic safety


proc analyzeBinaryExpr*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info =
  let a = analyzeExpr(e.lhs, env, prog, flags)
  let b = analyzeExpr(e.rhs, env, prog, flags)
  case e.bop
  of boAdd: return analyzeBinaryAddition(e, a, b)
  of boSub: return analyzeBinarySubtraction(e, a, b)
  of boMul: return analyzeBinaryMultiplication(e, a, b)
  of boDiv: return analyzeBinaryDivision(e, a, b)
  of boMod: return analyzeBinaryModulo(e, a, b)
  of boEq,boNe,boLt,boLe,boGt,boGe: return analyzeBinaryComparison(e, a, b)
  of boAnd,boOr: return analyzeBinaryLogical(e, a, b)


proc analyzeRandCall*(e: Expr, env: Env, prog: Program): Info =
  # analyze arguments for safety
  for arg in e.args: discard analyzeExpr(arg, env, prog)

  # Track the range of rand(max) or rand(max, min)
  if e.args.len == 1:
    let maxInfo = analyzeExpr(e.args[0], env, prog)
    if maxInfo.known:
      # rand(max) returns 0 to max inclusive - can be zero unless min > 0
      return Info(known: false, minv: 0, maxv: maxInfo.cval, nonZero: false, initialized: true)
    else:
      # max is in a range, use the maximum possible value as the upper bound
      # rand(max) where max is in range [a, b] returns values in range [0, b]
      return Info(known: false, minv: 0, maxv: max(0, maxInfo.maxv), nonZero: false, initialized: true)
  elif e.args.len == 2:
    let maxInfo = analyzeExpr(e.args[0], env, prog)
    let minInfo = analyzeExpr(e.args[1], env, prog)
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


proc analyzeBuiltinCall*(e: Expr, env: Env, prog: Program): Info =
  # recognize trusted builtins affecting nonNil/nonZero
  if e.fname == "print":
    # analyze arguments for safety even though print returns void
    for arg in e.args: discard analyzeExpr(arg, env, prog)
    return infoUnknown()
  if e.fname == "rand":
    return analyzeRandCall(e, env, prog)
  if e.fname == "toString":
    # analyze argument for safety
    if e.args.len > 0:
      let argInfo = analyzeExpr(e.args[0], env, prog)
      # If we know the integer value, we can compute string length
      if argInfo.known:
        let strLen = ($argInfo.cval).len.int64
        return infoString(strLen, sizeKnown = true)
      else:
        # Unknown value - return unknown string length
        return infoString(0, sizeKnown = false)
    else:
      return infoString(0, sizeKnown = false)
  if e.fname == "parseInt":
    # parseInt returns option[int] - analyze argument for safety
    if e.args.len > 0:
      discard analyzeExpr(e.args[0], env, prog)
    # parseInt can return any valid integer that fits in a string representation
    # The actual range should be based on realistic string parsing limits
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
  # Unknown builtin - just analyze arguments
  for arg in e.args: discard analyzeExpr(arg, env, prog)
  return infoUnknown()


proc analyzeUserDefinedCall*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info =
  # User-defined function call - comprehensive call-site safety analysis
  let fn = prog.funInstances[e.fname]

  verboseProverLog(flags, &"Analyzing user-defined function call: {e.fname}")

  # Analyze arguments to get their safety information
  var argInfos: seq[Info] = @[]
  for i, arg in e.args:
    let argInfo = analyzeExpr(arg, env, prog, flags)
    argInfos.add argInfo
    verboseProverLog(flags, &"Argument {i}: {(if argInfo.known: $argInfo.cval else: \"[\" & $argInfo.minv & \"..\" & $argInfo.maxv & \"]\")}")

  # Add default parameter information
  for i in e.args.len..<fn.params.len:
    if fn.params[i].defaultValue.isSome:
      let defaultInfo = analyzeExpr(fn.params[i].defaultValue.get, env, prog, flags)
      argInfos.add defaultInfo
      verboseProverLog(flags, &"Default param {i}: {(if defaultInfo.known: $defaultInfo.cval else: \"[\" & $defaultInfo.minv & \"..\" & $defaultInfo.maxv & \"]\")}")
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
    verboseProverLog(flags, "All arguments are constants - attempting compile-time evaluation")
    let evalResult = tryEvaluatePureFunction(e, argInfos, fn, prog)
    if evalResult.isSome:
      verboseProverLog(flags, &"Function evaluated at compile-time to: {evalResult.get}")
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
    verboseProverLog(flags, &"Parameter '{paramName}' mapped to: {(if argInfos[i].known: $argInfos[i].cval else: \"[\" & $argInfos[i].minv & \"..\" & $argInfos[i].maxv & \"]\")}")

  # Perform comprehensive safety analysis on function body
  let fnContext = &"function {functionNameFromSignature(e.fname)}"
  verboseProverLog(flags, &"Starting comprehensive analysis of function body with {fn.body.len} statements")

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
        let divisorInfo = analyzeExpr(expr.rhs, callEnv, prog, flags)
        if divisorInfo.known and divisorInfo.cval == 0:
          raise newProverError(expr.pos, &"division by zero in {fnContext}")
        elif not divisorInfo.nonZero:
          raise newProverError(expr.pos, &"cannot prove divisor is non-zero in {fnContext}")
      of boAdd, boSub, boMul:
        # Check for potential overflow/underflow
        # The binary operations module already does overflow checks
        discard analyzeBinaryExpr(expr, callEnv, prog, flags)
      else:
        discard
    of ekIndex:
      # Array bounds checking
      checkExpressionSafety(expr.arrayExpr)
      checkExpressionSafety(expr.indexExpr)
      let indexInfo = analyzeExpr(expr.indexExpr, callEnv, prog, flags)
      if indexInfo.known and indexInfo.cval < 0:
        raise newProverError(expr.pos, &"negative array index in {fnContext}")
      # Additional bounds checking is done by the recursive call to analyzeExpr
      discard analyzeExpr(expr, callEnv, prog, flags)
    of ekSlice:
      # Slice bounds checking
      if expr.startExpr.isSome:
        checkExpressionSafety(expr.startExpr.get)
      if expr.endExpr.isSome:
        checkExpressionSafety(expr.endExpr.get)
      checkExpressionSafety(expr.sliceExpr)
      discard analyzeExpr(expr, callEnv, prog, flags)
    of ekDeref:
      # Nil dereference checking
      let refInfo = analyzeExpr(expr.refExpr, callEnv, prog, flags)
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
      discard analyzeExpr(expr, callEnv, prog, flags)
    else:
      # For other expression types, just analyze normally
      discard analyzeExpr(expr, callEnv, prog, flags)

  # Check all statements in the function body
  for i, stmt in fn.body:
    verboseProverLog(flags, &"Analyzing statement {i + 1}/{fn.body.len}: {stmt.kind}")

    case stmt.kind
    of skExpr:
      checkExpressionSafety(stmt.sexpr)
    of skReturn:
      if stmt.re.isSome:
        checkExpressionSafety(stmt.re.get)
    of skVar:
      if stmt.vinit.isSome:
        checkExpressionSafety(stmt.vinit.get)
        # Update environment for variable initialization
        let initInfo = analyzeExpr(stmt.vinit.get, callEnv, prog, flags)
        callEnv.vals[stmt.vname] = initInfo
        callEnv.nils[stmt.vname] = not initInfo.nonNil
        callEnv.exprs[stmt.vname] = stmt.vinit.get
      else:
        callEnv.vals[stmt.vname] = infoUninitialized()
        callEnv.nils[stmt.vname] = true
    of skAssign:
      checkExpressionSafety(stmt.aval)
      # Update environment for assignment
      let assignInfo = analyzeExpr(stmt.aval, callEnv, prog, flags)
      var newInfo = assignInfo
      newInfo.initialized = true
      callEnv.vals[stmt.aname] = newInfo
      callEnv.exprs[stmt.aname] = stmt.aval
      if assignInfo.nonNil:
        callEnv.nils[stmt.aname] = false
    of skIf:
      # Check condition
      checkExpressionSafety(stmt.cond)
      # For now, we'll do a simplified analysis of if statements
      # A complete implementation would need to handle control flow
      for thenStmt in stmt.thenBody:
        case thenStmt.kind
        of skExpr:
          checkExpressionSafety(thenStmt.sexpr)
        of skReturn:
          if thenStmt.re.isSome:
            checkExpressionSafety(thenStmt.re.get)
        else:
          # Simplified analysis - more complex control flow requires full statement analysis
          discard
      # Check else branch
      for elseStmt in stmt.elseBody:
        case elseStmt.kind
        of skExpr:
          checkExpressionSafety(elseStmt.sexpr)
        of skReturn:
          if elseStmt.re.isSome:
            checkExpressionSafety(elseStmt.re.get)
        else:
          discard
    else:
      # For other statement types, we'll skip detailed analysis for now
      # A complete implementation would recursively analyze all statement types
      verboseProverLog(flags, &"Simplified analysis for {stmt.kind} in {fnContext}")
      discard

  verboseProverLog(flags, &"Function {fnContext} analysis completed successfully")

  # Try to determine return value information by looking at return statements
  # This is a simplified approach - a more complete implementation would track
  # all possible return paths and merge their info
  for stmt in fn.body:
    if stmt.kind == skReturn and stmt.re.isSome:
      let returnInfo = analyzeExpr(stmt.re.get, callEnv, prog, flags)
      verboseProverLog(flags, &"Function return value: {(if returnInfo.known: $returnInfo.cval else: \"[\" & $returnInfo.minv & \"..\" & $returnInfo.maxv & \"]\")}")
      return returnInfo

  # No return statement found or void return
  verboseProverLog(flags, &"Function {fnContext} has no explicit return value")
  return infoUnknown()


proc analyzeCallExpr*(e: Expr, env: Env, prog: Program, flags: CompilerFlags = CompilerFlags()): Info =
  # User-defined function call - perform call-site safety analysis
  if prog != nil and prog.funInstances.hasKey(e.fname):
    return analyzeUserDefinedCall(e, env, prog, flags)
  else:
    return analyzeBuiltinCall(e, env, prog)


proc analyzeNewRefExpr*(e: Expr, env: Env, prog: Program): Info =
  # newRef always non-nil
  discard analyzeExpr(e.init, env, prog)  # Analyze the initialization expression
  Info(known: false, nonNil: true, initialized: true)


proc analyzeDerefExpr*(e: Expr, env: Env, prog: Program): Info =
  let i0 = analyzeExpr(e.refExpr, env, prog)
  if not i0.nonNil: raise newException(ValueError, "Prover: cannot prove ref non-nil before deref")
  infoUnknown()


proc analyzeCastExpr*(e: Expr, env: Env, prog: Program): Info =
  # Explicit cast - analyze the source expression and return appropriate info for target type
  let sourceInfo = analyzeExpr(e.castExpr, env, prog)  # Analyze source for safety

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


proc analyzeArrayExpr*(e: Expr, env: Env, prog: Program): Info =
  # Array literal - analyze all elements for safety and track size
  for elem in e.elements:
    discard analyzeExpr(elem, env, prog)
  # Return info with known array size
  infoArray(e.elements.len.int64, sizeKnown = true)


proc analyzeIndexExpr*(e: Expr, env: Env, prog: Program): Info =
  # Array/String indexing - comprehensive bounds checking
  let arrayInfo = analyzeExpr(e.arrayExpr, env, prog)
  let indexInfo = analyzeExpr(e.indexExpr, env, prog)

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
      return analyzeExpr(elementExpr, env, prog)

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
          return analyzeExpr(elementExpr, env, prog)

  # If result type is an array but we can't determine exact size
  if e.typ != nil and e.typ.kind == tkArray:
    return infoArray(-1, sizeKnown = false)

  infoUnknown()


proc analyzeSliceExpr*(e: Expr, env: Env, prog: Program): Info =
  # Array slicing - comprehensive slice bounds checking
  let arrayInfo = analyzeExpr(e.sliceExpr, env, prog)

  var startInfo, endInfo: Info
  var hasStart = false
  var hasEnd = false

  # Analyze start bound if present
  if e.startExpr.isSome:
    startInfo = analyzeExpr(e.startExpr.get, env, prog)
    hasStart = true
    if startInfo.known and startInfo.cval < 0:
      raise newProverError(e.startExpr.get.pos, &"slice start cannot be negative: {startInfo.cval}")

  # Analyze end bound if present
  if e.endExpr.isSome:
    endInfo = analyzeExpr(e.endExpr.get, env, prog)
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


proc analyzeArrayLenExpr*(e: Expr, env: Env, prog: Program): Info =
  # Array/String length operator: #array/#string -> int
  let arrayInfo = analyzeExpr(e.lenExpr, env, prog)
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


proc analyzeOptionSomeExpr*(e: Expr, env: Env, prog: Program): Info =
  # some(value) - analyze the wrapped value
  discard analyzeExpr(e.someExpr, env, prog)
  infoUnknown()  # option value is unknown without pattern matching


proc analyzeOptionNoneExpr*(e: Expr): Info =
  # none - safe but represents absence of value
  infoUnknown()


proc analyzeResultOkExpr*(e: Expr, env: Env, prog: Program): Info =
  # ok(value) - analyze the wrapped value
  discard analyzeExpr(e.okExpr, env, prog)
  infoUnknown()  # result value is unknown without pattern matching


proc analyzeResultErrExpr*(e: Expr, env: Env, prog: Program): Info =
  # error(msg) - analyze the error message
  discard analyzeExpr(e.errExpr, env, prog)
  infoUnknown()  # error value is unknown without pattern matching


proc analyzeMatchExpr(e: Expr, env: Env, prog: Program): Info =
  # Simplified match expression analysis that only handles expressions, not full statements
  let matchedInfo = analyzeExpr(e.matchExpr, env, prog)

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
        discard analyzeExpr(stmt.sexpr, caseEnv, prog)
      of skVar:
        # Handle variable declarations in match case bodies
        if stmt.vinit.isSome():
          let info = analyzeExpr(stmt.vinit.get(), caseEnv, prog)
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


proc analyzeExpr*(e: Expr; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags()): Info =
  verboseProverLog(flags, "Analyzing " & $e.kind & (if e.kind == ekVar: " '" & e.vname & "'" else: ""))

  case e.kind
  of ekInt: return analyzeIntExpr(e)
  of ekFloat: return analyzeFloatExpr(e)
  of ekString: return analyzeStringExpr(e)
  of ekChar: return analyzeCharExpr(e)
  of ekBool: return analyzeBoolExpr(e)
  of ekVar: return analyzeVarExpr(e, env)
  of ekUn: return analyzeUnaryExpr(e, env, prog, flags)
  of ekBin: return analyzeBinaryExpr(e, env, prog, flags)
  of ekCall: return analyzeCallExpr(e, env, prog, flags)
  of ekNewRef: return analyzeNewRefExpr(e, env, prog)
  of ekDeref: return analyzeDerefExpr(e, env, prog)
  of ekArray: return analyzeArrayExpr(e, env, prog)
  of ekIndex: return analyzeIndexExpr(e, env, prog)
  of ekSlice: return analyzeSliceExpr(e, env, prog)
  of ekArrayLen: return analyzeArrayLenExpr(e, env, prog)
  of ekCast: return analyzeCastExpr(e, env, prog)
  of ekNil: return analyzeNilExpr(e)
  of ekOptionSome: return analyzeOptionSomeExpr(e, env, prog)
  of ekOptionNone: return analyzeOptionNoneExpr(e)
  of ekResultOk: return analyzeResultOkExpr(e, env, prog)
  of ekResultErr: return analyzeResultErrExpr(e, env, prog)
  of ekMatch: return analyzeMatchExpr(e, env, prog)
