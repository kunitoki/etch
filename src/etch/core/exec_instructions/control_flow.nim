# control_flow.nim
# Control flow instruction handlers
# Note: opCall and opReturn are left in vm_execution.nim due to tight coupling with
# frame management, debugger, profiler, and other VM internals

import std/strformat
import ../[vm, vm_types]
import ../../common/[logging]
from ./comparison import doLt, doLe, doEq

# Unconditional jump
proc execJmp*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  pc += int(instr.sbx)

# Conditional test and skip
proc execTest*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  let val = getReg(vm, instr.a)
  let isTrue = val.kind != vkNil and not (val.kind == vkBool and not val.bval)
  logVM(verbose, "opTest: reg" & $instr.a & " val=" & $val & " isTrue=" & $isTrue & " expected=" & $(instr.c != 0) & " skip=" & $(isTrue != (instr.c != 0)))
  if isTrue != (instr.c != 0):
    inc pc

# Test and set (short-circuit evaluation)
proc execTestSet*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let val = getReg(vm, instr.b)
  let isTrue = val.kind != vkNil and not (val.kind == vkBool and not val.bval)
  if isTrue == (instr.c != 0):
    setReg(vm, instr.a, val)
  else:
    inc pc

# Test value type tag
proc execTestTag*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  # Test if register has specific tag
  # Skip next instruction if tags MATCH (for match expressions)
  let val = getReg(vm, instr.a)
  let expectedKind = VKind(instr.b)
  let actualKind = val.kind
  logVM(verbose, "opTestTag: reg=" & $instr.a & " expected=" & $expectedKind & " actual=" & $actualKind & " match=" & $(actualKind == expectedKind))
  if actualKind == expectedKind:
    logVM(verbose, "opTestTag: tags match, skipping next instruction (PC " & $pc & " -> " & $(pc + 1) & ")")
    inc pc

# For loop iteration (increment and test)
proc execForLoop*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  # Increment loop variable and test
  # Fast path for integer loops (most common case)
  if vm.currentFrame.regs[instr.a].kind == vkInt and
     vm.currentFrame.regs[instr.a + 1].kind == vkInt and
     vm.currentFrame.regs[instr.a + 2].kind == vkInt:
    let stepVal = vm.currentFrame.regs[instr.a + 2].ival
    vm.currentFrame.regs[instr.a].ival += stepVal
    let newIdx = vm.currentFrame.regs[instr.a].ival
    let limitVal = vm.currentFrame.regs[instr.a + 1].ival

    logVM(verbose, &"ForLoop: R{instr.a}(idx)={newIdx}, R{instr.a+1}(limit)={limitVal}, R{instr.a+2}(step)={stepVal}, sbx={instr.sbx}")

    if stepVal > 0:
      if newIdx < limitVal:
        logVM(verbose, &"  -> Jumping to PC {pc + int(instr.sbx)} (continuing loop)")
        pc += int(instr.sbx)
      else:
        logVM(verbose, &"  -> NOT jumping, exiting loop (idx {newIdx} >= limit {limitVal})")
    else:
      if newIdx > limitVal:
        pc += int(instr.sbx)
      else:
        logVM(verbose, &"  -> NOT jumping, exiting loop")
  else:
    # Fallback for non-integer loops
    let idx = getReg(vm, instr.a)
    let limit = getReg(vm, instr.a + 1)
    let step = getReg(vm, instr.a + 2)

    if verbose:
      logVM(verbose, "ForLoop: idx=" & (if idx.isInt(): $idx.ival else: "nil/non-int") &
            " limit=" & (if limit.isInt(): $limit.ival else: "nil/non-int") &
            " step=" & (if step.isInt(): $step.ival else: "nil/non-int") &
            " sbx=" & $instr.sbx)

    if idx.isInt() and limit.isInt() and step.isInt():
      let newIdx = idx.ival + step.ival
      setReg(vm, instr.a, makeInt(newIdx))

      if step.ival > 0:
        if newIdx < limit.ival:
          pc += int(instr.sbx)
      else:
        if newIdx > limit.ival:
          pc += int(instr.sbx)

proc execForIntPrep*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Specialized prep for integer for-loops: if starting idx already outside range, skip body
  let idxVal = vm.currentFrame.regs[instr.a].ival
  let limitVal = vm.currentFrame.regs[instr.a + 1].ival
  let stepVal = vm.currentFrame.regs[instr.a + 2].ival
  if likely(stepVal > 0):
    if idxVal >= limitVal:
      pc += int(instr.sbx)
  else:
    if idxVal <= limitVal:
      pc += int(instr.sbx)

proc execForIntLoop*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  ## Specialized loop for contiguous int registers [idx, limit, step]
  let idxPtr = addr vm.currentFrame.regs[instr.a]
  let limitPtr = addr vm.currentFrame.regs[instr.a + 1]
  let stepPtr = addr vm.currentFrame.regs[instr.a + 2]
  idxPtr.ival += stepPtr.ival
  let newIdx = idxPtr.ival
  if likely(stepPtr.ival > 0):
    if newIdx < limitPtr.ival:
      pc += int(instr.sbx)
  else:
    if newIdx > limitPtr.ival:
      pc += int(instr.sbx)

# For loop preparation (check if loop should run)
proc execForPrep*(vm: VirtualMachine, instr: Instruction, pc: var int, verbose: bool) {.inline.} =
  # Prepare for loop - adjust initial value and check if loop should run
  let idx = getReg(vm, instr.a)
  let limit = getReg(vm, instr.a + 1)
  let step = getReg(vm, instr.a + 2)

  # Debug output
  logVM(verbose,
        "ForPrep: idx=" & (if idx.isInt(): $idx.ival else: "?") &
        " limit=" & (if limit.isInt(): $limit.ival else: "?") &
        " step=" & (if step.isInt(): $step.ival else: "?") &
        " sbx=" & $instr.sbx)

  if idx.isInt() and limit.isInt() and step.isInt():
    # Check if loop should run at all based on initial values
    let stepVal = step.ival
    let idxVal = idx.ival
    let limitVal = limit.ival

    logVM(verbose, "  -> Initial idx=" & $idxVal & " limit=" & $limitVal & " step=" & $stepVal)

    if likely(stepVal > 0):
      if unlikely(idxVal >= limitVal):
        pc += int(instr.sbx)  # Skip loop
    else:
      if unlikely(idxVal <= limitVal):
        pc += int(instr.sbx)  # Skip loop

# Fused compare and jump
proc execCmpJmp*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  # Combined compare and jump
  # A: Comparison type (0=Eq, 1=Ne, 2=Lt, 3=Le, 4=Gt, 5=Ge)
  # Ax: [Offset:16][C:8][B:8]
  let b = getReg(vm, uint8(instr.ax and 0xFF))
  let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
  let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)

  var condition = false
  case instr.a
  of 0: condition = doEq(vm, b, c)      # Eq
  of 1: condition = not doEq(vm, b, c)  # Ne
  of 2: condition = doLt(b, c)          # Lt
  of 3: condition = doLe(b, c)          # Le
  of 4: condition = doLt(c, b)          # Gt (swapped Lt)
  of 5: condition = doLe(c, b)          # Ge (swapped Le)
  else: discard

  if condition:
    pc += int(jmpOffset)

proc execCmpJmpInt*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[uint8(instr.ax and 0xFF)].ival
  let c = vm.currentFrame.regs[uint8((instr.ax shr 8) and 0xFF)].ival
  let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)

  var condition = false
  case instr.a
  of 0: condition = b == c      # Eq
  of 1: condition = b != c      # Ne
  of 2: condition = b < c       # Lt
  of 3: condition = b <= c      # Le
  of 4: condition = b > c       # Gt
  of 5: condition = b >= c      # Ge
  else: discard

  if condition:
    pc += int(jmpOffset)

proc execCmpJmpFloat*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  let b = vm.currentFrame.regs[uint8(instr.ax and 0xFF)].fval
  let c = vm.currentFrame.regs[uint8((instr.ax shr 8) and 0xFF)].fval
  let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)

  var condition = false
  case instr.a
  of 0: condition = b == c      # Eq
  of 1: condition = b != c      # Ne
  of 2: condition = b < c       # Lt
  of 3: condition = b <= c      # Le
  of 4: condition = b > c       # Gt
  of 5: condition = b >= c      # Ge
  else: discard

  if condition:
    pc += int(jmpOffset)

# Fused increment and test (common loop pattern)
proc execIncTest*(vm: VirtualMachine, instr: Instruction, pc: var int) {.inline.} =
  # Increment and test (common loop pattern)
  var val = getReg(vm, instr.a)
  if isInt(val):
    let newVal = getInt(val) + 1
    setReg(vm, instr.a, makeInt(newVal))
    if newVal < int64(instr.bx):
      pc += int(instr.sbx)
