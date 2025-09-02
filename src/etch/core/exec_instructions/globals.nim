# globals.nim
# Global variable instruction handlers

import std/tables
import ../[vm, vm_types]
import ../../capabilities/replay

proc execInitGlobal*(vm: VirtualMachine, instr: Instruction, pc: int) {.inline.} =
  # Initialize global only if not already set (used in <global> function)
  # This allows C API to override compile-time initialization
  assert instr.opType == ifmtABx, "opInitGlobal uses ABx format only"
  assert instr.bx < vm.constants.len.uint16, "opInitGlobal constant index out of bounds"
  let constVal = vm.constants[instr.bx]
  assert constVal.kind == vkString, "global name constant must be a string"
  let name = constVal.sval
  if not vm.globals.hasKey(name):
    # Only set if not already present
    if vm.replayEngine != nil:
      let engine = cast[ReplayEngine](vm.replayEngine)
      if engine.isRecording:
        engine.recordDelta(ExecutionDelta(
          instructionIndex: pc,
          kind: dkGlobalWrite,
          globalName: name,
          oldGlobal: makeNil(),
          newGlobal: getReg(vm, instr.a)
        ))
    vm.globals[name] = getReg(vm, instr.a)

proc execGetGlobal*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  assert instr.opType == ifmtABx, "opGetGlobal uses ABx format only"
  assert instr.bx < vm.constants.len.uint16, "opGetGlobal constant index out of bounds"
  let constVal = vm.constants[instr.bx]
  assert constVal.kind == vkString, "global name constant must be a string"
  let name = constVal.sval
  if vm.globals.hasKey(name):
    setReg(vm, instr.a, vm.globals[name])
  else:
    setReg(vm, instr.a, makeNil())

proc execSetGlobal*(vm: VirtualMachine, instr: Instruction, pc: int) {.inline.} =
  assert instr.opType == ifmtABx, "opSetGlobal uses ABx format only"
  assert instr.bx < vm.constants.len.uint16, "opSetGlobal constant index out of bounds"
  let constVal = vm.constants[instr.bx]
  assert constVal.kind == vkString, "global name constant must be a string"
  let name = constVal.sval
  # Record delta for replay
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      let oldValue = if vm.globals.hasKey(name): vm.globals[name] else: makeNil()
      let newValue = getReg(vm, instr.a)
      engine.recordDelta(ExecutionDelta(
        instructionIndex: pc,
        kind: dkGlobalWrite,
        globalName: name,
        oldGlobal: oldValue,
        newGlobal: newValue
      ))
  vm.globals[name] = getReg(vm, instr.a)
