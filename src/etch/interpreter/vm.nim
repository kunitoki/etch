# vm.nim
# Simple AST interpreter acting as Etch VM (used both at runtime and for comptime eval)

import std/[tables, strformat, strutils, random]
import ../frontend/ast, bytecode

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
    mode*: VMMode

  VMMode* = enum
    vmAST,      # AST interpretation mode
    vmBytecode  # Bytecode execution mode

proc vInt(x: int64): V = V(kind: tkInt, ival: x)
proc vFloat(x: float64): V = V(kind: tkFloat, fval: x)
proc vString(x: string): V = V(kind: tkString, sval: x)
proc vChar(x: char): V = V(kind: tkChar, cval: x)
proc vBool(x: bool): V = V(kind: tkBool, bval: x)
proc vRef(id: int): V = V(kind: tkRef, refId: id)
proc vArray(elements: seq[V]): V = V(kind: tkArray, aval: elements)

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

# Bytecode VM functionality
proc push(vm: VM; val: V) =
  vm.stack.add(val)

proc pop(vm: VM): V =
  if vm.stack.len == 0:
    raise newException(ValueError, "Stack underflow")
  result = vm.stack[^1]
  vm.stack.setLen(vm.stack.len - 1)

proc peek(vm: VM): V =
  if vm.stack.len == 0:
    raise newException(ValueError, "Stack empty")
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

  raise newException(ValueError, "Unknown variable: " & name)

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

proc opAddImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in addition")
  if a.kind == tkInt:
    vm.push(vInt(a.ival + b.ival))
  elif a.kind == tkFloat:
    vm.push(vFloat(a.fval + b.fval))
  elif a.kind == tkString:
    vm.push(vString(a.sval & b.sval))
  elif a.kind == tkArray:
    vm.push(vArray(a.aval & b.aval))
  else:
    raise newException(ValueError, "Unsupported types in addition")

proc opSubImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in subtraction")
  if a.kind == tkInt:
    vm.push(vInt(a.ival - b.ival))
  elif a.kind == tkFloat:
    vm.push(vFloat(a.fval - b.fval))
  else:
    raise newException(ValueError, "Unsupported types in subtraction")

proc opMulImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in multiplication")
  if a.kind == tkInt:
    vm.push(vInt(a.ival * b.ival))
  elif a.kind == tkFloat:
    vm.push(vFloat(a.fval * b.fval))
  else:
    raise newException(ValueError, "Unsupported types in multiplication")

proc opDivImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in division")
  if a.kind == tkInt:
    if b.ival == 0:
      raise newException(ValueError, "Division by zero")
    vm.push(vInt(a.ival div b.ival))
  elif a.kind == tkFloat:
    if b.fval == 0.0:
      raise newException(ValueError, "Division by zero")
    vm.push(vFloat(a.fval / b.fval))
  else:
    raise newException(ValueError, "Unsupported types in division")

proc opModImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in modulo")
  if a.kind == tkInt:
    if b.ival == 0:
      raise newException(ValueError, "Modulo by zero")
    vm.push(vInt(a.ival mod b.ival))
  else:
    raise newException(ValueError, "Unsupported types in modulo")

proc opNegImpl(vm: VM, instr: Instruction) =
  let a = vm.pop()
  if a.kind == tkInt:
    vm.push(vInt(-a.ival))
  elif a.kind == tkFloat:
    vm.push(vFloat(-a.fval))
  else:
    raise newException(ValueError, "Negation requires numeric type")

proc opEqImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  let res = case a.kind:
    of tkInt: a.ival == b.ival
    of tkFloat: a.fval == b.fval
    of tkBool: a.bval == b.bval
    of tkString: a.sval == b.sval
    of tkChar: a.cval == b.cval
    else: false
  vm.push(vBool(res))

proc opNeImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  let res = case a.kind:
    of tkInt: a.ival != b.ival
    of tkFloat: a.fval != b.fval
    of tkBool: a.bval != b.bval
    of tkString: a.sval != b.sval
    of tkChar: a.cval != b.cval
    else: true
  vm.push(vBool(res))

proc opLtImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  if a.kind == tkInt:
    vm.push(vBool(a.ival < b.ival))
  elif a.kind == tkFloat:
    vm.push(vBool(a.fval < b.fval))
  else:
    raise newException(ValueError, "Unsupported types in comparison")

proc opLeImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  if a.kind == tkInt:
    vm.push(vBool(a.ival <= b.ival))
  elif a.kind == tkFloat:
    vm.push(vBool(a.fval <= b.fval))
  else:
    raise newException(ValueError, "Unsupported types in comparison")

proc opGtImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  if a.kind == tkInt:
    vm.push(vBool(a.ival > b.ival))
  elif a.kind == tkFloat:
    vm.push(vBool(a.fval > b.fval))
  else:
    raise newException(ValueError, "Unsupported types in comparison")

proc opGeImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != b.kind:
    raise newException(ValueError, "Type mismatch in comparison")
  if a.kind == tkInt:
    vm.push(vBool(a.ival >= b.ival))
  elif a.kind == tkFloat:
    vm.push(vBool(a.fval >= b.fval))
  else:
    raise newException(ValueError, "Unsupported types in comparison")

proc opAndImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != tkBool or b.kind != tkBool:
    raise newException(ValueError, "Logical AND requires bools")
  vm.push(vBool(a.bval and b.bval))

proc opOrImpl(vm: VM, instr: Instruction) =
  let b = vm.pop()
  let a = vm.pop()
  if a.kind != tkBool or b.kind != tkBool:
    raise newException(ValueError, "Logical OR requires bools")
  vm.push(vBool(a.bval or b.bval))

proc opNotImpl(vm: VM, instr: Instruction) =
  let a = vm.pop()
  if a.kind != tkBool:
    raise newException(ValueError, "Logical NOT requires bool")
  vm.push(vBool(not a.bval))

proc opNewRefImpl(vm: VM, instr: Instruction) =
  let value = vm.pop()
  vm.push(vm.alloc(value))

proc opDerefImpl(vm: VM, instr: Instruction) =
  let refVal = vm.pop()
  if refVal.kind != tkRef:
    raise newException(ValueError, "Deref expects reference")
  if refVal.refId < 0 or refVal.refId >= vm.heap.len:
    raise newException(ValueError, "Invalid reference")
  let cell = vm.heap[refVal.refId]
  if not cell.alive:
    raise newException(ValueError, "Dereferencing dead reference")
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
    raise newException(ValueError, "Index must be int")
  case array.kind
  of tkArray:
    if index.ival < 0 or index.ival >= array.aval.len:
      raise newException(ValueError, &"Array index {index.ival} out of bounds")
    vm.push(array.aval[index.ival])
  of tkString:
    if index.ival < 0 or index.ival >= array.sval.len:
      raise newException(ValueError, &"String index {index.ival} out of bounds")
    vm.push(vChar(array.sval[index.ival]))
  else:
    raise newException(ValueError, "Indexing requires array or string type")

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
    raise newException(ValueError, "Slicing requires array or string type")

proc opArrayLenImpl(vm: VM, instr: Instruction) =
  let array = vm.pop()
  case array.kind
  of tkArray:
    vm.push(vInt(array.aval.len.int64))
  of tkString:
    vm.push(vInt(array.sval.len.int64))
  else:
    raise newException(ValueError, "Length operator requires array or string type")

proc opCastImpl(vm: VM, instr: Instruction) =
  let source = vm.pop()
  case instr.arg:
  of 1:
    case source.kind:
    of tkFloat: vm.push(vInt(source.fval.int64))
    of tkInt: vm.push(source)
    else: raise newException(ValueError, "invalid cast to int")
  of 2:
    case source.kind:
    of tkInt: vm.push(vFloat(source.ival.float64))
    of tkFloat: vm.push(source)
    else: raise newException(ValueError, "invalid cast to float")
  of 3:
    case source.kind:
    of tkInt: vm.push(vString($source.ival))
    of tkFloat: vm.push(vString($source.fval))
    else: raise newException(ValueError, "invalid cast to string")
  else:
    raise newException(ValueError, "unsupported cast type")

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
    raise newException(ValueError, "extractSome: not a Some value")

proc opExtractOkImpl(vm: VM, instr: Instruction) =
  let result = vm.pop()
  if result.kind == tkResult and result.hasValue and result.wrappedVal != nil:
    vm.push(result.wrappedVal[])
  else:
    raise newException(ValueError, "extractOk: not an Ok value")

proc opExtractErrImpl(vm: VM, instr: Instruction) =
  let result = vm.pop()
  if result.kind == tkResult and not result.hasValue and result.wrappedVal != nil:
    vm.push(result.wrappedVal[])
  else:
    raise newException(ValueError, "extractErr: not an Err value")

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
    case arg.kind
    of tkString: echo arg.sval
    of tkChar: echo arg.cval
    of tkInt: echo arg.ival
    of tkFloat: echo arg.fval
    of tkBool: echo if arg.bval: "true" else: "false"
    else: echo "<ref>"
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
      raise newException(ValueError, "deref on non-ref")
    let cell = vm.heap[refVal.refId]
    if cell.isNil or not cell.alive:
      raise newException(ValueError, "nil ref")
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
    raise newException(ValueError, "Unknown function: " & funcName)

  # Create new frame
  let newFrame = Frame(
    vars: initTable[string, V](),
    returnAddress: vm.pc
  )

  # Pop arguments and collect them
  var args: seq[V] = @[]
  for i in 0..<argCount:
    args.add(vm.pop())

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

proc executeInstruction*(vm: VM): bool =
  ## Execute a single bytecode instruction. Returns false when program should halt.
  if vm.pc >= vm.program.instructions.len:
    return false

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
  of opJump: vm.opJumpImpl(instr)
  of opJumpIfFalse: vm.opJumpIfFalseImpl(instr)
  of opCall:
    return vm.opCallImpl(instr)
  of opReturn:
    return vm.opReturnImpl(instr)

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
        vm.globals[globalName] = vInt(0)  # Default initialization

    # Start execution from main function if it exists
    if vm.program.functions.hasKey("main"):
      vm.pc = vm.program.functions["main"]
    else:
      echo "No main function found"
      return 1

    # Execute instructions
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
    mode: vmBytecode,
    stack: @[],
    heap: @[],
    callStack: @[],
    program: program,
    pc: 0,
    globals: initTable[string, V]()
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
    let startAddr = bytecodeProgram.instructions.len
    bytecodeProgram.functions[funDecl.name] = startAddr

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
