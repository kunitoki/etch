proc compileYieldExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile yield expression
  let resultReg = c.allocator.allocReg()
  let debug = c.makeDebugInfo(e.pos)
  if e.yieldValue.isSome:
    # Compile the yield value
    let valueReg = c.compileExpression(e.yieldValue.get)
    c.prog.emitABC(opMove, resultReg, valueReg, 0, debug)
    c.allocator.freeReg(valueReg)
  else:
    # Yield with no value (yield nil)
    c.prog.emitABC(opLoadNil, resultReg, 0, 0, debug)
  # Emit yield instruction - VM will save state and return
  c.prog.emitABC(opYield, resultReg, 0, 0, debug)
  return resultReg


proc compileResumeExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile resume expression
  let resultReg = c.allocator.allocReg()
  let coroReg = c.compileExpression(e.resumeValue)
  c.prog.emitABC(opResume, resultReg, coroReg, 0, c.makeDebugInfo(e.pos))
  c.allocator.freeReg(coroReg)
  return resultReg


proc compileSpawnExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile spawn expression
  let resultReg = c.allocator.allocReg()
  let debug = c.makeDebugInfo(e.pos)

  # Check if spawning a function call or async block
  if e.spawnExpression.kind == ekCall:
    let callExpression = e.spawnExpression
    if callExpression.callIsValue:
      raise newCompileError(e.pos, "spawn requires a direct function reference (no closures yet)")

    let funcName = callExpression.fname
    var completeArgs: seq[Expression] = @[]
    for arg in callExpression.args:
      completeArgs.add(arg)

    # Add default parameter values when available (same as regular calls)
    if c.funInstances.hasKey(funcName):
      let funcDecl = c.funInstances[funcName]
      if completeArgs.len < funcDecl.params.len:
        for i in completeArgs.len..<funcDecl.params.len:
          let param = funcDecl.params[i]
          if param.defaultValue.isSome():
            completeArgs.add(param.defaultValue.get())
            logCompiler(c.verbose, &"Spawn: added default argument {i} for function {funcName}")
          else:
            raise newCompileError(e.pos, &"missing required argument {i} for function {funcName}")
    elif c.prog.functions.hasKey(funcName):
      let funcInfo = c.prog.functions[funcName]
      if completeArgs.len < funcInfo.paramTypes.len:
        logCompiler(c.verbose, &"Spawn: function {funcName} missing argument for parameter {completeArgs.len}")

    # Collect parameter types for weak/ref conversion checks
    var paramTypes: seq[EtchType] = @[]
    if c.prog.functions.hasKey(funcName):
      let funcInfo = c.prog.functions[funcName]
      for paramTypeStr in funcInfo.paramTypes:
        paramTypes.add(etchTypeFromString(paramTypeStr))
    elif c.funInstances.hasKey(funcName):
      let funcDecl = c.funInstances[funcName]
      for param in funcDecl.params:
        paramTypes.add(param.typ)

    # Queue arguments via opArg/opArgImm so VM pending queue can capture them
    for i, arg in completeArgs:
      let needsWeakConversion =
        i < paramTypes.len and
        paramTypes[i] != nil and paramTypes[i].kind == tkWeak and
        arg.typ != nil and arg.typ.kind == tkRef

      let canUseImm = not needsWeakConversion
      if canUseImm:
        let immIdx = literalArgConstIndex(c, arg)
        if immIdx.isSome:
          let constIdx = immIdx.get()
          c.prog.emitABx(opArgImm, 0, constIdx, debug)
          logCompiler(c.verbose, &"Spawn: queued literal arg {i} as const idx {constIdx}")
          continue

      let isVarReg = arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname)
      var tempReg: uint8
      if isVarReg:
        tempReg = c.allocator.regMap[arg.vname]
      else:
        tempReg = c.compileExpression(arg)

      var producedReg = tempReg
      var producedIsVar = isVarReg

      if needsWeakConversion:
        let weakReg = c.allocator.allocReg()
        c.prog.emitABC(opNewWeak, weakReg, tempReg, 0, debug)
        logCompiler(c.verbose, &"Spawn: wrapped ref arg {i} from reg {tempReg} into weak reg {weakReg}")
        if not isVarReg:
          c.allocator.freeReg(tempReg)
        producedReg = weakReg
        producedIsVar = false

      c.prog.emitABC(opArg, producedReg, 0, 0, debug)
      logCompiler(c.verbose, &"Spawn: queued arg {i} from reg {producedReg}")

      if not producedIsVar:
        c.allocator.freeReg(producedReg)

    if completeArgs.len > 255:
      raise newCompileError(e.pos, "spawn supports at most 255 arguments")

    let funcIdx = c.addFunctionIndex(funcName)
    logCompiler(c.verbose, &"Spawn: function '{funcName}' has index {funcIdx}")

    c.prog.emitABC(opSpawn, resultReg, uint8(funcIdx), uint8(completeArgs.len), debug)

  elif e.spawnExpression.kind == ekSpawnBlock:
    # Spawn an async block - needs to create anonymous coroutine
    raise newCompileError(e.pos, "Launching spawn blocks not yet implemented - use spawn with function calls")

  else:
    # Spawn other expression types - evaluate and wrap in coroutine
    let exprReg = c.compileExpression(e.spawnExpression)
    # For now, just return the expression result
    # TODO: Wrap in coroutine if the expression type is async
    c.prog.emitABC(opMove, resultReg, exprReg, 0, debug)
    c.allocator.freeReg(exprReg)

  return resultReg


proc compileChannelNewExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile channel creation expression
  let resultReg = c.allocator.allocReg()
  let debug = c.makeDebugInfo(e.pos)

  if e.channelCapacity.isSome:
    # Compile capacity expression
    let capReg = c.compileExpression(e.channelCapacity.get)
    c.prog.emitABC(opChannelNew, resultReg, capReg, 0, debug)
    c.allocator.freeReg(capReg)
  else:
    # Default capacity of 1 (buffered by 1)
    let capReg = c.allocator.allocReg()
    let constIdx = c.addConst(makeInt(1))
    c.prog.emitABx(opLoadK, capReg, constIdx, debug)
    c.prog.emitABC(opChannelNew, resultReg, capReg, 0, debug)
    c.allocator.freeReg(capReg)

  return resultReg


proc compileChannelSendExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile channel send expression
  let resultReg = c.allocator.allocReg()
  let chanReg = c.compileExpression(e.sendChannel)
  let valueReg = c.compileExpression(e.sendValue)
  let debug = c.makeDebugInfo(e.pos)

  # Emit channel send: send R[B] to channel R[A] (may suspend)
  c.prog.emitABC(opChannelSend, chanReg, valueReg, 0, debug)

  # Channel send returns void
  c.prog.emitABC(opLoadNil, resultReg, 0, 0, debug)

  c.allocator.freeReg(chanReg)
  c.allocator.freeReg(valueReg)
  return resultReg


proc compileChannelRecvExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile channel receive expression
  let resultReg = c.allocator.allocReg()
  let chanReg = c.compileExpression(e.recvChannel)

  # Emit channel receive: R[A] = receive from channel R[B] (may suspend)
  c.prog.emitABC(opChannelRecv, resultReg, chanReg, 0, c.makeDebugInfo(e.pos))

  c.allocator.freeReg(chanReg)
  return resultReg
