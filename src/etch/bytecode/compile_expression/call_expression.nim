proc literalArgConstIndex(c: var Compiler, arg: Expression): Option[uint16] =
  ## Try to fold a literal argument directly into the constant pool
  case arg.kind
  of ekNil:
    some(c.addConst(makeNil()))
  of ekBool:
    some(c.addConst(makeBool(arg.bval)))
  of ekChar:
    some(c.addConst(makeChar(arg.cval)))
  of ekInt:
    some(c.addConst(makeInt(arg.ival)))
  of ekFloat:
    some(c.addConst(makeFloat(arg.fval)))
  of ekString:
    some(c.addStringConst(arg.sval))
  else:
    none(uint16)


proc minRequiredArgs(decl: FunctionDeclaration): int =
  ## Count how many parameters do not provide a default value
  for param in decl.params:
    if param.defaultValue.isNone():
      inc result


proc resolveDirectCallName(c: Compiler, baseName: string, argCount: int): Option[string] =
  ## Try to resolve an unmangled function reference to its signature name
  var exactMatches: seq[string] = @[]
  var compatibleMatches: seq[string] = @[]

  for fname, decl in c.funInstances:
    if functionNameFromSignature(fname) != baseName:
      continue

    let minArgs = minRequiredArgs(decl)
    let maxArgs = decl.params.len
    if argCount < minArgs or argCount > maxArgs:
      continue

    if argCount == maxArgs:
      exactMatches.add(fname)
    else:
      compatibleMatches.add(fname)

  if exactMatches.len == 1:
    return some(exactMatches[0])
  if exactMatches.len == 0 and compatibleMatches.len == 1:
    return some(compatibleMatches[0])

  none(string)


proc compileCallExpression(c: var Compiler, e: Expression): uint8 =
  ## Compile function call
  result = c.allocator.allocReg()

  var callName = e.fname
  var completeArgs: seq[Expression] = @[]
  var paramTypes: seq[EtchType] = @[]
  var callViaClosure = e.callIsValue

  if callViaClosure and not e.callTarget.isNil and e.callTarget.kind == ekVar:
    let calleeName = e.callTarget.vname
    let hasLocalVar = c.allocator.regMap.hasKey(calleeName)
    let hasGlobalVar = calleeName in c.globalVars
    var resolvedCallName = none(string)

    if c.funInstances.hasKey(calleeName) or c.prog.functions.hasKey(calleeName):
      resolvedCallName = some(calleeName)
    else:
      resolvedCallName = c.resolveDirectCallName(calleeName, e.args.len)

    let resolvedDisplay = if resolvedCallName.isSome: resolvedCallName.get() else: "<none>"
    logCompiler(c.verbose, &"callIsValue candidate {calleeName}: local={hasLocalVar} global={hasGlobalVar} resolved={resolvedDisplay}")

    if not hasLocalVar and not hasGlobalVar and resolvedCallName.isSome:
      callViaClosure = false
      callName = resolvedCallName.get()

  if callViaClosure:
    if e.callTarget.isNil:
      raise newCompileError(e.pos, "invalid closure call without target")
    callName = "__invoke_closure"
    completeArgs.add(e.callTarget)
    for arg in e.args:
      completeArgs.add(arg)
  else:
    if not c.prog.functions.hasKey(callName):
      let resolvedName = c.resolveDirectCallName(callName, e.args.len)
      if resolvedName.isSome:
        let canonicalName = resolvedName.get()
        if c.prog.functions.hasKey(canonicalName):
          logCompiler(c.verbose, &"Resolved direct call '{callName}' -> '{canonicalName}'")
          callName = canonicalName

    completeArgs = e.args

    # Look up the function info to get parameter information and default values
    if c.funInstances.hasKey(callName):
      let funcDecl = c.funInstances[callName]
      if e.args.len < funcDecl.params.len:
        for i in e.args.len..<funcDecl.params.len:
          let param = funcDecl.params[i]
          if param.defaultValue.isSome():
            completeArgs.add(param.defaultValue.get())
            logCompiler(c.verbose, &"Added default value for parameter {i} of function {callName}")
          else:
            logCompiler(c.verbose, &"Error: Missing required argument for parameter {i} of function {callName}")
            raise newCompileError(e.pos, &"Missing required argument for parameter {i} of function {callName}")
    elif c.prog.functions.hasKey(callName):
      let funcInfo = c.prog.functions[callName]
      if e.args.len < funcInfo.paramTypes.len:
        logCompiler(c.verbose, &"Warning: Function {callName} missing argument for parameter {e.args.len}, but no default value available")

  if c.verbose:
    logCompiler(c.verbose, &"compileCall: {callName} allocated reg {result}")
    logCompiler(c.verbose, &"   original args.len = {e.args.len}")
    logCompiler(c.verbose, &"   complete args.len = {completeArgs.len}")

  # Create debug info for the entire call statement (including argument preparation)
  let callDebug = c.makeDebugInfo(e.pos)

  # Compile arguments and queue them via opArg/opArgImm

  # Get parameter types for conversion checking
  if not callViaClosure:
    if c.prog.functions.hasKey(callName):
      let funcInfo = c.prog.functions[callName]
      for paramTypeStr in funcInfo.paramTypes:
        let paramType = etchTypeFromString(paramTypeStr)
        paramTypes.add(paramType)
    elif c.funInstances.hasKey(callName):
      let funcDecl = c.funInstances[callName]
      for param in funcDecl.params:
        paramTypes.add(param.typ)

  for i, arg in completeArgs:
    logCompiler(c.verbose, &"Compiling argument {i} for function {callName}")
    logCompiler(c.verbose and arg.kind == ekString, &"   String argument: '{arg.sval}'")

    # Check if we need ref->weak conversion
    let needsWeakConversion = i < paramTypes.len and paramTypes[i].kind == tkWeak and arg.typ != nil and arg.typ.kind == tkRef
    let canUseImm = not needsWeakConversion
    if canUseImm:
      let immIdx = literalArgConstIndex(c, arg)
      if immIdx.isSome:
        let constIdx = immIdx.get()
        c.prog.emitABx(opArgImm, 0, constIdx, callDebug)
        logCompiler(c.verbose, &"  Queued literal arg {i} as constant idx {constIdx}")
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
      c.prog.emitABC(opNewWeak, weakReg, tempReg, 0, callDebug)
      logCompiler(c.verbose, &"  Wrapping ref arg {i} in reg {tempReg} with weak wrapper in reg {weakReg}")
      if not isVarReg:
        c.allocator.freeReg(tempReg)
      producedReg = weakReg
      producedIsVar = false

    c.prog.emitABC(opArg, producedReg, 0, 0, callDebug)
    logCompiler(c.verbose, &"  Queued arg {i} from reg {producedReg}")

    if not producedIsVar:
      c.allocator.freeReg(producedReg)

  # Emit call instruction with opcode determined by callee kind
  c.emitCallInstruction(result, callName, completeArgs.len, 1, callDebug)
