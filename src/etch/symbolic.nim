# symbolic.nim
# Symbolic execution engine for constant propagation and program flow analysis
# Tracks known values through program execution until runtime uncertainty

import std/[tables, options]
import ast

const MAX_LOOP_ITERATIONS = 1000  # Prevent infinite symbolic execution

type
  SymbolicValue* = object
    known*: bool
    value*: int64
    minRange*, maxRange*: int64
    initialized*: bool
    # Extension fields for future enhancements
    isBool*: bool
    nonZero*: bool
    nonNil*: bool
    # Array tracking
    isArray*: bool
    arraySize*: int64
    arraySizeKnown*: bool

  SymbolicState* = ref object
    variables*: Table[string, SymbolicValue]
    # Track original expressions for re-evaluation
    expressions*: Table[string, Expr]
    # Execution state
    iterationCount*: int
    hitRuntimeBoundary*: bool

  ExecutionResult* = enum
    erContinue,      # Continue symbolic execution
    erComplete,      # Execution completed successfully
    erRuntimeHit,    # Hit runtime boundary (unknown values)
    erIterationLimit # Hit iteration limit

# Factory functions for SymbolicValue
proc symConst*(value: int64): SymbolicValue =
  SymbolicValue(
    known: true, value: value,
    minRange: value, maxRange: value,
    initialized: true, nonZero: value != 0
  )

proc symBool*(b: bool): SymbolicValue =
  let val = if b: 1'i64 else: 0'i64
  SymbolicValue(
    known: true, value: val,
    minRange: 0, maxRange: 1,
    initialized: true, isBool: true, nonZero: b
  )

proc symUnknown*(minVal: int64 = low(int64), maxVal: int64 = high(int64)): SymbolicValue =
  SymbolicValue(
    known: false, value: 0,
    minRange: minVal, maxRange: maxVal,
    initialized: true
  )

proc symUninitialized*(): SymbolicValue =
  SymbolicValue(
    known: false, value: 0,
    minRange: low(int64), maxRange: high(int64),
    initialized: false
  )

proc symArray*(size: int64, sizeKnown: bool = true): SymbolicValue =
  SymbolicValue(
    known: false, value: 0,
    minRange: low(int64), maxRange: high(int64),
    initialized: true, isArray: true,
    arraySize: size, arraySizeKnown: sizeKnown
  )

# Symbolic value operations
proc symAdd*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    # Both values known - compute exact result
    let res = a.value + b.value
    # Check for overflow
    if (a.value > 0 and b.value > 0 and res < a.value) or
       (a.value < 0 and b.value < 0 and res > a.value):
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    # At least one unknown - compute range
    let minResult = a.minRange + b.minRange
    let maxResult = a.maxRange + b.maxRange
    return symUnknown(minResult, maxResult)

proc symSub*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    let res = a.value - b.value
    # Check for overflow
    if (a.value >= 0 and b.value < 0 and res < a.value) or
       (a.value < 0 and b.value > 0 and res > a.value):
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    let minResult = a.minRange - b.maxRange
    let maxResult = a.maxRange - b.minRange
    return symUnknown(minResult, maxResult)

proc symMul*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    let res = a.value * b.value
    # Check for overflow (simplified)
    if a.value != 0 and res div a.value != b.value:
      return symUnknown()  # Overflow - become unknown
    return symConst(res)
  else:
    # Range multiplication is complex, use conservative approach
    return symUnknown()

proc symDiv*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known and b.value != 0:
    return symConst(a.value div b.value)
  else:
    return symUnknown()

proc symMod*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known and b.value != 0:
    return symConst(a.value mod b.value)
  else:
    return symUnknown()

# Comparison operations
proc symLt*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value < b.value)
  elif a.maxRange < b.minRange:
    return symBool(true)   # Always true
  elif a.minRange >= b.maxRange:
    return symBool(false)  # Always false
  else:
    return symUnknown(0, 1)  # Unknown boolean

proc symLe*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value <= b.value)
  elif a.maxRange <= b.minRange:
    return symBool(true)
  elif a.minRange > b.maxRange:
    return symBool(false)
  else:
    return symUnknown(0, 1)

proc symGt*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value > b.value)
  elif a.minRange > b.maxRange:
    return symBool(true)
  elif a.maxRange <= b.minRange:
    return symBool(false)
  else:
    return symUnknown(0, 1)

proc symGe*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value >= b.value)
  elif a.minRange >= b.maxRange:
    return symBool(true)
  elif a.maxRange < b.minRange:
    return symBool(false)
  else:
    return symUnknown(0, 1)

proc symEq*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value == b.value)
  elif a.maxRange < b.minRange or a.minRange > b.maxRange:
    return symBool(false)  # Ranges don't overlap
  else:
    return symUnknown(0, 1)

proc symNe*(a, b: SymbolicValue): SymbolicValue =
  if a.known and b.known:
    return symBool(a.value != b.value)
  elif a.maxRange < b.minRange or a.minRange > b.maxRange:
    return symBool(true)   # Ranges don't overlap
  else:
    return symUnknown(0, 1)

# Merge operation for control flow joins
proc symMeet*(a, b: SymbolicValue): SymbolicValue =
  # Conservative merge - only keep information that's true in both paths
  result = SymbolicValue()
  result.known = a.known and b.known and a.value == b.value
  result.value = if result.known: a.value else: 0
  result.minRange = max(a.minRange, b.minRange)
  result.maxRange = min(a.maxRange, b.maxRange)
  result.initialized = a.initialized and b.initialized
  result.nonZero = a.nonZero and b.nonZero
  result.nonNil = a.nonNil and b.nonNil
  result.isBool = a.isBool and b.isBool
  # Array info
  result.isArray = a.isArray and b.isArray
  if result.isArray:
    result.arraySizeKnown = a.arraySizeKnown and b.arraySizeKnown and a.arraySize == b.arraySize
    result.arraySize = if result.arraySizeKnown: a.arraySize else: -1

# State management
proc newSymbolicState*(): SymbolicState =
  SymbolicState(
    variables: initTable[string, SymbolicValue](),
    expressions: initTable[string, Expr](),
    iterationCount: 0,
    hitRuntimeBoundary: false
  )

proc copy*(state: SymbolicState): SymbolicState =
  result = SymbolicState(
    variables: state.variables,  # Tables are ref types, this creates a shallow copy
    expressions: state.expressions,
    iterationCount: state.iterationCount,
    hitRuntimeBoundary: state.hitRuntimeBoundary
  )
  # Deep copy the variables table
  result.variables = initTable[string, SymbolicValue]()
  for k, v in state.variables:
    result.variables[k] = v

proc setVariable*(state: SymbolicState, name: string, value: SymbolicValue, expr: Expr = nil) =
  state.variables[name] = value
  if expr != nil:
    state.expressions[name] = expr

proc getVariable*(state: SymbolicState, name: string): Option[SymbolicValue] =
  if state.variables.hasKey(name):
    some(state.variables[name])
  else:
    none(SymbolicValue)

proc hasVariable*(state: SymbolicState, name: string): bool =
  state.variables.hasKey(name)

# Forward declarations
proc symbolicExecuteWhile*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult

# Expression evaluation
proc symbolicEvaluateExpr*(expr: Expr, state: SymbolicState, prog: Program = nil): SymbolicValue =
  case expr.kind
  of ekInt:
    return symConst(expr.ival)
  of ekFloat:
    # Convert float to int for symbolic execution
    if expr.fval >= low(int64).float64 and expr.fval <= high(int64).float64:
      return symConst(expr.fval.int64)
    else:
      return symUnknown()
  of ekBool:
    return symBool(expr.bval)
  of ekString:
    return symUnknown()  # Strings not tracked symbolically
  of ekVar:
    let varOpt = state.getVariable(expr.vname)
    if varOpt.isSome():
      return varOpt.get()
    else:
      # Variable not found - this should be caught by type checking
      return symUninitialized()
  of ekBin:
    let lhs = symbolicEvaluateExpr(expr.lhs, state, prog)
    let rhs = symbolicEvaluateExpr(expr.rhs, state, prog)

    # Check for runtime contamination
    if not lhs.initialized or not rhs.initialized:
      return symUninitialized()

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
    else: return symUnknown()
  of ekUn:
    let operand = symbolicEvaluateExpr(expr.ue, state, prog)
    if not operand.initialized:
      return symUninitialized()

    case expr.uop
    of uoNeg:
      if operand.known:
        return symConst(-operand.value)
      else:
        return symUnknown(-operand.maxRange, -operand.minRange)
    of uoNot:
      if operand.known:
        return symBool(operand.value == 0)
      else:
        return symUnknown(0, 1)
  of ekCall:
    # Handle special functions
    if expr.fname == "rand":
      state.hitRuntimeBoundary = true
      # Rand with range argument
      if expr.args.len == 1:
        let maxVal = symbolicEvaluateExpr(expr.args[0], state, prog)
        if maxVal.known and maxVal.value > 0:
          return symUnknown(0, maxVal.value - 1)
      return symUnknown(0, high(int32))
    else:
      # Other function calls - conservatively unknown
      state.hitRuntimeBoundary = true
      return symUnknown()
  else:
    # Other expression types (arrays, refs, etc.) - not tracked symbolically for now
    return symUnknown()

# Statement execution
proc symbolicExecuteStmt*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult =
  case stmt.kind
  of skVar:
    if stmt.vinit.isSome():
      let value = symbolicEvaluateExpr(stmt.vinit.get(), state, prog)
      state.setVariable(stmt.vname, value, stmt.vinit.get())
    else:
      state.setVariable(stmt.vname, symUninitialized())
    return erContinue

  of skAssign:
    if not state.hasVariable(stmt.aname):
      # This should be caught by type checking, but handle gracefully
      return erRuntimeHit

    let value = symbolicEvaluateExpr(stmt.aval, state, prog)
    # Assignment makes uninitialized variables initialized
    var newValue = value
    newValue.initialized = true
    state.setVariable(stmt.aname, newValue, stmt.aval)
    return erContinue

  of skExpr:
    # Expression statements (like function calls) - evaluate for side effects
    discard symbolicEvaluateExpr(stmt.sexpr, state, prog)
    return erContinue

  of skIf:
    let condition = symbolicEvaluateExpr(stmt.cond, state, prog)

    if condition.known:
      # Condition is known at compile time
      if condition.value != 0:
        # Execute then branch
        for s in stmt.thenBody:
          let res = symbolicExecuteStmt(s, state, prog)
          if res != erContinue:
            return res
      else:
        # Execute else branch if it exists
        for s in stmt.elseBody:
          let res = symbolicExecuteStmt(s, state, prog)
          if res != erContinue:
            return res
    else:
      # Condition unknown - need to merge both paths
      # For now, conservatively merge (this could be enhanced)
      let thenState = state.copy()
      let elseState = state.copy()

      # Execute then branch in copy
      for s in stmt.thenBody:
        discard symbolicExecuteStmt(s, thenState, prog)

      # Execute else branch in copy
      for s in stmt.elseBody:
        discard symbolicExecuteStmt(s, elseState, prog)

      # Merge states conservatively
      for varName in state.variables.keys:
        if thenState.hasVariable(varName) and elseState.hasVariable(varName):
          let thenVal = thenState.getVariable(varName).get()
          let elseVal = elseState.getVariable(varName).get()
          state.setVariable(varName, symMeet(thenVal, elseVal))

      # Mark as hitting runtime boundary if either path did
      if thenState.hitRuntimeBoundary or elseState.hitRuntimeBoundary:
        state.hitRuntimeBoundary = true

    return erContinue

  of skWhile:
    # This is the key enhancement - symbolic execution of loops
    return symbolicExecuteWhile(stmt, state, prog)

  else:
    # Other statement types - treat conservatively
    return erContinue

# Enhanced while loop symbolic execution
proc symbolicExecuteWhile*(stmt: Stmt, state: SymbolicState, prog: Program = nil): ExecutionResult =
  var iterations = 0

  while iterations < MAX_LOOP_ITERATIONS:
    # Evaluate condition with current state
    let condition = symbolicEvaluateExpr(stmt.wcond, state, prog)

    if condition.known:
      if condition.value == 0:
        # Condition is false - exit loop
        return erContinue
      # Condition is true - continue with loop body
    else:
      # Condition is unknown - we can't continue symbolic execution
      # Handle conservatively: variables that might be initialized in loop
      # are considered potentially initialized
      state.hitRuntimeBoundary = true
      return erRuntimeHit

    # Execute loop body
    for s in stmt.wbody:
      let res = symbolicExecuteStmt(s, state, prog)
      if res != erContinue:
        return res

    iterations += 1
    state.iterationCount = iterations

    # Check if we've hit runtime boundary during loop execution
    if state.hitRuntimeBoundary:
      return erRuntimeHit

  # Hit iteration limit
  return erIterationLimit

# Integration helpers for the prover
proc convertSymbolicToProverInfo*(symVal: SymbolicValue): auto =
  # Convert SymbolicValue to prover's Info type structure
  # This returns the same fields that prover's Info type expects
  result = (
    known: symVal.known,
    cval: symVal.value,
    minv: symVal.minRange,
    maxv: symVal.maxRange,
    nonZero: symVal.nonZero,
    nonNil: symVal.nonNil,
    isBool: symVal.isBool,
    initialized: symVal.initialized,
    isArray: symVal.isArray,
    arraySize: symVal.arraySize,
    arraySizeKnown: symVal.arraySizeKnown
  )

proc convertProverInfoToSymbolic*(info: auto): SymbolicValue =
  # Convert prover's Info type to SymbolicValue
  SymbolicValue(
    known: info.known,
    value: info.cval,
    minRange: info.minv,
    maxRange: info.maxv,
    nonZero: info.nonZero,
    nonNil: info.nonNil,
    isBool: info.isBool,
    initialized: info.initialized,
    isArray: info.isArray,
    arraySize: info.arraySize,
    arraySizeKnown: info.arraySizeKnown
  )

# Main entry point for symbolic execution from prover
proc executeSymbolically*(statements: seq[Stmt], initialState: SymbolicState = nil, prog: Program = nil): SymbolicState =
  let state = if initialState != nil: initialState else: newSymbolicState()

  for stmt in statements:
    let res = symbolicExecuteStmt(stmt, state, prog)
    case res
    of erContinue:
      continue
    of erComplete:
      break
    of erRuntimeHit, erIterationLimit:
      # Mark that we hit a boundary but continue with what we have
      state.hitRuntimeBoundary = true
      break

  return state