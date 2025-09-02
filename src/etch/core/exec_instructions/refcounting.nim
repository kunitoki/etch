# refcounting.nim
# Reference counting and heap management instruction handlers

import std/[tables, strformat]
import ../[vm, vm_types]
import ../vm_heap
import ../../common/[logging]

proc execNewRef*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Allocate a new heap object (table, scalar, or array)
  # C=1: scalar ref - allocate scalar with value from R[B]
  # C=2: array ref - allocate array with elements from R[B]
  # C=0: table ref - allocate empty table with B=destructor function index (0 if none)
  if instr.c == 1:
    # Scalar ref: R[A] = new(R[B])
    let scalarValue = getReg(vm, instr.b)
    let objId = vm.heap.allocScalar(scalarValue)
    setReg(vm, instr.a, makeRef(objId))
    logVM(verbose, &"opNewRef: allocated scalar heap object #{objId} in R[{instr.a}]")
  elif instr.c == 2:
    # Array ref: R[A] = new[array[T]](R[B])
    # R[B] should contain an array value (vkArray)
    let arrayValue = getReg(vm, instr.b)
    assert arrayValue.kind == vkArray, &"opNewRef: expected array value in R[{instr.b}], got {arrayValue.kind}"

    # Allocate hokArray heap object with same size as the source array
    let size = arrayValue.aval[].len
    let objId = vm.heap.allocArray(size)

    # Copy elements from source array to heap array
    let heapObj = vm.heap.getObject(objId)
    if heapObj != nil:
      for i in 0 ..< size:
        heapObj.elements[i] = arrayValue.aval[i]
      logVM(verbose, &"opNewRef: allocated array heap object #{objId} with {size} elements in R[{instr.a}]")

    setReg(vm, instr.a, makeRef(objId))
  else:
    # Table ref: R[A] = new[T]{}
    # B contains encoded destructor index: 0 = none, n+1 = function index n
    let destructorIdx = if instr.b == 0: -1 else: int(instr.b) - 1
    let objId = vm.heap.allocTable(destructorFuncIdx = destructorIdx)
    setReg(vm, instr.a, makeRef(objId))
    logVM(verbose, &"opNewRef: allocated table heap object #{objId} with destructor funcIdx={destructorIdx} in R[{instr.a}]")


proc execSetRef*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Update the scalar value stored inside a heap reference
  let refVal = getReg(vm, instr.a)
  assert refVal.isRef and refVal.refId != 0, &"opSetRef: target in R[{instr.a} is not a valid ref"

  let heapObj = vm.heap.getObject(refVal.refId)
  assert heapObj != nil, &"opSetRef: heap object #{refVal.refId} not found"
  assert heapObj.kind == hokScalar, &"opSetRef: heap object #{refVal.refId} is not a scalar"

  let newValue = getReg(vm, instr.b)
  vm.heap.setScalarValue(refVal.refId, newValue)
  logVM(verbose, &"opSetRef: updated scalar heap object #{refVal.refId} from ref reg {instr.a} using value reg {instr.b}")


proc execIncRef*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Increment reference count of R[A]
  let val = getReg(vm, instr.a)
  if val.isHeapObject:
    let targetId = val.heapObjectId
    vm.heap.incRef(targetId)
    logVM(verbose, &"opIncRef: incremented refcount for object #{targetId}")
  elif val.kind == vkCoroutine:
    vm.retainCoroutineRef(val.coroId)
    logVM(verbose, &"opIncRef: incremented coroutine #{val.coroId}")
  else:
    logVM(verbose, "opIncRef: skipped (not a ref or heap not initialized)")


proc execDecRef*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Decrement reference count of R[A], free if zero
  let val = getReg(vm, instr.a)
  if val.isHeapObject:
    let targetId = val.heapObjectId
    vm.heap.decRef(targetId)
    logVM(verbose, &"opDecRef: decremented refcount for object #{targetId}")
  elif val.kind == vkCoroutine:
    vm.releaseCoroutineRef(val.coroId)
    logVM(verbose, &"opDecRef: released coroutine #{val.coroId}")
  else:
    logVM(verbose, "opDecRef: skipped (not a ref or heap not initialized)")


proc execNewWeak*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Create weak reference to R[B]
  let targetVal = getReg(vm, instr.b)
  assert targetVal.isRef, &"opNewWeak: target in R[{instr.b}] is not a ref"
  let weakId = vm.heap.allocWeak(targetVal.refId, "unknown")  # TODO: pass type info
  setReg(vm, instr.a, makeWeak(weakId))
  logVM(verbose, &"opNewWeak: created weak ref #{weakId} to object #{targetVal.refId}")


proc execWeakToStrong*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Promote weak ref R[B] to strong ref in R[A]
  let weakVal = getReg(vm, instr.b)
  assert weakVal.isWeak, &"opWeakToStrong: source in R[{instr.b}] is not a weak ref"
  let strongId = vm.heap.weakToStrong(weakVal.weakId)
  assert strongId > 0, &"opWeakToStrong: invalid weak ref id #{weakVal.weakId}"
  setReg(vm, instr.a, makeRef(strongId))
  logVM(verbose, &"opWeakToStrong: promoted weak #{weakVal.weakId} to strong #{strongId}")


proc execCheckCycles*(vm: VirtualMachine, verbose: bool) {.inline.} =
  # Manually trigger cycle detection and collection
  let cycles = vm.heap.detectCycles()
  if cycles.len <= 0:
    return

  logVM(verbose, "opCheckCycles: detected " & $cycles.len & " cycle(s)")
  for cycle in cycles:
    echo formatCycle(cycle)

  # Collect unreachable cyclic objects using mark-and-sweep
  proc getRoots(): seq[V] =
    result = @[]
    # Add all values from register frames
    for frame in vm.frames:
      for reg in frame.regs:
        if reg.isHeapObject:
          result.add(reg)
    # Add all global variables
    for key, globalVal in vm.globals:
      if globalVal.isHeapObject:
        result.add(globalVal)

  vm.heap.collectCycles(cycles, getRoots)
