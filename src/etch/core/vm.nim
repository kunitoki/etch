# vm.nim
# Register-based VM implementation (Lua-inspired architecture)

import std/[tables, sets, macros, monotimes, strformat, strutils]
import ../common/values
import vm_types


# Fast value constructors using discriminated union
template makeNil*(): V =
  V(kind: vkNil)


template makeBool*(val: bool): V =
  V(kind: vkBool, bval: val)


template makeChar*(val: char): V =
  V(kind: vkChar, cval: val)


template makeInt*(val: int): V =
  V(kind: vkInt, ival: val)


template makeFloat*(val: float64): V =
  V(kind: vkFloat, fval: val)


proc makeString*(val: sink string): V {.inline.} =
  V(kind: vkString, sval: val)


proc makeTypeDesc*(typeName: sink string): V {.inline.} =
  V(kind: vkTypeDesc, typeDescName: typeName)


proc makeSome*(val: sink V): V {.inline.} =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkSome, wrapped: boxed)


template makeNone*(): V =
  V(kind: vkNone)


proc makeOk*(val: sink V): V {.inline.} =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkOk, wrapped: boxed)


proc makeError*(val: sink V): V {.inline.} =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkErr, wrapped: boxed)


proc makeArray*(vals: sink seq[V]): V {.inline.} =
  var arrRef = new(seq[V])
  arrRef[] = vals
  V(kind: vkArray, aval: arrRef)


template makeTable*(): V =
  V(kind: vkTable, tval: initTable[string, V]())


template makeRef*(id: int): V =
  V(kind: vkRef, refId: id)


template makeClosure*(id: int): V =
  V(kind: vkClosure, closureId: id)


template makeWeak*(id: int): V =
  V(kind: vkWeak, weakId: id)


proc makeEnum*(typeId: int, intVal: int64, stringVal: sink string): V {.inline.} =
  V(kind: vkEnum, enumTypeId: typeId, enumIntVal: intVal, enumStringVal: stringVal)


# Type checking functions
template isInt*(v: V): bool =
  v.kind == vkInt


template isFloat*(v: V): bool =
  v.kind == vkFloat


template isChar*(v: V): bool =
  v.kind == vkChar


template isBool*(v: V): bool =
  v.kind == vkBool


template isNil*(v: V): bool =
  v.kind == vkNil


template isString*(v: V): bool =
  v.kind == vkString


template isArray*(v: V): bool =
  v.kind == vkArray


template isTable*(v: V): bool =
  v.kind == vkTable


template isSome*(v: V): bool =
  v.kind == vkSome


template isNone*(v: V): bool =
  v.kind == vkNone


template isOk*(v: V): bool =
  v.kind == vkOk


template isError*(v: V): bool =
  v.kind == vkErr


template isRef*(v: V): bool =
  v.kind == vkRef


template isClosure*(v: V): bool =
  v.kind == vkClosure


template isWeak*(v: V): bool =
  v.kind == vkWeak


template isEnum*(v: V): bool =
  v.kind == vkEnum


template isTypeDesc*(v: V): bool =
  v.kind == vkTypeDesc


# Value extraction functions
template getInt*(v: V): lent int64 =
  v.ival


template getFloat*(v: V): lent float64 =
  v.fval


template getBool*(v: V): lent bool =
  v.bval


template getChar*(v: V): lent char =
  v.cval


template getTypeDescName*(v: V): lent string =
  v.typeDescName


template unwrapOption*(v: V): lent V =
  if v.kind == vkSome:
    v.wrapped[]
  else:
    makeNil()


template unwrapResult*(v: V): lent V =
  if v.kind == vkOk or v.kind == vkErr:
    v.wrapped[]
  else:
    makeNil()


# Register helpers
proc allocReg*(ra: var RegisterAllocator, name: string = ""): uint8 =
  if name != "" and ra.regMap.hasKey(name):
    return ra.regMap[name]

  if ra.nextReg >= ra.maxRegs:
    raise newException(ValueError, &"Register allocation failed for {ra.nextReg}: out of registers (max: {ra.maxRegs})")

  result = ra.nextReg
  inc ra.nextReg
  # Track the highest register number we've allocated
  if ra.nextReg > ra.highWaterMark:
    ra.highWaterMark = ra.nextReg
  if name != "":
    ra.regMap[name] = result


proc freeReg*(ra: var RegisterAllocator, reg: uint8) =
  # Simple register reuse - mark register as free if it's the most recently allocated
  # This works well for expression evaluation where we allocate/free in stack order
  # However, in debug mode, don't reuse registers that belong to named variables
  for name, varReg in ra.regMap:
    if varReg == reg:
      # This register belongs to a named variable, don't free it
      return

  if reg == ra.nextReg - 1:
    dec ra.nextReg


template setNextReg*(ra: var RegisterAllocator, newNextReg: uint8) =
  # Set nextReg and automatically update highWaterMark if needed
  ra.nextReg = newNextReg
  if ra.nextReg > ra.highWaterMark:
    ra.highWaterMark = ra.nextReg


# Fast register access templates
template getReg*(vm: VirtualMachine, idx: uint8): V =
  # Automatically expand frame if needed
  if idx >= uint8(vm.currentFrame.regs.len):
    let oldSize = vm.currentFrame.regs.len
    let newSize = int(idx) + 1
    vm.currentFrame.regs.setLen(newSize)
    for i in oldSize ..< newSize:
      vm.currentFrame.regs[i] = V(kind: vkNil)
  vm.currentFrame.regs[idx]


template setReg*(vm: VirtualMachine, idx: uint8, val: sink V) =
  # Automatically expand frame if needed
  if idx >= uint8(vm.currentFrame.regs.len):
    let oldSize = vm.currentFrame.regs.len
    let newSize = int(idx) + 1
    vm.currentFrame.regs.setLen(newSize)
    for i in oldSize ..< newSize:
      vm.currentFrame.regs[i] = V(kind: vkNil)
  vm.currentFrame.regs[idx] = val


proc currentFunctionName*(vm: VirtualMachine): string {.inline.} =
  ## Safe accessor for the current frame's function name (empty string when unavailable)
  when not defined(deploy):
    if vm.currentFrame != nil:
      return vm.currentFrame.funcName
    return ""
  else:
    return ""


proc getRegPtr*(vm: VirtualMachine, idx: uint8): ptr V {.inline.} =
  ## Direct pointer access to register slot (hot path for in-place mutations)
  if idx >= uint8(vm.currentFrame.regs.len):
    let oldSize = vm.currentFrame.regs.len
    let newSize = int(idx) + 1
    vm.currentFrame.regs.setLen(newSize)
    for i in oldSize ..< newSize:
      vm.currentFrame.regs[i] = V(kind: vkNil)
  addr vm.currentFrame.regs[idx]


# Hot-path helpers that reuse the current register array length to avoid redundant len checks
template fastReadReg*(vm: VirtualMachine, idx: uint8, regsLen: int): V =
  if likely(int(idx) < regsLen):
    vm.currentFrame.regs[idx]
  else:
    getReg(vm, idx)


template fastWriteReg*(vm: VirtualMachine, idx: uint8, val: sink V, regsLen: int) =
  if likely(int(idx) < regsLen):
    vm.currentFrame.regs[idx] = val
  else:
    setReg(vm, idx, val)


proc ensureCoroRefSlot*(vm: VirtualMachine, coroId: int) {.inline.} =
  ## Ensure coroRefCounts has space for the given coroutine id
  if vm == nil or coroId < 0:
    return
  if coroId >= vm.coroRefCounts.len:
    let oldLen = vm.coroRefCounts.len
    vm.coroRefCounts.setLen(coroId + 1)
    for i in oldLen ..< vm.coroRefCounts.len:
      vm.coroRefCounts[i] = 0


proc retainCoroutineRef*(vm: VirtualMachine, coroId: int) {.inline.} =
  ## Increment the reference count for a coroutine handle
  if vm == nil or coroId < 0:
    return
  vm.ensureCoroRefSlot(coroId)
  inc vm.coroRefCounts[coroId]


proc releaseCoroutineRef*(vm: VirtualMachine, coroId: int) {.inline.} =
  ## Decrement the reference count and cleanup when it reaches zero
  if vm == nil or coroId < 0 or coroId >= vm.coroRefCounts.len:
    return
  if vm.coroRefCounts[coroId] == 0:
    return
  dec vm.coroRefCounts[coroId]
  if vm.coroRefCounts[coroId] == 0 and coroId < vm.coroutines.len:
    let coroPtr = vm.coroutines[coroId]
    if coroPtr != nil and vm.coroCleanupProc != nil:
      vm.coroCleanupProc(vm, coroPtr)


template getConst*(vm: VirtualMachine, idx: uint16): V =
  vm.constants[idx]


proc addInstruction*(prog: var BytecodeProgram, instr: sink Instruction, debug: DebugInfo) {.inline.} =
  ## Append instruction and debug info keeping the sequences aligned
  prog.instructions.add instr
  prog.debugInfo.add debug


proc getDebugInfo*(prog: BytecodeProgram, pc: int): DebugInfo {.inline.} =
  ## Retrieve debug information for a given instruction index (safe default when missing)
  if prog == nil or pc < 0 or pc >= prog.debugInfo.len:
    return DebugInfo()
  prog.debugInfo[pc]


# Bytecode generation helpers
proc emitABC*(prog: var BytecodeProgram, op: OpCode, a, b, c: uint8,
              debug: DebugInfo = DebugInfo()) {.inline.} =
  if op == opLoadNil and b < a:
    # Skip zero-length load-nil ranges (no registers to clear)
    return

  # Compile-time validation for constant-bearing ABC ops
  if op in {opGetField, opSetField}:
    assert int(c) < prog.constants.len, "Field constant index out of bounds for " & $op
    assert prog.constants[int(c)].kind == vkString, "Field name constant must be a string for " & $op

  prog.addInstruction(Instruction(
    op: op,
    a: a,
    opType: ifmtABC,
    b: b,
    c: c
  ), debug)


proc emitABx*(prog: var BytecodeProgram, op: OpCode, a: uint8, bx: uint16,
              debug: DebugInfo = DebugInfo()) {.inline.} =
  # Compile-time validation for constant-bearing ABx ops
  case op
  of opLoadK, opGetGlobal, opSetGlobal, opInitGlobal, opArgImm:
    assert bx < prog.constants.len.uint16, "Constant index out of bounds for " & $op
    if op in {opGetGlobal, opSetGlobal, opInitGlobal}:
      assert prog.constants[int(bx)].kind == vkString, "Global name constant must be a string for " & $op
  else:
    discard

  prog.addInstruction(Instruction(
    op: op,
    a: a,
    opType: ifmtABx,
    bx: bx
  ), debug)


proc emitAsBx*(prog: var BytecodeProgram, op: OpCode, a: uint8, sbx: int16,
               debug: DebugInfo = DebugInfo()) {.inline.} =
  prog.addInstruction(Instruction(
    op: op,
    a: a,
    opType: ifmtAsBx,
    sbx: sbx
  ), debug)


proc emitAx*(prog: var BytecodeProgram, op: OpCode, a: uint8, ax: uint32,
             debug: DebugInfo = DebugInfo()) {.inline.} =
  prog.addInstruction(Instruction(
    op: op,
    a: a,
    opType: ifmtAx,
    ax: ax
  ), debug)


proc emitCall*(prog: var BytecodeProgram, op: OpCode, a: uint8, funcIdx: uint16, argCount: uint8, numResults: uint8,
               debug: DebugInfo = DebugInfo()) {.inline.} =
  prog.addInstruction(Instruction(
    op: op,
    a: a,
    opType: ifmtCall,
    funcIdx: funcIdx,
    numArgs: argCount,
    numResults: numResults
  ), debug)


proc rebuildFunctionCaches*(vm: var VirtualMachine) =
  ## Build indexed function caches to avoid repeated string lookups at runtime.
  let total = vm.program.functionTable.len
  vm.hostFunctionCache = nil
  vm.functionInfos = newSeq[FunctionInfo](total)
  vm.functionInfoPresent = newSeq[bool](total)
  vm.cffiCache = newSeq[CffiCacheEntry](total)
  for i, name in vm.program.functionTable:
    if vm.program.functions.hasKey(name):
      vm.functionInfos[i] = vm.program.functions[name]
      vm.functionInfoPresent[i] = true
    else:
      vm.functionInfos[i] = FunctionInfo(
        name: name,
        baseName: name,
        kind: fkNative,
        paramTypes: @[],
        returnType: "",
        startPos: 0,
        endPos: 0,
        maxRegister: 0
      )


proc getFunctionInfo*(vm: VirtualMachine, funcIdx: uint16): lent FunctionInfo {.inline.} =
  assert int(funcIdx) < vm.functionInfos.len, "Function index out of range"
  vm.functionInfos[int(funcIdx)]


proc hasFunctionInfo*(vm: VirtualMachine, funcIdx: uint16): bool {.inline.} =
  int(funcIdx) < vm.functionInfoPresent.len and vm.functionInfoPresent[int(funcIdx)]


# Print current VirtualMachine state (for replay visualization)
proc printVirtualMachineState*(vm: VirtualMachine, showEmpty: bool = false) =
  if vm.frames.len == 0:
    echo "  [No active frames]"
    return

  let frame = vm.currentFrame[]
  let pc = frame.pc

  # Get current instruction debug info and function name
  var functionName = ""
  if pc >= 0 and pc < vm.program.instructions.len:
    let debug = vm.program.getDebugInfo(pc)
    functionName = debug.functionName
    echo "  Function: ", functionName, " (line ", debug.line, ")"
    echo "  PC: ", pc
  else:
    echo "  PC: ", pc, " (invalid)"

  # Get variables that are alive at the current PC
  var aliveVars: seq[string] = @[]
  if functionName != "" and vm.program.lifetimeData.hasKey(functionName):
    let lifetimeData = cast[ptr FunctionLifetimeData](vm.program.lifetimeData[functionName])[]
    if lifetimeData.pcToVariables.hasKey(pc):
      aliveVars = lifetimeData.pcToVariables[pc]

  # Build reverse map: register -> variable name for this function (only for alive variables)
  var regToVar = initTable[uint8, string]()
  if functionName != "" and vm.program.varMaps.hasKey(functionName):
    let varMap = vm.program.varMaps[functionName]
    for varName, regNum in varMap:
      # Only include variables that are alive at the current PC
      if varName in aliveVars:
        regToVar[regNum] = varName

  # Show local variables (using variable names)
  if regToVar.len > 0:
    echo "  Local Variables:"
    var foundValues = false
    for regNum, varName in regToVar:
      let val = frame.regs[regNum]
      # Show all values for alive variables (even nil)
      if true or val.kind != vkNil or showEmpty:
        foundValues = true
        case val.kind
        of vkInt:
          echo "    ", varName, " = ", val.ival
        of vkFloat:
          echo "    ", varName, " = ", val.fval
        of vkBool:
          echo "    ", varName, " = ", val.bval
        of vkChar:
          echo "    ", varName, " = '", val.cval, "'"
        of vkString:
          echo "    ", varName, " = \"", val.sval, "\""
        of vkNil:
          if showEmpty:
            echo "    ", varName, " = nil"
        else:
          echo "    ", varName, " = <complex>"

    if not foundValues:
      echo "    (no values yet)"
  else:
    echo "  Local Variables: (no variable map available)"

  # Show globals if any
  if vm.globals.len > 0:
    echo "  Globals:"
    for name, val in vm.globals:
      case val.kind
      of vkInt:
        echo "    ", name, " = ", val.ival
      of vkFloat:
        echo "    ", name, " = ", val.fval
      of vkBool:
        echo "    ", name, " = ", val.bval
      of vkChar:
        echo "    ", name, " = '", val.cval, "'"
      of vkString:
        echo "    ", name, " = \"", val.sval, "\""
      else:
        echo "    ", name, " = <complex>"


proc formatValueForPrint*(v: V): string =
  ## Format a value for print output (recursive for nested structures)
  case v.kind
  of vkInt:
    result = $v.ival
  of vkFloat:
    # Always print floats with decimal point (X.Y format)
    if v.fval == float64(int64(v.fval)):
      result = formatFloat(v.fval, ffDecimal, 1)  # X.0 format for whole numbers
    else:
      result = formatFloat(v.fval, ffDefault, -1)  # %g format
      if '.' notin result and 'e' notin result and 'E' notin result:
        result.add(".0")
  of vkChar:
    result = $v.cval
  of vkBool:
    result = if v.bval: "true" else: "false"
  of vkString:
    result = v.sval
  of vkNil:
    result = "nil"
  of vkArray:
    # Recursively format array elements
    var res = newStringOfCap(v.aval[].len * 8)
    res.add("[")
    for i, elem in v.aval[]:
      if i > 0: res.add(", ")
      if elem.isInt():
        res.add($elem.ival)
      elif elem.isFloat():
        if elem.fval == float64(int64(elem.fval)):
          res.add(formatFloat(elem.fval, ffDecimal, 1))
        else:
          let fstr = formatFloat(elem.fval, ffDefault, -1)
          if '.' notin fstr and 'e' notin fstr and 'E' notin fstr:
            res.add(fstr & ".0")
          else:
            res.add(fstr)
      elif elem.isChar():
        res.add("'")
        res.add($elem.cval)
        res.add("'")
      elif elem.kind == vkString:
        res.add("\"")
        res.add(elem.sval)
        res.add("\"")
      elif elem.kind == vkBool:
        res.add(if elem.bval: "true" else: "false")
      elif elem.kind == vkArray:
        # Recursively format nested arrays
        res.add(formatValueForPrint(elem))
      else:
        res.add("nil")
    res.add("]")
    result = res
  of vkSome:
    result = "some(" & formatValueForPrint(v.wrapped[]) & ")"
  of vkNone:
    result = "none"
  of vkOk:
    result = "ok(" & formatValueForPrint(v.wrapped[]) & ")"
  of vkErr:
    result = "error(" & formatValueForPrint(v.wrapped[]) & ")"
  of vkRef:
    result = "<ref#" & $v.refId & ">"
  of vkClosure:
    result = "<closure#" & $v.closureId & ">"
  of vkWeak:
    result = "<weak#" & $v.weakId & ">"
  of vkCoroutine:
    result = "<coroutine#" & $v.coroId & ">"
  of vkChannel:
    result = "<channel#" & $v.chanId & ">"
  of vkEnum:
    result = v.enumStringVal
  else:
    result = "nil"


# Converter between V type (VM value) and Value type (C FFI value)
proc toValue*(v: V): Value =
  ## Convert VM value to C FFI Value type
  case v.kind
  of vkBool:
    result = Value(kind: vkBool, boolVal: v.bval)
  of vkChar:
    result = Value(kind: vkInt, intVal: int64(v.cval))
  of vkInt:
    result = Value(kind: vkInt, intVal: v.ival)
  of vkFloat:
    result = Value(kind: vkFloat, floatVal: v.fval)
  of vkString:
    result = Value(kind: vkString, stringVal: v.sval)
  of vkEnum:
    result = Value(kind: vkInt, intVal: v.enumIntVal)
  of vkClosure:
    result = Value(kind: vkClosure, closureId: v.closureId)
  else:
    result = Value(kind: vkVoid)


proc fromValue*(val: Value): V =
  ## Convert C FFI Value type to VM value
  case val.kind
  of vkBool:
    result = makeBool(val.boolVal)
  of vkChar:
    result = makeChar(val.charVal)
  of vkInt:
    result = makeInt(val.intVal)
  of vkFloat:
    result = makeFloat(val.floatVal)
  of vkString:
    result = makeString(val.stringVal)
  of vkClosure:
    result = makeClosure(val.closureId)
  else:
    result = makeNil()


# Use VM-level output buffer for print statements - shared across coroutines to preserve chronological order
template flushOutput*(vm: VirtualMachine) =
  if vm.outputBuffer.len > 0:
    if vm.isDebugging:
      stderr.write(vm.outputBuffer)
      stderr.flushFile()
    else:
      stdout.write(vm.outputBuffer)
      stdout.flushFile()
    vm.outputBuffer.setLen(0)
    vm.outputCount = 0
