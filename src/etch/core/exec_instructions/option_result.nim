# option_result.nim
# Option and Result type instruction handlers

import ../[vm, vm_types]
import ../../common/[logging]


proc execWrapSome*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # Wrap value as some
  let val = getReg(vm, instr.b)
  setReg(vm, instr.a, makeSome(val))


proc execLoadNone*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # Load none value
  setReg(vm, instr.a, makeNone())


proc execWrapOk*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # Wrap value as ok
  let val = getReg(vm, instr.b)
  setReg(vm, instr.a, makeOk(val))


proc execWrapError*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # Wrap value as error
  let val = getReg(vm, instr.b)
  setReg(vm, instr.a, makeError(val))


proc execUnwrapOption*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Unwrap Option value
  let val = getReg(vm, instr.b)
  if val.isSome():
    let unwrapped = val.unwrapOption()
    setReg(vm, instr.a, unwrapped)
    logVM(verbose, "opUnwrapOption: unwrapped some value to reg " & $instr.a & " value: " & $unwrapped)
  else:
    setReg(vm, instr.a, makeNil())
    logVM(verbose, "opUnwrapOption: value was none, set nil in reg " & $instr.a)


proc execUnwrapResult*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # Unwrap Result value
  let val = getReg(vm, instr.b)
  if val.isOk() or val.isError():
    setReg(vm, instr.a, val.unwrapResult())
  else:
    setReg(vm, instr.a, makeNil())
