proc analyzeTupleExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Tuple literal - analyze all elements for safety and track size
  var haveRange = false
  var minElementValue = makeScalar(0'i64)
  var maxElementValue = makeScalar(0'i64)
  var allKnown = true

  for elem in e.tupleElements:
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

  # Return info with known tuple size (like arrays)
  var res = infoArray(e.tupleElements.len.int64, sizeKnown = true)

  # If all elements have valid ranges, store the overall element range
  if e.tupleElements.len > 0 and haveRange:
    res.minv = minElementValue
    res.maxv = maxElementValue
    res.initialized = true

  return res

