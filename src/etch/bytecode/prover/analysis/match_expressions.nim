proc bindPatternEnv(pattern: Pattern; matchedInfo: Info; env: var Env) =
  if pattern.isNil:
    return
  case pattern.kind
  of pkIdentifier:
    if pattern.bindName.len > 0:
      env.vals[pattern.bindName] = matchedInfo
      env.nils[pattern.bindName] = false

  of pkAs:
    if pattern.asBind.len > 0:
      env.vals[pattern.asBind] = matchedInfo
      env.nils[pattern.asBind] = false
    bindPatternEnv(pattern.innerAsPattern, matchedInfo, env)

  of pkSome, pkOk:
    if pattern.innerPattern.isSome:
      bindPatternEnv(pattern.innerPattern.get(), matchedInfo, env)

  of pkErr:
    if pattern.innerPattern.isSome:
      bindPatternEnv(pattern.innerPattern.get(), infoUnknown(), env)

  of pkType:
    if pattern.typeBind.len > 0:
      env.vals[pattern.typeBind] = matchedInfo
      env.nils[pattern.typeBind] = false

  of pkTuple:
    for subPat in pattern.tuplePatterns:
      bindPatternEnv(subPat, infoUnknown(), env)

  of pkArray:
    for subPat in pattern.arrayPatterns:
      bindPatternEnv(subPat, infoUnknown(), env)
    if pattern.spreadName.len > 0:
      env.vals[pattern.spreadName] = infoUnknown()
      env.nils[pattern.spreadName] = false

  of pkOr:
    if pattern.orPatterns.len > 0:
      bindPatternEnv(pattern.orPatterns[0], matchedInfo, env)

  else:
    discard


proc analyzeMatchCaseBody(caseBody: seq[Statement], env: var Env, ctx: ProverContext): Info =
  ## Analyze a match case body and return the value produced by its final expression.
  if caseBody.len == 0:
    return Info(known: false, initialized: true)

  var resultInfo = Info(known: false, initialized: true)
  var hasResult = false
  for idx, stmt in caseBody:
    let isLastExpr = (idx == caseBody.len - 1) and stmt.kind == skExpression
    if isLastExpr:
      resultInfo = analyzeExpression(stmt.sexpr, env, ctx)
      hasResult = true
    else:
      analyzeStatement(stmt, env, ctx)

  if hasResult:
    return resultInfo
  else:
    return Info(known: false, initialized: true)


proc analyzeMatchExpression(e: Expression, env: var Env, ctx: ProverContext): Info =
  # Simplified match expression analysis that only handles expressions, not full statements
  let matchedInfo = analyzeExpression(e.matchExpression, env, ctx)
  var caseInfos: seq[Info] = @[]

  for matchCase in e.cases:
    # Create new environment for this case with pattern bindings
    var caseEnv = copyEnv(env)

    bindPatternEnv(matchCase.pattern, matchedInfo, caseEnv)

    # Analyze case body statements (limited to avoid circular imports)
    let caseInfo = analyzeMatchCaseBody(matchCase.body, caseEnv, ctx)
    caseInfos.add(caseInfo)
    propagateUsage(env, caseEnv)

  if caseInfos.len == 0:
    return infoUnknown()

  var mergedInfo = caseInfos[0]
  for i in 1..<caseInfos.len:
    mergedInfo = union(mergedInfo, caseInfos[i])
  return mergedInfo

