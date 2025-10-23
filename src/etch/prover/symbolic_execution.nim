# prover/symbolic_execution.nim
# Integrated symbolic execution for enhanced precision in safety analysis

import std/[tables, options]
import ../common/[constants, errors]
import ../frontend/ast
import types


type
  SymbolicState* = ref object
    variables*: Table[string, Info]  # Use unified Info type
    expressions*: Table[string, Expr]  # Track original expressions for re-evaluation
    iterationCount*: int
    hitRuntimeBoundary*: bool

  ExecutionResult* = enum
    erContinue,      # Continue symbolic execution
    erComplete,      # Execution completed successfully
    erRuntimeHit,    # Hit runtime boundary (unknown values)
    erIterationLimit # Hit iteration limit


# Symbolic execution using unified Info type
proc symConst*(value: int64): Info =
  infoConst(value)  # Use existing function from types.nim


proc symBool*(b: bool): Info =
  infoBool(b)  # Use existing function from types.nim


proc symUnknown*(minVal: int64 = IMin, maxVal: int64 = IMax): Info =
  Info(known: false, cval: 0, minv: minVal, maxv: maxVal, initialized: true)


proc symUninitialized*(): Info =
  infoUninitialized()  # Use existing function from types.nim


proc symArray*(size: int64, sizeKnown: bool = true): Info =
  infoArray(size, sizeKnown)  # Use existing function from types.nim


proc symStringConcat*(a, b: Info): Info =
  ## Symbolically concatenate two strings and track the resulting length
  if a.isString and b.isString:
    # Both are strings - calculate combined length
    if a.arraySizeKnown and b.arraySizeKnown:
      # Both lengths known - result length is sum
      let totalLength = a.arraySize + b.arraySize
      return infoString(totalLength, sizeKnown = true)
    elif a.arraySizeKnown:
      # Only left side length known
      let minLen = a.arraySize + b.minv
      let maxLen = if b.maxv < IMax - a.arraySize: a.arraySize + b.maxv else: IMax
      var res = infoString(-1, sizeKnown = false)
      res.minv = minLen
      res.maxv = maxLen
      return res
    elif b.arraySizeKnown:
      # Only right side length known
      let minLen = a.minv + b.arraySize
      let maxLen = if a.maxv < IMax - b.arraySize: a.maxv + b.arraySize else: IMax
      var res = infoString(-1, sizeKnown = false)
      res.minv = minLen
      res.maxv = maxLen
      return res
    else:
      # Both unknown - add ranges
      let minLen = a.minv + b.minv
      let maxLen = if a.maxv < IMax - b.maxv: a.maxv + b.maxv else: IMax
      var res = infoString(-1, sizeKnown = false)
      res.minv = minLen
      res.maxv = maxLen
      return res
  else:
    # Unknown result
    return infoString(-1, sizeKnown = false)


proc symAdd*(a, b: Info, expr: Expr): Info =
  if a.known and b.known:
    # Check for overflow BEFORE performing the addition
    if (b.cval > 0 and a.cval > IMax - b.cval) or (b.cval < 0 and a.cval < IMin - b.cval):
      raise newProverError(expr.pos, "addition overflow")
    let res = a.cval + b.cval
    return symConst(res)
  else:
    # At least one unknown - compute range with overflow checking
    var minResult = IMin
    var maxResult = IMax

    # Check min overflow
    if not ((b.minv > 0 and a.minv > IMax - b.minv) or (b.minv < 0 and a.minv < IMin - b.minv)):
      minResult = a.minv + b.minv

    # Check max overflow
    if not ((b.maxv > 0 and a.maxv > IMax - b.maxv) or (b.maxv < 0 and a.maxv < IMin - b.maxv)):
      maxResult = a.maxv + b.maxv

    return symUnknown(minResult, maxResult)


proc symSub*(a, b: Info, expr: Expr): Info =
  if a.known and b.known:
    # Check for overflow BEFORE performing the subtraction
    if (b.cval < 0 and a.cval > IMax + b.cval) or (b.cval > 0 and a.cval < IMin + b.cval):
      raise newProverError(expr.pos, "subtraction overflow")
    let res = a.cval - b.cval
    return symConst(res)
  else:
    var minResult = IMin
    var maxResult = IMax

    # Check min overflow: a.minv - b.maxv
    if not ((b.maxv < 0 and a.minv > IMax + b.maxv) or (b.maxv > 0 and a.minv < IMin + b.maxv)):
      minResult = a.minv - b.maxv

    # Check max overflow: a.maxv - b.minv
    if not ((b.minv < 0 and a.maxv > IMax + b.minv) or (b.minv > 0 and a.maxv < IMin + b.minv)):
      maxResult = a.maxv - b.minv

    return symUnknown(minResult, maxResult)


proc symMul*(a, b: Info, expr: Expr): Info =
  if a.known and b.known:
    # Check for overflow BEFORE performing the multiplication
    if a.cval != 0 and b.cval != 0:
      let absA = if a.cval == IMin: IMax else: (if a.cval < 0: -a.cval else: a.cval)
      let absB = if b.cval == IMin: IMax else: (if b.cval < 0: -b.cval else: b.cval)
      if absB > 0 and absA > IMax div absB:
        raise newProverError(expr.pos, "multiplication overflow")
    let res = a.cval * b.cval
    return symConst(res)
  else:
    # Range multiplication - compute all four corner products
    # Result range is: [min(corners), max(corners)]

    proc mulWithOverflowCheck(x, y: int64): tuple[value: int64, overflowed: bool] =
      # Check for multiplication overflow
      if x == 0 or y == 0:
        return (0'i64, false)

      let absX = if x == IMin: IMax else: (if x < 0: -x else: x)
      let absY = if y == IMin: IMax else: (if y < 0: -y else: y)

      if absY > 0 and absX > IMax div absY:
        return (0'i64, true)  # Overflowed

      return (x * y, false)

    var candidates: seq[int64] = @[]

    # Try all four corner combinations
    let (v1, o1) = mulWithOverflowCheck(a.minv, b.minv)
    if not o1:
      candidates.add(v1)
    else:
      # Overflow: determine sign and add appropriate bound
      if (a.minv > 0 and b.minv > 0) or (a.minv < 0 and b.minv < 0):
        candidates.add(IMax)  # Both same sign = positive overflow
      else:
        candidates.add(IMin)  # Different signs = negative overflow

    let (v2, o2) = mulWithOverflowCheck(a.minv, b.maxv)
    if not o2:
      candidates.add(v2)
    else:
      if (a.minv > 0 and b.maxv > 0) or (a.minv < 0 and b.maxv < 0):
        candidates.add(IMax)
      else:
        candidates.add(IMin)

    let (v3, o3) = mulWithOverflowCheck(a.maxv, b.minv)
    if not o3:
      candidates.add(v3)
    else:
      if (a.maxv > 0 and b.minv > 0) or (a.maxv < 0 and b.minv < 0):
        candidates.add(IMax)
      else:
        candidates.add(IMin)

    let (v4, o4) = mulWithOverflowCheck(a.maxv, b.maxv)
    if not o4:
      candidates.add(v4)
    else:
      if (a.maxv > 0 and b.maxv > 0) or (a.maxv < 0 and b.maxv < 0):
        candidates.add(IMax)
      else:
        candidates.add(IMin)

    # Find min and max from candidates
    if candidates.len == 0:
      return symUnknown(IMin, IMax)

    var minResult = candidates[0]
    var maxResult = candidates[0]
    for val in candidates:
      if val < minResult: minResult = val
      if val > maxResult: maxResult = val

    return symUnknown(minResult, maxResult)


proc symDiv*(a, b: Info): Info =
  if a.known and b.known and b.cval != 0:
    return symConst(a.cval div b.cval)
  else:
    return symUnknown()


proc symMod*(a, b: Info): Info =
  if a.known and b.known and b.cval != 0:
    return symConst(a.cval mod b.cval)
  else:
    return symUnknown()


proc symLt*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval < b.cval)
  elif a.maxv < b.minv:
    return symBool(true)   # Always true
  elif a.minv >= b.maxv:
    return symBool(false)  # Always false
  else:
    return symUnknown(0, 1)  # Unknown boolean


proc symLe*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval <= b.cval)
  elif a.maxv <= b.minv:
    return symBool(true)
  elif a.minv > b.maxv:
    return symBool(false)
  else:
    return symUnknown(0, 1)


proc symGt*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval > b.cval)
  elif a.minv > b.maxv:
    return symBool(true)
  elif a.maxv <= b.minv:
    return symBool(false)
  else:
    return symUnknown(0, 1)


proc symGe*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval >= b.cval)
  elif a.minv >= b.maxv:
    return symBool(true)
  elif a.maxv < b.minv:
    return symBool(false)
  else:
    return symUnknown(0, 1)


proc symEq*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval == b.cval)
  elif a.maxv < b.minv or a.minv > b.maxv:
    return symBool(false)  # Ranges don't overlap
  else:
    return symUnknown(0, 1)


proc symNe*(a, b: Info): Info =
  if a.known and b.known:
    return symBool(a.cval != b.cval)
  elif a.maxv < b.minv or a.minv > b.maxv:
    return symBool(true)  # Ranges don't overlap
  else:
    return symUnknown(0, 1)


proc newSymbolicState*(): SymbolicState =
  SymbolicState(
    variables: initTable[string, Info](),
    expressions: initTable[string, Expr](),
    iterationCount: 0,
    hitRuntimeBoundary: false
  )


proc copy*(state: SymbolicState): SymbolicState =
  result = SymbolicState(
    variables: state.variables,
    expressions: state.expressions,
    iterationCount: state.iterationCount,
    hitRuntimeBoundary: state.hitRuntimeBoundary
  )


proc setVariable*(state: SymbolicState, name: string, value: Info, expr: Expr = nil) =
  state.variables[name] = value
  if expr != nil:
    state.expressions[name] = expr


proc getVariable*(state: SymbolicState, name: string): Option[Info] =
  if state.variables.hasKey(name):
    return some(state.variables[name])
  return none(Info)


proc hasVariable*(state: SymbolicState, name: string): bool =
  state.variables.hasKey(name)


proc symbolicEvaluateExpr*(expr: Expr, state: SymbolicState, prog: Program = nil): Info
proc symbolicExecuteStmt*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult


proc symbolicEvaluateExpr*(expr: Expr, state: SymbolicState, prog: Program = nil): Info =
  case expr.kind
  of ekInt:
    return symConst(expr.ival)
  of ekBool:
    return symBool(expr.bval)
  of ekVar:
    let varOpt = state.getVariable(expr.vname)
    if varOpt.isSome:
      return varOpt.get()
    else:
      # Variable not found - mark as runtime boundary
      state.hitRuntimeBoundary = true
      return symUnknown()
  of ekBin:
    let lhs = symbolicEvaluateExpr(expr.lhs, state, prog)
    let rhs = symbolicEvaluateExpr(expr.rhs, state, prog)
    case expr.bop
    of boAdd: return symAdd(lhs, rhs, expr)
    of boSub: return symSub(lhs, rhs, expr)
    of boMul: return symMul(lhs, rhs, expr)
    of boDiv: return symDiv(lhs, rhs)
    of boMod: return symMod(lhs, rhs)
    of boLt: return symLt(lhs, rhs)
    of boLe: return symLe(lhs, rhs)
    of boGt: return symGt(lhs, rhs)
    of boGe: return symGe(lhs, rhs)
    of boEq: return symEq(lhs, rhs)
    of boNe: return symNe(lhs, rhs)
    else:
      state.hitRuntimeBoundary = true
      return symUnknown()
  else:
    # Unsupported expression type - mark as runtime boundary
    state.hitRuntimeBoundary = true
    return symUnknown()


proc symbolicExecuteStmt*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult =
  case stmt.kind
  of skVar:
    if stmt.vinit.isSome:
      let initValue = symbolicEvaluateExpr(stmt.vinit.get, state, prog)
      state.setVariable(stmt.vname, initValue, stmt.vinit.get)
    else:
      state.setVariable(stmt.vname, symUninitialized())
    return erContinue
  of skAssign:
    let assignValue = symbolicEvaluateExpr(stmt.aval, state, prog)
    # Mark as initialized after assignment
    var newValue = assignValue
    newValue.initialized = true
    state.setVariable(stmt.aname, newValue, stmt.aval)
    return erContinue
  of skIf:
    let condValue = symbolicEvaluateExpr(stmt.cond, state, prog)
    if condValue.known:
      if condValue.cval != 0:
        # Execute then branch
        for thenStmt in stmt.thenBody:
          let res = symbolicExecuteStmt(thenStmt, state, prog)
          if res != erContinue:
            return res
      else:
        # Execute else branch
        for elseStmt in stmt.elseBody:
          let res = symbolicExecuteStmt(elseStmt, state, prog)
          if res != erContinue:
            return res
    else:
      # Condition is unknown - can't continue symbolic execution
      state.hitRuntimeBoundary = true
      return erRuntimeHit
    return erContinue
  of skReturn:
    return erComplete
  else:
    # Unsupported statement - mark as runtime boundary
    state.hitRuntimeBoundary = true
    return erRuntimeHit


proc symbolicExecuteWhile*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult =
  var iterations = 0
  while iterations < MAX_LOOP_ITERATIONS:
    # Evaluate condition
    let condValue = symbolicEvaluateExpr(stmt.wcond, state, prog)

    if condValue.known:
      if condValue.cval == 0:
        # Condition is false - exit loop
        return erContinue
      else:
        # Condition is true - execute body
        for bodyStmt in stmt.wbody:
          let res = symbolicExecuteStmt(bodyStmt, state, prog)
          if res != erContinue:
            return res

        iterations += 1
        state.iterationCount = iterations
    else:
      # Condition is unknown - can't continue symbolic execution
      state.hitRuntimeBoundary = true
      return erRuntimeHit

  # Hit iteration limit
  return erIterationLimit


proc executeSymbolically*(statements: seq[Stmt], initialState: SymbolicState = nil, prog: Program = nil): SymbolicState =
  let state = if initialState != nil: initialState else: newSymbolicState()

  for stmt in statements:
    let res = symbolicExecuteStmt(stmt, state, prog)
    case res
    of erContinue:
      continue  # Keep executing
    of erComplete, erRuntimeHit, erIterationLimit:
      break  # Stop execution

  return state
