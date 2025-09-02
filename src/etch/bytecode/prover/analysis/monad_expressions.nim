proc analyzeOptionSomeExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # some(value) - return info about the wrapped value, since result propagation
  # will expose it to callers on the success path.
  let innerInfo = analyzeExpression(e.someExpression, env, ctx)
  return innerInfo


proc analyzeOptionNoneExpression*(e: Expression): Info =
  # none - safe but represents absence of value
  infoUnknown()


proc analyzeResultOkExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # ok(value) - return info about the wrapped value, since result propagation
  # will expose it to callers on the success path.
  let innerInfo = analyzeExpression(e.okExpression, env, ctx)
  return innerInfo


proc analyzeResultErrExpression*(e: Expression, env: var Env, ctx: ProverContext): Info =
  # error(msg) - analyze the error message
  discard analyzeExpression(e.errExpression, env, ctx)
  infoUnknown()  # TODO - error value is unknown without pattern matching ?
