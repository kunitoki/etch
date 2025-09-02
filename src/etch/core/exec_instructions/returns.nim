# return.nim
# Return instruction implementation for VirtualMachine

import std/strformat
import ../../common/[constants, logging]
import ../[vm, vm_types, vm_coroutine]

when not defined(deploy):
  import ../[vm_hooks]


proc execReturn*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool): bool {.inline.} =
  # Return from function
  let numResults = instr.a
  let firstResultReg = instr.b
  logVM(verbose, &"opReturn: numResults={numResults} firstResultReg={firstResultReg} frames.len={vm.frames.len}")

  when not defined(deploy):
    onReturnInstructionBegin(vm, verbose)

  # Get return value (if any)
  var returnValue = makeNil()
  if numResults > 0:
    returnValue = getReg(vm, firstResultReg)

  logVM(verbose, &"opReturn: activeCoroId={vm.activeCoroId} frames.len={vm.frames.len} returnAddr={vm.currentFrame.returnAddr}")

  # IMPORTANT: Check coroutine context BEFORE checking for main return
  # If we're in a coroutine context and this is the coroutine's top-level return, mark it as completed
  if vm.activeCoroId >= 0 and vm.activeCoroId < vm.coroutines.len:
    let coro = cast[Coroutine](vm.coroutines[vm.activeCoroId])
    logVM(verbose, "Return in coroutine context: activeCoroId=" & $vm.activeCoroId & ", coro.state=" & (if coro != nil: $coro.state else: "nil") & ", returnAddr=" & $vm.currentFrame.returnAddr)
    if coro != nil and coro.state == csRunning:
      # Check if this is the coroutine's function returning (not a nested call)
      if vm.currentFrame.returnAddr == -1:
        # Top-level coroutine return
        logVM(verbose, &"Setting coroutine {vm.activeCoroId} to csCompleted with return value")
        coro.state = csCompleted
        coro.returnValue = returnValue
        # Don't continue execution, let handleResume restore the context
        return false

  # Check if we're returning from main (only 1 frame)
  if vm.frames.len <= 1:
    return false;

  # Pop frame
  let returnAddr = vm.currentFrame.returnAddr
  let resultReg = vm.currentFrame.baseReg
  let poppedFrame = vm.frames.pop()

  when not defined(deploy):
    onReturnInstructionEnd(vm, poppedFrame, pc, verbose)

  # Restore previous frame
  if vm.frames.len <= 0:
    return false

  # Store return value in the result register (only if function returns a value)
  vm.currentFrame = addr vm.frames[^1]
  if numResults > 0:
    setReg(vm, resultReg, returnValue)

  # Continue execution after the call
  # Note: pc will be incremented at the start of the loop, so we need to decrement by 1
  pc = returnAddr - 1
  return true
