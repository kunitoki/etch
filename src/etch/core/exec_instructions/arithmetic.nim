# arithmetic.nim
# Arithmetic instruction handlers

import std/math
import ../[vm, vm_types]
import ../../common/values

# Optimized arithmetic operations with type specialization
template doAdd*(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival + b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval + b.fval)
  elif a.kind == vkString and b.kind == vkString:
    var resultStr = newStringOfCap(a.sval.len + b.sval.len)
    resultStr.add(a.sval)
    resultStr.add(b.sval)
    makeString(resultStr)
  elif a.kind == vkArray and b.kind == vkArray:
    var resultArr = newSeqOfCap[V](a.aval[].len + b.aval[].len)
    resultArr.add(a.aval[])
    resultArr.add(b.aval[])
    makeArray(resultArr)
  else:
    makeNil()

template doSub*(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival - b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval - b.fval)
  else:
    makeNil()

template doMul*(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival * b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval * b.fval)
  else:
    makeNil()

template doDiv*(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival div b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval / b.fval)
  else:
    makeNil()

template doMod*(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival mod b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    if b.fval != 0.0:
      makeFloat(a.fval mod b.fval)
    else:
      makeNil()
  else:
    makeNil()

# Generic arithmetic operations (with type checking)
proc execAdd*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  if likely(int(instr.b) < regsLen and int(instr.c) < regsLen and
            vm.currentFrame.regs[instr.b].kind == vkInt and vm.currentFrame.regs[instr.c].kind == vkInt):
    let left = vm.currentFrame.regs[instr.b]
    let right = vm.currentFrame.regs[instr.c]
    if left.kind == vkInt and right.kind == vkInt:
      let resultVal = makeInt(left.ival + right.ival)
      fastWriteReg(vm, instr.a, resultVal, regsLen)
      return
  let left = fastReadReg(vm, instr.b, regsLen)
  let right = fastReadReg(vm, instr.c, regsLen)
  fastWriteReg(vm, instr.a, doAdd(left, right), regsLen)

proc execSub*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  if likely(int(instr.b) < regsLen and int(instr.c) < regsLen and
            vm.currentFrame.regs[instr.b].kind == vkInt and vm.currentFrame.regs[instr.c].kind == vkInt):
    let left = vm.currentFrame.regs[instr.b]
    let right = vm.currentFrame.regs[instr.c]
    if left.kind == vkInt and right.kind == vkInt:
      let resultVal = makeInt(left.ival - right.ival)
      fastWriteReg(vm, instr.a, resultVal, regsLen)
      return
  let left = fastReadReg(vm, instr.b, regsLen)
  let right = fastReadReg(vm, instr.c, regsLen)
  fastWriteReg(vm, instr.a, doSub(left, right), regsLen)

proc execMul*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  if likely(int(instr.b) < regsLen and int(instr.c) < regsLen and
            vm.currentFrame.regs[instr.b].kind == vkInt and vm.currentFrame.regs[instr.c].kind == vkInt):
    let left = vm.currentFrame.regs[instr.b]
    let right = vm.currentFrame.regs[instr.c]
    if left.kind == vkInt and right.kind == vkInt:
      let resultVal = makeInt(left.ival * right.ival)
      fastWriteReg(vm, instr.a, resultVal, regsLen)
      return
  let left = fastReadReg(vm, instr.b, regsLen)
  let right = fastReadReg(vm, instr.c, regsLen)
  fastWriteReg(vm, instr.a, doMul(left, right), regsLen)

proc execDiv*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  if likely(int(instr.b) < regsLen and int(instr.c) < regsLen and
            vm.currentFrame.regs[instr.b].kind == vkInt and vm.currentFrame.regs[instr.c].kind == vkInt):
    let left = vm.currentFrame.regs[instr.b]
    let right = vm.currentFrame.regs[instr.c]
    if left.kind == vkInt and right.kind == vkInt:
      let resultVal = makeInt(left.ival div right.ival)
      fastWriteReg(vm, instr.a, resultVal, regsLen)
      return
  let left = fastReadReg(vm, instr.b, regsLen)
  let right = fastReadReg(vm, instr.c, regsLen)
  fastWriteReg(vm, instr.a, doDiv(left, right), regsLen)

proc execMod*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  if likely(int(instr.b) < regsLen and int(instr.c) < regsLen and
            vm.currentFrame.regs[instr.b].kind == vkInt and vm.currentFrame.regs[instr.c].kind == vkInt):
    let left = vm.currentFrame.regs[instr.b]
    let right = vm.currentFrame.regs[instr.c]
    if left.kind == vkInt and right.kind == vkInt:
      let resultVal = makeInt(left.ival mod right.ival)
      fastWriteReg(vm, instr.a, resultVal, regsLen)
      return
  let left = fastReadReg(vm, instr.b, regsLen)
  let right = fastReadReg(vm, instr.c, regsLen)
  fastWriteReg(vm, instr.a, doMod(left, right), regsLen)

# Type-specialized integer arithmetic (no type checks, direct operations)
proc execAddInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[instr.b].ival + vm.currentFrame.regs[instr.c].ival)

proc execSubInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[instr.b].ival - vm.currentFrame.regs[instr.c].ival)

proc execMulInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[instr.b].ival * vm.currentFrame.regs[instr.c].ival)

proc execDivInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[instr.b].ival div vm.currentFrame.regs[instr.c].ival)

proc execModInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkInt, ival: vm.currentFrame.regs[instr.b].ival mod vm.currentFrame.regs[instr.c].ival)

# Type-specialized float arithmetic (no type checks, direct operations)
proc execAddFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[instr.b].fval + vm.currentFrame.regs[instr.c].fval)

proc execSubFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[instr.b].fval - vm.currentFrame.regs[instr.c].fval)

proc execMulFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[instr.b].fval * vm.currentFrame.regs[instr.c].fval)

proc execDivFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[instr.b].fval / vm.currentFrame.regs[instr.c].fval)

proc execModFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  vm.currentFrame.regs[instr.a] =
    V(kind: vkFloat, fval: vm.currentFrame.regs[instr.b].fval mod vm.currentFrame.regs[instr.c].fval)

proc execPow*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let base = fastReadReg(vm, instr.b, regsLen)
  let exp = fastReadReg(vm, instr.c, regsLen)
  if isFloat(base) and isFloat(exp):
    fastWriteReg(vm, instr.a, makeFloat(pow(getFloat(base), getFloat(exp))), regsLen)
  else:
    fastWriteReg(vm, instr.a, makeNil(), regsLen)

# Immediate arithmetic operations (with immediate values)
proc execAddI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let reg = fastReadReg(vm, uint8(instr.bx and 0xFF), regsLen)
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
  fastWriteReg(vm, instr.a, makeInt(getInt(reg) + imm), regsLen)

proc execSubI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let reg = fastReadReg(vm, uint8(instr.bx and 0xFF), regsLen)
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
  fastWriteReg(vm, instr.a, makeInt(getInt(reg) - imm), regsLen)

proc execMulI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let reg = fastReadReg(vm, uint8(instr.bx and 0xFF), regsLen)
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
  fastWriteReg(vm, instr.a, makeInt(getInt(reg) * imm), regsLen)

proc execDivI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let reg = fastReadReg(vm, uint8(instr.bx and 0xFF), regsLen)
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
  fastWriteReg(vm, instr.a, makeInt(getInt(reg) div imm), regsLen)

proc execModI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let reg = fastReadReg(vm, uint8(instr.bx and 0xFF), regsLen)
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
  fastWriteReg(vm, instr.a, makeInt(getInt(reg) mod imm), regsLen)

proc execUnm*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regsLen = vm.currentFrame.regs.len
  let val = fastReadReg(vm, instr.b, regsLen)
  if isInt(val):
    fastWriteReg(vm, instr.a, makeInt(-getInt(val)), regsLen)
  elif isFloat(val):
    fastWriteReg(vm, instr.a, makeFloat(-getFloat(val)), regsLen)
  else:
    fastWriteReg(vm, instr.a, makeNil(), regsLen)
