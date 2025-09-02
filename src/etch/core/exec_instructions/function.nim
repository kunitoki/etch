# function.nim
# Function-related instruction implementations for VirtualMachine

import std/[tables, strutils, strformat]
import ../../common/[constants, cffi, values, logging, builtins]
import ../[vm, vm_types, vm_heap, vm_hooks, vm_host_function]
import ../../capabilities/[debugger]


const BUFFER_SIZE = 8192  # Flush every 8KB


# Cross-platform deterministic PRNG using Xorshift64*
# This ensures consistent random number generation across Linux, macOS, and Windows
# Algorithm: https://en.wikipedia.org/wiki/Xorshift
# Period: 2^64 - 1, excellent statistical properties

proc etch_srand(vm: VirtualMachine, seed: uint64) {.inline.} =
  # Initialize RNG state with seed
  # Avoid zero state (would produce all zeros)
  vm.rngState = if seed == 0: 1'u64 else: seed


proc etch_rand(vm: VirtualMachine): uint64 {.inline.} =
  # Xorshift64* algorithm
  let oldState = vm.rngState
  var x = vm.rngState
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  vm.rngState = x

  when not defined(deploy):
    onUpdateRNGState(vm, oldState, x)

  result = x * 0x2545F4914F6CDD1D'u64  # Multiplication constant for better distribution


# Handle C FFI function calls
proc callCFFIFunction(vm: VirtualMachine, funcIdx: uint16, funcInfo: FunctionInfo, funcReg: uint8, argValues: openArray[V]): bool =
  ## Call a C FFI function through the registry
  ## Returns true if function was called successfully

  # Get the C FFI registry
  let registry = cast[CFFIRegistry](vm.cffiRegistry)
  assert registry != nil, "CFFI: no registry attached to VM, cannot call " & funcInfo.name
  assert int(funcIdx) < vm.cffiCache.len, "CFFI: function cache missing for idx " & $funcIdx

  var entry = vm.cffiCache[int(funcIdx)]
  if entry.state == ccsMissing:
    return false

  if entry.state == ccsUnresolved:
    var resolvedName = ""
    if registry.functions.hasKey(funcInfo.name):
      resolvedName = funcInfo.name
      entry.function = registry.functions[funcInfo.name]
    elif funcInfo.baseName.len > 0 and registry.functions.hasKey(funcInfo.baseName):
      resolvedName = funcInfo.baseName
      entry.function = registry.functions[funcInfo.baseName]
    else:
      for name, fn in registry.functions:
        if name.startsWith(funcInfo.baseName):
          resolvedName = name
          entry.function = fn
          break

    if resolvedName.len == 0:
      logVM(vm.verboseLogging, "CFFI: function '" & funcInfo.name & "' not found in registry")
      vm.cffiCache[int(funcIdx)] = CffiCacheEntry(state: ccsMissing)
      return false

    entry.state = ccsReady
    vm.cffiCache[int(funcIdx)] = entry
    logVM(vm.verboseLogging, "CFFI: calling '" & funcInfo.name & "' resolved as '" & resolvedName & "' with " & $argValues.len & " args")

  # Prepare arguments
  var cffiArgs = newSeqOfCap[Value](argValues.len)
  for val in argValues:
    cffiArgs.add(toValue(val))

  # Call the C function
  let res = callCFunction(entry.function, cffiArgs)
  logVM(vm.verboseLogging, "CFFI: call to '" & funcInfo.name & "' returned kind=" & $res.kind)
  setReg(vm, funcReg, fromValue(res))
  return true


# Instruction execution result
# Handle builtin function execution
# Returns true if output buffer should be flushed
proc executeBuiltinFunction*(vm: VirtualMachine, builtinId: BuiltinFuncId, resultReg: uint8,
                             args: openArray[V], verbose: bool): bool =
  ## Execute a builtin function and return true if output should be flushed
  result = false
  let numArgs = args.len

  case builtinId:
  of bfSeed:
    if numArgs == 1:
      let seedVal = args[0]
      assert seedVal.isInt, "builtin seed expects integer argument"
      etch_srand(vm, uint64(getInt(seedVal)))

  of bfRand:
    if numArgs == 1:
      let maxVal = args[0]
      assert maxVal.isInt, "builtin rand expects integer argument"
      let maxInt = getInt(maxVal)
      if maxInt > 0:
        let randVal = int64(etch_rand(vm) mod uint64(maxInt))
        setReg(vm, resultReg, makeInt(randVal))
      else:
        setReg(vm, resultReg, makeInt(0))
    elif numArgs == 2:
      let minVal = args[0]
      let maxVal = args[1]
      assert minVal.isInt and maxVal.isInt, "builtin rand expects integer arguments"
      let minInt = getInt(minVal)
      let maxInt = getInt(maxVal)
      let rng = maxInt - minInt
      if rng > 0:
        let randVal = int64(etch_rand(vm) mod uint64(rng)) + minInt
        setReg(vm, resultReg, makeInt(randVal))
      else:
        setReg(vm, resultReg, makeInt(minInt))

  of bfPrint:
    assert numArgs == 1, "builtin print expects 1 argument"
    let val = args[0]
    let output = formatValueForPrint(val)
    if vm.isDebugging:
      if vm.outputCallback != nil:
        vm.outputCallback(output & "\n")
      else:
        stderr.writeLine(output)
        stderr.flushFile()
    else:
      vm.outputBuffer.add(output)
      vm.outputBuffer.add('\n')
      vm.outputCount.inc
      result = (vm.outputBuffer.len >= BUFFER_SIZE or vm.outputCount >= 100)

  of bfNew:
    assert numArgs == 1, "builtin new expects 1 argument"
    setReg(vm, resultReg, args[0])

  of bfDeref:
    assert numArgs == 1, "builtin deref expects 1 argument"
    let val = args[0]
    assert val.isRef, "builtin deref expects a reference argument"
    let obj = vm.heap.getObject(val.refId)
    assert obj != nil, "builtin deref: invalid reference id"
    case obj.kind:
    of hokScalar:
      setReg(vm, resultReg, obj.value)
    of hokArray:
      setReg(vm, resultReg, makeArray(obj.elements))
    else:
      setReg(vm, resultReg, val)

  of bfArrayNew:
    if numArgs == 2:
      let sizeVal = args[0]
      let defaultVal = args[1]
      assert sizeVal.isInt, "builtin array_new expects integer size argument"
      var newArray = newSeq[V](sizeVal.ival)
      for i in 0 ..< sizeVal.ival:
        newArray[i] = defaultVal
        vm.heap.retainHeapValue(defaultVal)
      setReg(vm, resultReg, makeArray(newArray))
    else:
      setReg(vm, resultReg, makeArray(@[]))

  of bfReadFile:
    assert numArgs == 1 and args[0].isString, "builtin read_file expects 1 string argument"
    let pathVal = args[0]
    try:
      let content = readFile(pathVal.sval)
      setReg(vm, resultReg, makeOk(makeString(content)))
    except:
      setReg(vm, resultReg, makeError(makeString(&"unable to read from '{pathVal.sval}'")))

  of bfParseInt:
    assert numArgs == 1 and args[0].isString, "builtin parse_int expects 1 string argument"
    let strVal = args[0]
    try:
      let intVal = parseInt(strVal.sval)
      setReg(vm, resultReg, makeOk(makeInt(int64(intVal))))
    except:
      setReg(vm, resultReg, makeError(makeString(&"unable to parse int from '{strVal.sval}'")))

  of bfParseFloat:
    assert numArgs == 1 and args[0].isString, "builtin parse_float expects 1 string argument"
    let strVal = args[0]
    try:
      let floatVal = parseFloat(strVal.sval)
      setReg(vm, resultReg, makeOk(makeFloat(floatVal)))
    except:
      setReg(vm, resultReg, makeError(makeString(&"unable to parse float from '{strVal.sval}'")))

  of bfParseBool:
    assert numArgs == 1 and args[0].isString, "builtin parse_bool expects 1 string argument"
    let strVal = args[0]
    if strVal.sval == "true":
      setReg(vm, resultReg, makeOk(makeBool(true)))
    elif strVal.sval == "false":
      setReg(vm, resultReg, makeOk(makeBool(false)))
    else:
      setReg(vm, resultReg, makeError(makeString(&"unable to parse bool from '{strVal.sval}'")))

  of bfIsSome:
    if numArgs == 1:
      setReg(vm, resultReg, makeBool(isSome(args[0])))
    else:
      setReg(vm, resultReg, makeBool(false))

  of bfIsNone:
    if numArgs == 1:
      setReg(vm, resultReg, makeBool(isNone(args[0])))
    else:
      setReg(vm, resultReg, makeBool(true))

  of bfIsOk:
    if numArgs == 1:
      setReg(vm, resultReg, makeBool(isOk(args[0])))
    else:
      setReg(vm, resultReg, makeBool(false))

  of bfIsErr:
    if numArgs == 1:
      setReg(vm, resultReg, makeBool(isError(args[0])))
    else:
      setReg(vm, resultReg, makeBool(true))

  of bfMakeClosure:
    assert numArgs == 2, "builtin make_closure expects 2 arguments"
    let funcIdxVal = args[0]
    let capturesVal = args[1]
    assert funcIdxVal.isInt and capturesVal.isArray, "builtin make_closure expects (int, array) arguments"
    let closureId = if capturesVal.aval != nil:
      vm.heap.allocClosure(int(funcIdxVal.ival), capturesVal.aval[])
    else:
      vm.heap.allocClosure(int(funcIdxVal.ival), [])
    setReg(vm, resultReg, makeClosure(closureId))

  of bfInvokeClosure:
    logVM(verbose, "Unknown builtin id " & $builtinId & " (bfInvokeClosure) - returning nil")
    setReg(vm, resultReg, makeNil())


proc executeLegacyBuiltin(vm: VirtualMachine, funcName: string, resultReg: uint8,
                          args: openArray[V], verbose: bool): bool =
  ## Legacy string-based builtin dispatch used as a fallback
  try:
    let builtinId = getBuiltinId(funcName)
    return executeBuiltinFunction(vm, builtinId, resultReg, args, verbose)
  except ValueError:
    discard

  if funcName == "inject":
    if args.len == 3:
      let nameVal = args[0]
      let typeVal = args[1]
      let valueVal = args[2]
      if isString(nameVal) and isString(typeVal):
        vm.comptimeInjections[nameVal.sval] = valueVal

    setReg(vm, resultReg, makeInt(0))
    return false

  logVM(verbose, "Unknown function: " & funcName & " - returning nil")
  setReg(vm, resultReg, makeNil())
  false


template runBuiltinWithContext(vm: VirtualMachine, funcName: string,
                               instr: Instruction, verbose: bool, body: untyped) =
  ## Execute builtin with debugger hooks and buffer flush handling
  when not defined(deploy):
    if vm.debugger != nil:
      let debugger = cast[RegEtchDebugger](vm.debugger)
      let debug = vm.program.getDebugInfo(vm.currentFrame.pc)
      let currentFile = if debug.sourceFile.len > 0: debug.sourceFile else: MAIN_FUNCTION_NAME
      let currentLine = if debug.line > 0: debug.line else: 1
      debugger.pushStackFrame(funcName, currentFile, currentLine, true)

  let shouldFlush = body
  if shouldFlush:
    flushOutput(vm)

  when not defined(deploy):
    if vm.debugger != nil:
      let debugger = cast[RegEtchDebugger](vm.debugger)
      debugger.popStackFrame()


proc executeBuiltinWithContext(vm: VirtualMachine, builtinId: BuiltinFuncId, resultReg: uint8, args: openArray[V],
                               instr: Instruction, verbose: bool) =
  let funcName = BUILTIN_NAMES[builtinId]
  runBuiltinWithContext(vm, funcName, instr, verbose):
    executeBuiltinFunction(vm, builtinId, resultReg, args, verbose)


proc executeBuiltinWithContext(vm: VirtualMachine, funcName: string, resultReg: uint8, args: openArray[V],
                               instr: Instruction, verbose: bool) =
  runBuiltinWithContext(vm, funcName, instr, verbose):
    executeLegacyBuiltin(vm, funcName, resultReg, args, verbose)


proc takePendingArgsNoAlloc(vm: VirtualMachine, expected: uint8, args: var openArray[V]) {.inline.} =
  ## Drain `expected` arguments from the pending call queue into the provided buffer without new allocations.
  let need = min(int(expected), args.len)
  if need == 0:
    return

  let have = vm.pendingCallArgs.len
  let startIdx = max(0, have - int(expected))
  for i in 0..<need:
    let srcIdx = startIdx + i
    if srcIdx < have:
      args[i] = vm.pendingCallArgs[srcIdx]
    else:
      args[i] = makeNil()

  vm.pendingCallArgs.setLen(startIdx)


proc invokeHostFunction(vm: VirtualMachine, funcIdx: uint16, funcInfo: FunctionInfo, resultReg: uint8, args: openArray[V], verbose: bool) =
  ## Invoke host function and handle fallback
  if callHostFunction(vm, funcIdx, funcInfo, resultReg, args):
    logVM(verbose, "Called host function: " & funcInfo.name)
  else:
    logVM(verbose, "Host function unavailable: " & funcInfo.name)
    setReg(vm, resultReg, makeNil())


proc invokeCffiFunction(vm: VirtualMachine, funcIdx: uint16, funcInfo: FunctionInfo, resultReg: uint8, args: openArray[V], verbose: bool) =
  ## Invoke CFFI function and report missing libraries when necessary
  if callCFFIFunction(vm, funcIdx, funcInfo, resultReg, args):
    logVM(verbose, "Called C FFI function: " & funcInfo.name)
  else:
    if funcInfo.kind == fkCFFI:
      logVM(verbose, "C FFI function not loaded: " & funcInfo.name & " (library: " & funcInfo.library & ")")
    else:
      logVM(verbose, "C FFI function unavailable: " & funcInfo.name)
    setReg(vm, resultReg, makeNil())


proc execArg*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  ## Append register value as next call argument
  ## Optimized for common case: direct copy without bounds checks in release mode
  let srcReg = instr.a
  when not defined(release):
    assert int(srcReg) < vm.currentFrame.regs.len, "opArg source register must be within current frame"

  # Optimized: use direct access and add without intermediate variable
  vm.pendingCallArgs.add(vm.currentFrame.regs[srcReg])
  logVM(verbose, "opArg: queued argument from reg " & $srcReg)


proc execArgImm*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  ## Append constant value as next call argument
  ## Optimized for common case: direct access without bounds checks in release mode
  let constIdx = instr.bx
  when not defined(release):
    assert constIdx < vm.program.constants.len.uint16, "opArgImm constant index out of bounds"

  # Optimized: direct access and add
  vm.pendingCallArgs.add(vm.program.constants[int(constIdx)])
  logVM(verbose, "opArgImm: queued constant argument idx=" & $constIdx)


proc execInvokeClosure(vm: VirtualMachine, instr: Instruction, args: openArray[V], pc: var int, verbose: bool) =
  let resultReg = instr.a
  assert args.len > 0, "__invoke_closure must receive closure argument"

  let closureVal = args[0]
  assert closureVal.isClosure, "__invoke_closure expects closure value"

  let closureObj = vm.heap.getObject(closureVal.closureId)
  assert closureObj != nil and closureObj.kind == hokClosure, "Invalid closure object in heap"

  let funcIdx = closureObj.funcIdx
  assert funcIdx >= 0 and funcIdx < vm.program.functionTable.len, "Closure function index out of bounds"

  let funcInfo = vm.getFunctionInfo(uint16(funcIdx))
  let funcName = funcInfo.name
  assert vm.hasFunctionInfo(uint16(funcIdx)), "Closure function metadata missing"

  let maxArgReg = resultReg + uint8(args.len)
  if maxArgReg >= uint8(vm.currentFrame.regs.len):
    let oldSize = vm.currentFrame.regs.len
    let newSize = int(maxArgReg) + 1
    vm.currentFrame.regs.setLen(newSize)
    for i in oldSize ..< newSize:
      vm.currentFrame.regs[i] = V(kind: vkNil)

  let captureValues = closureObj.captures
  let captureCount = captureValues.len
  let userArgCount = if args.len > 1: args.len - 1 else: 0

  case funcInfo.kind
  of fkHost, fkCFFI:
    assert captureCount == 0, "__invoke_closure: host/CFFI closures cannot have captures"

    let called =
      if funcInfo.kind == fkHost:
        if userArgCount > 0:
          callHostFunction(vm, uint16(funcIdx), funcInfo, resultReg, args.toOpenArray(1, args.len-1))
        else:
          var empty: array[0, V]
          callHostFunction(vm, uint16(funcIdx), funcInfo, resultReg, empty)
      else:
        if userArgCount > 0:
          callCFFIFunction(vm, uint16(funcIdx), funcInfo, resultReg, args.toOpenArray(1, args.len-1))
        else:
          var empty: array[0, V]
          callCFFIFunction(vm, uint16(funcIdx), funcInfo, resultReg, empty)

    if not called:
      logVM(verbose, "__invoke_closure: failed to call " & funcName & " via " &
        (if funcInfo.kind == fkHost: "host" else: "CFFI"))
      setReg(vm, resultReg, makeNil())

    pc = pc + 1
    return

  of fkBuiltin:
    assert false, "__invoke_closure: builtin function cannot be invoked as closure"

  of fkNative:
    discard

  when not defined(deploy):
    onInvokeClosureInstructionBegin(vm, funcInfo, verbose)

  let totalArgs = captureCount + userArgCount

  let numRegs = max(max(1, totalArgs), funcInfo.maxRegister + 1)
  var newFrame: RegisterFrame
  if vm.framePool.len > 0:
    newFrame = vm.framePool.pop()
    if newFrame.regs.len < numRegs:
      newFrame.regs.setLen(numRegs)
    if newFrame.deferStack.len > 0:
      newFrame.deferStack.setLen(0)
  else:
    newFrame = RegisterFrame()
    newFrame.regs = newSeq[V](numRegs)
    newFrame.deferStack = @[]

  newFrame.returnAddr = pc + 1
  newFrame.baseReg = resultReg
  newFrame.deferReturnPC = 0
  newFrame.base = 0
  newFrame.pc = funcInfo.startPos
  when not defined(deploy):
    newFrame.funcName = funcName

  for i in 0..<numRegs:
    newFrame.regs[i] = V(kind: vkNil)

  for i, cap in captureValues:
    if i < numRegs:
      newFrame.regs[i] = cap

  for i in 0..<userArgCount:
    let dstIdx = captureCount + i
    if dstIdx < numRegs:
      newFrame.regs[dstIdx] = args[1+i]

  vm.frames.add(newFrame)
  vm.currentFrame = addr vm.frames[^1]

  when not defined(deploy):
    onInvokeClosureInstructionEnd(vm, newFrame, pc, verbose)

  pc = funcInfo.startPos


proc execCallEtch*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Execute native Etch function call (opCall)
  let funcIdx = instr.funcIdx
  let numArgs = instr.numArgs
  let resultReg = instr.a
  let numResults = instr.numResults

  let funcInfo = vm.getFunctionInfo(funcIdx)
  let funcName = funcInfo.name
  let need = int(numArgs)

  logVM(verbose, "opCallEtch: funcIdx=" & $funcIdx & " funcName='" & funcName & "' numArgs=" & $numArgs & " numResults=" & $numResults)

  if funcName == "__invoke_closure":
    if vm.argScratch.len < need: vm.argScratch.setLen(need)
    takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)
    execInvokeClosure(vm, instr, vm.argScratch.toOpenArray(0, need-1), pc, verbose)
    return

  if not vm.hasFunctionInfo(funcIdx):
    logVM(verbose, "opCallEtch: no metadata for '" & funcName & "', treating as legacy builtin")
    if vm.argScratch.len < need: vm.argScratch.setLen(need)
    takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)
    executeBuiltinWithContext(vm, funcName, resultReg, vm.argScratch.toOpenArray(0, need-1), instr, verbose)
    return

  case funcInfo.kind
  of fkNative:
    when not defined(deploy):
      onInvokeNativeInstructionBegin(vm, funcInfo, verbose)

    let numRegs = max(max(1, need), funcInfo.maxRegister + 1)
    var newFrame: RegisterFrame
    if vm.framePool.len > 0:
      newFrame = vm.framePool.pop()
      if newFrame.regs.len < numRegs:
        newFrame.regs.setLen(numRegs)
      if newFrame.deferStack.len > 0:
        newFrame.deferStack.setLen(0)
    else:
      newFrame = RegisterFrame()
      newFrame.regs = newSeq[V](numRegs)
      newFrame.deferStack = @[]

    newFrame.returnAddr = pc + 1
    newFrame.baseReg = resultReg
    newFrame.deferReturnPC = 0
    newFrame.base = 0
    newFrame.pc = funcInfo.startPos
    when not defined(deploy):
      newFrame.funcName = funcName

    # Optimized: Copy args with minimal overhead
    let pendingLen = vm.pendingCallArgs.len
    let startIdx = pendingLen - need

    # Copy arguments in tight loop (compiler will vectorize if possible)
    for i in 0..<need:
      newFrame.regs[i] = vm.pendingCallArgs[startIdx + i]

    # Clear remaining registers
    for i in need..<numRegs:
      newFrame.regs[i] = V(kind: vkNil)

    # Consume args
    vm.pendingCallArgs.setLen(startIdx)

    vm.frames.add(newFrame)
    vm.currentFrame = addr vm.frames[^1]

    when not defined(deploy):
      onInvokeNativeInstructionEnd(vm, newFrame, pc, verbose)

    pc = funcInfo.startPos

  of fkHost:
    logVM(verbose, "opCallEtch: rerouting host function '" & funcName & "' via host opcode")
    if vm.argScratch.len < need: vm.argScratch.setLen(need)
    takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)
    invokeHostFunction(vm, funcIdx, funcInfo, resultReg, vm.argScratch.toOpenArray(0, need-1), verbose)

  of fkCFFI:
    logVM(verbose, "opCallEtch: rerouting CFFI function '" & funcName & "'")
    if vm.argScratch.len < need: vm.argScratch.setLen(need)
    takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)
    invokeCffiFunction(vm, funcIdx, funcInfo, resultReg, vm.argScratch.toOpenArray(0, need-1), verbose)

  of fkBuiltin:
    let builtinName = if funcInfo.baseName.len > 0: funcInfo.baseName else: funcName
    logVM(verbose, "opCallEtch: rerouting builtin function '" & builtinName & "'")
    if vm.argScratch.len < need: vm.argScratch.setLen(need)
    takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)
    if funcInfo.builtinId <= uint16(ord(BuiltinFuncId.high)):
      let builtinId = BuiltinFuncId(funcInfo.builtinId)
      if builtinId == bfInvokeClosure:
        execInvokeClosure(vm, instr, vm.argScratch.toOpenArray(0, need-1), pc, verbose)
      else:
        executeBuiltinWithContext(vm, builtinId, resultReg, vm.argScratch.toOpenArray(0, need-1), instr, verbose)
    else:
      executeBuiltinWithContext(vm, builtinName, resultReg, vm.argScratch.toOpenArray(0, need-1), instr, verbose)


proc execCallBuiltin*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Execute builtin call (opCallBuiltin) using builtin ID encoding
  let builtinIdx = int(instr.funcIdx)
  let builtinId = BuiltinFuncId(builtinIdx)
  let maxBuiltin = ord(BuiltinFuncId.high)
  assert builtinIdx >= 0 and builtinIdx <= maxBuiltin, "Invalid builtin id in bytecode"

  let numArgs = instr.numArgs
  let resultReg = instr.a

  # Prepare arguments in scratch buffer
  let need = int(numArgs)
  if vm.argScratch.len < need:
    vm.argScratch.setLen(need)

  takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)

  let funcName = BUILTIN_NAMES[builtinId]
  logVM(verbose, "opCallBuiltin: id=" & $builtinIdx & " name='" & funcName & "' numArgs=" & $instr.numArgs)

  if builtinId == bfInvokeClosure:
    execInvokeClosure(vm, instr, vm.argScratch.toOpenArray(0, need-1), pc, verbose)
  else:
    executeBuiltinWithContext(vm, builtinId, resultReg, vm.argScratch.toOpenArray(0, need-1), instr, verbose)


proc execCallHost*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Execute host call (opCallHost)
  let numArgs = instr.numArgs
  let resultReg = instr.a

  let need = int(numArgs)
  if vm.argScratch.len < need:
    vm.argScratch.setLen(need)
  takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)

  let funcIdx = instr.funcIdx
  let funcInfo = vm.getFunctionInfo(funcIdx)
  let funcName = funcInfo.name

  logVM(verbose, "opCallHost: funcIdx=" & $funcIdx & " funcName='" & funcName & "' numArgs=" & $instr.numArgs)
  invokeHostFunction(vm, funcIdx, funcInfo, resultReg, vm.argScratch.toOpenArray(0, need-1), verbose)


proc execCallFFI*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Execute C FFI call (opCallFFI)
  let numArgs = instr.numArgs
  let resultReg = instr.a

  let need = int(numArgs)
  if vm.argScratch.len < need:
    vm.argScratch.setLen(need)
  takePendingArgsNoAlloc(vm, numArgs, vm.argScratch)

  let funcIdx = instr.funcIdx
  let funcInfo = vm.getFunctionInfo(funcIdx)
  let funcName = funcInfo.name

  logVM(verbose, "opCallFFI: funcIdx=" & $funcIdx & " funcName='" & funcName & "' numArgs=" & $instr.numArgs)
  invokeCffiFunction(vm, funcIdx, funcInfo, resultReg, vm.argScratch.toOpenArray(0, need-1), verbose)
