proc analyzeArrayExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Array literal - analyze all elements for safety and track size and element ranges
  var haveRange = false
  var minElementValue = makeScalar(0'i64)
  var maxElementValue = makeScalar(0'i64)
  var allKnown = true

  for elem in e.elements:
    let elemInfo = analyzeExpression(elem, env, ctx)
    if elemInfo.initialized:
      if not haveRange:
        minElementValue = elemInfo.minv
        maxElementValue = elemInfo.maxv
        haveRange = true
      else:
        minElementValue = min(minElementValue, elemInfo.minv)
        maxElementValue = max(maxElementValue, elemInfo.maxv)
    else:
      allKnown = false

  # Return info with known array size and element range information
  var res = infoArray(e.elements.len.int64, sizeKnown = true)

  # If all elements have valid ranges, store the overall element range
  if e.elements.len > 0 and haveRange:
    res.minv = minElementValue
    res.maxv = maxElementValue
    res.initialized = true

  return res


proc analyzeIndexExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Array/String indexing - comprehensive bounds checking
  let arrayInfo = analyzeExpression(e.arrayExpression, env, ctx)
  let indexInfo = analyzeExpression(e.indexExpression, env, ctx)

  # Basic negative index check
  if indexInfo.known and indexInfo.cval < 0:
    raise newProveError(e.indexExpression.pos, &"index cannot be negative: {indexInfo.cval}")

  # Array/String bounds checking
  if arrayInfo.isArray or arrayInfo.isString:
    # Comprehensive bounds checking when both array size and index are known
    if indexInfo.known and arrayInfo.arraySizeKnown:
      if indexInfo.cval >= arrayInfo.arraySize:
        raise newProveError(e.indexExpression.pos, &"index {indexInfo.cval} out of bounds [0, {arrayInfo.arraySize-1}]")

    # Range-based bounds checking when array size is known but index is in a range
    elif arrayInfo.arraySizeKnown:
      # Check for disjunctive intervals
      if indexInfo.isDisjunctive:
        # All intervals must be within bounds
        for interval in indexInfo.intervals:
          if interval.minv < 0:
            raise newProveError(e.indexExpression.pos, &"index interval [{interval.minv}, {interval.maxv}] includes negative values")
          if interval.maxv >= arrayInfo.arraySize:
            raise newProveError(e.indexExpression.pos, &"index interval [{interval.minv}, {interval.maxv}] extends beyond array bounds [0, {arrayInfo.arraySize-1}]")
      else:
        # Single interval check
        if indexInfo.minv < 0:
          raise newProveError(e.indexExpression.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] includes negative values")
        if indexInfo.minv >= arrayInfo.arraySize or indexInfo.maxv >= arrayInfo.arraySize:
          raise newProveError(e.indexExpression.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] extends beyond array bounds [0, {arrayInfo.arraySize-1}]")

    # Bounds checking when array size is in a range (stored in minv/maxv)
    # For arrayNew with runtime size, the size range is stored in minv/maxv
    elif not arrayInfo.arraySizeKnown and arrayInfo.isArray:
      # When arrayInfo.minv and maxv represent the array size range, check against index range
      # The index must be provably within bounds even for the smallest possible array size
      if arrayInfo.minv > 0:  # We have array size range information
        let minArraySize = arrayInfo.minv
        let maxArraySize = arrayInfo.maxv

        # Check if index and array size are correlated (e.g., for i in 0..<size where arr = arrayNew(size, 0))
        # If the index maxv is exactly maxArraySize-1, it suggests they're derived from the same bound
        # This handles the common pattern: var arr = arrayNew(n, 0); for i in 0..<n { arr[i] = ... }
        let indexMatchesArrayBound = (indexInfo.minv == 0 and indexInfo.maxv == maxArraySize - 1)

        if not indexMatchesArrayBound:
          # The maximum index must be less than the minimum array size to be safe
          if indexInfo.known:
            if indexInfo.cval >= minArraySize:
              raise newProveError(e.indexExpression.pos, &"index {indexInfo.cval} may be out of bounds (array size range: [{minArraySize}, {maxArraySize}])")
          elif indexInfo.maxv >= minArraySize:
            raise newProveError(e.indexExpression.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] may exceed array bounds (array size range: [{minArraySize}, {maxArraySize}])")

  # If size/length is unknown but we have range info on index, check for negatives
  if not ((arrayInfo.isArray and arrayInfo.arraySizeKnown) or (arrayInfo.isString and arrayInfo.arraySizeKnown)):
    if indexInfo.maxv < 0:
      raise newProveError(e.indexExpression.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] is entirely negative")
    elif indexInfo.minv < 0:
      raise newProveError(e.indexExpression.pos, &"index range [{indexInfo.minv}, {indexInfo.maxv}] includes negative values")

  # Determine the result type information for nested arrays and scalar elements
  # Case 1: Direct indexing into array literal
  if e.arrayExpression.kind == ekArray and indexInfo.known and
     indexInfo.cval >= 0 and indexInfo.cval < e.arrayExpression.elements.len:
    # We're indexing into an array literal with a known index
    let idxValue = toInt(indexInfo.cval)
    let elementExpression = e.arrayExpression.elements[idxValue]

    # If the element is itself an array literal, return array info
    if elementExpression.kind == ekArray:
      return infoArray(elementExpression.elements.len.int64, sizeKnown = true)
    # For scalar elements (like integers), analyze the element directly
    else:
      return analyzeExpression(elementExpression, env, ctx)

  # Case 1b: Direct indexing into tuple literal
  elif e.arrayExpression.kind == ekTuple and indexInfo.known and
       indexInfo.cval >= 0 and indexInfo.cval < e.arrayExpression.tupleElements.len:
    # We're indexing into a tuple literal with a known index
    let idxValue = toInt(indexInfo.cval)
    let elementExpression = e.arrayExpression.tupleElements[idxValue]
    # Analyze the element directly to get its range
    return analyzeExpression(elementExpression, env, ctx)

  # Case 2: Indexing into a variable that contains an array literal
  elif e.arrayExpression.kind == ekVar and indexInfo.known:
    # Look up the variable's original expression
    if env.exprs.hasKey(e.arrayExpression.vname):
      let originalExpression = env.exprs[e.arrayExpression.vname]
      if originalExpression.kind == ekArray and indexInfo.cval >= 0 and indexInfo.cval < originalExpression.elements.len:
        # The variable was initialized with an array literal
        let idxValue = toInt(indexInfo.cval)
        let elementExpression = originalExpression.elements[idxValue]

        # If the element is itself an array literal, return array info
        if elementExpression.kind == ekArray:
          return infoArray(elementExpression.elements.len.int64, sizeKnown = true)
        # For scalar elements (like integers), analyze the element directly
        else:
          return analyzeExpression(elementExpression, env, ctx)
      # Handle tuple literals
      elif originalExpression.kind == ekTuple and indexInfo.cval >= 0 and indexInfo.cval < originalExpression.tupleElements.len:
        # The variable was initialized with a tuple literal
        let idxValue = toInt(indexInfo.cval)
        let elementExpression = originalExpression.tupleElements[idxValue]
        # Analyze the element directly to get its range
        return analyzeExpression(elementExpression, env, ctx)

  # Case 3: Array/String has element range information
  # When the array info has been initialized with element bounds (minv/maxv),
  # return those bounds for scalar array indexing
  if (arrayInfo.isArray or arrayInfo.isString) and arrayInfo.initialized:
    var resInfo = Info(
      known: false,
      minv: arrayInfo.minv,
      maxv: arrayInfo.maxv,
      nonZero: false,
      initialized: true
    )

    # Check if this specific expression is tracked as non-nil in env.nils
    # This handles cases like: if arr[0] != nil { use arr[0] }
    proc serializeExpr(expr: Expression): string =
      case expr.kind
      of ekVar: return expr.vname
      of ekIndex:
        let baseStr = serializeExpr(expr.arrayExpression)
        if expr.indexExpression.kind == ekInt:
          return baseStr & "[" & $expr.indexExpression.ival & "]"
        else:
          return baseStr & "[?]"
      of ekDeref: return "@" & serializeExpr(expr.refExpression)
      of ekFieldAccess: return serializeExpr(expr.objectExpression) & "." & expr.fieldName
      else: return "?"

    let exprKey = serializeExpr(e)
    if env.nils.hasKey(exprKey):
      # Expression-specific nil tracking found
      if not env.nils[exprKey]:
        # Expression is known to be non-nil
        resInfo.nonNil = true
        logProver(ctx.options.verbose, &"Expression '{exprKey}' is known to be non-nil from constraint")
      # If it's known to be nil, keep nonNil = false (default)

    return resInfo

  # If result type is an array but we can't determine exact size
  if e.typ != nil and e.typ.kind == tkArray:
    return infoArray(-1, sizeKnown = false)

  # Check if this specific expression is tracked as non-nil even when we don't know much else
  proc serializeExprFinal(expr: Expression): string =
    case expr.kind
    of ekVar: return expr.vname
    of ekIndex:
      let baseStr = serializeExprFinal(expr.arrayExpression)
      if expr.indexExpression.kind == ekInt:
        return baseStr & "[" & $expr.indexExpression.ival & "]"
      else:
        return baseStr & "[?]"
    of ekDeref: return "@" & serializeExprFinal(expr.refExpression)
    of ekFieldAccess: return serializeExprFinal(expr.objectExpression) & "." & expr.fieldName
    else: return "?"

  let exprKeyFinal = serializeExprFinal(e)
  if env.nils.hasKey(exprKeyFinal) and not env.nils[exprKeyFinal]:
    # Expression is known to be non-nil
    var resInfo = infoUnknown()
    resInfo.nonNil = true
    logProver(ctx.options.verbose, &"Expression '{exprKeyFinal}' is known to be non-nil from constraint (unknown case)")
    return resInfo

  infoUnknown()


proc analyzeArrayLenExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Array/String length operator: #array/#string -> int
  let arrayInfo = analyzeExpression(e.lenExpression, env, ctx)
  if arrayInfo.isArray and arrayInfo.arraySizeKnown:
    # If we know the array size, return it as a constant
    infoConst(arrayInfo.arraySize)
  elif arrayInfo.isString and arrayInfo.arraySizeKnown:
    # If we know the string length, return it as a constant
    infoConst(arrayInfo.arraySize)
  elif arrayInfo.isArray:
    # Array with unknown size - the size range is stored in minv/maxv
    # (set by analyzeArrayNewCall when the size argument is in a range)
    if arrayInfo.minv >= 0 and arrayInfo.maxv < IMax:
      # We have a bounded size range
      return Info(known: false, minv: arrayInfo.minv, maxv: arrayInfo.maxv, nonZero: arrayInfo.minv > 0, initialized: true)
    elif arrayInfo.arraySize >= 0:
      # We have at least a minimum bound
      return Info(known: false,
                  minv: makeScalar(arrayInfo.arraySize),
                  maxv: makeScalar(IMax),
                  nonZero: arrayInfo.arraySize > 0,
                  initialized: true)
    else:
      # Completely unknown size
      return symUnknown()
  else:
    # Size/length is unknown at compile time, but we know it's non-negative
    return symUnknown(makeScalar(0'i64), makeScalar(IMax))