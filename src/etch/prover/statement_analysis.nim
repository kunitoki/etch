# prover/statement_analysis.nim
# Statement analysis and control flow for the safety prover

import std/[strformat, tables, options, strutils]
import ../frontend/ast, ../errors, ../interpreter/serialize
import types, expression_analysis, symbolic_execution

proc verboseProverLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[PROVER] ", msg

proc evaluateCondition*(cond: Expr, env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags()): ConditionResult =
  ## Unified condition evaluation for dead code detection
  let condInfo = analyzeExpr(cond, env, prog, flags)

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

proc isObviousConstant*(expr: Expr): bool =
  ## Check if expression uses only literal constants (not variables or function calls)
  case expr.kind
  of ekInt, ekBool:
    return true
  of ekBin:
    return isObviousConstant(expr.lhs) and isObviousConstant(expr.rhs)
  else:
    return false

proc proveStmt*(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags(), fnContext: string = "")

proc proveVar(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  verboseProverLog(flags, "Declaring variable: " & s.vname)
  if s.vinit.isSome():
    verboseProverLog(flags, "Variable " & s.vname & " has initializer")
    let info = analyzeExpr(s.vinit.get(), env, prog, flags)
    env.vals[s.vname] = info
    env.nils[s.vname] = not info.nonNil
    env.exprs[s.vname] = s.vinit.get()  # Store original expression
    if info.known:
      verboseProverLog(flags, "Variable " & s.vname & " initialized with constant value: " & $info.cval)
    else:
      verboseProverLog(flags, "Variable " & s.vname & " initialized with range [" & $info.minv & ".." & $info.maxv & "]")
  else:
    verboseProverLog(flags, "Variable " & s.vname & " declared without initializer (uninitialized)")
    # Variable is declared but not initialized
    env.vals[s.vname] = infoUninitialized()
    env.nils[s.vname] = true

proc proveAssign(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  verboseProverLog(flags, "Assignment to variable: " & s.aname)
  # Check if the variable being assigned to exists
  if not env.vals.hasKey(s.aname):
    raise newProverError(s.pos, &"assignment to undeclared variable '{s.aname}'")

  let info = analyzeExpr(s.aval, env, prog, flags)
  # Assignment initializes the variable
  var newInfo = info
  newInfo.initialized = true
  env.vals[s.aname] = newInfo
  env.exprs[s.aname] = s.aval  # Store original expression
  if info.nonNil: env.nils[s.aname] = false
  if info.known:
    verboseProverLog(flags, "Variable " & s.aname & " assigned constant value: " & $info.cval)
  else:
    verboseProverLog(flags, "Variable " & s.aname & " assigned range [" & $info.minv & ".." & $info.maxv & "]")

proc proveIf(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  let condResult = evaluateCondition(s.cond, env, prog, flags)
  verboseProverLog(flags, "If condition evaluation result: " & $condResult)

  case condResult
  of crAlwaysTrue:
    verboseProverLog(flags, "Condition is always true - analyzing only then branch")
    # Check if this is an obvious constant condition that should trigger error
    if isObviousConstant(s.cond) and s.elseBody.len > 0:
      raise newProverError(s.pos, "unreachable code (condition is always true)")
    # Only analyze then branch
    var thenEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
    verboseProverLog(flags, "Analyzing " & $s.thenBody.len & " statements in then branch")
    for st in s.thenBody: proveStmt(st, thenEnv, prog, flags, fnContext)
    # Copy then results back to main env
    for k, v in thenEnv.vals: env.vals[k] = v
    for k, v in thenEnv.exprs: env.exprs[k] = v
    verboseProverLog(flags, "Then branch analysis complete")
    return
  of crAlwaysFalse:
    verboseProverLog(flags, "Condition is always false - skipping then branch")
    # Check if this is an obvious constant condition that should trigger error
    if isObviousConstant(s.cond) and s.thenBody.len > 0 and s.elseBody.len == 0:
      raise newProverError(s.pos, "unreachable code (condition is always false)")
    # Skip then branch, analyze elif/else branches and merge results

    var elifEnvs: seq[Env] = @[]
    # Process elif chain
    for i, elifBranch in s.elifChain:
      var elifEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
      let elifCondResult = evaluateCondition(elifBranch.cond, env, prog, flags)
      if elifCondResult != crAlwaysFalse:
        for st in elifBranch.body: proveStmt(st, elifEnv, prog, flags, fnContext)
        elifEnvs.add(elifEnv)

    # Process else branch
    var elseEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs)
    for st in s.elseBody: proveStmt(st, elseEnv, prog, flags, fnContext)

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
    verboseProverLog(flags, "Condition result is unknown at compile time - analyzing all branches")
    discard # Continue with normal analysis

  # Normal case: condition is not known at compile time
  # Process then branch (condition could be true)
  verboseProverLog(flags, "Analyzing control flow with condition refinement")
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
    for st in s.thenBody: proveStmt(st, thenEnv, prog, flags, fnContext)

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

    for st in elifBranch.body: proveStmt(st, elifEnv, prog, flags)
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

  for st in s.elseBody: proveStmt(st, elseEnv, prog, flags)

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

proc proveWhile(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  # Enhanced while loop analysis using symbolic execution
  let condResult = evaluateCondition(s.wcond, env, prog)

  case condResult
  of crAlwaysFalse:
    if s.wbody.len > 0:
      if fnContext.len > 0 and '<' in fnContext and '>' in fnContext and "<>" notin fnContext:
        raise newProverError(s.pos, &"unreachable code (while condition is always false) in {fnContext}")
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
  let loopResult = symbolicExecuteWhile(s, symState, prog)

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
      proveStmt(st, loopEnv, prog, flags, fnContext)

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

proc proveFor(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  # Analyze for loop: for var in start..end or for var in array
  verboseProverLog(flags, "Analyzing for loop variable: " & s.fvar)

  var loopVarInfo: Info
  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayInfo = analyzeExpr(s.farray.get(), env, prog, flags)
    verboseProverLog(flags, "For loop over array with info: " & (if arrayInfo.isArray: "array" else: "unknown"))

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
    let startInfo = analyzeExpr(s.fstart.get(), env, prog, flags)
    let endInfo = analyzeExpr(s.fend.get(), env, prog, flags)

    verboseProverLog(flags, "For loop start range: [" & $startInfo.minv & ".." & $startInfo.maxv & "]")
    verboseProverLog(flags, "For loop end range: [" & $endInfo.minv & ".." & $endInfo.maxv & "]")

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

  verboseProverLog(flags, "Loop variable " & s.fvar & " has range [" & $loopVarInfo.minv & ".." & $loopVarInfo.maxv & "]")

  # Analyze loop body
  for stmt in s.fbody:
    proveStmt(stmt, env, prog, flags, fnContext)

  # Restore old variable state (for loops introduce block scope)
  if oldVarInfo.initialized:
    env.vals[s.fvar] = oldVarInfo
  else:
    env.vals.del(s.fvar)
    env.nils.del(s.fvar)

proc proveBreak(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  # Break statements are valid only inside loops, but this is a parse-time concern
  # For prover purposes, break doesn't change variable states
  verboseProverLog(flags, "Break statement (control flow transfer)")

proc proveExpr(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  discard analyzeExpr(s.sexpr, env, prog)

proc proveReturn(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  if s.re.isSome():
      discard analyzeExpr(s.re.get(), env, prog)

proc proveComptime(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags, fnContext: string) =
  # Comptime blocks may contain injected statements after folding
  for injectedStmt in s.cbody:
    proveStmt(injectedStmt, env, prog, flags, fnContext)

proc proveStmt*(s: Stmt; env: Env, prog: Program = nil, flags: CompilerFlags = CompilerFlags(), fnContext: string = "") =
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

  verboseProverLog(flags, "Analyzing " & stmtKindStr & (if fnContext != "": " in " & fnContext else: ""))

  case s.kind
  of skVar: proveVar(s, env, prog, flags, fnContext)
  of skAssign: proveAssign(s, env, prog, flags, fnContext)
  of skIf: proveIf(s, env, prog, flags, fnContext)
  of skWhile: proveWhile(s, env, prog, flags, fnContext)
  of skFor: proveFor(s, env, prog, flags, fnContext)
  of skBreak: proveBreak(s, env, prog, flags, fnContext)
  of skExpr: proveExpr(s, env, prog, flags, fnContext)
  of skReturn: proveReturn(s, env, prog, flags, fnContext)
  of skComptime: proveComptime(s, env, prog, flags, fnContext)
