proc analyzeCastExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Explicit cast - analyze the source expression and return appropriate info for target type
  let sourceInfo = analyzeExpression(e.castExpression, env, ctx)  # Analyze source for safety

  # For known values, we can be more precise about the cast result
  if e.castType.kind == tkString:
    # Compute string-related info for explicit cast to string
    # Special-case strings (identity), known ints (digit count), ranges, booleans, chars and nil
    if sourceInfo.isString:
      # Copy exact string length
      return infoString(sourceInfo.arraySize, sizeKnown = sourceInfo.arraySizeKnown)
    if sourceInfo.known:
      # Known literal numeric / boolean / char
      # Use the numeric value's string length for ints
      let s = $sourceInfo.cval
      return infoString(s.len.int64, sizeKnown = true)
    # Range based integer length analysis
    if sourceInfo.minv != IMin and sourceInfo.maxv != IMax:
      let minStrLen = ($sourceInfo.minv).len.int64
      let maxStrLen = ($sourceInfo.maxv).len.int64
      if minStrLen == maxStrLen:
        return infoString(minStrLen, sizeKnown = true)
      var res = infoString(-1, sizeKnown = false)
      res.minv = makeScalar(min(minStrLen, maxStrLen))
      res.maxv = makeScalar(max(minStrLen, maxStrLen))
      return res
    # Unknown source: we can provide some safety defaults for known boolean/char/nil cases
    if sourceInfo.isBool:
      var res = infoString(-1, sizeKnown = false)
      res.minv = makeScalar(4)
      res.maxv = makeScalar(5)
      return res
    if sourceInfo.isArray and sourceInfo.isString:
      return infoString(sourceInfo.arraySize, sizeKnown = sourceInfo.arraySizeKnown)
    # Other cases: unknown string length
    return infoString(0, sizeKnown = false)

  if sourceInfo.known:
    case e.castType.kind:
    of tkInt:
      # Cast to int: truncate float or pass through int
      infoConst(sourceInfo.cval)  # For simplicity, assume cast preserves value
    of tkFloat:
      # Cast to float: pass through
      infoConst(sourceInfo.cval)
    of tkString:
      # Cast to string: result is not numeric, return safe default
      infoUnknown()
    else:
      infoUnknown()
  else:
    # Unknown source value: be conservative
    infoUnknown()
