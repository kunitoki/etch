# objects.nim
# Object and table operation instruction handlers

import std/tables
import ../[vm, vm_heap, vm_types]
import ../../common/[logging]


proc getHeapTable(vm: VirtualMachine, refId: int, opName: string): HeapObject {.inline.} =
  let heapObj = vm.heap.getObject(refId)
  assert heapObj != nil and heapObj.kind == hokTable, opName & " expects table ref"
  heapObj


proc execNewTable*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Create a new empty table
  setReg(vm, instr.a, makeTable())
  logVM(verbose, "opNewTable: created new table in reg " & $instr.a)


proc execGetField*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Get field from table or heap object: R[A] = R[B][K[C]]
  let objVal = getReg(vm, instr.b)
  let fieldName = vm.constants[instr.c].sval
  let destPtr = vm.getRegPtr(instr.a)

  case objVal.kind
  of vkNil:
    destPtr[] = makeNil()
    logVM(verbose, "opGetField: accessing field '" & fieldName & "' on nil, returning nil")
  of vkRef:
    let heapObj = vm.getHeapTable(objVal.refId, "opGetField")
    if heapObj.fields.hasKey(fieldName):
      destPtr[] = heapObj.fields[fieldName]
      logVM(verbose, "opGetField: got field '" & fieldName & "' from heap object #" & $objVal.refId)
    else:
      destPtr[] = makeNil()
      logVM(verbose, "opGetField: field '" & fieldName & "' not found in heap object")
  of vkTable:
    if objVal.tval.hasKey(fieldName):
      destPtr[] = objVal.tval[fieldName]
    else:
      destPtr[] = makeNil()
      logVM(verbose, "opGetField: field '" & fieldName & "' not found in table")
  else:
    assert false, "opGetField expects table, nil, or ref"


proc execSetField*(vm: VirtualMachine, instr: Instruction, verbose: bool) {.inline.} =
  # Set field in table or heap object: R[B][K[C]] = R[A]
  let objVal = getReg(vm, instr.b)
  let fieldName = vm.constants[instr.c].sval
  let valueToSet = getReg(vm, instr.a)

  case objVal.kind
  of vkRef:
    let heapObj = vm.getHeapTable(objVal.refId, "opSetField")
    var oldVal: V
    let hadOld = heapObj.fields.hasKey(fieldName)
    if hadOld:
      oldVal = heapObj.fields[fieldName]
    heapObj.fields[fieldName] = valueToSet
    vm.heap.retainHeapValue(valueToSet)
    if valueToSet.isHeapObject:
      vm.heap.trackRef(objVal.refId, valueToSet)
    if hadOld:
      vm.heap.releaseHeapValue(oldVal)
    logVM(verbose, "opSetField: set field '" & fieldName & "' in heap object #" & $objVal.refId)
  of vkTable:
    let tablePtr = vm.getRegPtr(instr.b)
    tablePtr[].tval[fieldName] = valueToSet
    logVM(verbose, "opSetField: set field '" & fieldName & "' in table")
  else:
    assert false, "opSetField expects table or ref"
