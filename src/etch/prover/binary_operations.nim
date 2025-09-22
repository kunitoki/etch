# prover/binary_operations.nim
# Binary operation analysis for the safety prover

import ../frontend/ast, ../errors
import types

proc analyzeBinaryAddition*(e: Expr, a: Info, b: Info): Info =
  # Handle string concatenation - detect by operand types
  if a.isString and b.isString:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalLength = a.arraySize + b.arraySize
      return infoString(totalLength, lengthKnown = true)
    else:
      # Unknown length, but still a valid string
      return infoString(-1, lengthKnown = false)

  # Handle array concatenation - detect by operand types
  if a.isArray and b.isArray:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      return infoArray(totalSize, sizeKnown = true)
    else:
      # Unknown size, but still a valid array
      return infoArray(-1, sizeKnown = false)

  # Handle string concatenation with type fallback
  if e.typ != nil and e.typ.kind == tkString:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalLength = a.arraySize + b.arraySize
      return infoString(totalLength, lengthKnown = true)
    else:
      # Unknown length, but still a valid string
      return infoString(-1, lengthKnown = false)

  # Handle array concatenation with type fallback
  if e.typ != nil and e.typ.kind == tkArray:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      return infoArray(totalSize, sizeKnown = true)
    else:
      # Unknown size, but still a valid array
      return infoArray(-1, sizeKnown = false)

  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # Integer addition - original logic
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

proc analyzeBinarySubtraction*(e: Expr, a: Info, b: Info): Info =
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

proc analyzeBinaryMultiplication*(e: Expr, a: Info, b: Info): Info =
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

proc analyzeBinaryDivision*(e: Expr, a: Info, b: Info): Info =
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

proc analyzeBinaryModulo*(e: Expr, a: Info, b: Info): Info =
  if b.known:
    if b.cval == 0: raise newProverError(e.pos, "modulo by zero")
  else:
    if not b.nonZero:
      raise newProverError(e.pos, "cannot prove divisor is non-zero")
  # modulo result is always less than divisor (for positive divisor)
  return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

proc analyzeBinaryComparison*(e: Expr, a: Info, b: Info): Info =
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

proc analyzeBinaryLogical*(e: Expr, a: Info, b: Info): Info =
  # Boolean operations - for now return unknown
  return Info(known: false, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)