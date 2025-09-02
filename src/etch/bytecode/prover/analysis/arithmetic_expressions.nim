
proc analyzeBinaryAddition*(e: Expression, a: Info, b: Info): Info =
  # Handle string concatenation - detect by operand types
  if a.isString and b.isString:
    return symStringConcat(a, b)

  # Handle array concatenation - detect by operand types
  if a.isArray and b.isArray:
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      var concatInfo = infoArray(totalSize, sizeKnown = true)
      # Preserve element ranges if both arrays have range information
      if a.initialized and b.initialized and
         a.minv != int64.low and a.maxv != int64.high and
         b.minv != int64.low and b.maxv != int64.high:
        concatInfo.minv = min(a.minv, b.minv)
        concatInfo.maxv = max(a.maxv, b.maxv)
        concatInfo.initialized = true
      return concatInfo
    else:
      return infoArray(-1, sizeKnown = false)

  # Handle string concatenation with type fallback
  if e.typ != nil and e.typ.kind == tkString:
    return symStringConcat(a, b)

  # Handle array/tuple concatenation with type fallback
  if e.typ != nil and (e.typ.kind == tkArray or e.typ.kind == tkTuple):
    if a.arraySizeKnown and b.arraySizeKnown:
      let totalSize = a.arraySize + b.arraySize
      var concatInfo = infoArray(totalSize, sizeKnown = true)
      # Preserve element ranges if both arrays have range information
      if a.initialized and b.initialized and
         a.minv != int64.low and a.maxv != int64.high and
         b.minv != int64.low and b.maxv != int64.high:
        concatInfo.minv = min(a.minv, b.minv)
        concatInfo.maxv = max(a.maxv, b.maxv)
        concatInfo.initialized = true
      return concatInfo
    else:
      return infoArray(-1, sizeKnown = false)

  let wantsFloat = (e.typ != nil and e.typ.kind == tkFloat) or infoHasFloat(a) or infoHasFloat(b)
  if wantsFloat:
    if a.known and b.known:
      return infoConst(a.cval + b.cval)
    var res = infoUnknown()
    res.minv = a.minv + b.minv
    res.maxv = a.maxv + b.maxv
    res.nonZero = res.minv > 0 or res.maxv < 0
    return res

  # Integer addition
  if a.known and b.known:
    # Check for overflow BEFORE performing the addition to avoid Nim's OverflowDefect
    let aVal = toInt(a.cval)
    let bVal = toInt(b.cval)
    if ((bVal > 0 and aVal > IMax - bVal) or (bVal < 0 and aVal < IMin - bVal)):
      raise newProveError(e.pos, "addition overflow")
    let s = aVal + bVal
    return infoConst(s)

  # Range addition - check for overflow strictly
  let aMin = toInt(a.minv)
  let aMax = toInt(a.maxv)
  let bMin = toInt(b.minv)
  let bMax = toInt(b.maxv)
  var minS, maxS: int64

  # Check for overflow in minimum computation: a.minv + b.minv
  if (bMin > 0 and aMin > IMax - bMin) or (bMin < 0 and aMin < IMin - bMin):
    raise newProveError(e.pos, "addition overflow")
  minS = aMin + bMin

  # Check for overflow in maximum computation: a.maxv + b.maxv
  if (bMax > 0 and aMax > IMax - bMax) or (bMax < 0 and aMax < IMin - bMax):
    raise newProveError(e.pos, "addition overflow")
  maxS = aMax + bMax

  var res = symUnknown(makeScalar(minS), makeScalar(maxS))
  res.nonZero = a.nonZero or b.nonZero
  return res


proc analyzeBinarySubtraction*(e: Expression, a: Info, b: Info): Info =
  let wantsFloat = (e.typ != nil and e.typ.kind == tkFloat) or infoHasFloat(a) or infoHasFloat(b)
  if wantsFloat:
    if a.known and b.known:
      return infoConst(a.cval - b.cval)
    var res = infoUnknown()
    res.minv = a.minv - b.maxv
    res.maxv = a.maxv - b.minv
    res.nonZero = res.minv > 0 or res.maxv < 0
    return res

  # Check constant subtraction
  if a.known and b.known:
    # Check for overflow BEFORE performing the subtraction to avoid Nim's OverflowDefect
    let aVal = toInt(a.cval)
    let bVal = toInt(b.cval)
    if ((bVal < 0 and aVal > IMax + bVal) or (bVal > 0 and aVal < IMin + bVal)):
      raise newProveError(e.pos, "subtraction overflow")
    let d = aVal - bVal
    return infoConst(d)

  # Range subtraction - check for overflow strictly
  let aMin = toInt(a.minv)
  let aMax = toInt(a.maxv)
  let bMin = toInt(b.minv)
  let bMax = toInt(b.maxv)
  var minD, maxD: int64

  # Check for underflow in minimum computation: a.minv - b.maxv
  if (bMax < 0 and aMin > IMax + bMax) or (bMax > 0 and aMin < IMin + bMax):
    raise newProveError(e.pos, "subtraction overflow")
  minD = aMin - bMax

  # Check for overflow in maximum computation: a.maxv - b.minv
  if (bMin < 0 and aMax > IMax + bMin) or (bMin > 0 and aMax < IMin + bMin):
    raise newProveError(e.pos, "subtraction overflow")
  maxD = aMax - bMin

  var res = symUnknown(makeScalar(minD), makeScalar(maxD))
  return res


proc analyzeBinaryMultiplication*(e: Expression, a: Info, b: Info): Info =
  let wantsFloat = (e.typ != nil and e.typ.kind == tkFloat) or infoHasFloat(a) or infoHasFloat(b)
  if wantsFloat:
    if a.known and b.known:
      return infoConst(a.cval * b.cval)
    var corners = @[a.minv * b.minv, a.minv * b.maxv,
                    a.maxv * b.minv, a.maxv * b.maxv]
    var minVal = corners[0]
    var maxVal = corners[0]
    for val in corners:
      if val < minVal: minVal = val
      if val > maxVal: maxVal = val
    var res = infoUnknown()
    res.minv = minVal
    res.maxv = maxVal
    res.nonZero = res.minv > 0 or res.maxv < 0
    return res

  # Handle constant multiplication first
  if a.known and b.known:
    # Check for overflow BEFORE performing the multiplication to avoid Nim's OverflowDefect
    let aVal = toInt(a.cval)
    let bVal = toInt(b.cval)
    if aVal != 0 and bVal != 0:
      let absA = if aVal == IMin: IMax else: (if aVal < 0: -aVal else: aVal)
      let absB = if bVal == IMin: IMax else: (if bVal < 0: -bVal else: bVal)
      if absB > 0 and absA > IMax div absB:
        raise newProveError(e.pos, "multiplication overflow")
    let m = aVal * bVal
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
    return Info(known: b.known,
                cval: if b.known: -b.cval else: makeScalar(0'i64),
                minv: -b.maxv,
                maxv: -b.minv,
                nonZero: b.nonZero,
                initialized: true)
  if b.known and b.cval == -1:
    return Info(known: a.known,
                cval: if a.known: -a.cval else: makeScalar(0'i64),
                minv: -a.maxv,
                maxv: -a.minv,
                nonZero: a.nonZero,
                initialized: true)

  # For small constant ranges, we can compute exact bounds
  if (a.known or (a.minv == a.maxv)) and (b.known or (b.minv == b.maxv)):
    let aVal = if a.known: toInt(a.cval) else: toInt(a.minv)
    let bVal = if b.known: toInt(b.cval) else: toInt(b.minv)
    let product = aVal * bVal

    # Check for overflow
    if aVal != 0 and product div aVal != bVal:
      raise newProveError(e.pos, "multiplication overflow on small ranges")
    return infoConst(product)

  # General range multiplication with overflow checking
  # For ranges [a.minv, a.maxv] × [b.minv, b.maxv], compute all corner products
  # This handles positive, negative, and mixed-sign ranges correctly

  # Pre-check: ensure we can safely compute all corner products
  let corners = [(toInt(a.minv), toInt(b.minv)),
                 (toInt(a.minv), toInt(b.maxv)),
                 (toInt(a.maxv), toInt(b.minv)),
                 (toInt(a.maxv), toInt(b.maxv))]

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
            raise newProveError(e.pos, "multiplication range would overflow")
        except:
          # Even our division overflowed, this definitely would overflow
          raise newProveError(e.pos, "multiplication range would overflow")

  # All corner products are safe, compute the actual range
  var products: seq[int64] = @[]
  for (aVal, bVal) in corners:
    products.add(aVal * bVal)

  let minResult = min(products)
  let maxResult = max(products)

  var res = symUnknown(makeScalar(minResult), makeScalar(maxResult))
  res.nonZero = a.nonZero or b.nonZero
  return res


proc analyzeBinaryDivision*(e: Expression, a: Info, b: Info, ctx: ProverContext): Info =
  let wantsFloat = (e.typ != nil and e.typ.kind == tkFloat) or infoHasFloat(a) or infoHasFloat(b)
  if wantsFloat:
    if b.known:
      if isZero(b.cval):
        let fnCtx = getFunctionContext(e.pos, ctx)
        raise newProveError(e.pos, if fnCtx != "": &"division by zero in {fnCtx}" else: "division by zero")
      if a.known:
        return infoConst(a.cval / b.cval)
      var results = @[a.minv / b.minv, a.minv / b.maxv,
                      a.maxv / b.minv, a.maxv / b.maxv]
      var minVal = results[0]
      var maxVal = results[0]
      for val in results:
        if val < minVal: minVal = val
        if val > maxVal: maxVal = val
      var res = infoUnknown()
      res.minv = minVal
      res.maxv = maxVal
      res.nonZero = res.minv > 0 or res.maxv < 0
      return res
    else:
      if not b.nonZero:
        let fnCtx = getFunctionContext(e.pos, ctx)
        raise newProveError(e.pos, if fnCtx != "": &"cannot prove divisor is non-zero in {fnCtx}" else: "cannot prove divisor is non-zero")
      if b.minv <= 0 and b.maxv >= 0:
        return infoUnknown()
      var results = @[a.minv / b.minv, a.minv / b.maxv,
                      a.maxv / b.minv, a.maxv / b.maxv]
      var minVal = results[0]
      var maxVal = results[0]
      for val in results:
        if val < minVal: minVal = val
        if val > maxVal: maxVal = val
      var res = infoUnknown()
      res.minv = minVal
      res.maxv = maxVal
      res.nonZero = res.minv > 0 or res.maxv < 0
      return res

  if b.known:
    let divisor = toInt(b.cval)
    if divisor == 0:
      let fnCtx = getFunctionContext(e.pos, ctx)
      logProver(ctx.options.verbose, &"Division by zero detected in {fnCtx}")
      raise newProveError(e.pos, if fnCtx != "": &"division by zero in {fnCtx}" else: "division by zero")

    # When both operands are constants, compute exact result
    if a.known:
      let dividend = toInt(a.cval)
      return infoConst(dividend div divisor)

    # When divisor is constant, we can compute better bounds
    if divisor > 0:
      # Positive divisor: result has same sign as dividend, but smaller magnitude
      let minResult = toInt(a.minv) div divisor
      let maxResult = toInt(a.maxv) div divisor
      var res = symUnknown(makeScalar(minResult), makeScalar(maxResult))
      res.nonZero = a.nonZero
      return res
    else:
      # Negative divisor: result has opposite sign to dividend
      let minResult = toInt(a.maxv) div divisor  # Note: order swapped due to negative divisor
      let maxResult = toInt(a.minv) div divisor
      var res = symUnknown(makeScalar(minResult), makeScalar(maxResult))
      res.nonZero = a.nonZero
      return res
  else:
    # Skip overflow checks for float operations
    if e.typ != nil and e.typ.kind == tkFloat:
      return symUnknown()

    if not b.nonZero:
      let fnCtx = getFunctionContext(e.pos, ctx)
      raise newProveError(e.pos, if fnCtx != "": &"cannot prove divisor is non-zero in {fnCtx}" else: "cannot prove divisor is non-zero")

    # Divisor is not a constant, but we know it's non-zero
    # We can compute conservative bounds based on the ranges
    # For a/b where a in [a.minv, a.maxv] and b in [b.minv, b.maxv]:
    # - If b doesn't contain 0, we can compute bounds by considering all corners

    # Check if the divisor range contains zero (shouldn't happen since we checked nonZero)
    if b.minv <= 0 and b.maxv >= 0:
      # Divisor range contains zero, we can't compute precise bounds
      var res = symUnknown()
      res.nonZero = a.nonZero
      return res

    # Compute all possible division results at the corners
    var results: seq[int64] = @[]
    let aBounds = [toInt(a.minv), toInt(a.maxv)]
    let bBounds = [toInt(b.minv), toInt(b.maxv)]
    for aVal in aBounds:
      for bVal in bBounds:
        if bVal != 0:
          results.add(aVal div bVal)

    if results.len > 0:
      let minResult = min(results)
      let maxResult = max(results)
      var res = symUnknown(makeScalar(minResult), makeScalar(maxResult))
      res.nonZero = a.nonZero
      return res

  # Fallback: when divisor range is unknown, we can't be precise
  var res = symUnknown()
  res.nonZero = a.nonZero
  return res


proc analyzeBinaryModulo*(e: Expression, a: Info, b: Info, ctx: ProverContext): Info =
  let wantsFloat = (e.typ != nil and e.typ.kind == tkFloat) or infoHasFloat(a) or infoHasFloat(b)
  if wantsFloat:
    if b.known:
      if isZero(b.cval):
        let fnCtx = getFunctionContext(e.pos, ctx)
        raise newProveError(e.pos, if fnCtx != "": &"modulo by zero in {fnCtx}" else: "modulo by zero")
      if a.known:
        return infoConst(a.cval mod b.cval)
    else:
      if not b.nonZero:
        let fnCtx = getFunctionContext(e.pos, ctx)
        raise newProveError(e.pos, if fnCtx != "": &"cannot prove divisor is non-zero in {fnCtx}" else: "cannot prove divisor is non-zero")
    return infoUnknown()

  if b.known:
    let divisor = toInt(b.cval)
    if divisor == 0:
      let fnCtx = getFunctionContext(e.pos, ctx)
      raise newProveError(e.pos, if fnCtx != "": &"modulo by zero in {fnCtx}" else: "modulo by zero")

    # When divisor is a known constant, we can precisely determine the range
    if divisor > 0:
      # For positive divisor, result is in range [0, divisor-1]
      var res = symUnknown(makeScalar(0'i64), makeScalar(divisor - 1))
      return res
    elif divisor < 0:
      # For negative divisor, result is in range [divisor+1, 0]
      var res = symUnknown(makeScalar(divisor + 1), makeScalar(0'i64))
      return res

  else:
    if not b.nonZero:
      let fnCtx = getFunctionContext(e.pos, ctx)
      raise newProveError(e.pos, if fnCtx != "": &"cannot prove divisor is non-zero in {fnCtx}" else: "cannot prove divisor is non-zero")

  # When divisor is unknown, we can't determine exact bounds
  return symUnknown()


proc analyzeBinaryComparison*(e: Expression, a: Info, b: Info): Info =
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
    return Info(known: false,
                cval: scalarZero(),
                minv: makeScalar(0'i64),
                maxv: makeScalar(1'i64),
                nonZero: false,
                isBool: true,
                initialized: true) # unknown boolean


proc analyzeBinaryLogical*(e: Expression, a: Info, b: Info): Info =
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
      return Info(known: b.known,
                  cval: if b.known: (if bBool: scalarOne() else: scalarZero()) else: scalarZero(),
                  minv: makeScalar(0'i64),
                  maxv: makeScalar(1'i64),
                  nonZero: false,
                  isBool: true,
                  initialized: true)
    if b.known and bBool:
      # a && true = a
      return Info(known: a.known,
                  cval: if a.known: (if aBool: scalarOne() else: scalarZero()) else: scalarZero(),
                  minv: makeScalar(0'i64),
                  maxv: makeScalar(1'i64),
                  nonZero: false,
                  isBool: true,
                  initialized: true)

  of boOr:
    # Logical OR: false || false = false, otherwise true
    if a.known and b.known:
      let logicalResult = aBool or bBool
      return infoBool(logicalResult)
    if a.known and aBool:
      # true || x = true (always)
      return infoBool(true)
    if b.known and bBool:
      # x || true = true (always)
      return infoBool(true)

    # If one operand is known false, result depends on the other
    if a.known and not aBool:
      # false || b = b
      return Info(known: b.known,
                  cval: if b.known: (if bBool: scalarOne() else: scalarZero()) else: scalarZero(),
                  minv: makeScalar(0'i64),
                  maxv: makeScalar(1'i64),
                  nonZero: false,
                  isBool: true,
                  initialized: true)
    if b.known and not bBool:
      # a || false = a
      return Info(known: a.known,
                  cval: if a.known: (if aBool: scalarOne() else: scalarZero()) else: scalarZero(),
                  minv: makeScalar(0'i64),
                  maxv: makeScalar(1'i64),
                  nonZero: false,
                  isBool: true,
                  initialized: true)

  else:
    discard

  # Default case: unknown boolean result
  return Info(known: false,
              cval: scalarZero(),
              minv: makeScalar(0'i64),
              maxv: makeScalar(1'i64),
              nonZero: false,
              isBool: true,
              initialized: true)


proc analyzeUnaryExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  let i0 = analyzeExpression(e.ue, env, ctx)
  case e.uop
  of uoNeg:
    if i0.known:
      # Check for negation overflow: -IMin would overflow
      if i0.cval == IMin:
        raise newProveError(e.pos, "negation overflow: cannot negate minimum integer")
      return infoConst(-i0.cval)

    # For range negation, check if the range contains IMin
    if i0.minv == IMin:
      raise newProveError(e.pos, "potential negation overflow: range contains minimum integer")

    let negMin = if i0.maxv == makeScalar(IMax): makeScalar(IMin) else: -i0.maxv
    let negMax = if i0.minv == makeScalar(IMin): makeScalar(IMax) else: -i0.minv
    return Info(known: false, minv: negMin,
          maxv: negMax,
                nonZero: i0.nonZero, initialized: true)
  of uoNot:
    return infoBool(if i0.known: (i0.cval == 0) else: false) # boolean domain is tiny; not needed for arithmetic safety


proc analyzeBinaryExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  let a = analyzeExpression(e.lhs, env, ctx)
  let b = analyzeExpression(e.rhs, env, ctx)
  case e.bop
  of boAdd: return analyzeBinaryAddition(e, a, b)
  of boSub: return analyzeBinarySubtraction(e, a, b)
  of boMul: return analyzeBinaryMultiplication(e, a, b)
  of boDiv: return analyzeBinaryDivision(e, a, b, ctx)
  of boMod: return analyzeBinaryModulo(e, a, b, ctx)
  of boEq,boNe,boLt,boLe,boGt,boGe: return analyzeBinaryComparison(e, a, b)
  of boAnd,boOr: return analyzeBinaryLogical(e, a, b)
  of boIn,boNotIn: return analyzeBinaryComparison(e, a, b)  # Membership operators return bool like comparisons
