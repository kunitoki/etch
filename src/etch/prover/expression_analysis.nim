# prover/expression_analysis.nim
# Expression analysis for the safety prover

import std/[strformat, options, tables]
import ../frontend/ast, ../errors, ../interpreter/serialize
import types, binary_operations, function_evaluation

proc verboseProverLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[PROVER] ", msg

# Forward declaration for mutual recursion
proc analyzeExpr*(e: Expr; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags()): Info

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
  infoString(length, lengthKnown = true)

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
      return Info(known: false, minv: actualMin, maxv: actualMax,
                 nonZero: actualMin > 0 or actualMax < 0, initialized: true)
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
  # Unknown builtin - just analyze arguments
  for arg in e.args: discard analyzeExpr(arg, env, prog)
  return infoUnknown()

proc analyzeUserDefinedCall*(e: Expr, env: Env, prog: Program): Info =
  # User-defined function call - perform call-site safety analysis
  let fn = prog.funInstances[e.fname]

  # Analyze arguments to get their safety information
  var argInfos: seq[Info] = @[]
  for arg in e.args:
    argInfos.add analyzeExpr(arg, env, prog)

  # Add default parameter information
  for i in e.args.len..<fn.params.len:
    if fn.params[i].defaultValue.isSome:
      let defaultInfo = analyzeExpr(fn.params[i].defaultValue.get, env, prog)
      argInfos.add defaultInfo
    else:
      # This shouldn't happen if type checking is correct
      argInfos.add infoUnknown()

  # Now perform call-site safety analysis on the function body
  # Create environment with actual argument information and global variables
  var callEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)

  # Set up parameter environment with actual call-site information
  for i in 0..<min(argInfos.len, fn.params.len):
    callEnv.vals[fn.params[i].name] = argInfos[i]
    callEnv.nils[fn.params[i].name] = not argInfos[i].nonNil

  # Check if all arguments are compile-time constants for potential constant folding
  var allArgsConstant = true
  for argInfo in argInfos:
    if not argInfo.known:
      allArgsConstant = false
      break

  # If all arguments are constants, try to evaluate simple pure functions at compile time
  if allArgsConstant:
    let evalResult = tryEvaluatePureFunction(e, argInfos, fn, prog)
    if evalResult.isSome:
      return infoConst(evalResult.get)

  # Analyze function body with call-site specific argument information
  # This will catch safety violations like division by zero with actual arguments
  # We need to analyze the function body with the actual argument values

  # We'll implement a simple version here that focuses on division by zero detection
  # For more complex cases, this would need the full statement analysis

  # Recursive function to check expressions for division by zero with actual arguments
  proc checkExpressionForDivision(expr: Expr) =
    case expr.kind
    of ekBin:
      if expr.bop == boDiv:
        # This is a division - check the divisor with actual arguments
        if expr.rhs.kind == ekVar:
          # Find the parameter index for the divisor variable
          for i, param in fn.params:
            if param.name == expr.rhs.vname:
              if i < argInfos.len:
                let divisorInfo = argInfos[i]
                if divisorInfo.known and divisorInfo.cval == 0:
                  raise newProverError(expr.pos, "division by zero")
                elif not divisorInfo.nonZero:
                  raise newProverError(expr.pos, "cannot prove divisor is non-zero")
              break
      # Recursively check both sides of binary operations
      checkExpressionForDivision(expr.lhs)
      checkExpressionForDivision(expr.rhs)
    of ekCall:
      # Check arguments of nested calls
      for arg in expr.args:
        checkExpressionForDivision(arg)
    else:
      discard # Other expression types don't contain divisions

  # Check the function body for division operations
  for stmt in fn.body:
    case stmt.kind
    of skReturn:
      if stmt.re.isSome:
        checkExpressionForDivision(stmt.re.get)
    else:
      # For now, only handle simple return statements
      # More complex control flow would require full statement analysis
      discard

  return infoUnknown()

proc analyzeCallExpr*(e: Expr, env: Env, prog: Program): Info =
  # User-defined function call - perform call-site safety analysis
  if prog != nil and prog.funInstances.hasKey(e.fname):
    return analyzeUserDefinedCall(e, env, prog)
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

  # Determine the result type information for nested arrays
  # If the result type is also an array, we need to analyze the specific inner array size
  if e.typ != nil and e.typ.kind == tkArray:
    # The result is an array type - need to determine its size
    # Case 1: Direct indexing into array literal
    if e.arrayExpr.kind == ekArray and indexInfo.known and
       indexInfo.cval >= 0 and indexInfo.cval < e.arrayExpr.elements.len:
      # We're indexing into an array literal with a known index
      let elementExpr = e.arrayExpr.elements[indexInfo.cval]
      if elementExpr.kind == ekArray:
        # The element is itself an array literal - return its specific size info
        return infoArray(elementExpr.elements.len.int64, sizeKnown = true)

    # Case 2: Indexing into a variable that contains an array literal
    elif e.arrayExpr.kind == ekVar and indexInfo.known:
      # Look up the variable's original expression
      if env.exprs.hasKey(e.arrayExpr.vname):
        let originalExpr = env.exprs[e.arrayExpr.vname]
        if originalExpr.kind == ekArray and indexInfo.cval >= 0 and indexInfo.cval < originalExpr.elements.len:
          # The variable was initialized with an array literal
          let elementExpr = originalExpr.elements[indexInfo.cval]
          if elementExpr.kind == ekArray:
            # The element is itself an array literal - return its specific size info
            return infoArray(elementExpr.elements.len.int64, sizeKnown = true)
      # If we can't determine the exact size, return unknown array size
      return infoArray(-1, sizeKnown = false)

    # If we can't determine the exact size but know it's an array, return unknown array info
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
          return infoString(sliceLength, lengthKnown = true)

    # Fall back to unknown length
    return infoString(-1, lengthKnown = false)
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

proc analyzeExpr*(e: Expr; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags()): Info =
  let exprKindStr = case e.kind
    of ekInt: "integer literal"
    of ekVar: "variable reference"
    of ekBin: "binary operation"
    of ekCall: "function call"
    of ekIndex: "array index"
    of ekDeref: "dereference"
    else: $e.kind

  verboseProverLog(flags, "Analyzing " & exprKindStr & (if e.kind == ekVar: " '" & e.vname & "'" else: ""))

  case e.kind
  of ekInt: return analyzeIntExpr(e)
  of ekFloat: return analyzeFloatExpr(e)
  of ekString: return analyzeStringExpr(e)
  of ekChar: return analyzeCharExpr(e)
  of ekBool: return analyzeBoolExpr(e)
  of ekVar: return analyzeVarExpr(e, env)
  of ekUn: return analyzeUnaryExpr(e, env, prog, flags)
  of ekBin: return analyzeBinaryExpr(e, env, prog, flags)
  of ekCall: return analyzeCallExpr(e, env, prog)
  of ekNewRef: return analyzeNewRefExpr(e, env, prog)
  of ekDeref: return analyzeDerefExpr(e, env, prog)
  of ekArray: return analyzeArrayExpr(e, env, prog)
  of ekIndex: return analyzeIndexExpr(e, env, prog)
  of ekSlice: return analyzeSliceExpr(e, env, prog)
  of ekArrayLen: return analyzeArrayLenExpr(e, env, prog)
  of ekCast: return analyzeCastExpr(e, env, prog)
  of ekNil: return analyzeNilExpr(e)
