# move_load.nim
# Move and load instruction handlers

import ../[vm, vm_types]
import ../../common/logging


proc execMove*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let val = fastReadReg(vm, instr.b, regsLen)
  fastWriteReg(vm, instr.a, val, regsLen)
  logVM(verbose, "opMove: reg" & $instr.b & " -> reg" & $instr.a &  " value kind=" & $val.kind &
        (if val.isInt(): " int=" & $val.ival else: ""))


proc execLoadK*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Handle both ABx (constant pool) and AsBx (immediate) formats
  assert instr.opType == ifmtABx or instr.opType == ifmtAsBx, "opLoadK must be emitted with ABx or AsBx format"

  let regsLen = vm.currentFrame.regs.len
  var value: V

  if instr.opType == ifmtABx:
    logVM(verbose, "opLoadK: loading const[" & $instr.bx & "] to reg " & $instr.a)
    assert instr.bx < vm.constants.len.uint16, "opLoadK constant index out of bounds"
    value = getConst(vm, instr.bx)
  elif instr.opType == ifmtAsBx:
    logVM(verbose, "opLoadK: loading immediate " & $instr.sbx & " to reg " & $instr.a)
    value = makeInt(int64(instr.sbx))
  fastWriteReg(vm, instr.a, value, regsLen)


proc execLoadBool*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  setReg(vm, instr.a, makeBool(instr.b != 0))
  if instr.c != 0:
    inc pc  # Skip next instruction


proc execLoadNil*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  logVM(verbose, "opLoadNil: setting reg" & $instr.a & ".." & $instr.b & " to nil")
  let nilValue = makeNil()
  for i in instr.a..instr.b:
    setReg(vm, i, nilValue)
