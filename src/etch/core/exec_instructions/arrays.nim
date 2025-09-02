# arrays.nim
# Array and string operation instruction handlers

import std/[strformat]
import ../[vm, vm_types]
import ../vm_heap
import ../../common/[logging]


template retainArrayValue(vm: VirtualMachine, val: sink V) =
  vm.heap.retainHeapValue(val)


template releaseArrayValue(vm: VirtualMachine, val: sink V) =
  vm.heap.releaseHeapValue(val)


proc tryGetHeapArrayElement(vm: VirtualMachine, arr: V, idx: int, resultReg: uint8,
                            regsLen: int, verbose: bool, opName: string): bool {.inline.} =
  # Helper for getting element from ref[array[T]]. Returns true if handled (arr was a ref), false otherwise.
  if likely(not arr.isRef):
    return false

  let heapObj = vm.heap.getObject(arr.refId)
  if unlikely(heapObj == nil or heapObj.kind != hokArray):
    return false

  assert idx >= 0 and idx < heapObj.elements.len,
    &"{opName}: heap array #{arr.refId}[{idx}] out of bounds (len {heapObj.elements.len})"

  let elem = heapObj.elements[idx]
  fastWriteReg(vm, resultReg, elem, regsLen)

  logVM(verbose, &"{opName}: heap array #{arr.refId}[{idx}] -> R[{resultReg}]")
  return true


proc trySetHeapArrayElement(vm: VirtualMachine, arr: V, idx: int, newVal: V, verbose: bool, opName: string): bool {.inline.} =
  # Helper for setting element in ref[array[T]]. Returns true if handled (arr was a ref), false otherwise.
  if likely(not arr.isRef):
    return false

  let heapObj = vm.heap.getObject(arr.refId)
  if unlikely(heapObj == nil or heapObj.kind != hokArray):
    return false

  assert idx >= 0 and idx < heapObj.elements.len,
    &"{opName}: heap array #{arr.refId}[{idx}] out of bounds (len {heapObj.elements.len})"

  releaseArrayValue(vm, heapObj.elements[idx])
  heapObj.elements[idx] = newVal
  retainArrayValue(vm, newVal)

  logVM(verbose, &"{opName}: heap array #{arr.refId}[{idx}] = value")
  return true


proc setArrayElement*(vm: VirtualMachine, arr: var V, idx: int, newVal: V) {.inline.} =
  # Set element in direct array (bounds already proven by prover)
  assert arr.kind == vkArray, "setArrayElement expects array target"
  assert idx >= 0 and idx < arr.aval[].len, &"setArrayElement index {idx} out of bounds (len {arr.aval[].len})"

  let oldVal = arr.aval[][idx]
  releaseArrayValue(vm, oldVal)
  arr.aval[][idx] = newVal
  retainArrayValue(vm, newVal)


proc execNewArray*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Create array with actual size, initialized to nil
  var nilSeq = newSeq[V](instr.bx)
  let nilValue = makeNil()
  for i in 0 ..< nilSeq.len:
    nilSeq[i] = nilValue
  setReg(vm, instr.a, makeArray(nilSeq))

  logVM(verbose, &"opNewArray: created array of size {instr.bx} in R[{instr.a}]")


proc execGetIndex*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Optimized: check array fast path first (most common case)
  let arr = getReg(vm, instr.b)
  let idx = getReg(vm, instr.c)
  let i = idx.ival
  let regsLen = vm.currentFrame.regs.len

  # Fast path: direct array access
  if likely(arr.kind == vkArray):
    assert i >= 0 and i < arr.aval[].len,
      &"opGetIndex array out of bounds: index {i} len {arr.aval[].len}"
    let elem = arr.aval[][int(i)]
    fastWriteReg(vm, instr.a, elem, regsLen)
    logVM(verbose, &"execGetIndex: R[{instr.b}][{i}] -> R{instr.a}")
    return

  # String access
  if likely(arr.kind == vkString):
    assert i >= 0 and i < arr.sval.len,
      &"opGetIndex string out of bounds: index {i} len {arr.sval.len}"
    fastWriteReg(vm, instr.a, makeChar(arr.sval[int(i)]), regsLen)
    logVM(verbose, &"execGetIndex: R[{instr.b}][{i}] -> R{instr.a}")
    return

  # Heap array access (slow path)
  if tryGetHeapArrayElement(vm, arr, i, instr.a, regsLen, verbose, "execGetIndex"):
    return

  assert false, "opGetIndex expects array, string, or ref[array]"


proc execSetIndex*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Optimized: check array fast path first (most common case)
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = getReg(vm, instr.b)
  let i = idx.ival
  let newVal = getReg(vm, instr.c)

  # Fast path: direct array set
  if likely(arrPtr[].kind == vkArray):
    assert idx.kind == vkInt, "opSetIndex expects integer index"
    setArrayElement(vm, arrPtr[], int(i), newVal)
    logVM(verbose, &"execSetIndex: R[{instr.a}][{i}] = R[{instr.c}]")
    return

  # Slow path: heap array
  if trySetHeapArrayElement(vm, arrPtr[], i, newVal, verbose, "execSetIndex"):
    return

  assert false, "opSetIndex expects array or ref[array] target"


proc execGetIndexI*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let arr = getReg(vm, uint8(instr.bx and 0xFF))
  let idx = int(instr.bx shr 8)
  let regsLen = vm.currentFrame.regs.len

  if tryGetHeapArrayElement(vm, arr, idx, instr.a, regsLen, verbose, "opGetIndexI"):
    return

  if likely(arr.kind == vkArray):
    assert idx >= 0 and idx < arr.aval[].len,
      &"opGetIndexI array out of bounds: index {idx} len {arr.aval[].len}"
    let elem = arr.aval[][idx]
    fastWriteReg(vm, instr.a, elem, regsLen)
  else:
    assert arr.kind == vkString, "opGetIndexI expects array, string, or ref[array]"
    assert idx >= 0 and idx < arr.sval.len,
      &"opGetIndexI string out of bounds: index {idx} len {arr.sval.len}"
    fastWriteReg(vm, instr.a, makeChar(arr.sval[idx]), regsLen)

  logVM(verbose, &"execGetIndexI: R[{(instr.bx and 0xFF)}][{idx}] -> R{instr.a}")


proc execSetIndexI*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = int(instr.bx and 0xFF)
  let newVal = getReg(vm, uint8(instr.bx shr 8))

  if trySetHeapArrayElement(vm, arrPtr[], idx, newVal, verbose, "execSetIndexI"):
    return

  assert arrPtr[].kind == vkArray, "opSetIndexI expects array or ref[array] target"
  setArrayElement(vm, arrPtr[], idx, newVal)
  logVM(verbose, &"execSetIndexI: R[{instr.a}][{idx}] = R[{(instr.bx shr 8)}]")


proc execGetIndexInt*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized array indexing for integer arrays
  # Optimized hot path: direct array access first (most common case)
  let arr = getReg(vm, instr.b)
  let idx = getReg(vm, instr.c)
  let i = int(idx.ival)
  let regsLen = vm.currentFrame.regs.len

  # Fast path: direct array access (no heap indirection)
  if likely(arr.kind == vkArray):
    assert i >= 0 and i < arr.aval[].len,
      &"opGetIndexInt array out of bounds: index {i} len {arr.aval[].len}"
    let elem = arr.aval[][i]
    fastWriteReg(vm, instr.a, elem, regsLen)
    logVM(verbose, &"opGetIndexInt: R[{instr.b}][{i}] -> R{instr.a}")
    return

  # Slow path: heap array
  if tryGetHeapArrayElement(vm, arr, i, instr.a, regsLen, verbose, "opGetIndexInt"):
    return

  assert false, "opGetIndexInt expects array or ref[array] target"


proc execGetIndexFloat*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized array indexing for float arrays
  let arr = getReg(vm, instr.b)
  let idx = getReg(vm, instr.c)
  let i = int(idx.ival)
  let regsLen = vm.currentFrame.regs.len

  if tryGetHeapArrayElement(vm, arr, i, instr.a, regsLen, verbose, "opGetIndexFloat"):
    return

  assert arr.kind == vkArray, "opGetIndexFloat expects array target"
  assert i >= 0 and i < arr.aval[].len,
    &"opGetIndexFloat array out of bounds: index {i} len {arr.aval[].len}"
  let elem = arr.aval[][i]
  fastWriteReg(vm, instr.a, elem, regsLen)
  logVM(verbose, &"opGetIndexFloat: R[{instr.b}][{i}] -> R[{instr.a}")


proc execGetIndexIInt*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized immediate indexing for integer arrays
  let arr = getReg(vm, uint8(instr.bx and 0xFF))
  let idx = int(instr.bx shr 8)
  let regsLen = vm.currentFrame.regs.len

  if tryGetHeapArrayElement(vm, arr, idx, instr.a, regsLen, verbose, "opGetIndexIInt"):
    return

  assert arr.kind == vkArray, "opGetIndexIInt expects array target"
  assert idx >= 0 and idx < arr.aval[].len,
    &"opGetIndexIInt array out of bounds: index {idx} len {arr.aval[].len}"
  let elem = arr.aval[][idx]
  fastWriteReg(vm, instr.a, elem, regsLen)
  logVM(verbose, &"opGetIndexIInt: R[{(instr.bx and 0xFF)}][{idx}] -> R[{instr.a}")


proc execGetIndexIFloat*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized immediate indexing for float arrays
  let arr = getReg(vm, uint8(instr.bx and 0xFF))
  let idx = int(instr.bx shr 8)
  let regsLen = vm.currentFrame.regs.len

  if tryGetHeapArrayElement(vm, arr, idx, instr.a, regsLen, verbose, "opGetIndexIFloat"):
    return

  assert arr.kind == vkArray, "opGetIndexIFloat expects array target"
  assert idx >= 0 and idx < arr.aval[].len,
    &"opGetIndexIFloat array out of bounds: index {idx} len {arr.aval[].len}"
  let elem = arr.aval[][idx]
  fastWriteReg(vm, instr.a, elem, regsLen)
  logVM(verbose, &"opGetIndexIFloat: R[{(instr.bx and 0xFF)}][{idx}] -> R[{instr.a}]")


proc execSetIndexInt*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized array set for integer arrays
  # Optimized hot path: direct array access first (most common case)
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = getReg(vm, instr.b)
  let i = int(idx.ival)
  let newVal = getReg(vm, instr.c)

  # Fast path: direct array set (no heap indirection, no refcounting)
  if likely(arrPtr[].kind == vkArray):
    assert i >= 0 and i < arrPtr[].aval[].len,
      &"opSetIndexInt array out of bounds: index {i} len {arrPtr[].aval[].len}"
    arrPtr[].aval[][i] = newVal
    logVM(verbose, &"opSetIndexInt: R[{instr.a}][{i}] = R[{instr.c}]")
    return

  # Slow path: heap array (needs refcounting)
  if trySetHeapArrayElement(vm, arrPtr[], i, newVal, verbose, "opSetIndexInt"):
    return

  assert false, "opSetIndexInt expects array or ref[array] target"


proc execSetIndexFloat*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized array set for float arrays
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = getReg(vm, instr.b)
  let i = int(idx.ival)
  let newVal = getReg(vm, instr.c)

  if trySetHeapArrayElement(vm, arrPtr[], i, newVal, verbose, "opSetIndexFloat"):
    return

  assert arrPtr[].kind == vkArray, "opSetIndexFloat expects array target"
  assert i >= 0 and i < arrPtr[].aval[].len,
    &"opSetIndexFloat array out of bounds: index {i} len {arrPtr[].aval[].len}"
  arrPtr[].aval[][i] = newVal
  logVM(verbose, &"opSetIndexFloat: R[{instr.a}][{i}] = R[{instr.c}]")


proc execSetIndexIInt*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized immediate set for integer arrays
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = int(instr.bx and 0xFF)
  let newVal = getReg(vm, uint8(instr.bx shr 8))

  if trySetHeapArrayElement(vm, arrPtr[], idx, newVal, verbose, "opSetIndexIInt"):
    return

  assert arrPtr[].kind == vkArray, "opSetIndexIInt expects array target"
  assert idx >= 0 and idx < arrPtr[].aval[].len,
    &"opSetIndexIInt array out of bounds: index {idx} len {arrPtr[].aval[].len}"
  arrPtr[].aval[][idx] = newVal
  logVM(verbose, &"opSetIndexIInt: R[{instr.a}][{idx}] = R[{(instr.bx shr 8)}]")


proc execSetIndexIFloat*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Type-specialized immediate set for float arrays
  let arrPtr = vm.getRegPtr(instr.a)
  let idx = int(instr.bx and 0xFF)
  let newVal = getReg(vm, uint8(instr.bx shr 8))

  if trySetHeapArrayElement(vm, arrPtr[], idx, newVal, verbose, "opSetIndexIFloat"):
    return

  assert arrPtr[].kind == vkArray, "opSetIndexIFloat expects array target"
  assert idx >= 0 and idx < arrPtr[].aval[].len,
    &"opSetIndexIFloat array out of bounds: index {idx} len {arrPtr[].aval[].len}"
  arrPtr[].aval[][idx] = newVal
  logVM(verbose, &"opSetIndexIFloat: R[{instr.a}][{idx}] = R[{(instr.bx shr 8)}]")


proc execLen*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  let val = getReg(vm, instr.b)
  if val.kind == vkArray:
    let lenVal = makeInt(int64(val.aval[].len))
    logVM(verbose, &"opLen: array length = {val.aval[].len} -> R[{instr.a}")
    setReg(vm, instr.a, lenVal)
  elif val.kind == vkString:
    let lenVal = makeInt(int64(val.sval.len))
    logVM(verbose, &"opLen: string length = {val.sval.len} -> R[{instr.a}")
    setReg(vm, instr.a, lenVal)
  else:
    logVM(verbose, &"opLen: not array/string, setting 0 -> R[{instr.a}")
    setReg(vm, instr.a, makeInt(0))


proc execSlice*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  # R[A] = R[B][R[C]:R[D]] where B is array/string, C is start, D is end
  # D comes from the next register after C
  let arr = getReg(vm, instr.b)
  let startVal = getReg(vm, instr.c)
  let endVal = getReg(vm, instr.c + 1)  # End index is in the next register

  # Convert indices to integers, handling defaults
  let startIdx = if startVal.isInt(): startVal.ival else: 0

  if arr.kind == vkString:
    let endIdx = if endVal.isInt():
      let val = endVal.ival
      if val < 0: arr.sval.len else: int(val)  # -1 means "until end"
    else: arr.sval.len
    let actualStart = max(0, min(int(startIdx), arr.sval.len))
    let actualEnd = max(actualStart, min(int(endIdx), arr.sval.len))

    if actualStart >= actualEnd:
      setReg(vm, instr.a, makeString(""))
    else:
      var slicedStr = arr.sval[actualStart..<actualEnd]
      setReg(vm, instr.a, makeString(slicedStr))

  elif arr.kind == vkArray:
    let endIdx = if endVal.isInt():
      let val = endVal.ival
      if val < 0: arr.aval[].len else: int(val)  # -1 means "until end"
    else: arr.aval[].len
    let actualStart = max(0, min(int(startIdx), arr.aval[].len))
    let actualEnd = max(actualStart, min(int(endIdx), arr.aval[].len))

    if actualStart >= actualEnd:
      var emptyArr: seq[V] = @[]
      setReg(vm, instr.a, makeArray(emptyArr))
    else:
      var slicedArr = arr.aval[][actualStart..<actualEnd]
      setReg(vm, instr.a, makeArray(slicedArr))

  else:
    setReg(vm, instr.a, makeNil())


proc execConcatArray*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # R[A] = R[B] + R[C] (efficient array concatenation)
  let left = getReg(vm, instr.b)
  let right = getReg(vm, instr.c)
  assert left.kind == vkArray and right.kind == vkArray, "opConcatArray expects array operands"

  let leftLen = left.aval[].len
  let rightLen = right.aval[].len
  var res = new(seq[V])
  res[].setLen(leftLen + rightLen)

  # Bulk copy left array
  for i in 0..<leftLen:
    res[][i] = left.aval[][i]

  # Bulk copy right array
  for i in 0..<rightLen:
    res[][leftLen + i] = right.aval[][i]

  setReg(vm, instr.a, V(kind: vkArray, aval: res))
  logVM(verbose, &"opConcatArray: concatenated arrays of length {leftLen} and {rightLen} -> R[{instr.a}]")
