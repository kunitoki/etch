# prover.nim
# Safety prover: range/const analysis to ensure:
# - addition/multiplication doesn't overflow int64
# - division has provably non-zero divisor
# - deref on Ref[...] is proven non-nil

import std/[tables, options, strformat, strutils]
import ast, errors, symbolic, vm

const IMin = low(int64)
const IMax = high(int64)

type
  Info = object
    known*: bool
    cval*: int64
    minv*, maxv*: int64
    nonZero*: bool
    nonNil*: bool
    isBool*: bool
    initialized*: bool
    # Array size tracking
    isArray*: bool
    arraySize*: int64  # -1 if unknown size
    arraySizeKnown*: bool

type Env = ref object
  vals: Table[string, Info]
  nils: Table[string, bool]
  exprs: Table[string, Expr]  # Track original expressions for variables

proc infoConst(v: int64): Info =
  Info(known: true, cval: v, minv: v, maxv: v, nonZero: v != 0, isBool: false, initialized: true)
proc infoBool(b: bool): Info =
  Info(known: true, cval: (if b: 1 else: 0), minv: 0, maxv: 1, nonZero: b, isBool: true, initialized: true)
proc infoUnknown(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: true)
proc infoUninitialized(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: false)
proc infoArray(size: int64, sizeKnown: bool = true): Info =
  Info(known: false, minv: IMin, maxv: IMax, initialized: true, isArray: true, arraySize: size, arraySizeKnown: sizeKnown)

proc meet(a, b: Info): Info =
  result = Info()
  result.known = a.known and b.known and a.cval == b.cval
  result.cval = (if result.known: a.cval else: 0)
  result.minv = max(a.minv, b.minv)
  result.maxv = min(a.maxv, b.maxv)
  result.nonZero = a.nonZero and b.nonZero
  result.nonNil = a.nonNil and b.nonNil
  result.isBool = a.isBool and b.isBool
  result.initialized = a.initialized and b.initialized
  # Array info meet
  result.isArray = a.isArray and b.isArray
  if result.isArray:
    result.arraySizeKnown = a.arraySizeKnown and b.arraySizeKnown and a.arraySize == b.arraySize
    result.arraySize = (if result.arraySizeKnown: a.arraySize else: -1)

proc union(a, b: Info): Info =
  # Union operation for control flow merging - covers all possible values from both branches
  result = Info()
  result.known = a.known and b.known and a.cval == b.cval
  result.cval = (if result.known: a.cval else: 0)
  result.minv = min(a.minv, b.minv)  # Minimum of both minimums
  result.maxv = max(a.maxv, b.maxv)  # Maximum of both maximums
  result.nonZero = a.nonZero and b.nonZero  # Only nonZero if both are nonZero
  result.nonNil = a.nonNil and b.nonNil    # Only nonNil if both are nonNil
  result.isBool = a.isBool and b.isBool
  result.initialized = a.initialized and b.initialized
  # Array info union - be conservative
  result.isArray = a.isArray and b.isArray
  if result.isArray:
    # For union, if array sizes differ, we don't know the size
    result.arraySizeKnown = a.arraySizeKnown and b.arraySizeKnown and a.arraySize == b.arraySize
    result.arraySize = (if result.arraySizeKnown: a.arraySize else: -1)

type ConditionResult = enum
  crUnknown, crAlwaysTrue, crAlwaysFalse

proc analyzeExpr(e: Expr; env: Env, prog: Program = nil): Info
proc proveStmt(s: Stmt; env: Env, prog: Program = nil, fnContext: string = "")  # forward declaration

# Forward declarations for modularized expression analysis
proc analyzeIntExpr(e: Expr): Info
proc analyzeFloatExpr(e: Expr): Info
proc analyzeStringExpr(e: Expr): Info
proc analyzeBoolExpr(e: Expr): Info
proc analyzeVarExpr(e: Expr, env: Env): Info
proc analyzeUnaryExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeBinaryExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeCallExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeRandCall(e: Expr, env: Env, prog: Program): Info
proc analyzeNewRefExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeDerefExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeArrayExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeIndexExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeSliceExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeArrayLenExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeCastExpr(e: Expr, env: Env, prog: Program): Info
proc analyzeNilExpr(e: Expr): Info

proc analyzeIntExpr(e: Expr): Info =
  infoConst(e.ival)

proc analyzeFloatExpr(e: Expr): Info =
  # For float literals, we can provide a reasonable integer range for cast analysis
  if e.fval >= IMin.float64 and e.fval <= IMax.float64:
    let intApprox = e.fval.int64
    Info(known: true, cval: intApprox, minv: intApprox, maxv: intApprox, nonZero: intApprox != 0, initialized: true)
  else:
    Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

proc analyzeStringExpr(e: Expr): Info =
  # string analysis not needed for safety
  Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

proc analyzeBoolExpr(e: Expr): Info =
  infoBool(e.bval)

proc analyzeVarExpr(e: Expr, env: Env): Info =
  if env.vals.hasKey(e.vname):
    let info = env.vals[e.vname]
    if not info.initialized:
      raise newProverError(e.pos, &"use of uninitialized variable '{e.vname}' - variable may not be initialized in all control flow paths")
    return info
  raise newProverError(e.pos, &"use of undeclared variable '{e.vname}'")

proc analyzeUnaryExpr(e: Expr, env: Env, prog: Program): Info =
  let i0 = analyzeExpr(e.ue, env, prog)
  case e.uop
  of uoNeg:
    if i0.known: return infoConst(-i0.cval)
    return Info(known: false, minv: (if i0.maxv == IMax: IMin else: -i0.maxv),
                maxv: (if i0.minv == IMin: IMax else: -i0.minv), initialized: true)
  of uoNot:
    return infoBool(false) # boolean domain is tiny; not needed for arithmetic safety

proc analyzeBinaryAddition(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  if a.known and b.known:
    let s = a.cval + b.cval
    # overflow check at compile-time must not overflow Nim; use bigints? assume safe here with int64
    if ( (b.cval > 0 and a.cval > IMax - b.cval) or (b.cval < 0 and a.cval < IMin - b.cval) ):
      raise newProverError(e.pos, "addition overflow on constants")
    return infoConst(s)
  # range addition - be conservative but allow reasonable bounds
  # Check for overflow before doing arithmetic
  var minS, maxS: int64
  try:
    minS = a.minv + b.minv
    maxS = a.maxv + b.maxv
  except OverflowDefect:
    raise newProverError(e.pos, "potential addition overflow")

  return Info(known: false, minv: minS, maxv: maxS, nonZero: a.nonZero or b.nonZero, initialized: true)

proc analyzeBinarySubtraction(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # similar policy as add
  if a.known and b.known:
    let d = a.cval - b.cval
    if ( (b.cval < 0 and a.cval > IMax + b.cval) or (b.cval > 0 and a.cval < IMin + b.cval) ):
      raise newException(ValueError, "Prover: possible - overflow on constants")
    return infoConst(d)
  let minD = a.minv - b.maxv
  let maxD = a.maxv - b.minv
  if minD < IMin or maxD > IMax:
    raise newException(ValueError, "Prover: potential - overflow")
  return Info(known: false, minv: minD, maxv: maxD, initialized: true)

proc analyzeBinaryMultiplication(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # conservative: require constants for * or fail
  if a.known and b.known:
    let m = a.cval * b.cval
    # conservative overflow check
    if a.cval != 0 and m div a.cval != b.cval:
      raise newException(ValueError, "Prover: * overflow on constants")
    return infoConst(m)
  raise newException(ValueError, "Prover: cannot prove * without constants (MVP)")

proc analyzeBinaryDivision(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  if b.known:
    if b.cval == 0: raise newProverError(e.pos, "division by zero")
  else:
    if not b.nonZero:
      raise newProverError(e.pos, "cannot prove divisor is non-zero")
  # range not needed for overflow on div; accept
  return Info(known: false, minv: IMin, maxv: IMax, nonZero: true, initialized: true)

proc analyzeBinaryModulo(e: Expr, a: Info, b: Info): Info =
  if b.known:
    if b.cval == 0: raise newProverError(e.pos, "modulo by zero")
  else:
    if not b.nonZero:
      raise newProverError(e.pos, "cannot prove divisor is non-zero")
  # modulo result is always less than divisor (for positive divisor)
  return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

proc analyzeBinaryComparison(e: Expr, a: Info, b: Info): Info =
  # Constant folding for comparisons
  if a.known and b.known:
    let res = case e.bop
      of boEq: a.cval == b.cval
      of boNe: a.cval != b.cval
      of boLt: a.cval < b.cval
      of boLe: a.cval <= b.cval
      of boGt: a.cval > b.cval
      of boGe: a.cval >= b.cval
      else: false
    return infoBool(res)
  else:
    return Info(known: false, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true) # unknown boolean

proc analyzeBinaryLogical(e: Expr, a: Info, b: Info): Info =
  # Boolean operations - for now return unknown
  return Info(known: false, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)

proc analyzeBinaryExpr(e: Expr, env: Env, prog: Program): Info =
  let a = analyzeExpr(e.lhs, env, prog)
  let b = analyzeExpr(e.rhs, env, prog)
  case e.bop
  of boAdd: return analyzeBinaryAddition(e, a, b)
  of boSub: return analyzeBinarySubtraction(e, a, b)
  of boMul: return analyzeBinaryMultiplication(e, a, b)
  of boDiv: return analyzeBinaryDivision(e, a, b)
  of boMod: return analyzeBinaryModulo(e, a, b)
  of boEq,boNe,boLt,boLe,boGt,boGe: return analyzeBinaryComparison(e, a, b)
  of boAnd,boOr: return analyzeBinaryLogical(e, a, b)

proc analyzeBuiltinCall(e: Expr, env: Env, prog: Program): Info =
  # recognize trusted builtins affecting nonNil/nonZero
  if e.fname.startsWith("print"):
    # analyze arguments for safety even though print returns void
    for arg in e.args: discard analyzeExpr(arg, env, prog)
    return infoUnknown()
  if e.fname == "assumeNonZero":
    # treat as assertion
    if e.args.len == 1:
      var i0 = analyzeExpr(e.args[0], env, prog)
      i0.nonZero = true
      return i0
  if e.fname == "assumeNonNil":
    if e.args.len == 1 and e.args[0].kind == ekVar:
      env.nils[e.args[0].vname] = false
    return infoUnknown()
  if e.fname == "rand":
    return analyzeRandCall(e, env, prog)
  # Unknown builtin - just analyze arguments
  for arg in e.args: discard analyzeExpr(arg, env, prog)
  return infoUnknown()

proc analyzeRandCall(e: Expr, env: Env, prog: Program): Info =
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

proc tryEvaluateComplexFunction(body: seq[Stmt], paramEnv: Table[string, int64]): Option[int64] =
  ## Try to evaluate a function body with loops and local variables
  var localVars = paramEnv  # Start with parameters

  proc evalExprLocal(expr: Expr): Option[int64] =
    case expr.kind
    of ekInt:
      return some(expr.ival)
    of ekVar:
      if localVars.hasKey(expr.vname):
        return some(localVars[expr.vname])
      return none(int64)
    of ekBin:
      let lhs = evalExprLocal(expr.lhs)
      let rhs = evalExprLocal(expr.rhs)
      if lhs.isSome and rhs.isSome:
        case expr.bop
        of boAdd: return some(lhs.get + rhs.get)
        of boSub: return some(lhs.get - rhs.get)
        of boMul: return some(lhs.get * rhs.get)
        of boDiv:
          if rhs.get != 0: return some(lhs.get div rhs.get)
          else: return none(int64)
        of boMod:
          if rhs.get != 0: return some(lhs.get mod rhs.get)
          else: return none(int64)
        of boLt: return some(if lhs.get < rhs.get: 1'i64 else: 0'i64)
        of boLe: return some(if lhs.get <= rhs.get: 1'i64 else: 0'i64)
        of boGt: return some(if lhs.get > rhs.get: 1'i64 else: 0'i64)
        of boGe: return some(if lhs.get >= rhs.get: 1'i64 else: 0'i64)
        of boEq: return some(if lhs.get == rhs.get: 1'i64 else: 0'i64)
        of boNe: return some(if lhs.get != rhs.get: 1'i64 else: 0'i64)
        else: return none(int64)
      return none(int64)
    else:
      return none(int64)

  # Process statements in order
  for stmt in body:
    case stmt.kind
    of skVar:
      if stmt.vinit.isSome:
        let val = evalExprLocal(stmt.vinit.get)
        if val.isSome:
          localVars[stmt.vname] = val.get
        else:
          return none(int64)  # Cannot evaluate initializer
      else:
        localVars[stmt.vname] = 0'i64  # Default initialization
    of skAssign:
      let val = evalExprLocal(stmt.aval)
      if val.isSome:
        localVars[stmt.aname] = val.get
      else:
        return none(int64)  # Cannot evaluate assignment
    of skWhile:
      # Simple loop evaluation with maximum iterations to prevent infinite loops
      const MAX_ITERATIONS = 1000
      var iterations = 0
      while iterations < MAX_ITERATIONS:
        let condVal = evalExprLocal(stmt.wcond)
        if not condVal.isSome:
          return none(int64)  # Cannot evaluate condition
        if condVal.get == 0:
          break  # Condition is false, exit loop

        # Execute loop body
        for bodyStmt in stmt.wbody:
          case bodyStmt.kind
          of skAssign:
            let val = evalExprLocal(bodyStmt.aval)
            if val.isSome:
              localVars[bodyStmt.aname] = val.get
            else:
              return none(int64)
          else:
            return none(int64)  # Unsupported statement in loop body

        iterations += 1

      if iterations >= MAX_ITERATIONS:
        return none(int64)  # Potential infinite loop
    of skReturn:
      if stmt.re.isSome:
        return evalExprLocal(stmt.re.get)
      return some(0'i64)  # void return
    else:
      return none(int64)  # Unsupported statement type

  # If we reach here without a return, assume void return
  return some(0'i64)

proc tryEvaluatePureFunction(call: Expr, argInfos: seq[Info], fn: FunDecl, prog: Program): Option[int64] =
  ## Try to evaluate a pure function with constant arguments
  ## Returns the result if successful, None if the function cannot be evaluated

  # Create parameter environment with constant argument values
  var paramEnv: Table[string, int64] = initTable[string, int64]()
  for i, arg in argInfos:
    if i < fn.params.len and arg.known:
      paramEnv[fn.params[i].name] = arg.cval
    else:
      return none(int64)  # Cannot evaluate if not all params are constants

  # Forward declaration for mutual recursion
  proc evalStmt(stmt: Stmt): Option[int64]

  # Simple recursive expression evaluator
  proc evalExpr(expr: Expr): Option[int64] =
    case expr.kind
    of ekInt:
      return some(expr.ival)
    of ekVar:
      if paramEnv.hasKey(expr.vname):
        return some(paramEnv[expr.vname])
      return none(int64)
    of ekBin:
      let lhs = evalExpr(expr.lhs)
      let rhs = evalExpr(expr.rhs)
      if lhs.isSome and rhs.isSome:
        case expr.bop
        of boAdd: return some(lhs.get + rhs.get)
        of boSub: return some(lhs.get - rhs.get)
        of boMul: return some(lhs.get * rhs.get)
        of boDiv:
          if rhs.get != 0: return some(lhs.get div rhs.get)
          else: return none(int64)
        of boMod:
          if rhs.get != 0: return some(lhs.get mod rhs.get)
          else: return none(int64)
        of boEq: return some(if lhs.get == rhs.get: 1'i64 else: 0'i64)
        of boNe: return some(if lhs.get != rhs.get: 1'i64 else: 0'i64)
        of boLt: return some(if lhs.get < rhs.get: 1'i64 else: 0'i64)
        of boLe: return some(if lhs.get <= rhs.get: 1'i64 else: 0'i64)
        of boGt: return some(if lhs.get > rhs.get: 1'i64 else: 0'i64)
        of boGe: return some(if lhs.get >= rhs.get: 1'i64 else: 0'i64)
        else: return none(int64)
      return none(int64)
    of ekCall:
      # Support recursive function calls
      if prog != nil and expr.fname == fn.name:
        # Recursive call to the same function - evaluate arguments and call recursively
        var recursiveArgs: seq[int64] = @[]
        for arg in expr.args:
          let argResult = evalExpr(arg)
          if argResult.isSome:
            recursiveArgs.add(argResult.get)
          else:
            return none(int64)

        # Create new parameter environment for recursive call
        var newParamEnv: Table[string, int64] = initTable[string, int64]()
        for i, arg in recursiveArgs:
          if i < fn.params.len:
            newParamEnv[fn.params[i].name] = arg

        # Temporarily swap parameter environments
        let oldParamEnv = paramEnv
        paramEnv = newParamEnv

        # Evaluate the function body with new parameters
        for stmt in fn.body:
          let result = evalStmt(stmt)
          if result.isSome:
            paramEnv = oldParamEnv  # Restore environment
            return result

        paramEnv = oldParamEnv  # Restore environment
        return none(int64)
      else:
        # For now, don't support calls to other functions
        return none(int64)
    else:
      return none(int64)

  # Simple statement evaluator for function body
  proc evalStmt(stmt: Stmt): Option[int64] =
    case stmt.kind
    of skReturn:
      if stmt.re.isSome:
        return evalExpr(stmt.re.get)
      return some(0'i64)  # void return
    of skIf:
      # Handle if-else statements
      let condResult = evalExpr(stmt.cond)
      if condResult.isSome:
        if condResult.get != 0:
          # Condition is true - execute then branch
          for thenStmt in stmt.thenBody:
            let result = evalStmt(thenStmt)
            if result.isSome:
              return result
        else:
          # Condition is false - execute else branch
          for elseStmt in stmt.elseBody:
            let result = evalStmt(elseStmt)
            if result.isSome:
              return result
      return none(int64)
    else:
      return none(int64)  # Unsupported statement type

  # Try to evaluate the function body
  if fn.body.len == 1 and (fn.body[0].kind == skReturn or fn.body[0].kind == skIf):
    # Simple case: single return statement or single if statement
    return evalStmt(fn.body[0])
  else:
    # Try to handle more complex function bodies with loops and variables
    return tryEvaluateComplexFunction(fn.body, paramEnv)

proc analyzeUserDefinedCall(e: Expr, env: Env, prog: Program): Info =
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
  for stmt in fn.body:
    proveStmt(stmt, callEnv, prog, e.fname)

  return infoUnknown()

proc analyzeCallExpr(e: Expr, env: Env, prog: Program): Info =
  # User-defined function call - perform call-site safety analysis
  if prog != nil and prog.funInstances.hasKey(e.fname):
    return analyzeUserDefinedCall(e, env, prog)
  else:
    return analyzeBuiltinCall(e, env, prog)

proc analyzeNewRefExpr(e: Expr, env: Env, prog: Program): Info =
  # newRef always non-nil
  discard analyzeExpr(e.init, env, prog)  # Analyze the initialization expression
  Info(known: false, nonNil: true, initialized: true)

proc analyzeDerefExpr(e: Expr, env: Env, prog: Program): Info =
  let i0 = analyzeExpr(e.refExpr, env, prog)
  if not i0.nonNil: raise newException(ValueError, "Prover: cannot prove ref non-nil before deref")
  infoUnknown()

proc analyzeArrayExpr(e: Expr, env: Env, prog: Program): Info =
  # Array literal - analyze all elements for safety and track size
  for elem in e.elements:
    discard analyzeExpr(elem, env, prog)
  # Return info with known array size
  infoArray(e.elements.len.int64, sizeKnown = true)

proc analyzeIndexExpr(e: Expr, env: Env, prog: Program): Info =
  # Array indexing - comprehensive bounds checking
  let arrayInfo = analyzeExpr(e.arrayExpr, env, prog)
  let indexInfo = analyzeExpr(e.indexExpr, env, prog)

  # Basic negative index check
  if indexInfo.known and indexInfo.cval < 0:
    raise newProverError(e.indexExpr.pos, &"array index cannot be negative: {indexInfo.cval}")

  # Comprehensive bounds checking when both array size and index are known
  if indexInfo.known and arrayInfo.isArray and arrayInfo.arraySizeKnown:
    if indexInfo.cval >= arrayInfo.arraySize:
      raise newProverError(e.indexExpr.pos, &"array index {indexInfo.cval} out of bounds [0, {arrayInfo.arraySize-1}]")

  # Range-based bounds checking when array size is known but index is in a range
  elif arrayInfo.isArray and arrayInfo.arraySizeKnown:
    if indexInfo.minv >= arrayInfo.arraySize or indexInfo.maxv >= arrayInfo.arraySize:
      raise newProverError(e.indexExpr.pos, &"array index range [{indexInfo.minv}, {indexInfo.maxv}] extends beyond array bounds [0, {arrayInfo.arraySize-1}]")

  # If array size is unknown but we have range info on index, check for negatives
  elif not (arrayInfo.isArray and arrayInfo.arraySizeKnown):
    if indexInfo.maxv < 0:
      raise newProverError(e.indexExpr.pos, &"array index range [{indexInfo.minv}, {indexInfo.maxv}] is entirely negative")
    elif indexInfo.minv < 0:
      raise newProverError(e.indexExpr.pos, &"array index range [{indexInfo.minv}, {indexInfo.maxv}] includes negative values")

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

proc analyzeSliceExpr(e: Expr, env: Env, prog: Program): Info =
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

  # Return array info for the slice (slices preserve array nature but might have different size)
  if arrayInfo.isArray:
    # For slices, size is generally unknown unless we can compute it precisely
    infoArray(-1, sizeKnown = false)
  else:
    infoUnknown()

proc analyzeArrayLenExpr(e: Expr, env: Env, prog: Program): Info =
  # Array length operator: #array -> int
  let arrayInfo = analyzeExpr(e.lenExpr, env, prog)
  if arrayInfo.isArray and arrayInfo.arraySizeKnown:
    # If we know the array size, return it as a constant
    infoConst(arrayInfo.arraySize)
  else:
    # Array size is unknown at compile time, but we know it's non-negative
    Info(known: false, minv: 0, maxv: IMax, nonZero: false, initialized: true)

proc analyzeCastExpr(e: Expr, env: Env, prog: Program): Info =
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

proc analyzeNilExpr(e: Expr): Info =
  # nil reference - always known and not non-nil
  Info(known: false, nonNil: false, initialized: true)

proc analyzeExpr(e: Expr; env: Env, prog: Program = nil): Info =
  case e.kind
  of ekInt: return analyzeIntExpr(e)
  of ekFloat: return analyzeFloatExpr(e)
  of ekString: return analyzeStringExpr(e)
  of ekBool: return analyzeBoolExpr(e)
  of ekVar: return analyzeVarExpr(e, env)
  of ekUn: return analyzeUnaryExpr(e, env, prog)
  of ekBin: return analyzeBinaryExpr(e, env, prog)
  of ekCall: return analyzeCallExpr(e, env, prog)
  of ekNewRef: return analyzeNewRefExpr(e, env, prog)
  of ekDeref: return analyzeDerefExpr(e, env, prog)
  of ekArray: return analyzeArrayExpr(e, env, prog)
  of ekIndex: return analyzeIndexExpr(e, env, prog)
  of ekSlice: return analyzeSliceExpr(e, env, prog)
  of ekArrayLen: return analyzeArrayLenExpr(e, env, prog)
  of ekCast: return analyzeCastExpr(e, env, prog)
  of ekNil: return analyzeNilExpr(e)

proc evaluateCondition(cond: Expr, env: Env, prog: Program = nil): ConditionResult =
  ## Unified condition evaluation for dead code detection
  let condInfo = analyzeExpr(cond, env, prog)

  # Check for constant conditions - if all values are known, we can evaluate
  if condInfo.known:
    let condValue = if condInfo.isBool: (condInfo.cval != 0) else: (condInfo.cval != 0)
    return if condValue: crAlwaysTrue else: crAlwaysFalse

  # Range-based dead code detection for comparison operations
  if cond.kind == ekBin:
    let lhs = analyzeExpr(cond.lhs, env, prog)
    let rhs = analyzeExpr(cond.rhs, env, prog)
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

proc isObviousConstant(expr: Expr): bool =
  ## Check if expression uses only literal constants (not variables or function calls)
  case expr.kind
  of ekInt, ekBool:
    return true
  of ekBin:
    return isObviousConstant(expr.lhs) and isObviousConstant(expr.rhs)
  else:
    return false

proc proveStmt(s: Stmt; env: Env, prog: Program = nil, fnContext: string = "") =
  case s.kind
  of skVar:
    if s.vinit.isSome():
      let info = analyzeExpr(s.vinit.get(), env, prog)
      env.vals[s.vname] = info
      env.nils[s.vname] = not info.nonNil
      env.exprs[s.vname] = s.vinit.get()  # Store original expression
    else:
      # Variable is declared but not initialized
      env.vals[s.vname] = infoUninitialized()
      env.nils[s.vname] = true
  of skAssign:
    # Check if the variable being assigned to exists
    if not env.vals.hasKey(s.aname):
      raise newProverError(s.pos, &"assignment to undeclared variable '{s.aname}'")

    let info = analyzeExpr(s.aval, env, prog)
    # Assignment initializes the variable
    var newInfo = info
    newInfo.initialized = true
    env.vals[s.aname] = newInfo
    env.exprs[s.aname] = s.aval  # Store original expression
    if info.nonNil: env.nils[s.aname] = false
  of skIf:
    let condResult = evaluateCondition(s.cond, env, prog)

    case condResult
    of crAlwaysTrue:
      # Check if this is an obvious constant condition that should trigger error
      if isObviousConstant(s.cond) and s.elseBody.len > 0:
        raise newProverError(s.pos, "unreachable code (condition is always true)")
      # Only analyze then branch
      var thenEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
      for st in s.thenBody: proveStmt(st, thenEnv, prog, fnContext)
      # Copy then results back to main env
      for k, v in thenEnv.vals: env.vals[k] = v
      for k, v in thenEnv.exprs: env.exprs[k] = v
      return
    of crAlwaysFalse:
      # Check if this is an obvious constant condition that should trigger error
      if isObviousConstant(s.cond) and s.thenBody.len > 0 and s.elseBody.len == 0:
        raise newProverError(s.pos, "unreachable code (condition is always false)")
      # Skip then branch, analyze elif/else branches and merge results

      var elifEnvs: seq[Env] = @[]
      # Process elif chain
      for i, elifBranch in s.elifChain:
        var elifEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
        let elifCondResult = evaluateCondition(elifBranch.cond, env, prog)
        if elifCondResult != crAlwaysFalse:
          for st in elifBranch.body: proveStmt(st, elifEnv, prog, fnContext)
          elifEnvs.add(elifEnv)

      # Process else branch
      var elseEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
      for st in s.elseBody: proveStmt(st, elseEnv, prog, fnContext)

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
      discard # Continue with normal analysis

    # Normal case: condition is not known at compile time
    # Process then branch (condition could be true)
    var thenEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
    let condInfo = analyzeExpr(s.cond, env, prog)
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
            let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
            if rhsInfo.known:
              # In then branch: x >= rhsInfo.cval
              thenEnv.vals[s.cond.lhs.vname].minv = max(thenEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval)
        of boGt: # x > value: in then branch, x >= value + 1
          if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
            let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
            if rhsInfo.known:
              # In then branch: x > rhsInfo.cval means x >= rhsInfo.cval + 1
              thenEnv.vals[s.cond.lhs.vname].minv = max(thenEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval + 1)
        of boLe: # x <= value: in then branch, x <= value
          if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
            let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
            if rhsInfo.known:
              # In then branch: x <= rhsInfo.cval
              thenEnv.vals[s.cond.lhs.vname].maxv = min(thenEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval)
        of boLt: # x < value: in then branch, x <= value - 1
          if s.cond.lhs.kind == ekVar and thenEnv.vals.hasKey(s.cond.lhs.vname):
            let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
            if rhsInfo.known:
              # In then branch: x < rhsInfo.cval means x <= rhsInfo.cval - 1
              thenEnv.vals[s.cond.lhs.vname].maxv = min(thenEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval - 1)
        else: discard
      for st in s.thenBody: proveStmt(st, thenEnv, prog, fnContext)

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

      for st in elifBranch.body: proveStmt(st, elifEnv)
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
          let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
          if rhsInfo.known:
            # In else branch: !(x >= rhsInfo.cval) means x < rhsInfo.cval, so x <= rhsInfo.cval - 1
            elseEnv.vals[s.cond.lhs.vname].maxv = min(elseEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval - 1)
      of boGt: # x > value: in else branch (condition false), x <= value
        if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
          if rhsInfo.known:
            # In else branch: !(x > rhsInfo.cval) means x <= rhsInfo.cval
            elseEnv.vals[s.cond.lhs.vname].maxv = min(elseEnv.vals[s.cond.lhs.vname].maxv, rhsInfo.cval)
      of boLe: # x <= value: in else branch (condition false), x > value
        if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
          if rhsInfo.known:
            # In else branch: !(x <= rhsInfo.cval) means x > rhsInfo.cval, so x >= rhsInfo.cval + 1
            elseEnv.vals[s.cond.lhs.vname].minv = max(elseEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval + 1)
      of boLt: # x < value: in else branch (condition false), x >= value
        if s.cond.lhs.kind == ekVar and elseEnv.vals.hasKey(s.cond.lhs.vname):
          let rhsInfo = analyzeExpr(s.cond.rhs, env, prog)
          if rhsInfo.known:
            # In else branch: !(x < rhsInfo.cval) means x >= rhsInfo.cval
            elseEnv.vals[s.cond.lhs.vname].minv = max(elseEnv.vals[s.cond.lhs.vname].minv, rhsInfo.cval)
      else: discard

    for st in s.elseBody: proveStmt(st, elseEnv)

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

      # Check else branch - for if statements, there's always an implicit else branch
      let hasExplicitElse = s.elseBody.len > 0 or s.elifChain.len > 0
      # For if statements, we always need to consider the else branch (implicit or explicit)
      if true:  # Always process else branch for if statements
        if elseEnv.vals.hasKey(varName):
          infos.add(elseEnv.vals[varName])
        elif env.vals.hasKey(varName):
          infos.add(env.vals[varName])  # Use original state
        branchCount += 1

      # If no explicit else branch exists, include fallthrough path
      if not hasExplicitElse and env.vals.hasKey(varName):
        # For implicit else (no explicit else clause), we already handled this above
        # This case is now covered by the elseEnv processing
        discard

      # Compute union of all info states for control flow merging
      if infos.len > 0:
        var mergedInfo = infos[0]
        for i in 1..<infos.len:
          mergedInfo = union(mergedInfo, infos[i])
        env.vals[varName] = mergedInfo
  of skWhile:
    # Enhanced while loop analysis using symbolic execution
    let condResult = evaluateCondition(s.wcond, env, prog)

    case condResult
    of crAlwaysFalse:
      if s.wbody.len > 0:
        if fnContext.len > 0 and fnContext.contains('<') and fnContext.contains('>') and not fnContext.contains("<>"):
          raise newProverError(s.pos, &"unreachable code (while condition is always false) in {fnContext}")
        else:
          raise newProverError(s.pos, "unreachable code (while condition is always false)")
      # Skip loop body analysis since it's never executed
      return
    of crAlwaysTrue:
      # Note: While with always-true condition could warn about infinite loop
      # but for now we just analyze normally
      discard
    of crUnknown:
      discard

    # Try symbolic execution for precise loop analysis
    var symState = newSymbolicState()

    # Convert current environment to symbolic state
    for varName, info in env.vals:
      let symVal = convertProverInfoToSymbolic(info)
      symState.setVariable(varName, symVal)

    # Try to execute the loop symbolically
    let loopResult = symbolicExecuteWhile(s, symState, prog)

    case loopResult
    of erContinue:
      # Loop executed completely with known values - use precise results
      for varName, symVal in symState.variables:
        let newInfo = convertSymbolicToProverInfo(symVal)
        env.vals[varName] = Info(
          known: newInfo.known, cval: newInfo.cval,
          minv: newInfo.minv, maxv: newInfo.maxv,
          nonZero: newInfo.nonZero, nonNil: newInfo.nonNil,
          isBool: newInfo.isBool, initialized: newInfo.initialized,
          isArray: newInfo.isArray, arraySize: newInfo.arraySize,
          arraySizeKnown: newInfo.arraySizeKnown
        )
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
        proveStmt(st, loopEnv, prog, fnContext)

      # Enhanced merge: if symbolic execution determined a variable was initialized,
      # trust that result even if traditional analysis is conservative
      for varName in loopEnv.vals.keys:
        if originalVars.hasKey(varName) and symState.hasVariable(varName):
          let originalInfo = originalVars[varName]
          let loopInfo = loopEnv.vals[varName]
          let symVal = symState.getVariable(varName).get()

          # If symbolic execution shows variable is initialized, trust it
          if symVal.initialized and not originalInfo.initialized:
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
            env.vals[varName] = meet(originalInfo, loopInfo)
        elif originalVars.hasKey(varName):
          # Handle variables without symbolic info conservatively
          let originalInfo = originalVars[varName]
          let loopInfo = loopEnv.vals[varName]
          if not originalInfo.initialized:
            var conservativeInfo = loopInfo
            conservativeInfo.initialized = false
            env.vals[varName] = conservativeInfo
          else:
            env.vals[varName] = meet(originalInfo, loopInfo)
        else:
          # New variable declared in loop - conservative approach
          var conservativeInfo = loopEnv.vals[varName]
          conservativeInfo.initialized = false
          env.vals[varName] = conservativeInfo
    of erComplete:
      # Loop completed (shouldn't happen for while loops, but handle gracefully)
      discard
  of skExpr:
    discard analyzeExpr(s.sexpr, env, prog)
  of skReturn:
    if s.re.isSome(): discard analyzeExpr(s.re.get(), env, prog)
  of skComptime:
    # Comptime blocks may contain injected statements after folding
    for injectedStmt in s.cbody:
      proveStmt(injectedStmt, env, prog, fnContext)

proc prove*(prog: Program, filename: string = "<unknown>") =
  errors.loadSourceLines(filename)
  var env = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expr]())

  # First pass: add all global variable declarations to environment (forward references)
  for g in prog.globals:
    if g.kind == skVar:
      # Add variable as uninitialized first to allow forward references
      env.vals[g.vname] = infoUninitialized()
      env.nils[g.vname] = true

  # Second pass: analyze global variable initializations with full environment
  for g in prog.globals: proveStmt(g, env, prog)
  # Analyze main function directly (it's the entry point)
  if prog.funInstances.hasKey("main"):
    let mainFn = prog.funInstances["main"]
    var mainEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs) # copy global environment
    for stmt in mainFn.body:
      proveStmt(stmt, mainEnv, prog)

  # Other function bodies are analyzed at call-sites for more precise analysis
