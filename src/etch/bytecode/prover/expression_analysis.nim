# prover/expression_analysis.nim
# Expression analysis for the safety prover

import std/[strformat, options, tables, strutils]
import ../../common/[constants, logging, errors, types]
import ../frontend/ast
import ./[types, function_evaluation, symbolic_execution, unused]


proc analyzeStatement*(s: Statement; env: var Env, ctx: ProverContext)
proc analyzeExpression*(e: Expression; env: var Env, ctx: ProverContext): Info
proc extractPreconditions*(stmt: Statement, paramNames: seq[string], paramMap: Table[string, int], abstractEnv: var Env, ctx: ProverContext): seq[Constraint]
proc markExpressionUsage(expr: Expression, env: var Env)
proc markStatementUsage(stmt: Statement, env: var Env)
proc registerStatementDecls(stmt: Statement, env: var Env)
proc registerStatementsDecls(stmts: seq[Statement], env: var Env)


proc evaluateCondition*(cond: Expression, env: var Env, ctx: ProverContext): ConditionResult =
  ## Unified condition evaluation for dead code detection
  let condInfo = analyzeExpression(cond, env, ctx)

  # Check for constant conditions - if all values are known, we can evaluate
  if condInfo.known:
    let condValue = if condInfo.isBool: (condInfo.cval != 0) else: (condInfo.cval != 0)
    return if condValue: crAlwaysTrue else: crAlwaysFalse

  # Range-based dead code detection for comparison operations
  if cond.kind == ekBin:
    let lhs = analyzeExpression(cond.lhs, env, ctx)
    let rhs = analyzeExpression(cond.rhs, env, ctx)
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


proc isObviousConstant*(expr: Expression): bool =
  ## Check if expression uses only literal constants (not variables or function calls)
  case expr.kind
  of ekInt, ekBool:
    return true
  of ekBin:
    return isObviousConstant(expr.lhs) and isObviousConstant(expr.rhs)
  else:
    return false


proc propagateUsage(target: var Env, source: Env) =
  ## Merge variable usage information from a temporary environment back into the parent.
  if target.isNil or source.isNil:
    return
  for name, info in source.vals:
    if target.vals.hasKey(name) and info.used:
      var baseInfo = target.vals[name]
      if not baseInfo.used:
        baseInfo.used = true
        target.vals[name] = baseInfo


proc assignRefValue(expr: Expression, valueInfo: Info, env: var Env) =
  ## Store known value information for a reference expression when assigning through deref
  case expr.kind
  of ekVar:
    if env.vals.hasKey(expr.vname):
      var info = env.vals[expr.vname]
      copyRefValue(info.refValue, valueInfo)
      env.vals[expr.vname] = info
  else:
    discard


proc isWeakVariable(env: Env, name: string): bool =
  ## Returns true when the tracked variable has been declared as a weak reference.
  if env.types.hasKey(name):
    let varType = env.types[name]
    return (not varType.isNil) and varType.kind == tkWeak
  return false


proc hasReturn(stmts: seq[Statement]): bool =
  ## Check if a statement block has a return statement
  for stmt in stmts:
    if stmt.kind == skReturn:
      return true
  return false


proc registerStatementDecls(stmt: Statement, env: var Env) =
  ## Record declaration positions for statements analyzed outside the normal analyzeVar path.
  case stmt.kind
  of skVar:
    if not env.declPos.hasKey(stmt.vname):
      env.declPos[stmt.vname] = stmt.pos

  of skIf:
    registerStatementsDecls(stmt.thenBody, env)
    for branch in stmt.elifChain:
      registerStatementsDecls(branch.body, env)
    registerStatementsDecls(stmt.elseBody, env)

  of skWhile:
    registerStatementsDecls(stmt.wbody, env)

  of skFor:
    registerStatementsDecls(stmt.fbody, env)

  of skBlock:
    registerStatementsDecls(stmt.blockBody, env)

  of skComptime:
    registerStatementsDecls(stmt.cbody, env)

  of skDefer:
    registerStatementsDecls(stmt.deferBody, env)

  else:
    discard


proc registerStatementsDecls(stmts: seq[Statement], env: var Env) =
  for stmt in stmts:
    registerStatementDecls(stmt, env)


proc markStatementsUsage(stmts: seq[Statement], env: var Env) =
  ## Mark all variables referenced inside the provided statements as used.
  for stmt in stmts:
    markStatementUsage(stmt, env)


proc markElifChainUsage(chain: seq[tuple[cond: Expression, body: seq[Statement]]], env: var Env) =
  ## Mark variables referenced in elif conditions and bodies as used.
  for branch in chain:
    markExpressionUsage(branch.cond, env)
    markStatementsUsage(branch.body, env)


proc markStatementUsage(stmt: Statement, env: var Env) =
  ## Recursively mark variables that appear in the given statement as used.
  case stmt.kind
  of skVar:
    if stmt.vinit.isSome:
      markExpressionUsage(stmt.vinit.get, env)

  of skAssign:
    markExpressionUsage(stmt.aval, env)

  of skCompoundAssign:
    if env.vals.hasKey(stmt.caname):
      var info = env.vals[stmt.caname]
      if info.initialized:
        info.used = true
        env.vals[stmt.caname] = info
    markExpressionUsage(stmt.crhs, env)

  of skFieldAssign:
    markExpressionUsage(stmt.faTarget, env)
    markExpressionUsage(stmt.faValue, env)

  of skIf:
    markExpressionUsage(stmt.cond, env)
    markStatementsUsage(stmt.thenBody, env)
    markElifChainUsage(stmt.elifChain, env)
    markStatementsUsage(stmt.elseBody, env)

  of skWhile:
    markExpressionUsage(stmt.wcond, env)
    markStatementsUsage(stmt.wbody, env)

  of skFor:
    if stmt.fstart.isSome:
      markExpressionUsage(stmt.fstart.get, env)
    if stmt.fend.isSome:
      markExpressionUsage(stmt.fend.get, env)
    if stmt.farray.isSome:
      markExpressionUsage(stmt.farray.get, env)
    markStatementsUsage(stmt.fbody, env)

  of skExpression:
    markExpressionUsage(stmt.sexpr, env)

  of skReturn:
    if stmt.re.isSome:
      markExpressionUsage(stmt.re.get, env)

  of skComptime:
    markStatementsUsage(stmt.cbody, env)

  of skDiscard:
    for expr in stmt.dexprs:
      markExpressionUsage(expr, env)

  of skDefer:
    markStatementsUsage(stmt.deferBody, env)

  of skBlock:
    markStatementsUsage(stmt.blockBody, env)

  of skTupleUnpack:
    markExpressionUsage(stmt.tupInit, env)

  of skObjectUnpack:
    markExpressionUsage(stmt.objInit, env)

  of skTypeDecl, skImport, skBreak:
    discard


proc markExpressionUsage(expr: Expression, env: var Env) =
  ## Recursively walk the expression tree to mark referenced variables as used.
  if expr.isNil:
    return

  case expr.kind
  of ekBool, ekChar, ekInt, ekFloat, ekString, ekNil, ekOptionNone:
    discard

  of ekVar:
    if env.vals.hasKey(expr.vname):
      var info = env.vals[expr.vname]
      if info.initialized:
        info.used = true
        env.vals[expr.vname] = info

  of ekUn:
    markExpressionUsage(expr.ue, env)

  of ekBin:
    markExpressionUsage(expr.lhs, env)
    markExpressionUsage(expr.rhs, env)

  of ekCall:
    if expr.callIsValue and not expr.callTarget.isNil:
      markExpressionUsage(expr.callTarget, env)
    if env.vals.hasKey(expr.fname):
      var info = env.vals[expr.fname]
      if info.initialized:
        info.used = true
        env.vals[expr.fname] = info
    for arg in expr.args:
      markExpressionUsage(arg, env)

  of ekNewRef:
    if expr.init != nil:
      markExpressionUsage(expr.init, env)

  of ekDeref:
    markExpressionUsage(expr.refExpression, env)

  of ekArray:
    for elem in expr.elements:
      markExpressionUsage(elem, env)

  of ekIndex:
    markExpressionUsage(expr.arrayExpression, env)
    markExpressionUsage(expr.indexExpression, env)

  of ekSlice:
    markExpressionUsage(expr.sliceExpression, env)
    if expr.startExpression.isSome:
      markExpressionUsage(expr.startExpression.get, env)
    if expr.endExpression.isSome:
      markExpressionUsage(expr.endExpression.get, env)

  of ekArrayLen:
    markExpressionUsage(expr.lenExpression, env)

  of ekCast:
    markExpressionUsage(expr.castExpression, env)

  of ekOptionSome:
    markExpressionUsage(expr.someExpression, env)

  of ekResultOk:
    markExpressionUsage(expr.okExpression, env)

  of ekResultErr:
    markExpressionUsage(expr.errExpression, env)

  of ekResultPropagate:
    markExpressionUsage(expr.propagateExpression, env)

  of ekMatch:
    markExpressionUsage(expr.matchExpression, env)
    for matchCase in expr.cases:
      markStatementsUsage(matchCase.body, env)

  of ekObjectLiteral:
    for field in expr.fieldInits:
      markExpressionUsage(field.value, env)

  of ekFieldAccess:
    markExpressionUsage(expr.objectExpression, env)

  of ekNew:
    if expr.initExpression.isSome:
      markExpressionUsage(expr.initExpression.get, env)

  of ekIf:
    markExpressionUsage(expr.ifCond, env)
    markStatementsUsage(expr.ifThen, env)
    markElifChainUsage(expr.ifElifChain, env)
    markStatementsUsage(expr.ifElse, env)

  of ekComptime:
    if expr.comptimeExpression != nil:
      markExpressionUsage(expr.comptimeExpression, env)

  of ekCompiles:
    for stmt in expr.compilesBlock:
      markStatementUsage(stmt, env)

  of ekTuple:
    for elem in expr.tupleElements:
      markExpressionUsage(elem, env)

  of ekYield:
    if expr.yieldValue.isSome:
      markExpressionUsage(expr.yieldValue.get, env)

  of ekResume:
    markExpressionUsage(expr.resumeValue, env)

  of ekSpawn:
    markExpressionUsage(expr.spawnExpression, env)

  of ekSpawnBlock:
    markStatementsUsage(expr.spawnBody, env)

  of ekChannelNew:
    if expr.channelCapacity.isSome:
      markExpressionUsage(expr.channelCapacity.get, env)

  of ekChannelSend:
    markExpressionUsage(expr.sendChannel, env)
    markExpressionUsage(expr.sendValue, env)

  of ekChannelRecv:
    markExpressionUsage(expr.recvChannel, env)

  of ekTypeof:
    markExpressionUsage(expr.typeofExpression, env)

  of ekLambda:
    for captureName in expr.lambdaCaptures:
      if env.vals.hasKey(captureName):
        var info = env.vals[captureName]
        if info.initialized:
          info.used = true
          env.vals[captureName] = info
    for stmt in expr.lambdaBody:
      markStatementUsage(stmt, env)


proc applyConstraintToInfo(info: Info, cond: Expression, baseEnv: var Env, ctx: ProverContext, negate: bool, varName: string): Info =
  ## Apply a constraint to a single Info value and return the refined Info
  ## This is a pure function that doesn't mutate the input
  ## varName is the variable we're refining
  result = info  # Start with a copy

  # Try to extract constraint from the condition
  # Handle cases where variable is on either side of the comparison
  var isLeftSide = (cond.lhs.kind == ekVar and cond.lhs.vname == varName)
  var isRightSide = (cond.rhs.kind == ekVar and cond.rhs.vname == varName)

  if not isLeftSide and not isRightSide:
    # This condition doesn't constrain this variable
    return result

  case cond.bop
  of boNe:
    # Handle x != value or value != x
    let valueExpression = if isLeftSide: cond.rhs else: cond.lhs
    if valueExpression.kind == ekNil:
      # Comparing with nil (for ref/weak types)
      if not negate:
        # x != nil: variable is non-nil
        result.nonNil = true
      else:
        # !(x != nil): x == nil
        result.minv = makeScalar(0'i64)
        result.maxv = makeScalar(0'i64)
        result.known = true
        result.cval = makeScalar(0'i64)
        result.nonNil = false
    elif valueExpression.kind == ekInt and valueExpression.ival == 0:
      if not negate:
        # x != 0: x is nonZero
        result.nonZero = true
      else:
        # !(x != 0): x == 0
        result.minv = makeScalar(0'i64)
        result.maxv = makeScalar(0'i64)
        result.known = true
        result.cval = makeScalar(0'i64)
  of boEq:
    # Handle x == value or value == x
    let valueExpression = if isLeftSide: cond.rhs else: cond.lhs
    if valueExpression.kind == ekNil:
      # Comparing with nil (for ref/weak types)
      if not negate:
        # x == nil: variable is nil
        result.minv = makeScalar(0'i64)
        result.maxv = makeScalar(0'i64)
        result.known = true
        result.cval = makeScalar(0'i64)
        result.nonNil = false
      else:
        # !(x == nil): x != nil, x is non-nil
        result.nonNil = true
    elif valueExpression.kind == ekInt and valueExpression.ival == 0:
      if not negate:
        # x == 0
        result.minv = makeScalar(0'i64)
        result.maxv = makeScalar(0'i64)
        result.known = true
        result.cval = makeScalar(0'i64)
      else:
        # !(x == 0): x != 0, x is nonZero
        result.nonZero = true
    elif valueExpression.kind == ekInt:
      # x == constant
      let constVal = makeScalar(valueExpression.ival)
      if not negate:
        result.minv = constVal
        result.maxv = constVal
        result.known = true
        result.cval = constVal
  of boGe, boGt, boLe, boLt:
    # Handle comparisons: x op value or value op x
    let rhsExpression = if isLeftSide: cond.rhs else: cond.lhs
    let rhsInfo = analyzeExpression(rhsExpression, baseEnv, ctx)

    # We need range information (known value or bounded range)
    if not rhsInfo.known and (rhsInfo.minv == IMin or rhsInfo.maxv == IMax):
      # RHS is completely unbounded, can't refine
      return result

    # Get the effective comparison value
    # For known values, use cval; for ranges, use conservative bounds
    let constraintValue = if rhsInfo.known: rhsInfo.cval else:
      # For inequality constraints with ranges, use conservative bound
      case cond.bop
      of boGe, boGt: rhsInfo.minv  # x >= [a,b] → x >= a (conservative)
      of boLe, boLt: rhsInfo.maxv  # x <= [a,b] → x <= b (conservative)
      else: return result

    # Apply the constraint based on which side the variable is on
    if isLeftSide:
      # Variable on left: x op value
      case cond.bop
      of boGe:
        if not negate:
          # x >= value
          result.minv = max(result.minv, constraintValue)
        else:
          # !(x >= value): x < value, so x <= value - 1
          result.maxv = min(result.maxv, constraintValue - 1)
      of boGt:
        if not negate:
          # x > value: x >= value + 1
          result.minv = max(result.minv, constraintValue + 1)
        else:
          # !(x > value): x <= value
          result.maxv = min(result.maxv, constraintValue)
      of boLe:
        if not negate:
          # x <= value
          result.maxv = min(result.maxv, constraintValue)
        else:
          # !(x <= value): x > value, so x >= value + 1
          result.minv = max(result.minv, constraintValue + 1)
      of boLt:
        if not negate:
          # x < value: x <= value - 1
          result.maxv = min(result.maxv, constraintValue - 1)
        else:
          # !(x < value): x >= value
          result.minv = max(result.minv, constraintValue)
      else: discard
    else:
      # Variable on right: value op x
      # Reverse the comparison: value op x ↔ x op' value
      case cond.bop
      of boGe:
        # value >= x → x <= value
        if not negate:
          result.maxv = min(result.maxv, constraintValue)
        else:
          # !(value >= x): x > value
          result.minv = max(result.minv, constraintValue + 1)
      of boGt:
        # value > x → x < value
        if not negate:
          result.maxv = min(result.maxv, constraintValue - 1)
        else:
          # !(value > x): x >= value
          result.minv = max(result.minv, constraintValue)
      of boLe:
        # value <= x → x >= value
        if not negate:
          result.minv = max(result.minv, constraintValue)
        else:
          # !(value <= x): x < value
          result.maxv = min(result.maxv, constraintValue - 1)
      of boLt:
        # value < x → x > value
        if not negate:
          result.minv = max(result.minv, constraintValue + 1)
        else:
          # !(value < x): x <= value
          result.maxv = min(result.maxv, constraintValue)
      else: discard
  else:
    discard


proc collectVariablesInCondition(cond: Expression): seq[string] =
  ## Recursively collect all variable names mentioned in a condition
  result = @[]
  case cond.kind
  of ekVar:
    if cond.vname notin result:
      result.add(cond.vname)
  of ekBin:
    for v in collectVariablesInCondition(cond.lhs):
      if v notin result:
        result.add(v)
    for v in collectVariablesInCondition(cond.rhs):
      if v notin result:
        result.add(v)
  of ekUn:
    for v in collectVariablesInCondition(cond.ue):
      if v notin result:
        result.add(v)
  of ekArrayLen:
    for v in collectVariablesInCondition(cond.lenExpression):
      if v notin result:
        result.add(v)
  else:
    discard


proc applyConstraints(env: Env, cond: Expression, baseEnv: var Env, ctx: ProverContext, negate: bool = false) =
  ## Apply constraints from a condition expression to an environment
  ## Handles compound conditions (AND/OR) recursively
  ## Modifies env in place for efficiency (env is already a copy from copyEnv)
  if cond.kind != ekBin:
    return

  case cond.bop
  of boAnd:
    # For AND: both sides must be true
    if not negate:
      # In then branch: both sides are true - recursively apply both
      applyConstraints(env, cond.lhs, baseEnv, ctx, negate = false)
      applyConstraints(env, cond.rhs, baseEnv, ctx, negate = false)
    else:
      # In else branch: at least one side is false (De Morgan's law: not(A and B) = not(A) or not(B))
      # We can't make strong assumptions here - be conservative
      discard
  of boOr:
    # For OR: at least one side must be true
    if not negate:
      # In then branch: at least one side is true
      # We need to compute disjunctive intervals: apply each side separately and union
      logProver(ctx.options.verbose, "Applying disjunctive OR constraint")

      # Collect all variables mentioned in the condition
      let variables = collectVariablesInCondition(cond)

      for varName in variables:
        if not env.vals.hasKey(varName):
          continue

        # Create two temp environments for left and right branches
        var leftEnv = copyEnv(env)
        var rightEnv = copyEnv(env)

        # Apply left constraint
        applyConstraints(leftEnv, cond.lhs, baseEnv, ctx, negate = false)
        # Apply right constraint
        applyConstraints(rightEnv, cond.rhs, baseEnv, ctx, negate = false)

        # Get intervals from both branches
        let leftIntervals = leftEnv.vals[varName].getIntervals()
        let rightIntervals = rightEnv.vals[varName].getIntervals()

        # Union the intervals
        let combined = unionIntervals(leftIntervals, rightIntervals)

        # Update the variable with disjunctive intervals
        var updatedInfo = env.vals[varName]
        updatedInfo.setIntervals(combined)
        env.vals[varName] = updatedInfo

        logProver(ctx.options.verbose, &"Variable '{varName}' has disjunctive intervals: {combined.len} intervals")
    else:
      # In else branch: both sides are false (De Morgan's law: not(A or B) = not(A) and not(B))
      applyConstraints(env, cond.lhs, baseEnv, ctx, negate = true)
      applyConstraints(env, cond.rhs, baseEnv, ctx, negate = true)
  of boNe, boEq, boGe, boGt, boLe, boLt:
    # Special case: Handle expr != nil or expr == nil where expr is a complex expression
    # This is needed after inlining where we might have arr[0] != nil (where arr[0] is a ref type)
    if (cond.bop == boNe or cond.bop == boEq):
      # Check if one side is nil and the other is any expression
      var refExpr: Expression = nil
      var isNilComparison = false

      logProver(ctx.options.verbose, &"Checking for ref-nil comparison: lhs.kind={cond.lhs.kind} rhs.kind={cond.rhs.kind}")

      if cond.rhs.kind == ekNil:
        refExpr = cond.lhs
        isNilComparison = true
        logProver(ctx.options.verbose, &"Detected expr != nil (lhs={cond.lhs.kind})")
      elif cond.lhs.kind == ekNil:
        refExpr = cond.rhs
        isNilComparison = true
        logProver(ctx.options.verbose, &"Detected nil != expr (rhs={cond.rhs.kind})")

      # Only track complex expressions (not simple variables, as those are handled elsewhere)
      if isNilComparison and refExpr != nil and refExpr.kind != ekVar:
        # Determine if this means non-nil or nil
        var shouldBeNonNil = false
        if cond.bop == boNe:
          # expr != nil means the reference is non-nil (when not negated)
          shouldBeNonNil = not negate
        else:  # boEq
          # expr == nil means the reference is nil (when not negated), non-nil when negated
          shouldBeNonNil = negate

        # Generate a unique key for this expression to track its nil state
        # We'll use a simple serialization of the expression
        proc serializeExpr(e: Expression): string =
          case e.kind
          of ekVar: return e.vname
          of ekIndex:
            let baseStr = serializeExpr(e.arrayExpression)
            if e.indexExpression.kind == ekInt:
              return baseStr & "[" & $e.indexExpression.ival & "]"
            else:
              return baseStr & "[?]"
          of ekDeref: return "@" & serializeExpr(e.refExpression)
          of ekFieldAccess: return serializeExpr(e.objectExpression) & "." & e.fieldName
          else: return "?"

        let exprKey = serializeExpr(refExpr)
        let nilStatus = if shouldBeNonNil: "non-nil" else: "nil"
        logProver(ctx.options.verbose, &"Expression constraint: {exprKey} is {nilStatus}")

        # Track this constraint in env.nils using the expression key
        # This allows expressions analysis to check if the expression is known to be non-nil
        env.nils[exprKey] = not shouldBeNonNil

    # Apply constraint to all variables mentioned in this condition
    let variables = collectVariablesInCondition(cond)
    logProver(ctx.options.verbose, &"Applying constraint to variables: {variables}, negate={negate}")
    for varName in variables:
      if env.vals.hasKey(varName):
        let oldInfo = env.vals[varName]
        let refinedInfo = applyConstraintToInfo(env.vals[varName], cond, baseEnv, ctx, negate, varName)
        env.vals[varName] = refinedInfo
        # Update nils table based on nonNil flag
        env.nils[varName] = not refinedInfo.nonNil
        logProver(ctx.options.verbose, &"Variable '{varName}': nonNil changed from {oldInfo.nonNil} to {refinedInfo.nonNil}, nils[{varName}] = {env.nils[varName]}")
  else:
    discard


include analysis/arithmetic_expressions
include analysis/types_expressions
include analysis/var_expressions
include analysis/function_expressions
include analysis/ref_expressions
include analysis/cast_expressions
include analysis/match_expressions
include analysis/tuple_expressions
include analysis/array_expressions
include analysis/slice_expressions
include analysis/monad_expressions
include analysis/object_expressions
include analysis/if_expressions
include analysis/unpack_expressions
include analysis/while_expressions
include analysis/for_expressions
include analysis/assign_expressions
include analysis/comptime_expressions
include analysis/controlflow_expressions


proc analyzeExpression(s: Statement; env: var Env, ctx: ProverContext) =
  discard analyzeExpression(s.sexpr, env, ctx)


proc analyzeExpression*(e: Expression; env: var Env, ctx: ProverContext): Info =
  logProver(ctx.options.verbose, "Analyzing " & $e.kind & (if e.kind == ekVar: " '" & e.vname & "'" else: ""))

  case e.kind
  of ekInt: return analyzeIntExpression(e)
  of ekFloat: return analyzeFloatExpression(e)
  of ekString: return analyzeStringExpression(e)
  of ekChar: return analyzeCharExpression(e)
  of ekBool: return analyzeBoolExpression(e)
  of ekTypeof: return analyzeTypeofExpression(e, env, ctx)
  of ekVar: return analyzeVarExpression(e, env, ctx)
  of ekUn: return analyzeUnaryExpression(e, env, ctx)
  of ekBin: return analyzeBinaryExpression(e, env, ctx)
  of ekCall: return analyzeCallExpression(e, env, ctx)
  of ekNewRef: return analyzeNewRefExpression(e, env, ctx)
  of ekDeref: return analyzeDerefExpression(e, env, ctx)
  of ekArray: return analyzeArrayExpression(e, env, ctx)
  of ekIndex: return analyzeIndexExpression(e, env, ctx)
  of ekSlice: return analyzeSliceExpression(e, env, ctx)
  of ekArrayLen: return analyzeArrayLenExpression(e, env, ctx)
  of ekCast: return analyzeCastExpression(e, env, ctx)
  of ekNil: return analyzeNilExpression(e)
  of ekOptionSome: return analyzeOptionSomeExpression(e, env, ctx)
  of ekOptionNone: return analyzeOptionNoneExpression(e)
  of ekResultOk: return analyzeResultOkExpression(e, env, ctx)
  of ekResultErr: return analyzeResultErrExpression(e, env, ctx)
  of ekResultPropagate: return analyzeExpression(e.propagateExpression, env, ctx)
  of ekMatch: return analyzeMatchExpression(e, env, ctx)
  of ekObjectLiteral: return analyzeObjectLiteralExpression(e, env, ctx)
  of ekFieldAccess: return analyzeFieldAccessExpression(e, env, ctx)
  of ekNew: return analyzeNewExpression(e, env, ctx)
  of ekIf: return analyzeIfExpression(e, env, ctx)
  of ekTuple: return analyzeTupleExpression(e, env, ctx)
  of ekComptime: return analyzeExpression(e.comptimeExpression, env, ctx)
  of ekCompiles: return infoRange(0, 1)
  of ekYield:
    # Mark that this function has yielded - after this point, ref parameters are invalidated
    ctx.hasYielded = true
    logProver(ctx.options.verbose, "Encountered yield - ref parameters are now invalidated")
    return Info(known: false, initialized: true)
  of ekResume: return analyzeExpression(e.resumeValue, env, ctx)
  of ekSpawn: return analyzeExpression(e.spawnExpression, env, ctx)
  of ekSpawnBlock: return Info(known: false, initialized: true)
  of ekChannelNew: return Info(known: false, initialized: true)
  of ekChannelSend:
    discard analyzeExpression(e.sendValue, env, ctx)
    return Info(known: false, initialized: true)
  of ekChannelRecv:
    return Info(known: false, initialized: true)
  of ekLambda:
    # Lambda expressions - analyze the body to mark captured variables as used
    # We create a temporary environment for the lambda scope that includes parameters
    var lambdaEnv = env  # Start with outer scope (captures available)

    # Add lambda parameters to the environment (they shadow outer variables)
    for param in e.lambdaParams:
      lambdaEnv.vals[param.name] = Info(known: false, initialized: true, used: false)
      lambdaEnv.nils[param.name] = false

    # Analyze lambda body - this will mark any captured variables as used
    for stmt in e.lambdaBody:
      analyzeStatement(stmt, lambdaEnv, ctx)

    # Copy back the 'used' flags for captured variables from lambdaEnv to env
    for varName in env.vals.keys:
      if lambdaEnv.vals.hasKey(varName):
        var info = env.vals[varName]
        info.used = lambdaEnv.vals[varName].used
        env.vals[varName] = info

    return Info(known: false, initialized: true)


proc analyzeStatement*(s: Statement; env: var Env, ctx: ProverContext) =
  logProver(ctx.options.verbose, "Analyzing " & $s.kind & (if ctx.fnContext != "": " in " & ctx.fnContext else: ""))

  case s.kind
  of skVar: analyzeVar(s, env, ctx)
  of skTupleUnpack: analyzeTupleUnpack(s, env, ctx)
  of skObjectUnpack: analyzeObjectUnpack(s, env, ctx)
  of skAssign: analyzeAssign(s, env, ctx)
  of skCompoundAssign:
    let desugared = desugarCompoundAssign(s)
    analyzeAssign(desugared, env, ctx)
  of skFieldAssign: analyzeFieldAssign(s, env, ctx)
  of skIf: analyzeIf(s, env, ctx)
  of skWhile: analyzeWhile(s, env, ctx)
  of skFor: analyzeFor(s, env, ctx)
  of skBreak: analyzeBreak(s, env, ctx)
  of skExpression: analyzeExpression(s, env, ctx)
  of skReturn: analyzeReturn(s, env, ctx)
  of skComptime: analyzeComptime(s, env, ctx)
  of skDefer:
    # Defer blocks - analyze the deferred statements
    for stmt in s.deferBody:
      analyzeStatement(stmt, env, ctx)
  of skBlock:
    # Unnamed scope blocks - analyze all statements in the block
    for stmt in s.blockBody:
      analyzeStatement(stmt, env, ctx)
  of skDiscard:
    # Discard statements - analyze the expressions but ignore results
    for expr in s.dexprs:
      discard analyzeExpression(expr, env, ctx)
  of skTypeDecl, skImport:
    # Type declarations and import statements don't need proving
    discard
