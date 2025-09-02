# comparison.nim
# Comparison and logical operation instruction handlers

import std/strutils
import ../[vm, vm_types]
import ../vm_heap
import ../../common/[values, logging]

# Helper templates for comparisons
template doLt*(a, b: V): bool =
  if a.kind == vkInt and b.kind == vkInt:
    a.ival < b.ival
  elif a.kind == vkFloat and b.kind == vkFloat:
    a.fval < b.fval
  elif a.kind == vkChar and b.kind == vkChar:
    a.cval < b.cval
  elif a.kind == vkString and b.kind == vkString:
    a.sval < b.sval
  else:
    false

template doLe*(a, b: V): bool =
  if a.kind == vkInt and b.kind == vkInt:
    a.ival <= b.ival
  elif a.kind == vkFloat and b.kind == vkFloat:
    a.fval <= b.fval
  elif a.kind == vkChar and b.kind == vkChar:
    a.cval <= b.cval
  elif a.kind == vkString and b.kind == vkString:
    a.sval <= b.sval
  else:
    false

proc doEq*(vm: VirtualMachine, a, b: V): bool =
  # Handle cross-type comparisons for references and nil
  if a.kind == vkNil and b.kind == vkRef:
    return b.refId == 0
  elif a.kind == vkRef and b.kind == vkNil:
    return a.refId == 0
  elif a.kind == vkNil and b.kind == vkClosure:
    return b.closureId == 0
  elif a.kind == vkClosure and b.kind == vkNil:
    return a.closureId == 0
  elif a.kind == vkNil and b.kind == vkWeak:
    # Check if weak reference's target is freed
    if b.weakId == 0:
      return true
    let weakObj = vm.heap.getObject(b.weakId)
    if weakObj == nil:
      return true
    return weakObj.targetId <= 0  # -1 means freed, 0 means nil
  elif a.kind == vkWeak and b.kind == vkNil:
    # Check if weak reference's target is freed
    if a.weakId == 0:
      return true
    let weakObj = vm.heap.getObject(a.weakId)
    if weakObj == nil:
      return true
    return weakObj.targetId <= 0  # -1 means freed, 0 means nil

  # Same-type comparisons
  if a.kind != b.kind:
    return false
  elif a.kind == vkInt:
    return a.ival == b.ival
  elif a.kind == vkFloat:
    return a.fval == b.fval
  elif a.kind == vkBool:
    return a.bval == b.bval
  elif a.kind == vkChar:
    return a.cval == b.cval
  elif a.kind == vkString:
    return a.sval == b.sval
  elif a.kind == vkEnum:
    return a.enumTypeId == b.enumTypeId and a.enumIntVal == b.enumIntVal
  elif a.kind == vkTypeDesc:
    return a.typeDescName == b.typeDescName
  elif a.kind == vkNil:
    return true
  elif a.kind == vkRef:
    return a.refId == b.refId
  elif a.kind == vkClosure:
    return a.closureId == b.closureId
  elif a.kind == vkWeak:
    return a.weakId == b.weakId
  else:
    return false

# Comparison instructions (skip next if condition matches)
proc execEq*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  let isEqual = doEq(vm, b, c)
  let skipIfNot = instr.a != 0
  logVM(verbose, "opEq: reg" & $instr.b & " kind=" & $b.kind & " reg" & $instr.c & " kind=" & $c.kind &
        " equal=" & $isEqual & " skipIfNot=" & $skipIfNot & " willSkip=" & $(isEqual != skipIfNot))
  if isEqual != skipIfNot:
    inc pc

proc execLt*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  let bVal = getReg(vm, instr.b)
  let cVal = getReg(vm, instr.c)
  let cond = doLt(bVal, cVal)
  let skipIfNot = instr.a != 0
  let willSkip = cond != skipIfNot
  logVM(verbose, "opLt: reg" & $instr.b & "=" & $bVal & " reg" & $instr.c & "=" & $cVal &
        " cond=" & $cond & " skipIfNot=" & $skipIfNot & " willSkip=" & $willSkip)
  if willSkip:
    inc pc

proc execLtJmp*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  ## Fused less-than compare with branch offset (similar to Test/Jmp fusion)
  var b: uint8
  var c: uint8
  var offset: int
  case instr.opType
  of ifmtAx:
    b = uint8((instr.ax shr 16) and 0xFF)
    c = uint8((instr.ax shr 24) and 0xFF)
    offset = int(int16(instr.ax and 0xFFFF))
  of ifmtAsBx:
    b = instr.b
    c = instr.c
    offset = int(instr.sbx)
  else:
    return

  let bVal = getReg(vm, b)
  let cVal = getReg(vm, c)
  let cond = doLt(bVal, cVal)
  # a==0 -> branch when cond is false (skip path used in fused Lt+Jmp)
  # a!=0 -> branch when cond is true
  let branchWhen = instr.a != 0
  if cond == branchWhen:
    pc = pc + offset

proc execLe*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  let bVal = getReg(vm, instr.b)
  let cVal = getReg(vm, instr.c)
  let cond = doLe(bVal, cVal)
  let skipIfNot = instr.a != 0
  let willSkip = cond != skipIfNot
  logVM(verbose, "opLe: reg" & $instr.b & "=" & $bVal & " reg" & $instr.c & "=" & $cVal &
        " cond=" & $cond & " skipIfNot=" & $skipIfNot & " willSkip=" & $willSkip)
  if willSkip:
    inc pc

# Immediate comparison instructions
proc execEqI*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let reg = getReg(vm, uint8(instr.bx and 0xFF))
  if isInt(reg):
    let imm = int64(int8(instr.bx shr 8))
    if (getInt(reg) == imm) != (instr.a != 0):
      inc pc
  else:
    inc pc

proc execLtI*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let reg = getReg(vm, uint8(instr.bx and 0xFF))
  if isInt(reg):
    let imm = int64(int8(instr.bx shr 8))
    if (getInt(reg) < imm) != (instr.a != 0):
      inc pc
  else:
    inc pc

proc execLeI*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let reg = getReg(vm, uint8(instr.bx and 0xFF))
  if isInt(reg):
    let imm = int64(int8(instr.bx shr 8))
    if (getInt(reg) <= imm) != (instr.a != 0):
      inc pc
  else:
    inc pc

# Store comparison results in registers
proc execEqStore*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  setReg(vm, instr.a, makeBool(doEq(vm, b, c)))

proc execNeStore*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  setReg(vm, instr.a, makeBool(not doEq(vm, b, c)))

proc execLtStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  let res = makeBool(doLt(b, c))
  logVM(verbose, "opLtStore: reg" & $instr.a & " = reg" & $instr.b & "(" & $b & ") < reg" & $instr.c & "(" & $c & ") = " & $res)
  setReg(vm, instr.a, res)

proc execLeStore*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  let res = makeBool(doLe(b, c))
  logVM(verbose, "opLeStore: reg" & $instr.a & " = reg" & $instr.b & "(" & $b & ") <= reg" & $instr.c & "(" & $c & ") = " & $res)
  setReg(vm, instr.a, res)

# Type-specialized comparisons (no runtime type checks)
proc execEqInt*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  let isEqual = b == c
  let skipIfNot = instr.a != 0
  if isEqual != skipIfNot:
    inc pc

proc execLtInt*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  let cond = b < c
  let skipIfNot = instr.a != 0
  if cond != skipIfNot:
    inc pc

proc execLeInt*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  let cond = b <= c
  let skipIfNot = instr.a != 0
  if cond != skipIfNot:
    inc pc

proc execEqFloat*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  let isEqual = b == c
  let skipIfNot = instr.a != 0
  if isEqual != skipIfNot:
    inc pc

proc execLtFloat*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  let cond = b < c
  let skipIfNot = instr.a != 0
  if cond != skipIfNot:
    inc pc

proc execLeFloat*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  let cond = b <= c
  let skipIfNot = instr.a != 0
  if cond != skipIfNot:
    inc pc

# Type-specialized store comparisons
proc execEqStoreInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  vm.currentFrame.regs[instr.a] = makeBool(b == c)

proc execLtStoreInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  vm.currentFrame.regs[instr.a] = makeBool(b < c)

proc execLeStoreInt*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].ival
  let c = vm.currentFrame.regs[instr.c].ival
  vm.currentFrame.regs[instr.a] = makeBool(b <= c)

proc execEqStoreFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  vm.currentFrame.regs[instr.a] = makeBool(b == c)

proc execLtStoreFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  vm.currentFrame.regs[instr.a] = makeBool(b < c)

proc execLeStoreFloat*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = vm.currentFrame.regs[instr.b].fval
  let c = vm.currentFrame.regs[instr.c].fval
  vm.currentFrame.regs[instr.a] = makeBool(b <= c)

# Logical operations
proc execNot*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let val = getReg(vm, instr.b)
  setReg(vm, instr.a, makeBool(val.kind == vkNil or (val.kind == vkBool and not val.bval)))

proc execAnd*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  logVM(verbose, "opAnd: reg" & $instr.b & " kind=" & $b.kind & " AND reg" & $instr.c & " kind=" & $c.kind)
  # Both values should be booleans - perform logical AND
  if b.kind == vkBool and c.kind == vkBool:
    let bVal = b.bval
    let cVal = c.bval
    setReg(vm, instr.a, makeBool(bVal and cVal))
    logVM(verbose, "opAnd: " & $bVal & " AND " & $cVal & " = " & $(bVal and cVal))
  else:
    # Fallback to old behavior for non-boolean values
    if b.kind == vkNil or (b.kind == vkBool and not b.bval):
      setReg(vm, instr.a, b)
    else:
      setReg(vm, instr.a, c)

proc execOr*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let b = getReg(vm, instr.b)
  let c = getReg(vm, instr.c)
  if b.kind != vkNil and not (b.kind == vkBool and not b.bval):
    setReg(vm, instr.a, b)
  else:
    setReg(vm, instr.a, c)

# Immediate boolean operations
proc execAndI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regVal = getReg(vm, uint8(instr.bx and 0xFF))
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let immBool = imm8 != 0
  assert regVal.kind == vkBool, "opAndI expects boolean operand"
  setReg(vm, instr.a, makeBool(regVal.bval and immBool))

proc execOrI*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let regVal = getReg(vm, uint8(instr.bx and 0xFF))
  let imm8 = uint8((instr.bx shr 8) and 0xFF)
  let immBool = imm8 != 0
  assert regVal.kind == vkBool, "opOrI expects boolean operand"
  setReg(vm, instr.a, makeBool(regVal.bval or immBool))

# Membership operators
proc execIn*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let needle = getReg(vm, instr.b)
  let haystack = getReg(vm, instr.c)
  var found = false

  if isArray(haystack):
    # Check if needle is in array
    for i in 0..<haystack.aval[].len:
      if doEq(vm, needle, haystack.aval[][i]):
        found = true
        break
  elif isString(haystack):
    # Check if needle (substring) is in string
    if isString(needle):
      found = needle.sval in haystack.sval
    else:
      found = false
  else:
    found = false

  setReg(vm, instr.a, makeBool(found))

proc execNotIn*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let needle = getReg(vm, instr.b)
  let haystack = getReg(vm, instr.c)
  var found = false

  if isArray(haystack):
    # Check if needle is in array
    for i in 0..<haystack.aval[].len:
      if doEq(vm, needle, haystack.aval[][i]):
        found = true
        break
  elif isString(haystack):
    # Check if needle (substring) is in string
    if isString(needle):
      found = needle.sval in haystack.sval
    else:
      found = false
  else:
    found = false

  setReg(vm, instr.a, makeBool(not found))
