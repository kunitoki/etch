# prover/types.nim
# Type definitions and basic constructors for the safety prover

import std/[tables]
import ../frontend/ast, ../interpreter/serialize

const IMin* = low(int64)
const IMax* = high(int64)

type
  Info* = object
    # Core value tracking (unified from SymbolicValue)
    known*: bool
    cval*: int64
    minv*, maxv*: int64

    # Safety properties
    nonZero*: bool
    nonNil*: bool
    isBool*: bool
    initialized*: bool

    # Array/String size tracking (strings are array[char])
    isArray*: bool
    isString*: bool
    arraySize*: int64  # -1 if unknown size (for arrays) or length (for strings)
    arraySizeKnown*: bool  # true if size/length is known

type Env* = ref object
  vals*: Table[string, Info]
  nils*: Table[string, bool]
  exprs*: Table[string, Expr]  # Track original expressions for variables

type ConditionResult* = enum
  crUnknown, crAlwaysTrue, crAlwaysFalse

type ProverContext* = ref object
  fnContext*: string  # Current function context for error messages
  flags*: CompilerFlags  # Compiler flags (includes verbose mode)
  prog*: Program  # Program being analyzed (can be nil)

proc newProverContext*(fnContext: string = "", flags: CompilerFlags = CompilerFlags(), prog: Program = nil): ProverContext =
  ProverContext(fnContext: fnContext, flags: flags, prog: prog)

proc infoConst*(v: int64): Info =
  Info(known: true, cval: v, minv: v, maxv: v, nonZero: v != 0, isBool: false, initialized: true)

proc infoBool*(b: bool): Info =
  Info(known: true, cval: (if b: 1 else: 0), minv: 0, maxv: 1, nonZero: b, isBool: true, initialized: true)

proc infoUnknown*(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: true)

proc infoUninitialized*(): Info = Info(known: false, minv: IMin, maxv: IMax, initialized: false)

proc infoArray*(size: int64, sizeKnown: bool = true): Info =
  Info(known: false, minv: IMin, maxv: IMax, initialized: true, isArray: true, arraySize: size, arraySizeKnown: sizeKnown)

proc infoString*(length: int64, sizeKnown: bool = true): Info =
  Info(known: false, minv: IMin, maxv: IMax, initialized: true, isString: true, arraySize: length, arraySizeKnown: sizeKnown)

proc infoRange*(minv, maxv: int64): Info =
  Info(known: false, minv: minv, maxv: maxv, initialized: true, nonZero: minv > 0 or maxv < 0)

proc union*(a, b: Info): Info =
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
  # Array/String info union - be conservative
  result.isArray = a.isArray and b.isArray
  result.isString = a.isString and b.isString
  if result.isArray or result.isString:
    # For union, if sizes/lengths differ, we don't know the size
    result.arraySizeKnown = a.arraySizeKnown and b.arraySizeKnown and a.arraySize == b.arraySize
    result.arraySize = (if result.arraySizeKnown: a.arraySize else: -1)
