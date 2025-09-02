proc analyzeSliceExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Array slicing - comprehensive slice bounds checking
  let arrayInfo = analyzeExpression(e.sliceExpression, env, ctx)

  var startInfo, endInfo: Info
  var hasStart = false
  var hasEnd = false

  # Analyze start bound if present
  if e.startExpression.isSome:
    startInfo = analyzeExpression(e.startExpression.get, env, ctx)
    hasStart = true
    if startInfo.known and startInfo.cval < 0:
      raise newProveError(e.startExpression.get.pos, &"slice start cannot be negative: {startInfo.cval}")

  # Analyze end bound if present
  if e.endExpression.isSome:
    endInfo = analyzeExpression(e.endExpression.get, env, ctx)
    hasEnd = true
    if endInfo.known and endInfo.cval < 0:
      raise newProveError(e.endExpression.get.pos, &"slice end cannot be negative: {endInfo.cval}")

  # Advanced bounds checking when array size is known
  if arrayInfo.isArray and arrayInfo.arraySizeKnown:
    # Check start bounds
    if hasStart and startInfo.known and startInfo.cval > arrayInfo.arraySize:
      raise newProveError(e.startExpression.get.pos, &"slice start {startInfo.cval} beyond array size {arrayInfo.arraySize}")

    # Check end bounds
    if hasEnd and endInfo.known and endInfo.cval > arrayInfo.arraySize:
      raise newProveError(e.endExpression.get.pos, &"slice end {endInfo.cval} beyond array size {arrayInfo.arraySize}")

    # Check start <= end when both are known constants
    if hasStart and hasEnd and startInfo.known and endInfo.known:
      if startInfo.cval > endInfo.cval:
        raise newProveError(e.pos, &"invalid slice: start {startInfo.cval} > end {endInfo.cval}")

  # Advanced bounds checking when string length is known
  elif arrayInfo.isString and arrayInfo.arraySizeKnown:
    # Check start bounds
    if hasStart and startInfo.known and startInfo.cval > arrayInfo.arraySize:
      raise newProveError(e.startExpression.get.pos, &"slice start {startInfo.cval} beyond string length {arrayInfo.arraySize}")

    # Check end bounds
    if hasEnd and endInfo.known and endInfo.cval > arrayInfo.arraySize:
      raise newProveError(e.endExpression.get.pos, &"slice end {endInfo.cval} beyond string length {arrayInfo.arraySize}")

    # Check start <= end when both are known constants
    if hasStart and hasEnd and startInfo.known and endInfo.known:
      if startInfo.cval > endInfo.cval:
        raise newProveError(e.pos, &"invalid slice: start {startInfo.cval} > end {endInfo.cval}")

  # Calculate slice size when possible
  if arrayInfo.isArray:
    # Determine actual slice bounds
    var canComputeSize = false
    var actualStart, actualEnd: int64

    if (not hasStart or startInfo.known) and (not hasEnd or endInfo.known):
      # Can compute bounds - either known or defaulted
      if arrayInfo.arraySizeKnown:
        let startVal = if hasStart and startInfo.known: toInt(startInfo.cval) else: 0
        let endVal = if hasEnd and endInfo.known: toInt(endInfo.cval) else: arrayInfo.arraySize
        actualStart = max(0, startVal)
        actualEnd = min(arrayInfo.arraySize, max(actualStart, endVal))
        canComputeSize = true
      elif hasStart and startInfo.known and hasEnd and endInfo.known:
        actualStart = max(0, toInt(startInfo.cval))
        actualEnd = max(actualStart, toInt(endInfo.cval))
        canComputeSize = true

    if canComputeSize and actualEnd >= actualStart:
      let sliceSize = actualEnd - actualStart
      var sliceInfo = infoArray(sliceSize, sizeKnown = true)

      # Try to preserve element range information from tuple/array literals
      # If slicing from a tuple literal with known values, compute element range
      if e.sliceExpression.kind == ekTuple and actualStart >= 0 and actualEnd <= e.sliceExpression.tupleElements.len:
        var haveElemRange = false
        var minVal = makeScalar(0'i64)
        var maxVal = makeScalar(0'i64)
        for i in actualStart..<actualEnd:
          let elemExpression = e.sliceExpression.tupleElements[i]
          let elemInfo = analyzeExpression(elemExpression, env, ctx)
          if elemInfo.known:
            if not haveElemRange:
              minVal = elemInfo.cval
              maxVal = elemInfo.cval
              haveElemRange = true
            else:
              minVal = min(minVal, elemInfo.cval)
              maxVal = max(maxVal, elemInfo.cval)
          elif elemInfo.minv != makeScalar(IMin) and elemInfo.maxv != makeScalar(IMax):
            if not haveElemRange:
              minVal = elemInfo.minv
              maxVal = elemInfo.maxv
              haveElemRange = true
            else:
              minVal = min(minVal, elemInfo.minv)
              maxVal = max(maxVal, elemInfo.maxv)
        if haveElemRange:
          sliceInfo.minv = minVal
          sliceInfo.maxv = maxVal
          sliceInfo.initialized = true
      # If slicing from a variable, try to look up the original expression
      elif e.sliceExpression.kind == ekVar and env.exprs.hasKey(e.sliceExpression.vname):
        let originalExpression = env.exprs[e.sliceExpression.vname]
        if originalExpression.kind == ekTuple and actualStart >= 0 and actualEnd <= originalExpression.tupleElements.len:
          var haveElemRange = false
          var minVal = makeScalar(0'i64)
          var maxVal = makeScalar(0'i64)
          for i in actualStart..<actualEnd:
            let elemExpression = originalExpression.tupleElements[i]
            let elemInfo = analyzeExpression(elemExpression, env, ctx)
            if elemInfo.known:
              if not haveElemRange:
                minVal = elemInfo.cval
                maxVal = elemInfo.cval
                haveElemRange = true
              else:
                minVal = min(minVal, elemInfo.cval)
                maxVal = max(maxVal, elemInfo.cval)
            elif elemInfo.minv != makeScalar(IMin) and elemInfo.maxv != makeScalar(IMax):
              if not haveElemRange:
                minVal = elemInfo.minv
                maxVal = elemInfo.maxv
                haveElemRange = true
              else:
                minVal = min(minVal, elemInfo.minv)
                maxVal = max(maxVal, elemInfo.maxv)
          if haveElemRange:
            sliceInfo.minv = minVal
            sliceInfo.maxv = maxVal
            sliceInfo.initialized = true
        # Preserve element range if available in the variable info
        elif arrayInfo.initialized and arrayInfo.minv != makeScalar(IMin) and arrayInfo.maxv != makeScalar(IMax):
          sliceInfo.minv = arrayInfo.minv
          sliceInfo.maxv = arrayInfo.maxv
          sliceInfo.initialized = true

      return sliceInfo

    # Fall back to unknown size
    return infoArray(-1, sizeKnown = false)

  elif arrayInfo.isString:
    # Try to calculate string slice length when bounds and original length are known
    if arrayInfo.arraySizeKnown:
      let startVal = if hasStart and startInfo.known: toInt(startInfo.cval) else: 0
      let endVal = if hasEnd and endInfo.known: toInt(endInfo.cval) else: arrayInfo.arraySize

      # Ensure bounds are valid
      if (not hasStart or startInfo.known) and (not hasEnd or endInfo.known):
        let actualStart = max(0, startVal)
        let actualEnd = min(arrayInfo.arraySize, endVal)
        if actualEnd >= actualStart:
          let sliceLength = actualEnd - actualStart
          return infoString(sliceLength, sizeKnown = true)

    # Fall back to unknown length
    return infoString(-1, sizeKnown = false)
  else:
    return infoUnknown()
