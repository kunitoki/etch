type PatternBinding = tuple[name: string, previous: Option[uint8]]

proc compilePattern(c: var Compiler; pattern: Pattern; valueReg: uint8; failJumps: var seq[int]; bindings: var seq[PatternBinding]): bool


proc literalToValue(lit: PatternLiteral): V =
  case lit.kind
  of plInt: makeInt(lit.ival)
  of plFloat: makeFloat(lit.fval)
  of plString: makeString(lit.sval)
  of plChar: makeChar(lit.cval)
  of plBool: makeBool(lit.bval)


proc loadLiteralRegister(c: var Compiler; lit: PatternLiteral; debug: DebugInfo): uint8 =
  let reg = c.allocator.allocReg()
  let constIdx = c.addConst(literalToValue(lit))
  c.prog.emitABx(opLoadK, reg, constIdx, debug)
  reg


proc emitFailJump(c: var Compiler; failJumps: var seq[int]; debug: DebugInfo) =
  let jumpPos = c.prog.instructions.len
  c.prog.emitAsBx(opJmp, 0, 0, debug)
  failJumps.add(jumpPos)


proc vKindForType(t: EtchType): VKind =
  if t.isNil:
    return vkNil
  case t.kind
  of tkInt: vkInt
  of tkFloat: vkFloat
  of tkBool: vkBool
  of tkChar: vkChar
  of tkString: vkString
  of tkArray, tkTuple: vkArray
  of tkObject, tkUserDefined: vkTable
  of tkRef: vkRef
  of tkWeak: vkWeak
  of tkFunction: vkClosure
  else:
    vkNil



proc recordPatternBinding(c: var Compiler; name: string; valueReg: uint8; bindings: var seq[PatternBinding]) =
  var previous = none(uint8)
  if c.allocator.regMap.hasKey(name):
    previous = some(c.allocator.regMap[name])
  bindings.add((name, previous))
  c.allocator.regMap[name] = valueReg


proc compileOrPattern(c: var Compiler; pattern: Pattern; valueReg: uint8; failJumps: var seq[int]; bindings: var seq[PatternBinding]): bool =
  var successJumps: seq[int] = @[]
  var pendingFailJumps: seq[int] = @[]
  var keepValue = false

  for idx, option in pattern.orPatterns:
    let altStart = c.prog.instructions.len
    for pos in pendingFailJumps:
      c.prog.instructions[pos].sbx = int16(altStart - pos - 1)
    pendingFailJumps.setLen(0)

    var altFail: seq[int] = @[]
    let altKeeps = compilePattern(c, option, valueReg, altFail, bindings)
    keepValue = keepValue or altKeeps

    let jumpPos = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(option.pos))
    successJumps.add(jumpPos)

    pendingFailJumps = altFail
  # Remaining fail jumps belong to the last alternative
  for pos in pendingFailJumps:
    failJumps.add(pos)

  let exitPos = c.prog.instructions.len
  for pos in successJumps:
    c.prog.instructions[pos].sbx = int16(exitPos - pos - 1)

  keepValue


proc compileRangePattern(c: var Compiler; pattern: Pattern; valueReg: uint8; failJumps: var seq[int]; debug: DebugInfo) =
  let startReg = loadLiteralRegister(c, pattern.rangeStart, debug)
  let endReg = loadLiteralRegister(c, pattern.rangeEnd, debug)

  # Fail when value < start (i.e., not >= start)
  c.prog.emitABC(opLt, 1, valueReg, startReg, debug)
  emitFailJump(c, failJumps, debug)

  if pattern.endInclusive:
    c.prog.emitABC(opLe, 0, valueReg, endReg, debug)
  else:
    c.prog.emitABC(opLt, 0, valueReg, endReg, debug)
  emitFailJump(c, failJumps, debug)

  c.allocator.freeReg(endReg)
  c.allocator.freeReg(startReg)


proc compilePattern(c: var Compiler; pattern: Pattern; valueReg: uint8; failJumps: var seq[int]; bindings: var seq[PatternBinding]): bool =
  if pattern.isNil:
    return false

  let debug = c.makeDebugInfo(pattern.pos)
  case pattern.kind
  of pkWildcard:
    return false

  of pkIdentifier:
    if pattern.bindName.len > 0:
      recordPatternBinding(c, pattern.bindName, valueReg, bindings)
    return pattern.bindName.len > 0

  of pkLiteral:
    let litReg = loadLiteralRegister(c, pattern.literal, debug)
    c.prog.emitABC(opEq, 0, valueReg, litReg, debug)
    emitFailJump(c, failJumps, debug)
    c.allocator.freeReg(litReg)
    return false

  of pkRange:
    compileRangePattern(c, pattern, valueReg, failJumps, debug)
    return false

  of pkSome:
    c.prog.emitABC(opTestTag, valueReg, uint8(vkSome), 0, debug)
    emitFailJump(c, failJumps, debug)
    if pattern.innerPattern.isSome:
      let payloadReg = c.allocator.allocReg()
      c.prog.emitABC(opUnwrapOption, payloadReg, valueReg, 0, debug)
      let keepInner = compilePattern(c, pattern.innerPattern.get(), payloadReg, failJumps, bindings)
      if not keepInner:
        c.allocator.freeReg(payloadReg)
      return keepInner
    return false

  of pkNone:
    c.prog.emitABC(opTestTag, valueReg, uint8(vkNone), 0, debug)
    emitFailJump(c, failJumps, debug)
    return false

  of pkOk:
    c.prog.emitABC(opTestTag, valueReg, uint8(vkOk), 0, debug)
    emitFailJump(c, failJumps, debug)
    if pattern.innerPattern.isSome:
      let payloadReg = c.allocator.allocReg()
      c.prog.emitABC(opUnwrapResult, payloadReg, valueReg, 0, debug)
      let keepInner = compilePattern(c, pattern.innerPattern.get(), payloadReg, failJumps, bindings)
      if not keepInner:
        c.allocator.freeReg(payloadReg)
      return keepInner
    return false

  of pkErr:
    c.prog.emitABC(opTestTag, valueReg, uint8(vkErr), 0, debug)
    emitFailJump(c, failJumps, debug)
    if pattern.innerPattern.isSome:
      let payloadReg = c.allocator.allocReg()
      c.prog.emitABC(opUnwrapResult, payloadReg, valueReg, 0, debug)
      let keepInner = compilePattern(c, pattern.innerPattern.get(), payloadReg, failJumps, bindings)
      if not keepInner:
        c.allocator.freeReg(payloadReg)
      return keepInner
    return false

  of pkType:
    let expectedKind = vKindForType(pattern.typePattern)
    if expectedKind == vkNil:
      logCompiler(c.verbose, &"  Warning: unsupported type for type-pattern matching: {pattern.typePattern.kind}")
    c.prog.emitABC(opTestTag, valueReg, uint8(expectedKind), 0, debug)
    emitFailJump(c, failJumps, debug)
    if pattern.typeBind.len > 0:
      recordPatternBinding(c, pattern.typeBind, valueReg, bindings)
      return true
    return false

  of pkTuple:
    let expectedLen = pattern.tuplePatterns.len
    let lenReg = c.allocator.allocReg()
    c.prog.emitABC(opLen, lenReg, valueReg, 0, debug)
    let lenConstReg = c.allocator.allocReg()
    c.prog.emitABx(opLoadK, lenConstReg, c.addConst(makeInt(int64(expectedLen))), debug)
    c.prog.emitABC(opEq, 0, lenReg, lenConstReg, debug)
    emitFailJump(c, failJumps, debug)
    c.allocator.freeReg(lenConstReg)
    c.allocator.freeReg(lenReg)

    var keepValue = false
    for idx, subPat in pattern.tuplePatterns:
      let idxReg = c.allocator.allocReg()
      c.prog.emitABx(opLoadK, idxReg, c.addConst(makeInt(int64(idx))), debug)
      let elemReg = c.allocator.allocReg()
      c.prog.emitABC(opGetIndex, elemReg, valueReg, idxReg, debug)
      c.allocator.freeReg(idxReg)
      let keepElem = compilePattern(c, subPat, elemReg, failJumps, bindings)
      keepValue = keepValue or keepElem
      if not keepElem:
        c.allocator.freeReg(elemReg)
    return keepValue

  of pkArray:
    let headCount = pattern.arrayPatterns.len
    let lenReg = c.allocator.allocReg()
    c.prog.emitABC(opLen, lenReg, valueReg, 0, debug)
    let lenConstReg = c.allocator.allocReg()
    c.prog.emitABx(opLoadK, lenConstReg, c.addConst(makeInt(int64(headCount))), debug)
    if pattern.hasSpread:
      c.prog.emitABC(opLt, 1, lenReg, lenConstReg, debug)
    else:
      c.prog.emitABC(opEq, 0, lenReg, lenConstReg, debug)
    emitFailJump(c, failJumps, debug)
    c.allocator.freeReg(lenConstReg)
    c.allocator.freeReg(lenReg)

    var keepValue = false
    for idx, subPat in pattern.arrayPatterns:
      let idxReg = c.allocator.allocReg()
      c.prog.emitABx(opLoadK, idxReg, c.addConst(makeInt(int64(idx))), debug)
      let elemReg = c.allocator.allocReg()
      c.prog.emitABC(opGetIndex, elemReg, valueReg, idxReg, debug)
      c.allocator.freeReg(idxReg)
      let keepElem = compilePattern(c, subPat, elemReg, failJumps, bindings)
      keepValue = keepValue or keepElem
      if not keepElem:
        c.allocator.freeReg(elemReg)

    if pattern.hasSpread and pattern.spreadName.len > 0:
      let startReg = c.allocator.allocReg()
      let endReg = c.allocator.allocReg()
      c.prog.emitABx(opLoadK, startReg, c.addConst(makeInt(int64(headCount))), debug)
      c.prog.emitAsBx(opLoadK, endReg, -1, debug)
      let restReg = c.allocator.allocReg()
      c.prog.emitABC(opSlice, restReg, valueReg, startReg, debug)
      c.allocator.freeReg(endReg)
      c.allocator.freeReg(startReg)
      recordPatternBinding(c, pattern.spreadName, restReg, bindings)
      keepValue = true

    return keepValue

  of pkAs:
    let keepInner = compilePattern(c, pattern.innerAsPattern, valueReg, failJumps, bindings)
    if pattern.asBind.len > 0:
      recordPatternBinding(c, pattern.asBind, valueReg, bindings)
      return true
    return keepInner

  of pkOr:
    return compileOrPattern(c, pattern, valueReg, failJumps, bindings)

  of pkEnum:
    # For enum patterns, we need to match both the type and the specific member
    if pattern.enumType != nil and pattern.enumMember.isSome:
      let enumReg = loadEnumConstant(c, pattern.enumType, pattern.enumMember.get(), debug)
      c.prog.emitABC(opEq, 0, valueReg, enumReg, debug)
      emitFailJump(c, failJumps, debug)
      c.allocator.freeReg(enumReg)
    else:
      emitFailJump(c, failJumps, debug)
    return false


proc compileMatchExpression(c: var Compiler, e: Expression): uint8 =
  logCompiler(c.verbose, "Compiling ekMatch expression")

  let matchReg = c.compileExpression(e.matchExpression)
  result = c.allocator.allocReg()

  var jumpToEndPositions: seq[int] = @[]

  for i, matchCase in e.cases:
    logCompiler(c.verbose, &"  Compiling match case {i}")
    var caseFailJumps: seq[int] = @[]
    var caseBindings: seq[PatternBinding] = @[]
    discard compilePattern(c, matchCase.pattern, matchReg, caseFailJumps, caseBindings)

    if matchCase.body.len > 0:
      if matchCase.body.len == 1 and matchCase.body[0].kind == skExpression:
        let exprReg = c.compileExpression(matchCase.body[0].sexpr)
        if exprReg != result:
          c.prog.emitABC(opMove, result, exprReg, 0)
          c.allocator.freeReg(exprReg)
      else:
        for stmt in matchCase.body[0..^2]:
          c.compileStatement(stmt)
        if matchCase.body[^1].kind == skExpression:
          let exprReg = c.compileExpression(matchCase.body[^1].sexpr)
          if exprReg != result:
            c.prog.emitABC(opMove, result, exprReg, 0)
            c.allocator.freeReg(exprReg)
        else:
          c.compileStatement(matchCase.body[^1])

    if i < e.cases.len - 1:
      let jumpPos = c.prog.instructions.len
      c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(e.pos))
      jumpToEndPositions.add(jumpPos)

    for pos in caseFailJumps:
      c.prog.instructions[pos].sbx = int16(c.prog.instructions.len - pos - 1)

    # Restore any bindings introduced by this case so outer scopes keep their registers
    if caseBindings.len > 0:
      for idx in countdown(caseBindings.high, 0):
        let binding = caseBindings[idx]
        if binding.previous.isSome:
          c.allocator.regMap[binding.name] = binding.previous.get()
        else:
          if c.allocator.regMap.hasKey(binding.name):
            c.allocator.regMap.del(binding.name)

  for jumpPos in jumpToEndPositions:
    c.prog.instructions[jumpPos].sbx = int16(c.prog.instructions.len - jumpPos - 1)

  c.allocator.freeReg(matchReg)
