# fused.nim
# Fused operation instruction handlers (aggressive optimizations)

import std/[tables, strformat]
import ../[vm, vm_types]
import ../vm_heap
import ../../common/logging
import ./arithmetic
from ./arrays import setArrayElement


type
  FieldArithmeticOp = enum
    faAdd, faSub, faMul, faDiv, faMod


proc applyFieldArithmetic(base, operand: V, op: FieldArithmeticOp): V {.inline.} =
  case op
  of faAdd:
    doAdd(base, operand)
  of faSub:
    doSub(base, operand)
  of faMul:
    doMul(base, operand)
  of faDiv:
    doDiv(base, operand)
  of faMod:
    doMod(base, operand)


proc execLoadFieldOp(vm: VirtualMachine, instr: Instruction, op: FieldArithmeticOp, verbose: bool) {.inline.} =
  ## Shared implementation for fused field arithmetic instructions.
  let objVal = getReg(vm, instr.a)
  let rhsVal = getReg(vm, instr.b)
  let fieldName = vm.constants[instr.c].sval

  var baseVal = makeNil()
  var newVal = makeNil()
  var updated = false

  let compute = proc(val: V): V =
    applyFieldArithmetic(val, rhsVal, op)

  if objVal.kind == vkRef:
    let heapObj = vm.heap.getObject(objVal.refId)
    if heapObj != nil and heapObj.kind == hokTable:
      if fieldName in heapObj.fields:
        baseVal = heapObj.fields[fieldName]
      newVal = compute(baseVal)
      heapObj.fields[fieldName] = newVal
      if newVal.isHeapObject:
        vm.heap.trackRef(objVal.refId, newVal)
      updated = true
    else:
      logVM(verbose, "opLoadFieldOp: ERROR - heap object not found or not a table")
  elif objVal.kind == vkTable:
    var table = objVal
    if fieldName in table.tval:
      baseVal = table.tval[fieldName]
    newVal = compute(baseVal)
    table.tval[fieldName] = newVal
    setReg(vm, instr.a, table)
    updated = true
  else:
    logVM(verbose, "opLoadFieldOp: ERROR - target is not a table or heap ref")

  if not updated:
    newVal = makeNil()

  logVM(verbose, &"opLoadFieldOp: field '{fieldName}' updated via {op}, new value kind={newVal.kind}")


proc execArrayGetSetOp(vm: VirtualMachine, instr: Instruction, op: FieldArithmeticOp, verbose: bool) {.inline.} =
  ## Shared implementation for fused array[i] op= value instructions.
  let arrPtr = vm.getRegPtr(instr.a)
  let idxVal = getReg(vm, instr.b)
  let rhsVal = getReg(vm, instr.c)
  let idx = int(idxVal.ival)

  assert arrPtr[].kind == vkArray, "opArrayGetSet expects array target"
  assert idxVal.isInt(), "opArrayGetSet expects integer index"
  assert idx >= 0 and idx < arrPtr[].aval[].len,
    &"opArrayGetSet invalid index {idx} for array of length {arrPtr[].aval[].len}"

  var baseVal = arrPtr[].aval[][idx]
  let newVal = applyFieldArithmetic(baseVal, rhsVal, op)
  setArrayElement(vm, arrPtr[], idx, newVal)

  logVM(verbose, &"opArrayGetSet: R[{instr.a}][{idx}] updated via {op} -> kind={newVal.kind}")


proc execMulAdd*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] * R[C] + R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opMulAdd expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt(getInt(b) * getInt(c) + getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat(getFloat(b) * getFloat(c) + getFloat(d)))

proc execSubSub*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] - R[C] - R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opSubSub expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt(getInt(b) - getInt(c) - getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat(getFloat(b) - getFloat(c) - getFloat(d)))

proc execMulSub*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] * R[C] - R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opMulSub expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt(getInt(b) * getInt(c) - getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat(getFloat(b) * getFloat(c) - getFloat(d)))

proc execSubMul*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] - R[C] * R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opSubMul expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt(getInt(b) - getInt(c) * getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat(getFloat(b) - getFloat(c) * getFloat(d)))

proc execDivAdd*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] / R[C] + R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opDivAdd expects numeric operands"

  if isInt(b):
    if getInt(c) != 0:
      setReg(vm, instr.a, makeInt(getInt(b) div getInt(c) + getInt(d)))
    else:
      setReg(vm, instr.a, makeNil())
  else:
    if getFloat(c) != 0.0:
      setReg(vm, instr.a, makeFloat(getFloat(b) / getFloat(c) + getFloat(d)))
    else:
      setReg(vm, instr.a, makeNil())

proc execAddSub*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B] + R[C] - R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opAddSub expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt(getInt(b) + getInt(c) - getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat(getFloat(b) + getFloat(c) - getFloat(d)))

proc execAddMul*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = (R[B] + R[C]) * R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opAddMul expects numeric operands"

  if isInt(b):
    setReg(vm, instr.a, makeInt((getInt(b) + getInt(c)) * getInt(d)))
  else:
    setReg(vm, instr.a, makeFloat((getFloat(b) + getFloat(c)) * getFloat(d)))

proc execSubDiv*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = (R[B] - R[C]) / R[D]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

  assert (isInt(b) and isInt(c) and isInt(d)) or (isFloat(b) and isFloat(c) and isFloat(d)),
    "opSubDiv expects numeric operands"

  if isInt(b):
    if getInt(d) != 0:
      setReg(vm, instr.a, makeInt((getInt(b) - getInt(c)) div getInt(d)))
    else:
      setReg(vm, instr.a, makeNil())
  else:
    if getFloat(d) != 0.0:
      setReg(vm, instr.a, makeFloat((getFloat(b) - getFloat(c)) / getFloat(d)))
    else:
      setReg(vm, instr.a, makeNil())

proc execLoadAddStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execLoadFieldOp(vm, instr, faAdd, verbose)

proc execLoadSubStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execLoadFieldOp(vm, instr, faSub, verbose)

proc execLoadMulStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execLoadFieldOp(vm, instr, faMul, verbose)

proc execLoadDivStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execLoadFieldOp(vm, instr, faDiv, verbose)

proc execLoadModStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execLoadFieldOp(vm, instr, faMod, verbose)

proc execGetAddSet*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execArrayGetSetOp(vm, instr, faAdd, verbose)

proc execGetSubSet*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execArrayGetSetOp(vm, instr, faSub, verbose)

proc execGetMulSet*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execArrayGetSetOp(vm, instr, faMul, verbose)

proc execGetDivSet*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execArrayGetSetOp(vm, instr, faDiv, verbose)

proc execGetModSet*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  execArrayGetSetOp(vm, instr, faMod, verbose)

proc execAddAddInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a].ival += vm.currentFrame.regs[instr.b].ival + vm.currentFrame.regs[instr.c].ival

proc execAddAddFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a].fval += vm.currentFrame.regs[instr.b].fval + vm.currentFrame.regs[instr.c].fval

proc execMulAddInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[b].ival * vm.currentFrame.regs[c].ival + vm.currentFrame.regs[d].ival)

proc execMulAddFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[b].fval * vm.currentFrame.regs[c].fval + vm.currentFrame.regs[d].fval)

proc execSubSubInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[b].ival - vm.currentFrame.regs[c].ival - vm.currentFrame.regs[d].ival)

proc execSubSubFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[b].fval - vm.currentFrame.regs[c].fval - vm.currentFrame.regs[d].fval)

proc execMulSubInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[b].ival * vm.currentFrame.regs[c].ival - vm.currentFrame.regs[d].ival)

proc execMulSubFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[b].fval * vm.currentFrame.regs[c].fval - vm.currentFrame.regs[d].fval)

proc execSubMulInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[b].ival - vm.currentFrame.regs[c].ival * vm.currentFrame.regs[d].ival)

proc execSubMulFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[b].fval - vm.currentFrame.regs[c].fval * vm.currentFrame.regs[d].fval)

proc execDivAddInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: (vm.currentFrame.regs[b].ival div vm.currentFrame.regs[c].ival) + vm.currentFrame.regs[d].ival)

proc execDivAddFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: (vm.currentFrame.regs[b].fval / vm.currentFrame.regs[c].fval) + vm.currentFrame.regs[d].fval)

proc execAddSubInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[b].ival + vm.currentFrame.regs[c].ival - vm.currentFrame.regs[d].ival)

proc execAddSubFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[b].fval + vm.currentFrame.regs[c].fval - vm.currentFrame.regs[d].fval)

proc execAddMulInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: (vm.currentFrame.regs[b].ival + vm.currentFrame.regs[c].ival) * vm.currentFrame.regs[d].ival)

proc execAddMulFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: (vm.currentFrame.regs[b].fval + vm.currentFrame.regs[c].fval) * vm.currentFrame.regs[d].fval)

proc execSubDivInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: (vm.currentFrame.regs[b].ival - vm.currentFrame.regs[c].ival) div vm.currentFrame.regs[d].ival)

proc execSubDivFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = uint8(instr.ax and 0xFF)
  let c = uint8((instr.ax shr 8) and 0xFF)
  let d = uint8((instr.ax shr 16) and 0xFF)
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: (vm.currentFrame.regs[b].fval - vm.currentFrame.regs[c].fval) / vm.currentFrame.regs[d].fval)

proc execAddAdd*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let a = fastReadReg(vm, instr.a, regsLen)
  let b = fastReadReg(vm, instr.b, regsLen)
  let c = fastReadReg(vm, instr.c, regsLen)
  let tmp = doAdd(a, b)
  fastWriteReg(vm, instr.a, doAdd(tmp, c), regsLen)
