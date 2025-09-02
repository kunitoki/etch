# coroutines.nim
# Coroutine operation helpers

import std/strformat
import ../../common/logging
import ../[vm, vm_types]
import ../vm_coroutine
import ./arg_queue


proc handleYield*(vm: VirtualMachine, instr: Instruction): bool {.inline.} =
  ## Handle opYield instruction. Returns true if should exit execute loop.
  if vm.activeCoroId >= 0 and vm.activeCoroId < vm.coroutines.len:
    let coro = cast[Coroutine](vm.coroutines[vm.activeCoroId])
    if coro != nil:
      # Save current state
      coro.state = csSuspended
      coro.savedFrame = vm.currentFrame[]
      coro.resumePC = vm.currentFrame.pc + 1  # Resume after yield
      coro.yieldValue = getReg(vm, instr.a)

      # Set result register to yielded value for caller
      setReg(vm, instr.a, coro.yieldValue)

      # Signal to exit execution loop
      return true
  else:
    # Yield outside coroutine context - error
    raise newException(ValueError, "yield can only be called from within a coroutine")

  return false


proc handleSpawn*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  ## Handle opSpawn instruction - create a new coroutine
  let funcIdx = int(instr.b)
  let numArgs = int(instr.c)

  # Get function info
  if funcIdx < 0 or funcIdx >= vm.functionInfos.len:
    raise newException(ValueError, "Invalid function index for spawn")

  let funcInfo = vm.getFunctionInfo(uint16(funcIdx))
  let funcName = funcInfo.name
  if not vm.hasFunctionInfo(uint16(funcIdx)):
    raise newException(ValueError, &"Function {funcName} not found for spawn")

  # Create initial register frame for the coroutine
  var initialFrame = RegisterFrame(
    regs: newSeq[V](funcInfo.maxRegister + 1),
    pc: funcInfo.startPos,
    base: 0,
    returnAddr: -1,  # No return address for top-level coroutine
    baseReg: 0,
    deferStack: @[],
    deferReturnPC: -1
  )

  when not defined(deploy):
    initialFrame.funcName = funcName

  # Attempt to pull arguments from the VM's pending call queue (new format)
  let pendingBefore = vm.pendingCallArgs.len
  let queuedArgs = takePendingCallArgs(vm, instr.c, verbose)
  let hasQueuedArgs = numArgs == 0 or pendingBefore >= numArgs
  let paramsToCopy = min(numArgs, funcInfo.paramTypes.len)

  if hasQueuedArgs:
    for i in 0..<paramsToCopy:
      initialFrame.regs[i] = queuedArgs[i]
  else:
    if numArgs > 0:
      logVM(verbose, "handleSpawn: falling back to legacy register-based argument decoding")
    for i in 0..<paramsToCopy:
      initialFrame.regs[i] = getReg(vm, instr.a + uint8(i) + 1)

  # Create coroutine
  let coroId = vm.coroutines.len
  let coro = newCoroutine(coroId, funcIdx, initialFrame, vm.activeCoroId)
  let coroPtr = cast[pointer](coro)
  vm.coroutines.add(coroPtr)
  # TODO: Add to GC keepalive table (see heapKeepalive in vm_execution.nim)
  # For now, using GC_ref to prevent collection
  GC_ref(coro)
  vm.retainCoroutineRef(coroId)

  # Return coroutine reference
  setReg(vm, instr.a, V(kind: vkCoroutine, coroId: coroId))


proc setResumeError(vm: VirtualMachine, target: uint8, message: string, verbose: bool) =
  ## Helper to write an error(string) result into a register for resume failures
  logVM(verbose, "opResume: " & message)
  let errVal = makeError(makeString(message))
  setReg(vm, target, errVal)


proc handleResume*(vm: VirtualMachine, instr: Instruction, executeProc: proc(vm: VirtualMachine, verbose: bool): int, verbose: bool) {.inline.} =
  ## Handle opResume instruction - resume a coroutine while always returning result[T]
  ## executeProc is passed in to avoid circular dependencies
  let targetReg = instr.a
  let coroVal = getReg(vm, instr.b)
  if coroVal.kind != vkCoroutine:
    setResumeError(vm, targetReg, "resume requires a coroutine value", verbose)
    return

  let coroId = coroVal.coroId
  if coroId < 0 or coroId >= vm.coroutines.len:
    setResumeError(vm, targetReg, "invalid coroutine reference", verbose)
    return

  let coro = cast[Coroutine](vm.coroutines[coroId])
  if coro == nil:
    setResumeError(vm, targetReg, "coroutine has been collected", verbose)
    return

  logVM(verbose, "opResume: coroutine " & $coroId & " in state " & $coro.state)

  case coro.state:
  of csRunning:
    setResumeError(vm, targetReg, &"coroutine {coroId} is already running", verbose)
    return

  of csCompleted, csDead:
    setResumeError(vm, targetReg, "cannot resume completed coroutine", verbose)
    return

  of csSuspended:
    # Save current context
    let savedActiveCoroId = vm.activeCoroId
    let savedFrame = vm.currentFrame[]
    let savedFrameIndex = vm.frames.len - 1

    # Switch to coroutine context
    vm.activeCoroId = coroId
    coro.state = csRunning
    logVM(verbose, "opResume: set coroutine " & $coroId & " to csRunning")

    # Replace current frame with coroutine's frame
    vm.frames[savedFrameIndex] = coro.savedFrame
    vm.currentFrame = addr vm.frames[savedFrameIndex]

    # Resume from stored PC
    if coro.resumePC >= 0:
      vm.currentFrame.pc = coro.resumePC

    logVM(verbose, "opResume: executing coroutine from PC " & $vm.currentFrame.pc)

    # Execute the coroutine (runs until yield, return, or end)
    discard executeProc(vm, verbose)

    logVM(verbose, "opResume: coroutine " & $coroId & " now in state " & $coro.state)

    # Save coroutine state after execution
    coro.savedFrame = vm.currentFrame[]

    # Determine value to unwrap inside ok(...)
    let payload =
      if coro.state == csSuspended:
        coro.yieldValue
      elif coro.state == csCompleted:
        coro.returnValue
      else:
        makeNil()

    logVM(verbose, "opResume: payload value kind = " & $payload.kind)

    # Restore original context
    vm.activeCoroId = savedActiveCoroId
    vm.frames[savedFrameIndex] = savedFrame
    vm.currentFrame = addr vm.frames[savedFrameIndex]

    # Successful resume always returns ok(payload)
    setReg(vm, targetReg, makeOk(payload))


proc handleChannelNew*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  ## Handle opChannelNew instruction - create a new channel
  let capacity = if isInt(getReg(vm, instr.b)): int(getInt(getReg(vm, instr.b))) else: 1
  let chanId = vm.channels.len
  let channel = newChannel(chanId, capacity)
  vm.channels.add(cast[pointer](channel))
  GC_ref(channel)  # Keep alive
  setReg(vm, instr.a, V(kind: vkChannel, chanId: chanId))


proc handleChannelSend*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  ## Handle opChannelSend instruction - send to channel
  # TODO: Implement proper channel send with blocking
  discard


proc handleChannelRecv*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  ## Handle opChannelRecv instruction - receive from channel
  # TODO: Implement proper channel receive with blocking
  setReg(vm, instr.a, makeNil())


proc handleChannelClose*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  ## Handle opChannelClose instruction - close channel
  # TODO: Mark channel as closed
  discard
