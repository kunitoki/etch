# vm.nim
# Simple AST interpreter acting as Etch VM (used both at runtime and for comptime eval)

import std/[tables, strformat, strutils, random, json]
import ../frontend/ast, bytecode, debugger
import ../common/[constants, errors, types]


type
  V* = object
    kind*: TypeKind
    ival*: int64
    fval*: float64
    bval*: bool
    sval*: string
    cval*: char
    # Ref represented as reference to heap slot
    refId*: int
    # Array represented as sequence of values
    aval*: seq[V]
    # Option/Result represented as wrapped value with presence flag
    hasValue*: bool        # true for Some/Ok, false for None/Err
    wrappedVal*: ref V     # the actual value for Some/Ok, or error msg for Err
    # Object represented as field name -> value mapping
    oval*: Table[string, V]

  HeapCell = ref object
    alive: bool
    val: V

  Frame* = ref object
    vars*: Table[string, V]
    returnAddress*: int  # For bytecode execution

  VM* = ref object
    # AST interpreter state
    heap*: seq[HeapCell]
    funs*: Table[string, FunDecl]
    injectedStmts*: seq[Stmt]  # Queue for statements to inject from comptime

    # Bytecode interpreter state
    stack*: seq[V]
    callStack*: seq[Frame]
    program*: BytecodeProgram
    pc*: int  # Program counter
    globals*: Table[string, V]

    # Debugger support (optional - zero cost when nil)
    debugger*: EtchDebugger

proc vInt(x: int64): V = V(kind: tkInt, ival: x)
proc vFloat(x: float64): V = V(kind: tkFloat, fval: x)
proc vString(x: string): V = V(kind: tkString, sval: x)
proc vChar(x: char): V = V(kind: tkChar, cval: x)
proc vBool(x: bool): V = V(kind: tkBool, bval: x)
proc vRef(id: int): V = V(kind: tkRef, refId: id)
proc vArray(elements: seq[V]): V = V(kind: tkArray, aval: elements)
proc vObject(fields: Table[string, V]): V = V(kind: tkObject, oval: fields)

proc vOptionSome(val: V): V =
  var refVal = new(V)
  refVal[] = val
  V(kind: tkOption, hasValue: true, wrappedVal: refVal)

proc vOptionNone(): V = V(kind: tkOption, hasValue: false)

proc vResultOk(val: V): V =
  var refVal = new(V)
  refVal[] = val
  V(kind: tkResult, hasValue: true, wrappedVal: refVal)

proc vResultErr(err: V): V =
  var refVal = new(V)
  refVal[] = err
  V(kind: tkResult, hasValue: false, wrappedVal: refVal)

proc alloc(vm: VM; v: V): V =
  vm.heap.add HeapCell(alive: true, val: v)
  vRef(vm.heap.high)

proc truthy(v: V): bool =
  case v.kind
  of tkBool: v.bval
  of tkInt: v.ival != 0
  of tkFloat: v.fval != 0.0
  else: false

proc getCurrentPos(vm: VM): Pos =
  ## Get current source position from the executing instruction
  if vm.pc > 0 and vm.pc <= vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc - 1]
    return Pos(
      line: instr.debug.line,
      col: instr.debug.col,
      filename: instr.debug.sourceFile
    )
  else:
    return Pos()

proc raiseRuntimeError(vm: VM, msg: string) =
  ## Raise a runtime error with current position information
  raise newRuntimeError(vm.getCurrentPos(), msg)

# Bytecode VM functionality
proc push(vm: VM; val: V) =
  vm.stack.add(val)

proc pop(vm: VM): V =
  if vm.stack.len == 0:
    vm.raiseRuntimeError("Stack underflow")
  result = vm.stack[^1]
  vm.stack.setLen(vm.stack.len - 1)

proc peek(vm: VM): V =
  if vm.stack.len == 0:
    vm.raiseRuntimeError("Stack empty")
  vm.stack[^1]

proc getVar(vm: VM, name: string): V =
  # Check current frame first
  if vm.callStack.len > 0:
    let frame = vm.callStack[^1]
    if frame.vars.hasKey(name):
      return frame.vars[name]

  # Check globals
  if vm.globals.hasKey(name):
    return vm.globals[name]

  vm.raiseRuntimeError(&"Unknown variable: {name}")

proc setVar(vm: VM, name: string, value: V) =
  # Set in current frame if we're in a function, otherwise global
  if vm.callStack.len > 0:
    vm.callStack[^1].vars[name] = value
  else:
    vm.globals[name] = value

# Individual operation functions
proc opLoadIntImpl(vm: VM, instr: Instruction) = vm.push(vInt(instr.arg))
proc opLoadFloatImpl(vm: VM, instr: Instruction) = vm.push(vFloat(parseFloat(vm.program.constants[instr.arg])))
proc opLoadStringImpl(vm: VM, instr: Instruction) = vm.push(vString(vm.program.constants[instr.arg]))
proc opLoadCharImpl(vm: VM, instr: Instruction) = vm.push(vChar(vm.program.constants[instr.arg][0]))
proc opLoadBoolImpl(vm: VM, instr: Instruction) = vm.push(vBool(instr.arg != 0))
proc opLoadVarImpl(vm: VM, instr: Instruction) = vm.push(vm.getVar(instr.sarg))
proc opStoreVarImpl(vm: VM, instr: Instruction) = vm.setVar(instr.sarg, vm.pop())
proc opLoadNilImpl(vm: VM, instr: Instruction) = vm.push(vRef(-1))
proc opPopImpl(vm: VM, instr: Instruction) = discard vm.pop()
proc opDupImpl(vm: VM, instr: Instruction) = vm.push(vm.peek())

proc executeBinaryOp(vm: VM, operationName: string,
    intOp: proc(a, b: int64): int64,
    floatOp: proc(a, b: float64): float64,
    stringOp: proc(a, b: string): string = nil,
    arrayOp: proc(a, b: seq[V]): seq[V] = nil,
    supportsStrings: bool = false,
    supportsArrays: bool = false,
    intValidator: proc(a, b: int64): void = nil,
    floatValidator: proc(a, b: float64): void = nil) =
  let b = vm.pop()
  let a = vm.pop()

  if a.kind != b.kind:
    vm.raiseRuntimeError("Type mismatch in " & operationName)

  case a.kind:
  of tkInt:
    if intValidator != nil:
      intValidator(a.ival, b.ival)
    vm.push(vInt(intOp(a.ival, b.ival)))
  of tkFloat:
    if floatValidator != nil:
      floatValidator(a.fval, b.fval)
    vm.push(vFloat(floatOp(a.fval, b.fval)))
  of tkString:
    if supportsStrings and stringOp != nil:
      vm.push(vString(stringOp(a.sval, b.sval)))
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
  of tkArray:
    if supportsArrays and arrayOp != nil:
      vm.push(vArray(arrayOp(a.aval, b.aval)))
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
  else:
    vm.raiseRuntimeError("Unsupported types in " & operationName)

proc executeUnaryOp(vm: VM, operationName: string,
    intOp: proc(a: int64): int64,
    floatOp: proc(a: float64): float64) =
  let a = vm.pop()
  case a.kind:
  of tkInt:
    vm.push(vInt(intOp(a.ival)))
  of tkFloat:
    vm.push(vFloat(floatOp(a.fval)))
  else:
    vm.raiseRuntimeError(operationName & " requires numeric type")

proc executeComparisonOp(vm: VM, operationName: string,
    intOp: proc(a, b: int64): bool,
    floatOp: proc(a, b: float64): bool,
    stringOp: proc(a, b: string): bool = nil,
    charOp: proc(a, b: char): bool = nil,
    boolOp: proc(a, b: bool): bool = nil,
    refOp: proc(a, b: int): bool = nil,
    supportsStrings: bool = false,
    supportsChars: bool = false,
    supportsBools: bool = false,
    supportsRefs: bool = false) =
  let b = vm.pop()
  let a = vm.pop()

  if a.kind != b.kind:
    vm.raiseRuntimeError("Type mismatch in " & operationName)

  let result = case a.kind:
  of tkInt:
    intOp(a.ival, b.ival)
  of tkFloat:
    floatOp(a.fval, b.fval)
  of tkString:
    if supportsStrings and stringOp != nil:
      stringOp(a.sval, b.sval)
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
      false  # This will never be reached due to exception, but needed for compilation
  of tkChar:
    if supportsChars and charOp != nil:
      charOp(a.cval, b.cval)
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
      false  # This will never be reached due to exception, but needed for compilation
  of tkBool:
    if supportsBools and boolOp != nil:
      boolOp(a.bval, b.bval)
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
      false  # This will never be reached due to exception, but needed for compilation
  of tkRef:
    if supportsRefs and refOp != nil:
      refOp(a.refId, b.refId)
    else:
      vm.raiseRuntimeError("Unsupported types in " & operationName)
      false  # This will never be reached due to exception, but needed for compilation
  else:
    vm.raiseRuntimeError("Unsupported types in " & operationName)
    false  # This will never be reached due to exception, but needed for compilation

  vm.push(vBool(result))

proc opAddImpl(vm: VM, instr: Instruction) =
  executeBinaryOp(vm, "addition",
    proc(a, b: int64): int64 = a + b,
    proc(a, b: float64): float64 = a + b,
    proc(a, b: string): string = a & b,
    proc(a, b: seq[V]): seq[V] = a & b,
    supportsStrings = true,
    supportsArrays = true)

proc opSubImpl(vm: VM, instr: Instruction) =
  executeBinaryOp(vm, "subtraction",
    proc(a, b: int64): int64 = a - b,
    proc(a, b: float64): float64 = a - b)

proc opMulImpl(vm: VM, instr: Instruction) =
  executeBinaryOp(vm, "multiplication",
    proc(a, b: int64): int64 = a * b,
    proc(a, b: float64): float64 = a * b)

proc opDivImpl(vm: VM, instr: Instruction) =
  executeBinaryOp(vm, "division",
    proc(a, b: int64): int64 = a div b,
    proc(a, b: float64): float64 = a / b,
    intValidator = proc(a, b: int64): void =
      if b == 0: vm.raiseRuntimeError("Division by zero"),
    floatValidator = proc(a, b: float64): void =
      if b == 0.0: vm.raiseRuntimeError("Division by zero"))

proc opModImpl(vm: VM, instr: Instruction) =
  executeBinaryOp(vm, "modulo",
    proc(a, b: int64): int64 = a mod b,
    proc(a, b: float64): float64 = 0.0, # Not used - modulo doesn't support floats
    intValidator = proc(a, b: int64): void =
      if b == 0: vm.raiseRuntimeError("Modulo by zero"))

proc opNegImpl(vm: VM, instr: Instruction) =
  executeUnaryOp(vm, "Negation",
    proc(a: int64): int64 = -a,
    proc(a: float64): float64 = -a)

proc opEqImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "equality",
    proc(a, b: int64): bool = a == b,
    proc(a, b: float64): bool = a == b,
    proc(a, b: string): bool = a == b,
    proc(a, b: char): bool = a == b,
    proc(a, b: bool): bool = a == b,
    proc(a, b: int): bool = a == b,
    supportsStrings = true,
    supportsChars = true,
    supportsBools = true,
    supportsRefs = true)

proc opNeImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "inequality",
    proc(a, b: int64): bool = a != b,
    proc(a, b: float64): bool = a != b,
    proc(a, b: string): bool = a != b,
    proc(a, b: char): bool = a != b,
    proc(a, b: bool): bool = a != b,
    proc(a, b: int): bool = a != b,
    supportsStrings = true,
    supportsChars = true,
    supportsBools = true,
    supportsRefs = true)

proc opLtImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "less than",
    proc(a, b: int64): bool = a < b,
    proc(a, b: float64): bool = a < b)

proc opLeImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "less than or equal",
    proc(a, b: int64): bool = a <= b,
    proc(a, b: float64): bool = a <= b)

proc opGtImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "greater than",
    proc(a, b: int64): bool = a > b,
    proc(a, b: float64): bool = a > b)

proc opGeImpl(vm: VM, instr: Instruction) =
  executeComparisonOp(vm, "greater than or equal",
    proc(a, b: int64): bool = a >= b,
    proc(a, b: float64): bool = a >= b)

proc opAndImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != tkBool or b.kind != tkBool:
    vm.raiseRuntimeError("Logical AND requires bools")
  vm.push(vBool(a.bval and b.bval))

proc opOrImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != tkBool or b.kind != tkBool:
    vm.raiseRuntimeError("Logical OR requires bools")
  vm.push(vBool(a.bval or b.bval))

proc opNotImpl(vm: VM, instr: Instruction) =
  let a = vm.pop()
  if a.kind != tkBool:
    vm.raiseRuntimeError("Logical NOT requires bool")
  vm.push(vBool(not a.bval))

proc opNewRefImpl(vm: VM, instr: Instruction) =
  let value = vm.pop()
  vm.push(vm.alloc(value))

proc opDerefImpl(vm: VM, instr: Instruction) =
  let refVal = vm.pop()
  if refVal.kind != tkRef:
    vm.raiseRuntimeError("Deref expects reference")
  if refVal.refId < 0 or refVal.refId >= vm.heap.len:
    vm.raiseRuntimeError("Invalid reference")
  let cell = vm.heap[refVal.refId]
  if not cell.alive:
    vm.raiseRuntimeError("Dereferencing dead reference")
  vm.push(cell.val)

proc opMakeArrayImpl(vm: VM, instr: Instruction) =
  let count = instr.arg
  var elements: seq[V] = @[]
  for i in 0..<count:
    elements.insert(vm.pop(), 0)
  vm.push(vArray(elements))

proc opArrayGetImpl(vm: VM, instr: Instruction) =
  let index = vm.pop()
  let array = vm.pop()
  if index.kind != tkInt:
    vm.raiseRuntimeError("Index must be int")
  case array.kind
  of tkArray:
    if index.ival < 0 or index.ival >= array.aval.len:
      vm.raiseRuntimeError(&"Array index {index.ival} out of bounds")
    vm.push(array.aval[index.ival])
  of tkString:
    if index.ival < 0 or index.ival >= array.sval.len:
      vm.raiseRuntimeError(&"String index {index.ival} out of bounds")
    vm.push(vChar(array.sval[index.ival]))
  else:
    vm.raiseRuntimeError("Indexing requires array or string type")

proc opArraySliceImpl(vm: VM, instr: Instruction) =
  let endVal = vm.pop()
  let startVal = vm.pop()
  let array = vm.pop()
  let startIdx = if startVal.kind == tkInt and startVal.ival != -1: startVal.ival else: 0
  case array.kind
  of tkArray:
    let endIdx = if endVal.kind == tkInt and endVal.ival != -1: endVal.ival else: array.aval.len
    let actualStart = max(0, min(startIdx, array.aval.len))
    let actualEnd = max(actualStart, min(endIdx, array.aval.len))
    if actualStart >= actualEnd:
      vm.push(vArray(@[]))
    else:
      vm.push(vArray(array.aval[actualStart..<actualEnd]))
  of tkString:
    let endIdx = if endVal.kind == tkInt and endVal.ival != -1: endVal.ival else: array.sval.len
    let actualStart = max(0, min(startIdx, array.sval.len))
    let actualEnd = max(actualStart, min(endIdx, array.sval.len))
    if actualStart >= actualEnd:
      vm.push(vString(""))
    else:
      vm.push(vString(array.sval[actualStart..<actualEnd]))
  else:
    vm.raiseRuntimeError("Slicing requires array or string type")

proc opArrayLenImpl(vm: VM, instr: Instruction) =
  let array = vm.pop()
  case array.kind
  of tkArray:
    vm.push(vInt(array.aval.len.int64))
  of tkString:
    vm.push(vInt(array.sval.len.int64))
  else:
    vm.raiseRuntimeError("Length operator requires array or string type")

proc opCastImpl(vm: VM, instr: Instruction) =
  let source = vm.pop()
  case instr.arg:
  of 1:
    case source.kind:
    of tkFloat: vm.push(vInt(source.fval.int64))
    of tkInt: vm.push(source)
    else: vm.raiseRuntimeError("invalid cast to int")
  of 2:
    case source.kind:
    of tkInt: vm.push(vFloat(source.ival.float64))
    of tkFloat: vm.push(source)
    else: vm.raiseRuntimeError("invalid cast to float")
  of 3:
    case source.kind:
    of tkInt: vm.push(vString($source.ival))
    of tkFloat: vm.push(vString($source.fval))
    else: vm.raiseRuntimeError("invalid cast to string")
  else:
    vm.raiseRuntimeError("unsupported cast type")

proc opMakeOptionSomeImpl(vm: VM, instr: Instruction) =
  let value = vm.pop()
  vm.push(vOptionSome(value))

proc opMakeOptionNoneImpl(vm: VM, instr: Instruction) =
  vm.push(vOptionNone())

proc opMakeResultOkImpl(vm: VM, instr: Instruction) =
  let value = vm.pop()
  vm.push(vResultOk(value))

proc opMakeResultErrImpl(vm: VM, instr: Instruction) =
  let errValue = vm.pop()
  vm.push(vResultErr(errValue))

proc opMatchValueImpl(vm: VM, instr: Instruction) =
  let value = vm.peek() # Don't pop yet, just peek
  case instr.arg:
  of 0: # check for None
    if value.kind == tkOption and not value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 1: # check for Some
    if value.kind == tkOption and value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 2: # check for Ok
    if value.kind == tkResult and value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 3: # check for Err
    if value.kind == tkResult and not value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  else:
    vm.push(vBool(false))

proc opExtractSomeImpl(vm: VM, instr: Instruction) =
  let option = vm.pop()
  if option.kind == tkOption and option.hasValue and option.wrappedVal != nil:
    vm.push(option.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractSome: not a Some value")

proc opExtractOkImpl(vm: VM, instr: Instruction) =
  let result = vm.pop()
  if result.kind == tkResult and result.hasValue and result.wrappedVal != nil:
    vm.push(result.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractOk: not an Ok value")

proc opExtractErrImpl(vm: VM, instr: Instruction) =
  let result = vm.pop()
  if result.kind == tkResult and not result.hasValue and result.wrappedVal != nil:
    vm.push(result.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractErr: not an Err value")

proc opMakeObjectImpl(vm: VM, instr: Instruction) =
  # arg contains number of field pairs on stack
  # Stack format: value1, "field1", value2, "field2", ... (top of stack has last pair)
  let numFields = int(instr.arg)
  var fields = initTable[string, V]()

  # Pop field-value pairs from stack (in reverse order)
  for i in 0..<numFields:
    let fieldName = vm.pop().sval  # Field name
    let fieldValue = vm.pop()      # Field value
    fields[fieldName] = fieldValue

  vm.push(vObject(fields))

proc opObjectGetImpl(vm: VM, instr: Instruction) =
  let fieldName = instr.sarg  # Field name is stored in instruction
  let obj = vm.pop()          # Object to access

  # Handle automatic dereferencing for reference types
  var actualObj = obj
  if obj.kind == tkRef:
    if obj.refId < 0 or obj.refId >= vm.heap.len:
      vm.raiseRuntimeError("invalid reference")
    let cell = vm.heap[obj.refId]
    if cell.isNil or not cell.alive:
      vm.raiseRuntimeError("attempted to access field on null reference")
    actualObj = cell.val

  if actualObj.kind != tkObject:
    vm.raiseRuntimeError(&"field access requires object type, got '{actualObj.kind}'")

  if not actualObj.oval.hasKey(fieldName):
    vm.raiseRuntimeError(&"object has no field '{fieldName}'")

  vm.push(actualObj.oval[fieldName])

proc opJumpImpl(vm: VM, instr: Instruction) =
  vm.pc = int(instr.arg)

proc opJumpIfFalseImpl(vm: VM, instr: Instruction) =
  let condition = vm.pop()
  if not truthy(condition):
    vm.pc = int(instr.arg)

proc opReturnImpl(vm: VM, instr: Instruction): bool =
  if vm.callStack.len == 0:
    return false
  let frame = vm.callStack.pop()
  vm.pc = frame.returnAddress
  return true

proc opCallImpl(vm: VM, instr: Instruction): bool =
  let funcName = instr.sarg
  let argCount = int(instr.arg)

  # Handle builtin functions using enhanced AST interpreter built-ins
  if funcName == "print":
    let arg = vm.pop()
    let output = case arg.kind:
      of tkString: arg.sval
      of tkChar: $arg.cval
      of tkInt: $arg.ival
      of tkFloat: $arg.fval
      of tkBool:
        if arg.bval: "true" else: "false"
      else: "<ref>"

    # When debugging, send output to stderr to avoid corrupting DAP protocol on stdout
    if vm.debugger != nil:
      stderr.writeLine(output)
      stderr.flushFile()
    else:
      echo output

    vm.push(V(kind: tkVoid))
    return true

  if funcName == "new":
    let arg = vm.pop()
    let refVal = vm.alloc(arg)
    vm.push(refVal)
    return true

  if funcName == "deref":
    let refVal = vm.pop()
    if refVal.kind != tkRef:
      vm.raiseRuntimeError("deref on non-ref")
    let cell = vm.heap[refVal.refId]
    if cell.isNil or not cell.alive:
      vm.raiseRuntimeError("nil ref")
    vm.push(cell.val)
    return true

  if funcName == "rand":
    if argCount == 1:
      let maxVal = vm.pop()
      if maxVal.kind == tkInt and maxVal.ival > 0:
        let res = rand(int(maxVal.ival))
        vm.push(vInt(int64(res)))
      else:
        vm.push(vInt(0))
    elif argCount == 2:
      let maxVal = vm.pop()
      let minVal = vm.pop()
      if maxVal.kind == tkInt and minVal.kind == tkInt and maxVal.ival >= minVal.ival:
        let res = rand(int(maxVal.ival - minVal.ival)) + int(minVal.ival)
        vm.push(vInt(int64(res)))
      else:
        vm.push(vInt(0))
    return true

  if funcName == "seed":
    if argCount == 1:
      let seedVal = vm.pop()
      if seedVal.kind == tkInt:
        randomize(int(seedVal.ival))
    elif argCount == 0:
      randomize()
    vm.push(V(kind: tkVoid))
    return true

  if funcName == "readFile":
    if argCount == 1:
      let pathArg = vm.pop()
      if pathArg.kind == tkString:
        try:
          let content = readFile(pathArg.sval)
          vm.push(vString(content))
        except:
          vm.push(vString(""))
      else:
        vm.push(vString(""))
    return true

  if funcName == "parseInt":
    if argCount == 1:
      let strArg = vm.pop()
      if strArg.kind == tkString:
        try:
          let parsed = parseInt(strArg.sval)
          vm.push(vOptionSome(vInt(parsed)))
        except:
          vm.push(vOptionNone())
      else:
        vm.push(vOptionNone())
    return true

  if funcName == "parseFloat":
    if argCount == 1:
      let strArg = vm.pop()
      if strArg.kind == tkString:
        try:
          let parsed = parseFloat(strArg.sval)
          vm.push(vOptionSome(vFloat(parsed)))
        except:
          vm.push(vOptionNone())
      else:
        vm.push(vOptionNone())
    return true

  if funcName == "parseBool":
    if argCount == 1:
      let strArg = vm.pop()
      if strArg.kind == tkString:
        case strArg.sval.toLower()
        of "true", "1", "yes", "on":
          vm.push(vOptionSome(vBool(true)))
        of "false", "0", "no", "off":
          vm.push(vOptionSome(vBool(false)))
        else:
          vm.push(vOptionNone())
      else:
        vm.push(vOptionNone())
    return true

  if funcName == "toString":
    if argCount == 1:
      let arg = vm.pop()
      case arg.kind
      of tkInt:
        vm.push(vString($arg.ival))
      of tkFloat:
        vm.push(vString($arg.fval))
      of tkBool:
        vm.push(vString($arg.bval))
      of tkChar:
        vm.push(vString($arg.cval))
      else:
        vm.push(vString(""))
    return true

  if funcName == "isSome":
    if argCount == 1:
      let arg = vm.pop()
      if arg.kind == tkOption:
        vm.push(vBool(arg.hasValue))
      else:
        vm.push(vBool(false))
    return true

  if funcName == "isNone":
    if argCount == 1:
      let arg = vm.pop()
      if arg.kind == tkOption:
        vm.push(vBool(not arg.hasValue))
      else:
        vm.push(vBool(false))
    return true

  if funcName == "isOk":
    if argCount == 1:
      let arg = vm.pop()
      if arg.kind == tkResult:
        vm.push(vBool(arg.hasValue))
      else:
        vm.push(vBool(false))
    return true

  if funcName == "isErr":
    if argCount == 1:
      let arg = vm.pop()
      if arg.kind == tkResult:
        vm.push(vBool(not arg.hasValue))
      else:
        vm.push(vBool(false))
    return true

  # User-defined function call
  if not vm.program.functions.hasKey(funcName):
    vm.raiseRuntimeError("Unknown function: " & funcName)

  # Create new frame
  let newFrame = Frame(
    vars: initTable[string, V](),
    returnAddress: vm.pc
  )

  # Pop arguments and collect them (they come off stack in reverse order)
  var args: seq[V] = @[]
  for i in 0..<argCount:
    args.add(vm.pop())
  # Arguments are already in correct order after popping from reverse-pushed stack
  # No need to reverse

  # Get parameter names from function debug info
  if vm.program.functionInfo.hasKey(funcName):
    let debugInfo = vm.program.functionInfo[funcName]
    for i in 0..<min(args.len, debugInfo.parameterNames.len):
      newFrame.vars[debugInfo.parameterNames[i]] = args[i]
  else:
    # Fallback: use generic parameter names if debug info is not available
    for i in 0..<args.len:
      newFrame.vars["param" & $i] = args[i]

  vm.callStack.add(newFrame)
  vm.pc = vm.program.functions[funcName]
  return true

proc vmValueToDisplayString(value: V, maxArrayElements: int = 10): string =
  ## Convert a VM value to a display string for debugger
  case value.kind
  of tkInt: return $value.ival
  of tkFloat: return $value.fval
  of tkString: return "\"" & value.sval & "\""
  of tkChar: return "'" & $value.cval & "'"
  of tkBool: return if value.bval: "true" else: "false"
  of tkVoid: return "(void)"
  of tkArray:
    if value.aval.len == 0:
      return "[]"
    var res = "["
    let elementsToShow = min(value.aval.len, maxArrayElements)
    for i in 0..<elementsToShow:
      if i > 0: res.add(", ")
      res.add(vmValueToDisplayString(value.aval[i], maxArrayElements))
    if value.aval.len > maxArrayElements:
      res.add(", ...")
    res.add("]")
    return res & " (length: " & $value.aval.len & ")"
  of tkOption:
    if value.hasValue:
      if value.wrappedVal != nil:
        return "Some(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Some(<invalid>)"
    else:
      return "None"
  of tkResult:
    if value.hasValue:
      if value.wrappedVal != nil:
        return "Ok(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Ok(<invalid>)"
    else:
      if value.wrappedVal != nil:
        return "Err(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Err(<invalid>)"
  of tkRef:
    if value.refId == -1:
      return "nil"
    else:
      return "ref#" & $value.refId
  else: return "<" & $value.kind & ">"

proc vmGetCurrentVariables*(vm: VM): Table[string, string] =
  ## Get current variables in scope for debugger display
  var variables = initTable[string, string]()

  # Get variables from current call frame (if any)
  if vm.callStack.len > 0:
    let currentFrame = vm.callStack[^1]
    for name, value in currentFrame.vars:
      variables[name] = vmValueToDisplayString(value)

  # Get global variables
  for name, value in vm.globals:
    # Only show globals if they're not shadowed by locals
    if not variables.hasKey(name):
      variables[name] = vmValueToDisplayString(value)

  return variables

proc vmGetVariableValue*(vm: VM, name: string): V =
  ## Get a variable value by name for debugger inspection
  # Check current call frame first
  if vm.callStack.len > 0:
    let currentFrame = vm.callStack[^1]
    if currentFrame.vars.hasKey(name):
      return currentFrame.vars[name]

  # Check globals
  if vm.globals.hasKey(name):
    return vm.globals[name]

  vm.raiseRuntimeError(&"Variable '{name}' not found")

proc vmInspectArrayElement*(vm: VM, arrayName: string, index: int): string =
  ## Inspect a specific array element for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      if index < 0 or index >= arrayValue.aval.len:
        return &"Index {index} out of bounds (array length: {arrayValue.aval.len})"
      return &"{arrayName}[{index}] = " & vmValueToDisplayString(arrayValue.aval[index])
    of tkString:
      if index < 0 or index >= arrayValue.sval.len:
        return &"Index {index} out of bounds (string length: {arrayValue.sval.len})"
      return &"{arrayName}[{index}] = '" & $arrayValue.sval[index] & "'"
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error inspecting {arrayName}[{index}]: {e.msg}"

proc vmInspectArraySlice*(vm: VM, arrayName: string, startIdx, endIdx: int): string =
  ## Inspect a slice of an array for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      let actualStart = max(0, min(startIdx, arrayValue.aval.len))
      let actualEnd = max(actualStart, min(endIdx, arrayValue.aval.len))
      if actualStart >= actualEnd:
        return &"{arrayName}[{startIdx}..{endIdx}] = [] (empty slice)"
      let slice = arrayValue.aval[actualStart..<actualEnd]
      let sliceArray = V(kind: tkArray, aval: slice)
      return &"{arrayName}[{startIdx}..{endIdx}] = " & vmValueToDisplayString(sliceArray)
    of tkString:
      let actualStart = max(0, min(startIdx, arrayValue.sval.len))
      let actualEnd = max(actualStart, min(endIdx, arrayValue.sval.len))
      if actualStart >= actualEnd:
        return &"{arrayName}[{startIdx}..{endIdx}] = \"\" (empty slice)"
      let slice = arrayValue.sval[actualStart..<actualEnd]
      return &"{arrayName}[{startIdx}..{endIdx}] = \"" & slice & "\""
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error inspecting {arrayName}[{startIdx}..{endIdx}]: {e.msg}"

proc vmGetArrayInfo*(vm: VM, arrayName: string): string =
  ## Get comprehensive array information for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      var info = &"Array '{arrayName}': length={arrayValue.aval.len}, type=array"
      if arrayValue.aval.len > 0:
        info.add(&", elements:")
        let maxShow = min(20, arrayValue.aval.len)  # Show more elements in detailed view
        for i in 0..<maxShow:
          info.add(&"\n  [{i}] = " & vmValueToDisplayString(arrayValue.aval[i]))
        if arrayValue.aval.len > maxShow:
          info.add(&"\n  ... and {arrayValue.aval.len - maxShow} more elements")
      return info
    of tkString:
      var info = &"String '{arrayName}': length={arrayValue.sval.len}, type=string"
      if arrayValue.sval.len > 0:
        info.add(&", characters:")
        let maxShow = min(50, arrayValue.sval.len)  # Show more chars for strings
        for i in 0..<maxShow:
          info.add(&"\n  [{i}] = '" & $arrayValue.sval[i] & "'")
        if arrayValue.sval.len > maxShow:
          info.add(&"\n  ... and {arrayValue.sval.len - maxShow} more characters")
      return info
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error getting array info for '{arrayName}': {e.msg}"

# Debugger implementation functions
proc vmDebuggerBeforeInstruction*(vm: VM) =
  ## Called before each instruction execution
  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction about to execute

    # Update stack frame tracking for step operations
    case instr.op:
    of opCall:
      let funcName = instr.sarg
      let currentFile = if instr.debug.sourceFile.len > 0: instr.debug.sourceFile else: MAIN_FUNCTION_NAME
      let isBuiltIn = not vm.program.functions.hasKey(funcName)
      vm.debugger.pushStackFrame(funcName, currentFile, instr.debug.line, isBuiltIn)
    of opReturn:
      vm.debugger.popStackFrame()
    else:
      discard

proc vmDebuggerAfterInstruction*(vm: VM) =
  ## Called after instruction execution for debugging
  if vm.debugger != nil and vm.pc > 0:
    let instr = vm.program.instructions[vm.pc - 1]  # Instruction just executed

    # For built-in function calls, pop stack frame immediately since they don't use opReturn
    if instr.op == opCall:
      let funcName = instr.sarg
      # Check if this is a built-in function (not a user-defined function)
      if not vm.program.functions.hasKey(funcName):
        vm.debugger.popStackFrame()

proc vmDebuggerShouldBreak*(vm: VM): bool =
  ## Check if execution should break at current instruction
  if vm.debugger.paused:
    return true

  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction about to execute
    let currentFile = instr.debug.sourceFile
    let currentLine = instr.debug.line

    # Skip breaking on internal control flow instructions
    if instr.op == opJump or instr.op == opJumpIfFalse:
      return false

    # Check breakpoints
    if vm.debugger.hasBreakpoint(currentFile, currentLine):
      return true

    # Check step modes
    case vm.debugger.stepMode:
    of smContinue:
      return false
    of smStepInto:
      # Break on any instruction (but not on the same line we just stepped from)
      let shouldBreak = currentLine != vm.debugger.lastLine or currentFile != vm.debugger.lastFile
      if shouldBreak and currentLine > 0:  # Only log for valid lines
        stderr.writeLine("DEBUG: StepInto - breaking at line " & $currentLine &
                        " (last was " & $vm.debugger.lastLine & ")")
        stderr.flushFile()
      return shouldBreak
    of smStepOver:
      # Break if we're at the same user call depth or returned, and on a different line
      let shouldBreak = vm.debugger.userCallDepth <= vm.debugger.stepCallDepth and
                        (currentLine != vm.debugger.lastLine or currentFile != vm.debugger.lastFile) and
                        currentLine > 0  # Only break on valid lines
      if currentLine > 0:  # Only log for valid lines
        stderr.writeLine("DEBUG: StepOver - line " & $currentLine &
                        " (last was " & $vm.debugger.lastLine & "), userDepth=" &
                        $vm.debugger.userCallDepth & "/" & $vm.debugger.stepCallDepth &
                        ", shouldBreak=" & $shouldBreak)
        stderr.flushFile()
      return shouldBreak
    of smStepOut:
      # Break if we've returned from current user function
      return vm.debugger.userCallDepth < vm.debugger.stepCallDepth

  return false

proc vmDebuggerOnBreak*(vm: VM) =
  ## Called when execution breaks
  vm.debugger.paused = true
  vm.debugger.stepMode = smContinue

  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction where we stopped
    vm.debugger.lastFile = instr.debug.sourceFile
    vm.debugger.lastLine = instr.debug.line

  # Send stopped event to debug adapter if callback is set
  if vm.debugger.onDebugEvent != nil:
    let event = %*{
      "reason": "breakpoint",
      "threadId": 1,
      "file": vm.debugger.lastFile,
      "line": vm.debugger.lastLine
    }
    vm.debugger.onDebugEvent("stopped", event)

proc executeInstruction*(vm: VM): bool =
  ## Execute a single bytecode instruction. Returns false when program should halt.
  if vm.pc >= vm.program.instructions.len:
    return false

  # Zero-cost debug hook - optimized away when debugger is nil
  if vm.debugger != nil:
    vmDebuggerBeforeInstruction(vm)
    if vmDebuggerShouldBreak(vm):
      vmDebuggerOnBreak(vm)

  let instr = vm.program.instructions[vm.pc]
  vm.pc += 1

  case instr.op
  of opLoadInt: vm.opLoadIntImpl(instr)
  of opLoadFloat: vm.opLoadFloatImpl(instr)
  of opLoadString: vm.opLoadStringImpl(instr)
  of opLoadChar: vm.opLoadCharImpl(instr)
  of opLoadBool: vm.opLoadBoolImpl(instr)
  of opLoadVar: vm.opLoadVarImpl(instr)
  of opStoreVar: vm.opStoreVarImpl(instr)
  of opLoadNil: vm.opLoadNilImpl(instr)
  of opPop: vm.opPopImpl(instr)
  of opDup: vm.opDupImpl(instr)
  of opAdd: vm.opAddImpl(instr)
  of opSub: vm.opSubImpl(instr)
  of opMul: vm.opMulImpl(instr)
  of opDiv: vm.opDivImpl(instr)
  of opMod: vm.opModImpl(instr)
  of opNeg: vm.opNegImpl(instr)
  of opEq: vm.opEqImpl(instr)
  of opNe: vm.opNeImpl(instr)
  of opLt: vm.opLtImpl(instr)
  of opLe: vm.opLeImpl(instr)
  of opGt: vm.opGtImpl(instr)
  of opGe: vm.opGeImpl(instr)
  of opAnd: vm.opAndImpl(instr)
  of opOr: vm.opOrImpl(instr)
  of opNot: vm.opNotImpl(instr)
  of opNewRef: vm.opNewRefImpl(instr)
  of opDeref: vm.opDerefImpl(instr)
  of opMakeArray: vm.opMakeArrayImpl(instr)
  of opArrayGet: vm.opArrayGetImpl(instr)
  of opArraySlice: vm.opArraySliceImpl(instr)
  of opArrayLen: vm.opArrayLenImpl(instr)
  of opCast: vm.opCastImpl(instr)
  of opMakeOptionSome: vm.opMakeOptionSomeImpl(instr)
  of opMakeOptionNone: vm.opMakeOptionNoneImpl(instr)
  of opMakeResultOk: vm.opMakeResultOkImpl(instr)
  of opMakeResultErr: vm.opMakeResultErrImpl(instr)
  of opMatchValue: vm.opMatchValueImpl(instr)
  of opExtractSome: vm.opExtractSomeImpl(instr)
  of opExtractOk: vm.opExtractOkImpl(instr)
  of opExtractErr: vm.opExtractErrImpl(instr)
  of opMakeObject: vm.opMakeObjectImpl(instr)
  of opObjectGet: vm.opObjectGetImpl(instr)
  of opJump: vm.opJumpImpl(instr)
  of opJumpIfFalse: vm.opJumpIfFalseImpl(instr)
  of opCall:
    return vm.opCallImpl(instr)
  of opReturn:
    return vm.opReturnImpl(instr)

  # Call debugger after instruction hook
  if vm.debugger != nil:
    vmDebuggerAfterInstruction(vm)

  return true

proc runBytecode*(vm: VM): int =
  ## Run the bytecode program. Returns exit code.
  try:
    # Initialize globals with stored values
    for globalName in vm.program.globals:
      if vm.program.globalValues.hasKey(globalName):
        let gv = vm.program.globalValues[globalName]
        case gv.kind
        of tkInt:
          vm.globals[globalName] = V(kind: tkInt, ival: gv.ival)
        of tkFloat:
          vm.globals[globalName] = V(kind: tkFloat, fval: gv.fval)
        of tkBool:
          vm.globals[globalName] = V(kind: tkBool, bval: gv.bval)
        of tkString:
          vm.globals[globalName] = V(kind: tkString, sval: gv.sval)
        of tkChar:
          vm.globals[globalName] = V(kind: tkChar, cval: gv.cval)
        else:
          vm.globals[globalName] = vInt(0)  # Default for unsupported types
      else:
        # For globals without pre-computed values, initialize with default
        # The runtime initialization code will set the correct values
        vm.globals[globalName] = vInt(0)  # Default initialization

    # Execute global initialization function if it exists
    if vm.program.functions.hasKey("__global_init__"):
      vm.pc = vm.program.functions["__global_init__"]
      while vm.executeInstruction():
        discard

    # Start execution from main function if it exists
    if vm.program.functions.hasKey(MAIN_FUNCTION_NAME):
      vm.pc = vm.program.functions[MAIN_FUNCTION_NAME]
    else:
      echo "No main function found"
      return 1

    # Execute main function
    while vm.executeInstruction():
      discard

    return 0
  except Exception as e:
    echo "Runtime error: ", e.msg
    if vm.program.sourceFile.len > 0 and vm.pc > 0 and vm.pc <= vm.program.instructions.len:
      let instr = vm.program.instructions[vm.pc - 1]
      if instr.debug.line > 0:
        echo "  at line ", instr.debug.line, " in ", instr.debug.sourceFile
    return 1

proc newBytecodeVM*(program: BytecodeProgram): VM =
  ## Create a new bytecode VM instance
  VM(
    stack: @[],
    heap: @[],
    callStack: @[],
    program: program,
    pc: 0,
    globals: initTable[string, V](),
    debugger: nil  # No debugger by default - zero cost
  )

proc newBytecodeVMWithDebugger*(program: BytecodeProgram, debugger: EtchDebugger): VM =
  ## Create a new bytecode VM instance with debugger attached
  VM(
    stack: @[],
    heap: @[],
    callStack: @[],
    program: program,
    pc: 0,
    globals: initTable[string, V](),
    debugger: debugger
  )

proc convertVMValueToGlobalValue*(val: V): GlobalValue =
  ## Convert a VM value to a GlobalValue for bytecode storage
  case val.kind
  of tkInt:
    GlobalValue(kind: tkInt, ival: val.ival)
  of tkFloat:
    GlobalValue(kind: tkFloat, fval: val.fval)
  of tkBool:
    GlobalValue(kind: tkBool, bval: val.bval)
  of tkString:
    GlobalValue(kind: tkString, sval: val.sval)
  of tkChar:
    GlobalValue(kind: tkChar, cval: val.cval)
  else:
    # Default for unsupported types
    GlobalValue(kind: tkInt, ival: 0)

proc evalExprWithBytecode*(prog: Program, expr: Expr, globals: Table[string, V] = initTable[string, V]()): V =
  ## Evaluate an expression using bytecode compilation and execution
  ## This reduces code duplication by using the same execution path as regular programs

  # Create a temporary bytecode program for expression evaluation
  var bytecodeProgram = BytecodeProgram(
    instructions: @[],
    constants: @[],
    functions: initTable[string, int](),
    globals: @[],
    globalValues: initTable[string, GlobalValue](),
    sourceFile: "",
    compilerFlags: CompilerFlags(),
    sourceHash: "",
    lineToInstructionMap: initTable[int, seq[int]](),
    functionInfo: initTable[string, FunctionInfo]()
  )

  # Add globals to the program
  for name, value in globals:
    if name notin bytecodeProgram.globals:
      bytecodeProgram.globals.add(name)
      bytecodeProgram.globalValues[name] = convertVMValueToGlobalValue(value)

  # Create compilation context
  var ctx = CompilationContext(
    currentFunction: "",
    localVars: @[],
    sourceFile: "",
    astProgram: prog
  )

  # First, compile all functions from the program so they're available for calls
  for name, funDecl in pairs(prog.funInstances):
    ctx.currentFunction = funDecl.name
    ctx.localVars = @[]

    # Add function parameters to local vars
    for param in funDecl.params:
      ctx.localVars.add(param.name)

    let startAddr = bytecodeProgram.instructions.len
    bytecodeProgram.functions[funDecl.name] = startAddr

    # Store function debug info for parameter handling
    var paramNames: seq[string] = @[]
    for param in funDecl.params:
      paramNames.add(param.name)
    bytecodeProgram.functionInfo[funDecl.name] = FunctionInfo(
      parameterNames: paramNames
    )

    # Compile function body
    for stmt in funDecl.body:
      compileStmt(bytecodeProgram, stmt, ctx)

    # Functions should end with opReturn, but make sure
    if bytecodeProgram.instructions.len == 0 or bytecodeProgram.instructions[^1].op != opReturn:
      # For void functions, push a dummy value
      if funDecl.ret.kind == tkVoid:
        emit(bytecodeProgram, opLoadInt, 0, ctx = ctx)
      emit(bytecodeProgram, opReturn, ctx = ctx)

  # Now compile the expression as a separate function
  ctx.currentFunction = "__eval_expr__"
  let exprAddr = bytecodeProgram.instructions.len
  bytecodeProgram.functions["__eval_expr__"] = exprAddr

  # Compile the expression
  compileExpr(bytecodeProgram, expr, ctx)

  # Add return instruction to get the result
  emit(bytecodeProgram, opReturn, ctx = ctx)

  # Create VM and execute
  var vm = newBytecodeVM(bytecodeProgram)

  # Set up globals in VM
  for name, value in globals:
    vm.globals[name] = value

  # Execute the expression function
  vm.pc = exprAddr
  try:
    while vm.executeInstruction():
      discard

    # Return the top stack value as result
    if vm.stack.len > 0:
      return vm.stack[^1]
    else:
      return vInt(0)  # Default value if no result
  except: # Exception as e:
    # Error in global evaluation - return default value silently
    # The actual error will be caught by the compiler's type checker
    return vInt(0)  # Default value on error
