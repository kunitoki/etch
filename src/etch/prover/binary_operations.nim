# prover/binary_operations.nim
# Binary operation analysis for the safety prover


import std/strformat
import ../frontend/ast
import ../common/[types, errors]
import types, symbolic_execution


proc analyzeBinaryAddition*(e: Expr, a: Info, b: Info): Info =
  # Handle string concatenation - detect by operand types
  if a.isString and b.isString:
    return symStringConcat(a, b)

  # Handle array concatenation - detect by operand types
  if a.isArray and b.isArray:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      return infoArray(totalSize, sizeKnown = true)
    else:
      return infoArray(-1, sizeKnown = false)

  # Handle string concatenation with type fallback
  if e.typ != nil and e.typ.kind == tkString:
    return symStringConcat(a, b)

  # Handle array concatenation with type fallback
  if e.typ != nil and e.typ.kind == tkArray:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      return infoArray(totalSize, sizeKnown = true)
    else:
      return infoArray(-1, sizeKnown = false)

  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # Integer addition
  if a.known and b.known:
    # Check for overflow BEFORE performing the addition to avoid Nim's OverflowDefect
    if ( (b.cval > 0 and a.cval > IMax - b.cval) or (b.cval < 0 and a.cval < IMin - b.cval) ):
      raise newProverError(e.pos, "addition overflow")
    let s = a.cval + b.cval
    return infoConst(s)

  # Range addition - check for overflow strictly
  var minS, maxS: int64

  # Check for overflow in minimum computation: a.minv + b.minv
  if (b.minv > 0 and a.minv > IMax - b.minv) or (b.minv < 0 and a.minv < IMin - b.minv):
    raise newProverError(e.pos, "addition overflow")
  minS = a.minv + b.minv

  # Check for overflow in maximum computation: a.maxv + b.maxv
  if (b.maxv > 0 and a.maxv > IMax - b.maxv) or (b.maxv < 0 and a.maxv < IMin - b.maxv):
    raise newProverError(e.pos, "addition overflow")
  maxS = a.maxv + b.maxv

  return Info(known: false, minv: minS, maxv: maxS, nonZero: a.nonZero or b.nonZero, initialized: true)


proc analyzeBinarySubtraction*(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # Check constant subtraction
  if a.known and b.known:
    # Check for overflow BEFORE performing the subtraction to avoid Nim's OverflowDefect
    if ( (b.cval < 0 and a.cval > IMax + b.cval) or (b.cval > 0 and a.cval < IMin + b.cval) ):
      raise newProverError(e.pos, "subtraction overflow")
    let d = a.cval - b.cval
    return infoConst(d)

  # Range subtraction - check for overflow strictly
  var minD, maxD: int64

  # Check for underflow in minimum computation: a.minv - b.maxv
  if (b.maxv < 0 and a.minv > IMax + b.maxv) or (b.maxv > 0 and a.minv < IMin + b.maxv):
    raise newProverError(e.pos, "subtraction overflow")
  minD = a.minv - b.maxv

  # Check for overflow in maximum computation: a.maxv - b.minv
  if (b.minv < 0 and a.maxv > IMax + b.minv) or (b.minv > 0 and a.maxv < IMin + b.minv):
    raise newProverError(e.pos, "subtraction overflow")
  maxD = a.maxv - b.minv

  return Info(known: false, minv: minD, maxv: maxD, initialized: true)


proc analyzeBinaryMultiplication*(e: Expr, a: Info, b: Info): Info =
  # Skip overflow checks for float operations
  if e.typ != nil and e.typ.kind == tkFloat:
    return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

  # Handle constant multiplication first
  if a.known and b.known:
    # Check for overflow BEFORE performing the multiplication to avoid Nim's OverflowDefect
    if a.cval != 0 and b.cval != 0:
      let absA = if a.cval == IMin: IMax else: (if a.cval < 0: -a.cval else: a.cval)
      let absB = if b.cval == IMin: IMax else: (if b.cval < 0: -b.cval else: b.cval)
      if absB > 0 and absA > IMax div absB:
        raise newProverError(e.pos, "multiplication overflow")
    let m = a.cval * b.cval
    return infoConst(m)

  # Handle multiplication by zero (always results in zero)
  if (a.known and a.cval == 0) or (b.known and b.cval == 0):
    return infoConst(0)

  # Handle multiplication by one (identity)
  if a.known and a.cval == 1:
    return b
  if b.known and b.cval == 1:
    return a

  # Handle multiplication by -1 (negation)
  if a.known and a.cval == -1:
    return Info(known: b.known, cval: if b.known: -b.cval else: 0, minv: -b.maxv, maxv: -b.minv, nonZero: b.nonZero, initialized: true)
  if b.known and b.cval == -1:
    return Info(known: a.known, cval: if a.known: -a.cval else: 0, minv: -a.maxv, maxv: -a.minv, nonZero: a.nonZero, initialized: true)

  # For small constant ranges, we can compute exact bounds
  if (a.known or (a.minv == a.maxv)) and (b.known or (b.minv == b.maxv)):
    let aVal = if a.known: a.cval else: a.minv
    let bVal = if b.known: b.cval else: b.minv
    let product = aVal * bVal

    # Check for overflow
    if aVal != 0 and product div aVal != bVal:
      raise newProverError(e.pos, "multiplication overflow on small ranges")
    return infoConst(product)

  # General range multiplication with overflow checking
  # For ranges [a.minv, a.maxv] × [b.minv, b.maxv], compute all corner products
  # This handles positive, negative, and mixed-sign ranges correctly

  # Pre-check: ensure we can safely compute all corner products
  let corners = [(a.minv, b.minv), (a.minv, b.maxv), (a.maxv, b.minv), (a.maxv, b.maxv)]

  # Verify each corner product is safe before computing
  for (aVal, bVal) in corners:
    if aVal != 0 and bVal != 0:
      # Check if |aVal * bVal| would overflow: use the fact that |a * b| > IMax iff |a| > IMax / |b|
      # Handle the special case of IMin which cannot be negated without overflow
      let absA = if aVal == IMin: IMax else: (if aVal < 0: -aVal else: aVal)
      let absB = if bVal == IMin: IMax else: (if bVal < 0: -bVal else: bVal)

      # Avoid division by zero and check overflow condition
      # Also protect against Nim integer overflow in our own calculations
      if absB > 0:
        try:
          let maxAllowed = IMax div absB
          if absA > maxAllowed:
            raise newProverError(e.pos, "multiplication range would overflow")
        except:
          # Even our division overflowed, this definitely would overflow
          raise newProverError(e.pos, "multiplication range would overflow")

  # All corner products are safe, compute the actual range
  var products: seq[int64] = @[]
  for (aVal, bVal) in corners:
    products.add(aVal * bVal)

  let minResult = min(products)
  let maxResult = max(products)

  return Info(known: false, minv: minResult, maxv: maxResult, nonZero: a.nonZero or b.nonZero, initialized: true)


proc analyzeBinaryDivision*(e: Expr, a: Info, b: Info, ctx: ProverContext): Info =
  if b.known:
    if b.cval == 0: raise newProverError(e.pos, if ctx.fnContext != "": &"division by zero in {ctx.fnContext}" else: "division by zero")

    # When both operands are constants, compute exact result
    if a.known:
      return infoConst(a.cval div b.cval)

    # When divisor is constant, we can compute better bounds
    if b.cval > 0:
      # Positive divisor: result has same sign as dividend, but smaller magnitude
      let minResult = a.minv div b.cval
      let maxResult = a.maxv div b.cval
      return Info(known: false, minv: minResult, maxv: maxResult, nonZero: a.nonZero, initialized: true)
    else:
      # Negative divisor: result has opposite sign to dividend
      let minResult = a.maxv div b.cval  # Note: order swapped due to negative divisor
      let maxResult = a.minv div b.cval
      return Info(known: false, minv: minResult, maxv: maxResult, nonZero: a.nonZero, initialized: true)
  else:
    # Skip overflow checks for float operations
    if e.typ != nil and e.typ.kind == tkFloat:
      return Info(known: false, minv: IMin, maxv: IMax, nonZero: false, initialized: true)

    if not b.nonZero:
      raise newProverError(e.pos, if ctx.fnContext != "": &"cannot prove divisor is non-zero in {ctx.fnContext}" else: "cannot prove divisor is non-zero")

  # When divisor range is unknown, we can't be precise but result is still non-zero if dividend is non-zero
  return Info(known: false, minv: IMin, maxv: IMax, nonZero: a.nonZero, initialized: true)


proc analyzeBinaryModulo*(e: Expr, a: Info, b: Info, ctx: ProverContext): Info =
  if b.known:
    if b.cval == 0: raise newProverError(e.pos, if ctx.fnContext != "": &"modulo by zero in {ctx.fnContext}" else: "modulo by zero")

    # When divisor is a known constant, we can precisely determine the range
    if b.cval > 0:
      # For positive divisor, result is in range [0, divisor-1]
      return Info(known: false, minv: 0, maxv: b.cval - 1, nonZero: false, initialized: true)
    elif b.cval < 0:
      # For negative divisor, result is in range [divisor+1, 0]
      return Info(known: false, minv: b.cval + 1, maxv: 0, nonZero: false, initialized: true)

  else:
    if not b.nonZero:
      raise newProverError(e.pos, if ctx.fnContext != "": &"cannot prove divisor is non-zero in {ctx.fnContext}" else: "cannot prove divisor is non-zero")

  # When divisor is unknown, we can't determine exact bounds
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
  # Boolean logical operations with constant folding

  # For logical operations, interpret values as booleans:
  # 0 = false, non-zero = true
  let aBool = if a.known: (a.cval != 0) else: false
  let bBool = if b.known: (b.cval != 0) else: false

  case e.bop
  of boAnd:
    # Logical AND: true && true = true, otherwise false
    if a.known and b.known:
      let logicalResult = aBool and bBool
      return infoBool(logicalResult)

    # Short-circuit evaluation opportunities
    if a.known and not aBool:
      # false && x = false (always)
      return infoBool(false)
    if b.known and not bBool:
      # x && false = false (always)
      return infoBool(false)

    # If one operand is known true, result depends on the other
    if a.known and aBool:
      # true && b = b
      return Info(known: b.known, cval: if b.known: (if bBool: 1 else: 0) else: 0, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)
    if b.known and bBool:
      # a && true = a
      return Info(known: a.known, cval: if a.known: (if aBool: 1 else: 0) else: 0, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)

  of boOr:
    # Logical OR: false || false = false, otherwise true
    if a.known and b.known:
      let logicalResult = aBool or bBool
      return infoBool(logicalResult)

    # Short-circuit evaluation opportunities
    if a.known and aBool:
      # true || x = true (always)
      return infoBool(true)
    if b.known and bBool:
      # x || true = true (always)
      return infoBool(true)

    # If one operand is known false, result depends on the other
    if a.known and not aBool:
      # false || b = b
      return Info(known: b.known, cval: if b.known: (if bBool: 1 else: 0) else: 0, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)
    if b.known and not bBool:
      # a || false = a
      return Info(known: a.known, cval: if a.known: (if aBool: 1 else: 0) else: 0, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)

  else:
    discard

  # Default case: unknown boolean result
  return Info(known: false, minv: 0, maxv: 1, nonZero: false, isBool: true, initialized: true)
