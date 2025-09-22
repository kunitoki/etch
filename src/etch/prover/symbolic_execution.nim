# prover/symbolic_execution.nim
# Integrated symbolic execution for enhanced precision in safety analysis

import std/[tables, options]
import ../frontend/ast
import types

const MAX_LOOP_ITERATIONS* = 1000  # Prevent infinite symbolic execution

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

# Symbolic value operations on Info type
proc symAdd*(a, b: Info): Info =
  if a.known and b.known:
    let res = a.cval + b.cval
    # Check for overflow
    if (a.cval > 0 and b.cval > 0 and res < a.cval) or
       (a.cval < 0 and b.cval < 0 and res > a.cval):
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    # At least one unknown - compute range
    let minResult = a.minv + b.minv
    let maxResult = a.maxv + b.maxv
    return symUnknown(minResult, maxResult)

proc symSub*(a, b: Info): Info =
  if a.known and b.known:
    let res = a.cval - b.cval
    # Check for overflow
    if (a.cval >= 0 and b.cval < 0 and res < a.cval) or
       (a.cval < 0 and b.cval > 0 and res > a.cval):
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    let minResult = a.minv - b.maxv
    let maxResult = a.maxv - b.minv
    return symUnknown(minResult, maxResult)

proc symMul*(a, b: Info): Info =
  if a.known and b.known:
    let res = a.cval * b.cval
    # Check for overflow (simplified)
    if a.cval != 0 and res div a.cval != b.cval:
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    # Range multiplication is complex, use conservative approach
    return symUnknown()

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

# Comparison operations
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

# Meet operation for control flow merging (use existing meet from types.nim)
proc symMeet*(a, b: Info): Info =
  meet(a, b)  # Use the existing meet operation from types.nim

# SymbolicState operations
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

# No conversion functions needed - using unified Info type

# Forward declarations
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
    of boAdd: return symAdd(lhs, rhs)
    of boSub: return symSub(lhs, rhs)
    of boMul: return symMul(lhs, rhs)
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