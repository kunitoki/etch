# prover/types.nim
# Type definitions and basic constructors for the safety prover

import std/[tables, algorithm]
import ../frontend/ast, ../common/types

const IMin* = low(int64)
const IMax* = high(int64)

type
  Interval* = tuple[minv: int64, maxv: int64]

  Info* = object
    # Core value tracking (unified from SymbolicValue)
    known*: bool
    cval*: int64
    minv*, maxv*: int64  # Overall range (min of all mins, max of all maxs)

    # Disjunctive intervals for OR constraints
    # If intervals.len > 0, the value is in one of these disjoint intervals
    # Otherwise, fall back to [minv, maxv]
    intervals*: seq[Interval]

    # Safety properties
    nonZero*: bool
    nonNil*: bool
    isBool*: bool
    initialized*: bool
    used*: bool  # Track if variable has been used

    # Array/String size tracking (strings are array[char])
    isArray*: bool
    isString*: bool
    arraySize*: int64  # -1 if unknown size (for arrays) or length (for strings)
    arraySizeKnown*: bool  # true if size/length is known

type Env* = ref object
  vals*: Table[string, Info]
  nils*: Table[string, bool]
  exprs*: Table[string, Expr]  # Track original expressions for variables
  declPos*: Table[string, Pos]  # Track declaration positions for error reporting
  unreachable*: bool  # Track if code is unreachable after this point

type ConditionResult* = enum
  crUnknown, crAlwaysTrue, crAlwaysFalse

type
  ConstraintKind* = enum
    ckRange      # minv <= param <= maxv
    ckNonZero    # param != 0
    ckNonNil     # param != nil
    ckPositive   # param > 0
    ckNegative   # param < 0
    ckEquals     # param == value

  Constraint* = object
    kind*: ConstraintKind
    paramIndex*: int        # Which parameter this constrains (-1 for return value)
    paramName*: string      # Parameter name for error messages
    minv*, maxv*: int64     # For ckRange
    value*: int64           # For ckEquals

  FunctionContract* = object
    funcName*: string
    preconditions*: seq[Constraint]   # Requirements on parameters at call site
    postconditions*: seq[Constraint]  # Guarantees about return value and effects
    returnRange*: tuple[minv: int64, maxv: int64]  # Range of possible return values

type ProverContext* = ref object
  fnContext*: string  # Current function context for error messages
  options*: CompilerOptions  # Compiler options (includes verbose mode)
  prog*: Program  # Program being analyzed (can be nil)
  callStack*: seq[string]  # Track function call stack to prevent infinite recursion
  contracts*: Table[string, FunctionContract]  # Cache of inferred function contracts

proc newProverContext*(fnContext: string = "", options: CompilerOptions, prog: Program = nil): ProverContext =
  ProverContext(fnContext: fnContext, options: options, prog: prog, callStack: @[], contracts: initTable[string, FunctionContract]())

proc infoConst*(v: int64): Info =
  Info(known: true, cval: v, minv: v, maxv: v, nonZero: v != 0, isBool: false, initialized: true, used: false)

proc infoBool*(b: bool): Info =
  Info(known: true, cval: (if b: 1 else: 0), minv: 0, maxv: 1, nonZero: b, isBool: true, initialized: true, used: false)

proc infoUnknown*(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: true, used: false)

proc infoUninitialized*(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: false, used: false)

proc infoArray*(size: int64, sizeKnown: bool = true): Info =
  Info(known: false, minv: IMin, maxv: IMax, initialized: true, isArray: true, arraySize: size, arraySizeKnown: sizeKnown, used: false)

proc infoString*(length: int64, sizeKnown: bool = true): Info =
  # For strings, minv and maxv represent the range of possible lengths
  # This helps with overflow checking when accumulating string lengths
  if sizeKnown:
    Info(known: false, minv: length, maxv: length, initialized: true, isString: true, arraySize: length, arraySizeKnown: true, used: false)
  else:
    # Unknown length - default to non-negative range
    Info(known: false, minv: 0, maxv: IMax, initialized: true, isString: true, arraySize: length, arraySizeKnown: false, used: false)

proc infoRange*(minv, maxv: int64): Info =
  Info(known: false, minv: minv, maxv: maxv, initialized: true, nonZero: minv > 0 or maxv < 0, used: false)


proc copyEnv*(env: Env): Env =
  ## Create a deep copy of an environment for independent branch analysis
  ## This ensures modifications to one branch don't affect others
  result = Env()
  # Tables are value types in Nim, so assignment creates a copy
  result.vals = env.vals
  result.nils = env.nils
  result.exprs = env.exprs
  result.declPos = env.declPos
  result.unreachable = env.unreachable


# ============================================================================
# Interval Operations for Disjunctive Constraints
# ============================================================================

proc normalizeIntervals*(intervals: seq[Interval]): seq[Interval] =
  ## Merge overlapping/adjacent intervals and sort
  ## Example: [(0,5), (3,8), (10,15)] → [(0,8), (10,15)]
  if intervals.len == 0:
    return @[]

  # Sort by start point
  var sorted = intervals
  sorted.sort(proc(a, b: Interval): int = cmp(a.minv, b.minv))

  result = @[sorted[0]]
  for i in 1..<sorted.len:
    let last = result[^1]
    let curr = sorted[i]

    # Check if current overlaps or is adjacent to last
    if curr.minv <= last.maxv + 1:
      # Merge: extend the last interval
      result[^1] = (last.minv, max(last.maxv, curr.maxv))
    else:
      # No overlap: add as new interval
      result.add(curr)


proc intersectIntervals*(a, b: seq[Interval]): seq[Interval] =
  ## Compute intersection of two disjunctive interval sets
  ## Example: [(0,5), (10,15)] ∩ [(3,12)] → [(3,5), (10,12)]
  result = @[]
  for ia in a:
    for ib in b:
      let startVal = max(ia.minv, ib.minv)
      let endVal = min(ia.maxv, ib.maxv)
      if startVal <= endVal:
        result.add((startVal, endVal))
  result = normalizeIntervals(result)


proc unionIntervals*(a, b: seq[Interval]): seq[Interval] =
  ## Compute union of two disjunctive interval sets
  ## Example: [(0,5)] ∪ [(10,15)] → [(0,5), (10,15)]
  result = a & b
  result = normalizeIntervals(result)


proc complementInterval*(interval: Interval): seq[Interval] =
  ## Compute complement of a single interval
  ## Example: complement([5, 10]) → [IMin, 4] ∪ [11, IMax]
  result = @[]
  if interval.minv > IMin:
    result.add((IMin, interval.minv - 1))
  if interval.maxv < IMax:
    result.add((interval.maxv + 1, IMax))


proc complementIntervals*(intervals: seq[Interval]): seq[Interval] =
  ## Compute complement of disjunctive intervals
  ## Example: complement([(0,5), (10,15)]) → [IMin,-1] ∪ [6,9] ∪ [16,IMax]
  if intervals.len == 0:
    return @[(IMin, IMax)]

  let normalized = normalizeIntervals(intervals)
  result = @[]

  # Add interval before first one
  if normalized[0].minv > IMin:
    result.add((IMin, normalized[0].minv - 1))

  # Add intervals between consecutive ones
  for i in 0..<normalized.len - 1:
    let gap_start = normalized[i].maxv + 1
    let gap_end = normalized[i + 1].minv - 1
    if gap_start <= gap_end:
      result.add((gap_start, gap_end))

  # Add interval after last one
  if normalized[^1].maxv < IMax:
    result.add((normalized[^1].maxv + 1, IMax))


proc isDisjunctive*(info: Info): bool =
  ## Check if Info uses disjunctive intervals
  info.intervals.len > 0


proc getIntervals*(info: Info): seq[Interval] =
  ## Get the intervals for an Info, handling both modes
  if info.isDisjunctive:
    return info.intervals
  else:
    return @[(info.minv, info.maxv)]


proc setIntervals*(info: var Info, intervals: seq[Interval]) =
  ## Set disjunctive intervals and update minv/maxv to cover all
  info.intervals = normalizeIntervals(intervals)
  if info.intervals.len > 0:
    info.minv = info.intervals[0].minv
    info.maxv = info.intervals[^1].maxv
    for interval in info.intervals:
      info.minv = min(info.minv, interval.minv)
      info.maxv = max(info.maxv, interval.maxv)
  # Update nonZero based on intervals
  if info.intervals.len > 0:
    var allNonZero = true
    for interval in info.intervals:
      if interval.minv <= 0 and interval.maxv >= 0:
        allNonZero = false
        break
    info.nonZero = allNonZero


proc union*(a, b: Info): Info =
  ## Union operation for control flow merging - covers all possible values from both branches
  result = Info()
  result.known = a.known and b.known and a.cval == b.cval
  result.cval = (if result.known: a.cval else: 0)

  # Handle disjunctive intervals
  if isDisjunctive(a) or isDisjunctive(b):
    # Use disjunctive union
    let aIntervals = getIntervals(a)
    let bIntervals = getIntervals(b)
    let merged = unionIntervals(aIntervals, bIntervals)
    setIntervals(result, merged)
  else:
    # Simple interval union
    result.minv = min(a.minv, b.minv)
    result.maxv = max(a.maxv, b.maxv)

  result.nonZero = a.nonZero and b.nonZero  # Only nonZero if both are nonZero
  result.nonNil = a.nonNil and b.nonNil    # Only nonNil if both are nonNil
  result.isBool = a.isBool and b.isBool
  result.initialized = a.initialized and b.initialized
  result.used = a.used or b.used  # Variable is used if it's used in either branch
  # Array/String info union - be conservative
  result.isArray = a.isArray and b.isArray
  result.isString = a.isString and b.isString
  if result.isArray or result.isString:
    # For union, if sizes/lengths differ, we don't know the size
    result.arraySizeKnown = a.arraySizeKnown and b.arraySizeKnown and a.arraySize == b.arraySize
    result.arraySize = (if result.arraySizeKnown: a.arraySize else: -1)


# ============================================================================
# Function Contract Operations
# ============================================================================

proc checkConstraint*(constraint: Constraint, info: Info, paramName: string): bool =
  ## Check if Info satisfies a constraint
  case constraint.kind
  of ckRange:
    return info.minv >= constraint.minv and info.maxv <= constraint.maxv
  of ckNonZero:
    return info.nonZero
  of ckNonNil:
    return info.nonNil
  of ckPositive:
    return info.minv > 0
  of ckNegative:
    return info.maxv < 0
  of ckEquals:
    return info.known and info.cval == constraint.value

proc applyConstraintToInfo*(constraint: Constraint, info: Info): Info =
  ## Apply a constraint to refine an Info value
  result = info
  case constraint.kind
  of ckRange:
    result.minv = max(result.minv, constraint.minv)
    result.maxv = min(result.maxv, constraint.maxv)
    if result.minv == result.maxv:
      result.known = true
      result.cval = result.minv
  of ckNonZero:
    result.nonZero = true
    # If we know it's nonzero and range is [-inf, inf], we can't narrow much
    # But if range includes 0, we could split into disjunctive intervals
  of ckNonNil:
    result.nonNil = true
  of ckPositive:
    result.minv = max(result.minv, 1)
  of ckNegative:
    result.maxv = min(result.maxv, -1)
  of ckEquals:
    result.known = true
    result.cval = constraint.value
    result.minv = constraint.value
    result.maxv = constraint.value

proc inferConstraintFromInfo*(info: Info, paramIndex: int, paramName: string): seq[Constraint] =
  ## Infer constraints from an Info value
  result = @[]

  # Infer range constraint if bounded
  if info.minv > IMin or info.maxv < IMax:
    result.add(Constraint(
      kind: ckRange,
      paramIndex: paramIndex,
      paramName: paramName,
      minv: info.minv,
      maxv: info.maxv
    ))

  # Infer nonZero constraint
  if info.nonZero:
    result.add(Constraint(
      kind: ckNonZero,
      paramIndex: paramIndex,
      paramName: paramName
    ))

  # Infer nonNil constraint
  if info.nonNil:
    result.add(Constraint(
      kind: ckNonNil,
      paramIndex: paramIndex,
      paramName: paramName
    ))

  # Infer positive constraint
  if info.minv > 0:
    result.add(Constraint(
      kind: ckPositive,
      paramIndex: paramIndex,
      paramName: paramName
    ))

  # Infer negative constraint
  if info.maxv < 0:
    result.add(Constraint(
      kind: ckNegative,
      paramIndex: paramIndex,
      paramName: paramName
    ))

  # Infer equals constraint
  if info.known:
    result.add(Constraint(
      kind: ckEquals,
      paramIndex: paramIndex,
      paramName: paramName,
      value: info.cval
    ))
