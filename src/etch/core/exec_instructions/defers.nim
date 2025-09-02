# defers.nim
# Defer mechanism instruction handlers

import ../vm_types
import ../../common/logging


proc execPushDefer*(vm: VirtualMachine, instr: Instruction, pc: int, verbose: bool) {.inline.} =
  # Register a defer block by pushing its PC location to the defer stack
  let deferBodyOffset = instr.sbx
  let deferBodyPC = pc + deferBodyOffset
  vm.currentFrame.deferStack.add(deferBodyPC)
  logVM(verbose, "opPushDefer: registered defer at PC " & $deferBodyPC)


proc execExecDefers*(vm: VirtualMachine, pc: var int, verbose: bool) {.inline.} =
  # Execute all registered defers in reverse order (LIFO)
  logVM(verbose, "opExecDefers: executing " & $vm.currentFrame.deferStack.len & " defers")
  if vm.currentFrame.deferStack.len > 0:
    # Pop the first defer and jump to it
    let deferPC = vm.currentFrame.deferStack.pop()
    logVM(verbose, "  Executing defer at PC " & $deferPC)

    # Save current PC to return after defer execution
    vm.currentFrame.deferReturnPC = pc
    # Jump to defer body (subtract 1 because pc will be incremented)
    pc = deferPC - 1


proc execDeferEnd*(vm: VirtualMachine, pc: var int, verbose: bool) {.inline.} =
  # End of defer body - check if there are more defers to execute
  if vm.currentFrame.deferStack.len > 0:
    # More defers to execute - pop and jump to next one
    let deferPC = vm.currentFrame.deferStack.pop()
    logVM(verbose, "opDeferEnd: executing next defer at PC " & $deferPC)
    pc = deferPC - 1
  else:
    # No more defers - return to saved PC
    logVM(verbose, "opDeferEnd: all defers executed, returning to PC " & $vm.currentFrame.deferReturnPC)
    pc = vm.currentFrame.deferReturnPC
