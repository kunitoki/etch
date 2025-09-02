proc analyzeTypeofExpression*(e: Expression; env: var Env, ctx: ProverContext): Info =
  # typeof returns a typedesc value, which is a compile-time constant
  # For prover purposes, we treat it as an unknown value since typedesc comparisons are type-based
  discard analyzeExpression(e.typeofExpression, env, ctx)  # Analyze the inner expression for side effects
  return infoUnknown()


proc analyzeBoolExpression*(e: Expression): Info =
  infoBool(e.bval)


proc analyzeCharExpression*(e: Expression): Info =
  # Char analysis not needed for safety, chars are always initialized
  infoUnknown()


proc analyzeIntExpression*(e: Expression): Info =
  infoConst(e.ival)


proc analyzeFloatExpression*(e: Expression): Info =
  infoConstFloat(e.fval)


proc analyzeStringExpression*(e: Expression): Info =
  # String literal - track length for bounds checking
  let length = e.sval.len.int64
  infoString(length, sizeKnown = true)


proc analyzeNilExpression*(e: Expression): Info =
  # nil reference - always known and not non-nil
  Info(known: false, nonNil: false, initialized: true)
