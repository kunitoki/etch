# prover.nim
# Safety prover: range/const analysis to ensure:
# - addition/multiplication doesn't overflow int64
# - division has provably non-zero divisor
# - deref on Ref[...] is proven non-nil

import std/[tables, options, strformat, strutils]
import ast, errors

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

type ConditionResult = enum
  crUnknown, crAlwaysTrue, crAlwaysFalse

proc analyzeExpr(e: Expr; env: Env, prog: Program = nil): Info
proc proveStmt(s: Stmt; env: Env, prog: Program = nil, fnContext: string = "")  # forward declaration

proc analyzeExpr(e: Expr; env: Env, prog: Program = nil): Info =
  case e.kind
  of ekInt: return infoConst(e.ival)
  of ekFloat: 
    # For float literals, we can provide a reasonable integer range for cast analysis
    if e.fval >= IMin.float64 and e.fval <= IMax.float64:
      let intApprox = e.fval.int64
      return Info(known: true, cval: intApprox, minv: intApprox, maxv: intApprox, nonZero: intApprox != 0, initialized: true)
    else:
      return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
  of ekString: return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true) # string analysis not needed
  of ekBool: return infoBool(e.bval)
  of ekVar:
    if env.vals.hasKey(e.vname):
      let info = env.vals[e.vname]
      if not info.initialized:
        raise newProverError(e.pos, &"use of uninitialized variable '{e.vname}' - variable may not be initialized in all control flow paths")
      return info
    raise newProverError(e.pos, &"use of undeclared variable '{e.vname}'")
  of ekUn:
    let i0 = analyzeExpr(e.ue, env, prog)
    case e.uop
    of uoNeg:
      if i0.known: return infoConst(-i0.cval)
      return Info(known: false, minv: (if i0.maxv == IMax: IMin else: -i0.maxv),
                  maxv: (if i0.minv == IMin: IMax else: -i0.minv), initialized: true)
    of uoNot:
      return infoBool(false) # boolean domain is tiny; not needed for arithmetic safety
  of ekBin:
    let a = analyzeExpr(e.lhs, env, prog)
    let b = analyzeExpr(e.rhs, env, prog)
    case e.bop
    of boAdd:
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
    of boSub:
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
    of boMul:
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
    of boDiv:
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
    of boMod:
      if b.known:
        if b.cval == 0: raise newProverError(e.pos, "modulo by zero")
      else:
        if not b.nonZero:
          raise newProverError(e.pos, "cannot prove divisor is non-zero")
      # modulo result is always less than divisor (for positive divisor)
      return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
    of boEq,boNe,boLt,boLe,boGt,boGe:
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
    of boAnd,boOr:
      # Boolean operations - for now return unknown
      return Info(known: false, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)
  of ekCall:
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
      # analyze arguments for safety
      for arg in e.args: discard analyzeExpr(arg, env, prog)

      # Track the range of rand(max) or rand(max, min)
      if e.args.len == 1:
        let maxInfo = analyzeExpr(e.args[0], env, prog)
        if maxInfo.known:
          # rand(max) returns 0 to max inclusive
          return Info(known: false, minv: 0, maxv: maxInfo.cval, nonZero: maxInfo.cval > 0, initialized: true)
        else:
          # max is unknown, be conservative
          return Info(known: false, minv: 0, maxv: IMax, nonZero: false, initialized: true)
      elif e.args.len == 2:
        let maxInfo = analyzeExpr(e.args[0], env, prog)
        let minInfo = analyzeExpr(e.args[1], env, prog)
        if maxInfo.known and minInfo.known:
          # Both arguments are constants
          let actualMin = min(minInfo.cval, maxInfo.cval)
          let actualMax = max(minInfo.cval, maxInfo.cval)
          return Info(known: false, minv: actualMin, maxv: actualMax,
                     nonZero: actualMin > 0 or actualMax < 0, initialized: true)
        else:
          # Use range information even when not constant
          let actualMin = min(minInfo.minv, maxInfo.minv)
          let actualMax = max(minInfo.maxv, maxInfo.maxv)
          return Info(known: false, minv: actualMin, maxv: actualMax,
                     nonZero: actualMin > 0 or actualMax < 0, initialized: true)
      else:
        # Invalid rand call, return unknown
        return infoUnknown()
    # User-defined function call - perform call-site safety analysis
    if prog != nil and prog.funInstances.hasKey(e.fname):
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
      var callEnv = Env(vals: env.vals, nils: env.nils)

      # Set up parameter environment with actual call-site information
      for i in 0..<min(argInfos.len, fn.params.len):
        callEnv.vals[fn.params[i].name] = argInfos[i]
        callEnv.nils[fn.params[i].name] = not argInfos[i].nonNil

      # Analyze function body with call-site specific argument information
      # This will catch safety violations like division by zero with actual arguments
      for stmt in fn.body:
        proveStmt(stmt, callEnv, prog, e.fname)

      return infoUnknown()
    else:
      # Unknown function - just analyze arguments
      for arg in e.args: discard analyzeExpr(arg, env, prog)
      return infoUnknown()
  of ekComptime:
    # replaced before prover normally; treat inner
    return analyzeExpr(e.inner, env, prog)
  of ekNewRef:
    return Info(known: false, nonNil: true, initialized: true) # newRef always non-nil
  of ekDeref:
    let i0 = analyzeExpr(e.refExpr, env, prog)
    if not i0.nonNil: raise newException(ValueError, "Prover: cannot prove ref non-nil before deref")
    return infoUnknown()
  of ekArray:
    # Array literal - analyze all elements for safety and track size
    for elem in e.elements:
      discard analyzeExpr(elem, env, prog)
    # Return info with known array size
    return infoArray(e.elements.len.int64, sizeKnown = true)
  of ekIndex:
    # Array indexing - comprehensive bounds checking
    let arrayInfo = analyzeExpr(e.arrayExpr, env, prog)
    let indexInfo = analyzeExpr(e.indexExpr, env, prog)
    
    # Basic negative index check
    if indexInfo.known and indexInfo.cval < 0:
      raise newProverError(e.indexExpr.pos, &"array index cannot be negative: {indexInfo.cval}")
    
    # Comprehensive bounds checking when both array size and index are known
    if arrayInfo.isArray and arrayInfo.arraySizeKnown and indexInfo.known:
      if indexInfo.cval >= arrayInfo.arraySize:
        raise newProverError(e.indexExpr.pos, &"array index {indexInfo.cval} out of bounds [0, {arrayInfo.arraySize-1}]")
    
    # Range-based bounds checking when array size is known but index is in a range
    elif arrayInfo.isArray and arrayInfo.arraySizeKnown:
      # Check if the minimum possible index is out of bounds
      if indexInfo.minv >= arrayInfo.arraySize:
        raise newProverError(e.indexExpr.pos, &"array index range [{indexInfo.minv}, {indexInfo.maxv}] entirely out of bounds [0, {arrayInfo.arraySize-1}]")
      # Check if the maximum possible index could be out of bounds
      elif indexInfo.maxv >= arrayInfo.arraySize:
        # Generate runtime bounds check - this access might be unsafe
        raise newProverError(e.indexExpr.pos, &"array index might be out of bounds: index range [{indexInfo.minv}, {indexInfo.maxv}] extends beyond array bounds [0, {arrayInfo.arraySize-1}]")
    
    # If array size is unknown but we have range info on index, check for negatives
    elif not (arrayInfo.isArray and arrayInfo.arraySizeKnown):
      if indexInfo.maxv < 0:
        raise newProverError(e.indexExpr.pos, &"array index range [{indexInfo.minv}, {indexInfo.maxv}] is entirely negative")
      elif indexInfo.minv < 0:
        raise newProverError(e.indexExpr.pos, &"array index might be negative: index range [{indexInfo.minv}, {indexInfo.maxv}] includes negative values")
    
    return infoUnknown()
  of ekSlice:
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
      return infoArray(-1, sizeKnown = false)
    else:
      return infoUnknown()
  of ekArrayLen:
    # Array length operator: #array -> int
    let arrayInfo = analyzeExpr(e.lenExpr, env, prog)
    if arrayInfo.isArray and arrayInfo.arraySizeKnown:
      # If we know the array size, return it as a constant
      return infoConst(arrayInfo.arraySize)
    else:
      # Array size is unknown at compile time, but we know it's non-negative
      return Info(known: false, minv: 0, maxv: IMax, nonZero: false, initialized: true)
  of ekCast:
    # Explicit cast - analyze the source expression and return appropriate info for target type
    let sourceInfo = analyzeExpr(e.castExpr, env, prog)  # Analyze source for safety
    
    # For known values, we can be more precise about the cast result
    if sourceInfo.known:
      case e.castType.kind:
      of tkInt:
        # Cast to int: truncate float or pass through int
        return infoConst(sourceInfo.cval)  # For simplicity, assume cast preserves value
      of tkFloat:
        # Cast to float: pass through
        return infoConst(sourceInfo.cval)
      of tkString:
        # Cast to string: result is not numeric, return safe default
        return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
      else:
        return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
    else:
      # Unknown source value: be conservative 
      return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)
  of ekNil:
    # nil reference - always known and not non-nil
    return Info(known: false, nonNil: false, initialized: true)

proc evaluateCondition(cond: Expr, env: Env, prog: Program = nil): ConditionResult =
  ## Unified condition evaluation for dead code detection
  let condInfo = analyzeExpr(cond, env, prog)

  # Check for constant conditions
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

proc proveStmt(s: Stmt; env: Env, prog: Program = nil, fnContext: string = "") =
  case s.kind
  of skVar:
    if s.vinit.isSome():
      let info = analyzeExpr(s.vinit.get(), env, prog)
      env.vals[s.vname] = info
      env.nils[s.vname] = not info.nonNil
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
    if info.nonNil: env.nils[s.aname] = false
  of skIf:
    let condResult = evaluateCondition(s.cond, env, prog)

    case condResult
    of crAlwaysTrue:
      if s.elifChain.len > 0 or s.elseBody.len > 0:
        if fnContext.len > 0 and fnContext.contains('<') and fnContext.contains('>') and not fnContext.contains("<>"):
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (condition is always true) in {fnContext}"
        else:
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (condition is always true)"
      # Only analyze then branch
      var thenEnv = Env(vals: env.vals, nils: env.nils)
      for st in s.thenBody: proveStmt(st, thenEnv, prog, fnContext)
      # Copy then results back to main env
      for k, v in thenEnv.vals: env.vals[k] = v
      return
    of crAlwaysFalse:
      if s.thenBody.len > 0:
        if fnContext.len > 0 and fnContext.contains('<') and fnContext.contains('>') and not fnContext.contains("<>"):
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (condition is always false) in {fnContext}"
        else:
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (condition is always false)"
      # Skip then branch, analyze elif/else branches and merge results
      
      var elifEnvs: seq[Env] = @[]
      # Process elif chain
      for i, elifBranch in s.elifChain:
        var elifEnv = Env(vals: env.vals, nils: env.nils)
        let elifCondResult = evaluateCondition(elifBranch.cond, env, prog)
        if elifCondResult != crAlwaysFalse:
          for st in elifBranch.body: proveStmt(st, elifEnv, prog, fnContext)
          elifEnvs.add(elifEnv)
      
      # Process else branch
      var elseEnv = Env(vals: env.vals, nils: env.nils)
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
          
          # Compute meet of all info states
          if infos.len > 0:
            var mergedInfo = infos[0]
            for i in 1..<infos.len:
              mergedInfo = meet(mergedInfo, infos[i])
            env.vals[varName] = mergedInfo
      else:
        # Only else branch executed, copy its results
        for k, v in elseEnv.vals:
          env.vals[k] = v
      return
    of crUnknown:
      discard # Continue with normal analysis

    # Normal case: condition is not known at compile time
    # Process then branch (condition could be true)
    var thenEnv = Env(vals: env.vals, nils: env.nils)
    let condInfo = analyzeExpr(s.cond, env, prog)
    if not (condInfo.known and condInfo.cval == 0):
      # Control flow sensitive analysis: refine environment based on condition
      if s.cond.kind == ekBin:
        case s.cond.bop
        of boNe: # x != 0 means x is nonZero in then branch
          if s.cond.rhs.kind == ekInt and s.cond.rhs.ival == 0 and s.cond.lhs.kind == ekVar:
            if thenEnv.vals.hasKey(s.cond.lhs.vname):
              thenEnv.vals[s.cond.lhs.vname].nonZero = true
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
    var elseEnv = Env(vals: env.vals, nils: env.nils)
    # Control flow sensitive analysis for else (condition is false)
    if s.cond.kind == ekBin:
      case s.cond.bop
      of boEq: # x == 0 means x is nonZero in else branch
        if s.cond.rhs.kind == ekInt and s.cond.rhs.ival == 0 and s.cond.lhs.kind == ekVar:
          if elseEnv.vals.hasKey(s.cond.lhs.vname):
            elseEnv.vals[s.cond.lhs.vname].nonZero = true
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
      
      # Check else branch (if it exists or if there are no elif branches)
      let hasElseBranch = s.elseBody.len > 0 or s.elifChain.len > 0
      if hasElseBranch:
        if elseEnv.vals.hasKey(varName):
          infos.add(elseEnv.vals[varName])
        elif env.vals.hasKey(varName):
          infos.add(env.vals[varName])  # Use original state
        branchCount += 1
      
      # If no else branch exists, the variable might not be initialized in all paths
      if not hasElseBranch and env.vals.hasKey(varName):
        infos.add(env.vals[varName])  # Include original state as potential path
      
      # Compute meet (intersection) of all info states
      if infos.len > 0:
        var mergedInfo = infos[0]
        for i in 1..<infos.len:
          mergedInfo = meet(mergedInfo, infos[i])
        env.vals[varName] = mergedInfo
  of skWhile:
    let condResult = evaluateCondition(s.wcond, env, prog)

    case condResult
    of crAlwaysFalse:
      if s.wbody.len > 0:
        if fnContext.len > 0 and fnContext.contains('<') and fnContext.contains('>') and not fnContext.contains("<>"):
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (while condition is always false) in {fnContext}"
        else:
          echo &"{errors.currentFilename}:{s.pos.line}:{s.pos.col}: warning: unreachable code (while condition is always false)"
      # Skip loop body analysis since it's never executed
      return
    of crAlwaysTrue:
      # Note: While with always-true condition could warn about infinite loop
      # but for now we just analyze normally
      discard
    of crUnknown:
      discard

    # Conservative loop analysis for initialization:
    # Variables initialized only inside the loop body cannot be considered initialized
    # after the loop, because the loop might never execute (condition could be false initially)
    
    # Save original environment state
    var originalVars = initTable[string, Info]()
    for k, v in env.vals:
      originalVars[k] = v
    
    # Create loop body environment
    var loopEnv = Env(vals: env.vals, nils: env.nils)
    
    # Analyze loop body
    for st in s.wbody: 
      proveStmt(st, loopEnv, prog, fnContext)
    
    # Merge loop results conservatively:
    # Only variables that were already initialized before the loop
    # or that maintain their initialization status are considered safe
    for varName in loopEnv.vals.keys:
      if originalVars.hasKey(varName):
        # Variable existed before loop
        let originalInfo = originalVars[varName]
        let loopInfo = loopEnv.vals[varName]
        
        # If variable was uninitialized before loop and only initialized inside,
        # it's still considered uninitialized after loop (loop might not execute)
        if not originalInfo.initialized:
          var conservativeInfo = loopInfo
          conservativeInfo.initialized = false
          env.vals[varName] = conservativeInfo
        else:
          # Variable was already initialized, merge normally
          env.vals[varName] = meet(originalInfo, loopInfo)
      else:
        # New variable declared in loop - it's not guaranteed to be initialized
        # after the loop since loop might not execute
        var conservativeInfo = loopEnv.vals[varName]
        conservativeInfo.initialized = false
        env.vals[varName] = conservativeInfo
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
  var env = Env(vals: initTable[string, Info](), nils: initTable[string, bool]())
  
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
    var mainEnv = Env(vals: env.vals, nils: env.nils) # copy global environment
    for stmt in mainFn.body:
      proveStmt(stmt, mainEnv, prog)

  # Other function bodies are analyzed at call-sites for more precise analysis
