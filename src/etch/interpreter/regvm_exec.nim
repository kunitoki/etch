# regvm_exec.nim
# Execution engine for register-based VM with aggressive optimizations

import std/[tables, math, strutils, dynlib]
import regvm, regvm_debugger, regvm_lifetime
import ../common/[cffi, values]

# C rand for consistency
proc c_rand(): cint {.importc: "rand", header: "<stdlib.h>".}
proc c_srand(seed: cuint) {.importc: "srand", header: "<stdlib.h>".}

# Create new VM instance
proc newRegisterVM*(prog: RegBytecodeProgram): RegisterVM =
  result = RegisterVM(
    frames: @[RegisterFrame()],
    program: prog,
    constants: prog.constants,
    globals: initTable[string, V](),
    debugger: nil,  # No debugger by default - zero cost
    isDebugging: false,  # Not in debug mode
    cffiRegistry: cast[pointer](globalCFFIRegistry)  # Use global C FFI registry
  )
  result.currentFrame = addr result.frames[0]

proc newRegisterVMWithDebugger*(prog: RegBytecodeProgram, debugger: RegEtchDebugger): RegisterVM =
  result = RegisterVM(
    frames: @[RegisterFrame()],
    program: prog,
    constants: prog.constants,
    globals: initTable[string, V](),
    debugger: cast[pointer](debugger),
    isDebugging: true,  # Set debug mode flag
    cffiRegistry: cast[pointer](globalCFFIRegistry)  # Use global C FFI registry
  )
  result.currentFrame = addr result.frames[0]
  # Attach the debugger to this VM
  if debugger != nil:
    debugger.attachToVM(cast[pointer](result))

# Fast register access macros
template getReg(vm: RegisterVM, idx: uint8): V =
  vm.currentFrame.regs[idx]

template setReg(vm: RegisterVM, idx: uint8, val: V) =
  vm.currentFrame.regs[idx] = val

template getConst(vm: RegisterVM, idx: uint16): V =
  vm.constants[idx]

# Debugger helper functions that need access to V type
proc formatRegisterValue*(v: V): string =
  ## Format a register value for display in debugger
  case v.getTag()
  of TAG_INT:
    result = $v.getInt()
  of TAG_FLOAT:
    result = $v.getFloat()
  of TAG_BOOL:
    result = $v.getBool()
  of TAG_NIL:
    result = "nil"
  of TAG_CHAR:
    result = "'" & $v.getChar() & "'"
  of TAG_STRING:
    result = "\"" & v.sval & "\""
  of TAG_ARRAY:
    # Format array contents for debugger display
    if v.aval.len == 0:
      result = "[]"
    elif v.aval.len <= 10:
      # Show all elements for small arrays
      var elements: seq[string] = @[]
      for item in v.aval:
        elements.add(formatRegisterValue(item))
      result = "[" & elements.join(", ") & "]"
    else:
      # Show first 5 and last 2 elements for large arrays
      var elements: seq[string] = @[]
      for i in 0..4:
        elements.add(formatRegisterValue(v.aval[i]))
      elements.add("...")
      for i in v.aval.len-2..<v.aval.len:
        elements.add(formatRegisterValue(v.aval[i]))
      result = "[" & elements.join(", ") & "] (" & $v.aval.len & " items)"
  of TAG_TABLE:
    result = "{table:" & $v.tval.len & " entries}"
  of TAG_SOME:
    let inner = v.unwrapOption()
    result = "Some(" & formatRegisterValue(inner) & ")"
  of TAG_NONE:
    result = "None"
  of TAG_OK:
    let inner = v.unwrapResult()
    result = "Ok(" & formatRegisterValue(inner) & ")"
  of TAG_ERR:
    let inner = v.unwrapResult()
    result = "Err(" & formatRegisterValue(inner) & ")"
  else:
    result = "<unknown>"

proc captureRegisters*(vm: RegisterVM): seq[tuple[index: uint8, value: string]] =
  ## Capture current register state for debugging
  result = @[]
  if vm.currentFrame != nil:
    for i in 0'u8..255'u8:
      let reg = vm.currentFrame.regs[i]
      # Only capture non-nil registers to save space
      if not reg.isNil():
        result.add((index: i, value: formatRegisterValue(reg)))

proc getValueType*(v: V): string =
  ## Get the type name of a register value for display in debugger
  case v.getTag()
  of TAG_INT:
    result = "int"
  of TAG_FLOAT:
    result = "float"
  of TAG_BOOL:
    result = "bool"
  of TAG_NIL:
    result = "nil"
  of TAG_CHAR:
    result = "char"
  of TAG_STRING:
    result = "string"
  of TAG_ARRAY:
    result = "array[" & $v.aval.len & "]"
  of TAG_TABLE:
    result = "table"
  of TAG_SOME:
    result = "option"
  of TAG_NONE:
    result = "option"
  of TAG_OK:
    result = "result"
  of TAG_ERR:
    result = "result"
  else:
    result = "unknown"

# Optimized arithmetic operations with type specialization
template doAdd(a, b: V): V =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    makeInt(a.ival + b.ival)  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    makeFloat(a.fval + b.fval)  # Direct field access
  elif tagA == TAG_STRING and tagB == TAG_STRING:
    # String concatenation
    var res: V
    res.data = TAG_STRING shl 48
    res.sval = a.sval & b.sval
    res
  elif getTag(a) == TAG_ARRAY and getTag(b) == TAG_ARRAY:
    # Array concatenation
    var res: V
    res.data = TAG_ARRAY shl 48
    res.aval = a.aval & b.aval
    res
  else:
    makeNil()  # Type error

template doSub(a, b: V): V =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    makeInt(a.ival - b.ival)  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    makeFloat(a.fval - b.fval)  # Direct field access
  else:
    makeNil()

template doMul(a, b: V): V =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    makeInt(a.ival * b.ival)  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    makeFloat(a.fval * b.fval)  # Direct field access
  else:
    makeNil()

template doDiv(a, b: V): V =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    makeInt(a.ival div b.ival)  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    makeFloat(a.fval / b.fval)  # Direct field access
  else:
    makeNil()

template doMod(a, b: V): V =
  if getTag(a) == TAG_INT and getTag(b) == TAG_INT:
    makeInt(a.ival mod b.ival)  # Direct field access
  else:
    makeNil()

template doLt(a, b: V): bool =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    a.ival < b.ival  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    a.fval < b.fval  # Direct field access
  elif tagA == TAG_CHAR and tagB == TAG_CHAR:
    getChar(a) < getChar(b)
  elif tagA == TAG_STRING and tagB == TAG_STRING:
    a.sval < b.sval
  else:
    false

template doLe(a, b: V): bool =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA == TAG_INT and tagB == TAG_INT:
    a.ival <= b.ival  # Direct field access
  elif tagA == TAG_FLOAT and tagB == TAG_FLOAT:
    a.fval <= b.fval  # Direct field access
  elif tagA == TAG_CHAR and tagB == TAG_CHAR:
    getChar(a) <= getChar(b)
  elif tagA == TAG_STRING and tagB == TAG_STRING:
    a.sval <= b.sval
  else:
    false

template doEq(a, b: V): bool =
  let tagA = getTag(a)
  let tagB = getTag(b)
  if tagA != tagB:
    false
  elif tagA == TAG_INT:
    a.ival == b.ival  # Direct field access
  elif tagA == TAG_FLOAT:
    a.fval == b.fval  # Direct field access
  elif tagA == TAG_BOOL:
    a.data == b.data
  elif tagA == TAG_CHAR:
    getChar(a) == getChar(b)
  elif tagA == TAG_STRING:
    a.sval == b.sval
  elif tagA == TAG_NIL:
    true
  else:
    false

proc doPow(a, b: V): V {.inline.} =
  if isFloat(a) and isFloat(b):
    makeFloat(pow(getFloat(a), getFloat(b)))
  elif isInt(a) and isInt(b):
    makeFloat(pow(float(getInt(a)), float(getInt(b))))
  else:
    makeNil()

proc doNeg(a: V): V {.inline.} =
  if isInt(a):
    makeInt(-getInt(a))
  elif isFloat(a):
    makeFloat(-getFloat(a))
  else:
    makeNil()

proc doNot(a: V): V {.inline.} =
  let isTrue = getTag(a) != TAG_NIL and
                not (getTag(a) == TAG_BOOL and (a.data and 1) == 0)
  makeBool(not isTrue)

# Converter between V type (VM value) and Value type (C FFI value)
proc toValue(v: V): Value =
  ## Convert VM value to C FFI Value type
  if isInt(v):
    result = Value(kind: vkInt, intVal: getInt(v))
  elif isFloat(v):
    result = Value(kind: vkFloat, floatVal: getFloat(v))
  elif isChar(v):
    # Convert char to int for C FFI
    result = Value(kind: vkInt, intVal: int64(getChar(v)))
  elif getTag(v) == TAG_STRING:
    result = Value(kind: vkString, stringVal: v.sval)
  elif getTag(v) == TAG_BOOL:
    result = Value(kind: vkBool, boolVal: (v.data and 1) != 0)
  elif getTag(v) == TAG_ARRAY:
    # Arrays not directly supported in C FFI, convert to void
    result = Value(kind: vkVoid)
  else:
    result = Value(kind: vkVoid)

proc fromValue(val: Value): V =
  ## Convert C FFI Value type to VM value
  case val.kind
  of vkInt:
    result = makeInt(val.intVal)
  of vkFloat:
    result = makeFloat(val.floatVal)
  of vkBool:
    result = makeBool(val.boolVal)
  of vkString:
    result = makeString(val.stringVal)
  of vkVoid:
    result = makeNil()
  else:
    result = makeNil()

# Handle C FFI function calls
proc callCFFIFunction(vm: RegisterVM, funcName: string, funcReg: uint8, numArgs: uint8): bool =
  ## Call a C FFI function through the registry
  ## Returns true if function was called successfully

  # Get the C FFI registry
  let registry = cast[CFFIRegistry](vm.cffiRegistry)
  if registry == nil:
    return false

  # Check if this is a registered C FFI function
  if funcName notin registry.functions:
    return false

  # Prepare arguments
  var args: seq[Value] = @[]
  for i in 0'u8..<numArgs:
    let vmVal = getReg(vm, funcReg + 1'u8 + i)
    args.add(toValue(vmVal))

  # Call the C function
  try:
    let result = registry.callFunction(funcName, args)
    setReg(vm, funcReg, fromValue(result))
    return true
  except:
    # On error, set result to nil
    setReg(vm, funcReg, makeNil())
    return true  # We handled it, even if it errored

# Unified output handling for consistent behavior between debug and normal execution
proc vmPrint(vm: RegisterVM, output: string, outputBuffer: var string, outputCount: var int) =
  ## Unified print function that handles output consistently
  if vm.isDebugging:
    # In debug mode, always output to stderr immediately
    stderr.writeLine(output)
    stderr.flushFile()
  else:
    # In normal mode, buffer output for performance
    if outputBuffer.addr != nil:
      # We have a buffer (optimized path)
      outputBuffer.add(output)
      outputBuffer.add('\n')
      outputCount.inc
      # Note: Caller is responsible for flushing when appropriate
    else:
      # No buffer (debug path in non-debug mode)
      echo output

# Shared implementation for builtin functions to ensure consistent behavior
proc handleBuiltinFunction(vm: RegisterVM, funcName: string, funcReg: uint8, numArgs: uint8,
                          outputBuffer: var string, outputCount: var int): bool =
  ## Handle builtin function execution. Returns true if function was handled.
  case funcName
  of "print":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      let output = if isInt(val): $getInt(val)
                  elif isFloat(val): $getFloat(val)
                  elif isChar(val): $getChar(val)
                  elif getTag(val) == TAG_STRING: val.sval
                  elif getTag(val) == TAG_BOOL:
                    if (val.data and 1) != 0: "true" else: "false"
                  elif getTag(val) == TAG_ARRAY:
                    # Print array elements
                    var res = "["
                    for i, elem in val.aval:
                      if i > 0: res.add(", ")
                      if isInt(elem): res.add($getInt(elem))
                      elif isFloat(elem): res.add($getFloat(elem))
                      elif getTag(elem) == TAG_STRING: res.add("\"" & elem.sval & "\"")
                      elif getTag(elem) == TAG_BOOL:
                        res.add(if (elem.data and 1) != 0: "true" else: "false")
                      else: res.add("nil")
                    res.add("]")
                    res
                  else: "nil"
      vmPrint(vm, output, outputBuffer, outputCount)
      setReg(vm, funcReg, makeNil())
    return true

  of "toString":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      var res: V
      res.data = TAG_STRING shl 48
      if isInt(val):
        res.sval = $getInt(val)
      elif isFloat(val):
        res.sval = $getFloat(val)
      elif isChar(val):
        res.sval = $getChar(val)
      elif getTag(val) == TAG_BOOL:
        res.sval = if (val.data and 1) != 0: "true" else: "false"
      elif getTag(val) == TAG_STRING:
        res.sval = val.sval
      else:
        res.sval = "nil"
      setReg(vm, funcReg, res)
    return true

  of "seed":
    if numArgs == 1:
      let seedVal = getReg(vm, funcReg + 1)
      if isInt(seedVal):
        c_srand(cuint(getInt(seedVal)))
      setReg(vm, funcReg, makeNil())
    return true

  of "rand":
    if numArgs == 1:
      # Single argument: rand(max) means rand from 0 to max
      let maxVal = getReg(vm, funcReg + 1)
      if isInt(maxVal):
        let maxInt = getInt(maxVal)
        if maxInt > 0:
          let randVal = c_rand() mod cint(maxInt)
          setReg(vm, funcReg, makeInt(int64(randVal)))
        else:
          setReg(vm, funcReg, makeInt(0))
    elif numArgs == 2:
      # Arguments: rand(max, min)
      let maxVal = getReg(vm, funcReg + 1)  # First argument is max
      let minVal = getReg(vm, funcReg + 2)  # Second argument is min
      if isInt(minVal) and isInt(maxVal):
        let minInt = getInt(minVal)
        let maxInt = getInt(maxVal)
        let range = maxInt - minInt
        if range > 0:
          let randVal = (c_rand() mod cint(range)) + cint(minInt)
          setReg(vm, funcReg, makeInt(int64(randVal)))
        else:
          setReg(vm, funcReg, makeInt(minInt))
    return true

  # Reference operations
  of "new":
    if numArgs == 1:
      # For now, just pass through the value (references are not truly implemented)
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, val)
    else:
      setReg(vm, funcReg, makeNil())
    return true

  of "deref":
    if numArgs == 1:
      # For now, just pass through the value (references are not truly implemented)
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, val)
    else:
      setReg(vm, funcReg, makeNil())
    return true

  # File I/O operations
  of "readFile":
    if numArgs == 1:
      let pathVal = getReg(vm, funcReg + 1)
      if isString(pathVal):
        try:
          let content = readFile(pathVal.sval)
          setReg(vm, funcReg, makeString(content))
        except:
          setReg(vm, funcReg, makeString(""))
      else:
        setReg(vm, funcReg, makeString(""))
    else:
      setReg(vm, funcReg, makeString(""))
    return true

  # Parsing functions
  of "parseInt":
    if numArgs == 1:
      let strVal = getReg(vm, funcReg + 1)
      if getTag(strVal) == TAG_STRING:
        try:
          let intVal = parseInt(strVal.sval)
          setReg(vm, funcReg, makeInt(intVal))
        except:
          setReg(vm, funcReg, makeNil())
      else:
        setReg(vm, funcReg, makeNil())
    return true

  of "parseFloat":
    if numArgs == 1:
      let strVal = getReg(vm, funcReg + 1)
      if getTag(strVal) == TAG_STRING:
        try:
          let floatVal = parseFloat(strVal.sval)
          setReg(vm, funcReg, makeFloat(floatVal))
        except:
          setReg(vm, funcReg, makeNil())
      else:
        setReg(vm, funcReg, makeNil())
    return true

  of "parseBool":
    if numArgs == 1:
      let strVal = getReg(vm, funcReg + 1)
      if isString(strVal):
        if strVal.sval == "true":
          setReg(vm, funcReg, makeSome(makeBool(true)))
        elif strVal.sval == "false":
          setReg(vm, funcReg, makeSome(makeBool(false)))
        else:
          setReg(vm, funcReg, makeNone())
      else:
        setReg(vm, funcReg, makeNone())
    else:
      setReg(vm, funcReg, makeNone())
    return true

  of "isSome":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, makeBool(isSome(val)))
    else:
      setReg(vm, funcReg, makeBool(false))
    return true

  of "isNone":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, makeBool(isNone(val)))
    else:
      setReg(vm, funcReg, makeBool(true))
    return true

  of "isOk":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, makeBool(isOk(val)))
    else:
      setReg(vm, funcReg, makeBool(false))
    return true

  of "isErr":
    if numArgs == 1:
      let val = getReg(vm, funcReg + 1)
      setReg(vm, funcReg, makeBool(isErr(val)))
    else:
      setReg(vm, funcReg, makeBool(true))
    return true

  else:
    return false  # Function not handled

# Execute a single instruction - used by debugger
proc executeInstruction*(vm: RegisterVM, verbose: bool = false): bool =
  ## Execute one instruction and return true if execution should continue
  ## Returns false if program terminated or error occurred

  if vm.currentFrame == nil or vm.currentFrame.pc >= vm.program.instructions.len:
    return false  # Program terminated

  var pc = vm.currentFrame.pc
  let instr = vm.program.instructions[pc]

  # Debugger hook - before instruction
  if vm.debugger != nil:
    let debugger = cast[RegEtchDebugger](vm.debugger)
    let debug = instr.debug

    # Update debugger's position
    debugger.currentPC = pc
    if debug.line > 0:
      # Check if we should break BEFORE updating lastFile/lastLine
      if debugger.shouldBreak(pc, debug.sourceFile, debug.line):
        # Update last position AFTER we decide to break
        debugger.lastFile = debug.sourceFile
        debugger.lastLine = debug.line
        debugger.pause()
        # Don't execute if we should break here
        return true  # Still running but paused

    # Debug output when in debug mode
    if vm.isDebugging and verbose:
      stderr.writeLine("[DEBUG executeInstruction] PC=" & $pc &
                      " op=" & $instr.op &
                      " line=" & $debug.line &
                      " file=" & debug.sourceFile &
                      " paused=" & $debugger.paused)
      stderr.flushFile()

  # Check for destructor injection points
  # This is where we would clean up variables going out of scope
  # For now, we just log when variables would be destroyed
  if vm.isDebugging and verbose:
    # Check if current function has lifetime data
    for fname, finfo in vm.program.functions:
      if pc >= finfo.startPos and pc <= finfo.endPos:
        # We're in this function
        if vm.program.lifetimeData.hasKey(fname):
          let lifetimeData = cast[ptr FunctionLifetimeData](vm.program.lifetimeData[fname])
          if lifetimeData.destructorPoints.hasKey(pc):
            let varsToDestroy = lifetimeData.destructorPoints[pc]
            for varName in varsToDestroy:
              stderr.writeLine("[DESTRUCTOR] Would destroy variable '" & varName & "' at PC " & $pc)
              stderr.flushFile()
        break

  # Actually execute the instruction
  # Default: increment PC after executing instruction
  var shouldContinue = true
  inc pc

  # Execute the instruction - we need to duplicate some of the execute loop logic
  case instr.op
  of ropLoadK:
    # Load constant: R[A] = K[Bx] or immediate
    if instr.opType == 1:  # ABx format - load from constant pool
      setReg(vm, instr.a, getConst(vm, instr.bx))
    elif instr.opType == 2:  # AsBx format - immediate integer
      setReg(vm, instr.a, makeInt(int64(instr.sbx)))

  of ropLoadNil:
    # Load nil: R[A] = nil
    setReg(vm, instr.a, makeNil())

  of ropLoadBool:
    # Load boolean: R[A] = B != 0
    setReg(vm, instr.a, makeBool(instr.b != 0))
    if instr.c != 0:
      inc pc  # Skip next instruction if C != 0

  of ropMove:
    # Move: R[A] = R[B]
    setReg(vm, instr.a, getReg(vm, instr.b))

  of ropAdd:
    setReg(vm, instr.a, doAdd(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropSub:
    setReg(vm, instr.a, doSub(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropMul:
    setReg(vm, instr.a, doMul(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropDiv:
    setReg(vm, instr.a, doDiv(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropMod:
    setReg(vm, instr.a, doMod(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropPow:
    setReg(vm, instr.a, doPow(getReg(vm, instr.b), getReg(vm, instr.c)))

  of ropUnm:
    setReg(vm, instr.a, doNeg(getReg(vm, instr.b)))

  of ropNot:
    setReg(vm, instr.a, doNot(getReg(vm, instr.b)))

  of ropEqStore:
    setReg(vm, instr.a, makeBool(doEq(getReg(vm, instr.b), getReg(vm, instr.c))))

  of ropLtStore:
    setReg(vm, instr.a, makeBool(doLt(getReg(vm, instr.b), getReg(vm, instr.c))))

  of ropLeStore:
    setReg(vm, instr.a, makeBool(doLe(getReg(vm, instr.b), getReg(vm, instr.c))))

  of ropJmp:
    pc += int(instr.sbx)

  of ropTest:
    let val = getReg(vm, instr.a)
    let isTrue = getTag(val) != TAG_NIL and
                  not (getTag(val) == TAG_BOOL and (val.data and 1) == 0)
    if isTrue != (instr.c != 0):
      inc pc  # Skip next instruction

  of ropCall:
    # Handle function calls (simplified for single-step execution)
    let funcReg = instr.a
    let numArgs = instr.b
    #let numResults = instr.c

    let funcNameVal = getReg(vm, funcReg)
    if getTag(funcNameVal) == TAG_STRING:
      let funcName = funcNameVal.sval

      # Check for user-defined functions
      if vm.program.functions.hasKey(funcName):
        let funcInfo = vm.program.functions[funcName]

        # Debugger hook - push stack frame
        if vm.debugger != nil:
          let debugger = cast[RegEtchDebugger](vm.debugger)
          # Get debug info from the first instruction of the function being called
          let funcFirstInstr = if funcInfo.startPos < vm.program.instructions.len:
            vm.program.instructions[funcInfo.startPos]
          else:
            instr
          let targetFile = if funcFirstInstr.debug.sourceFile.len > 0:
            funcFirstInstr.debug.sourceFile
          else:
            "main"
          let targetLine = if funcFirstInstr.debug.line > 0:
            funcFirstInstr.debug.line
          else:
            1  # Default to line 1 if no debug info
          debugger.pushStackFrame(funcName, targetFile, targetLine, false)

        # Create new frame
        var newFrame = RegisterFrame()
        newFrame.returnAddr = pc  # Return to instruction after call
        newFrame.baseReg = funcReg
        newFrame.pc = funcInfo.startPos

        # Copy arguments
        for i in 0'u8..<numArgs:
          newFrame.regs[i] = getReg(vm, funcReg + 1'u8 + i)

        # Push frame
        vm.frames.add(newFrame)
        vm.currentFrame = addr vm.frames[^1]

        # PC is now at function start
        pc = funcInfo.startPos
      else:
        # Try C FFI first
        if callCFFIFunction(vm, funcName, funcReg, numArgs):
          # C FFI function handled
          discard
        else:
          # Handle builtin functions using shared implementation
          # Debugger hook for builtin
          if vm.debugger != nil:
            let debugger = cast[RegEtchDebugger](vm.debugger)
            let currentFile = if instr.debug.sourceFile.len > 0: instr.debug.sourceFile else: "main"
            debugger.pushStackFrame(funcName, currentFile, instr.debug.line, true)

          # Use shared builtin handler - no buffering in debug path
          var dummyBuffer = ""
          var dummyCount = 0
          if not handleBuiltinFunction(vm, funcName, funcReg, numArgs, dummyBuffer, dummyCount):
            # Unknown function - check if it's an unloaded C FFI function
            if vm.program.cffiInfo.hasKey(funcName):
              let cffiInfo = vm.program.cffiInfo[funcName]
              if verbose:
                echo "[DEBUG] C FFI function not loaded: ", funcName, " (library: ", cffiInfo.library, ")"
            else:
              # Unknown function
              if verbose:
                echo "[DEBUG] Unknown function: ", funcName
            setReg(vm, funcReg, makeNil())

        # Pop builtin frame immediately
        if vm.debugger != nil:
          let debugger = cast[RegEtchDebugger](vm.debugger)
          debugger.popStackFrame()

  of ropReturn:
    # Return from function
    let numResults = instr.b
    let returnValue = if numResults > 0: getReg(vm, instr.a) else: makeNil()

    # Debugger hook - pop stack frame
    if vm.debugger != nil:
      let debugger = cast[RegEtchDebugger](vm.debugger)
      debugger.popStackFrame()

    # Pop frame
    let returnAddr = vm.currentFrame.returnAddr
    let resultReg = vm.currentFrame.baseReg
    vm.frames.setLen(vm.frames.len - 1)

    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
      if numResults > 0:
        setReg(vm, resultReg, returnValue)
      pc = returnAddr
    else:
      # No more frames - program terminated
      shouldContinue = false

  else:
    # For unhandled instructions, just continue
    # In a complete implementation, all instructions would be handled
    discard

  # Update PC in the frame
  vm.currentFrame.pc = pc

  return shouldContinue

# Main execution loop - highly optimized with computed goto if available
proc execute*(vm: RegisterVM, verbose: bool = false): int =
  var pc = vm.program.entryPoint
  let instructions = vm.program.instructions
  let maxInstr = instructions.len
  vm.currentFrame.pc = pc  # Initialize PC in frame

  # Output buffer for print statements - significantly improves performance
  var outputBuffer: string = ""
  var outputCount = 0
  const BUFFER_SIZE = 8192  # Flush every 8KB or 100 lines

  template flushOutput() =
    if outputBuffer.len > 0:
      if vm.isDebugging:
        stderr.write(outputBuffer)
      else:
        stdout.write(outputBuffer)
      outputBuffer.setLen(0)
      outputCount = 0

  # Main dispatch loop - unrolled for common instructions
  while pc < maxInstr:
    let instr = instructions[pc]
    vm.currentFrame.pc = pc  # Update frame PC for debugger

    # Debugger hook - before instruction
    if vm.debugger != nil:
      let debugger = cast[RegEtchDebugger](vm.debugger)
      let debug = instr.debug
      if debug.line > 0:  # Valid debug info
        if debugger.shouldBreak(pc, debug.sourceFile, debug.line):
          # Update last position AFTER we decide to break
          debugger.lastFile = debug.sourceFile
          debugger.lastLine = debug.line
          debugger.pause()
          # Send break event
          debugger.sendBreakpointHit(debug.sourceFile, debug.line)
          # Wait for debugger to continue
          while debugger.paused:
            # In a real implementation, this would yield to debugger
            # For now, we just break the pause
            break

    when defined(debugRegVM):
      echo "[", pc, "] ", instr.op, " a=", instr.a,
           (if instr.opType == 0: " b=" & $instr.b & " c=" & $instr.c
            elif instr.opType == 1: " bx=" & $instr.bx
            elif instr.opType == 2: " sbx=" & $instr.sbx
            else: " ax=" & $instr.ax)

    if verbose and pc >= 4:  # Only log main function instructions
      echo "[REGVM] PC=", pc, " op=", instr.op

    inc pc

    # Use computed goto table for maximum performance
    # (Nim doesn't support computed goto, so we use case)
    case instr.op:

    # --- Move and Load Instructions ---
    of ropMove:
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, val)
      if verbose:
        echo "[REGVM] ropMove: reg", instr.b, " -> reg", instr.a,
             " value tag=", val.getTag().toHex,
             if val.isInt(): " int=" & $val.getInt() else: ""

    of ropLoadK:
      # Handle both ABx (constant pool) and AsBx (immediate) formats
      if instr.opType == 1:  # ABx format - load from constant pool
        if verbose:
          echo "[REGVM] ropLoadK: loading const[", instr.bx, "] to reg ", instr.a
        setReg(vm, instr.a, getConst(vm, instr.bx))
      elif instr.opType == 2:  # AsBx format - immediate integer
        if verbose:
          echo "[REGVM] ropLoadK: loading immediate ", instr.sbx, " to reg ", instr.a
        setReg(vm, instr.a, makeInt(int64(instr.sbx)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropLoadBool:
      setReg(vm, instr.a, makeBool(instr.b != 0))
      if instr.c != 0:
        inc pc  # Skip next instruction

    of ropLoadNil:
      if verbose:
        echo "[REGVM] ropLoadNil: setting reg", instr.a, "..", instr.b, " to nil"
      for i in instr.a..instr.b:
        setReg(vm, i, makeNil())

    # --- Global Access ---
    of ropGetGlobal:
      if instr.opType == 1 and int(instr.bx) < vm.constants.len:
        let name = vm.constants[instr.bx].sval
        if vm.globals.hasKey(name):
          setReg(vm, instr.a, vm.globals[name])
        else:
          setReg(vm, instr.a, makeNil())
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetGlobal:
      if instr.opType == 1 and int(instr.bx) < vm.constants.len:
        let name = vm.constants[instr.bx].sval
        vm.globals[name] = getReg(vm, instr.a)

    # --- Arithmetic Operations ---
    of ropAdd:
      setReg(vm, instr.a, doAdd(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropSub:
      setReg(vm, instr.a, doSub(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropMul:
      setReg(vm, instr.a, doMul(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropDiv:
      setReg(vm, instr.a, doDiv(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropMod:
      setReg(vm, instr.a, doMod(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropPow:
      let base = getReg(vm, instr.b)
      let exp = getReg(vm, instr.c)
      if isFloat(base) and isFloat(exp):
        setReg(vm, instr.a, makeFloat(pow(getFloat(base), getFloat(exp))))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Immediate Arithmetic (Optimized) ---
    of ropAddI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) + imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSubI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) - imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropMulI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) * imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropUnm:
      let val = getReg(vm, instr.b)
      if isInt(val):
        setReg(vm, instr.a, makeInt(-getInt(val)))
      elif isFloat(val):
        setReg(vm, instr.a, makeFloat(-getFloat(val)))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Comparisons ---
    of ropEq:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let isEqual = doEq(b, c)
      let skipIfNot = instr.a != 0
      if verbose:
        echo "[REGVM] ropEq: reg", instr.b, "=", b.data.toHex, " reg", instr.c, "=", c.data.toHex,
             " equal=", isEqual, " skipIfNot=", skipIfNot, " willSkip=", (isEqual != skipIfNot)
      if isEqual != skipIfNot:
        inc pc  # Skip next instruction

    of ropLt:
      if doLt(getReg(vm, instr.b), getReg(vm, instr.c)) != (instr.a != 0):
        inc pc

    of ropLe:
      if doLe(getReg(vm, instr.b), getReg(vm, instr.c)) != (instr.a != 0):
        inc pc

    # --- Immediate Comparisons (Optimized) ---
    of ropEqI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) == imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    of ropLtI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) < imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    of ropLeI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) <= imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    # --- Store comparison results in registers ---
    of ropEqStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      setReg(vm, instr.a, makeBool(doEq(b, c)))

    of ropNeStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      setReg(vm, instr.a, makeBool(not doEq(b, c)))

    of ropLtStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let res = makeBool(doLt(b, c))
      if verbose:
        echo "[REGVM] ropLtStore: reg", instr.a, " = reg", instr.b, "(", $b, ") < reg", instr.c, "(", $c, ") = ", $res
      setReg(vm, instr.a, res)

    of ropLeStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let res = makeBool(doLe(b, c))
      if verbose:
        echo "[REGVM] ropLeStore: reg", instr.a, " = reg", instr.b, "(", $b, ") <= reg", instr.c, "(", $c, ") = ", $res
      setReg(vm, instr.a, res)

    # --- Logical Operations ---
    of ropNot:
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeBool(getTag(val) == TAG_NIL or (getTag(val) == TAG_BOOL and (val.data and 1) == 0)))

    of ropAnd:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      if verbose:
        echo "[REGVM] ropAnd: reg", instr.b, " tag=", getTag(b), " data=", b.data,
             " AND reg", instr.c, " tag=", getTag(c), " data=", c.data
      # Both values should be booleans - perform logical AND
      if getTag(b) == TAG_BOOL and getTag(c) == TAG_BOOL:
        let bVal = (b.data and 1) != 0
        let cVal = (c.data and 1) != 0
        setReg(vm, instr.a, makeBool(bVal and cVal))
        if verbose:
          echo "[REGVM] ropAnd: ", bVal, " AND ", cVal, " = ", bVal and cVal
      else:
        # Fallback to old behavior for non-boolean values
        if getTag(b) == TAG_NIL or (getTag(b) == TAG_BOOL and (b.data and 1) == 0):
          setReg(vm, instr.a, b)
        else:
          setReg(vm, instr.a, c)

    of ropOr:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      if getTag(b) != TAG_NIL and not (getTag(b) == TAG_BOOL and (b.data and 1) == 0):
        setReg(vm, instr.a, b)
      else:
        setReg(vm, instr.a, c)

    # --- Type conversions ---
    of ropCast:
      let val = getReg(vm, instr.b)
      let castType = instr.c
      var res: V

      case castType:
      of 1:  # To int
        if isInt(val):
          res = val
        elif isFloat(val):
          res = makeInt(int64(getFloat(val)))
        elif isString(val):
          # Try to parse string to int
          try:
            res = makeInt(int64(parseInt(val.sval)))
          except:
            res = makeNil()
        else:
          res = makeNil()

      of 2:  # To float
        if isFloat(val):
          res = val
        elif isInt(val):
          res = makeFloat(float64(getInt(val)))
        elif isString(val):
          # Try to parse string to float
          try:
            res = makeFloat(parseFloat(val.sval))
          except:
            res = makeNil()
        else:
          res = makeNil()

      of 3:  # To string
        if isInt(val):
          res = makeString($getInt(val))
        elif isFloat(val):
          res = makeString($getFloat(val))
        elif isString(val):
          res = val
        elif isBool(val):
          res = makeString(if getBool(val): "true" else: "false")
        elif isNil(val):
          res = makeString("nil")
        else:
          res = makeString("")

      else:
        res = makeNil()

      setReg(vm, instr.a, res)

    # --- Option/Result handling ---
    of ropWrapSome:
      # Wrap value as Some
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeSome(val))

    of ropLoadNone:
      # Load None value
      setReg(vm, instr.a, makeNone())

    of ropWrapOk:
      # Wrap value as Ok
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeOk(val))

    of ropWrapErr:
      # Wrap value as Err
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeErr(val))

    of ropTestTag:
      # Test if register has specific tag
      # Skip next instruction if tags MATCH (for match expressions)
      let val = getReg(vm, instr.a)
      let expectedTag = instr.b.uint64
      let actualTag = getTag(val)
      if verbose:
        echo "[REGVM] ropTestTag: reg=", instr.a, " expected=", expectedTag, " actual=", actualTag, " match=", actualTag == expectedTag
      if actualTag == expectedTag:
        if verbose:
          echo "[REGVM] ropTestTag: tags match, skipping next instruction (PC ", pc, " -> ", pc + 1, ")"
        inc pc  # Skip next instruction if tags match

    of ropUnwrapOption:
      # Unwrap Option value
      let val = getReg(vm, instr.b)
      if isSome(val):
        let unwrapped = unwrapOption(val)
        setReg(vm, instr.a, unwrapped)
        if verbose:
          echo "[REGVM] ropUnwrapOption: unwrapped Some value to reg ", instr.a, " value: ",
            if isInt(unwrapped): $getInt(unwrapped)
            elif isFloat(unwrapped): $getFloat(unwrapped)
            elif isString(unwrapped): unwrapped.sval
            else: "unknown"
      else:
        setReg(vm, instr.a, makeNil())
        if verbose:
          echo "[REGVM] ropUnwrapOption: value was None, set nil in reg ", instr.a

    of ropUnwrapResult:
      # Unwrap Result value
      let val = getReg(vm, instr.b)
      if isOk(val) or isErr(val):
        setReg(vm, instr.a, unwrapResult(val))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Arrays ---
    of ropNewArray:
      var arr: V
      arr.data = TAG_ARRAY shl 48
      # Create array with actual size, initialized to nil
      arr.aval = newSeq[V](instr.bx)  # ABx format: use bx not b
      for i in 0'u16..<instr.bx:
        arr.aval[i] = makeNil()
      setReg(vm, instr.a, arr)
      if verbose:
        let checkReg = getReg(vm, instr.a)
        echo "[REGVM] ropNewArray: created array of size ", instr.bx, " in reg ", instr.a,
             " tag=", checkReg.getTag().toHex, " verify isArray=", checkReg.isArray()
        # Also check what's actually in register 3 right now
        if instr.a == 3:
          let r3 = vm.currentFrame.regs[3]
          echo "[REGVM] Register 3 check: tag=", r3.getTag().toHex,
               " isInt=", r3.isInt(),
               " isArray=", r3.isArray(),
               if r3.isInt(): " intVal=" & $r3.getInt() else: "",
               if r3.isArray(): " arrayLen=" & $r3.aval.len else: ""

    of ropGetIndex:
      let arr = getReg(vm, instr.b)
      let idx = getReg(vm, instr.c)
      if getTag(arr) == TAG_ARRAY and isInt(idx):
        let i = getInt(idx)
        if i >= 0 and i < arr.aval.len:
          setReg(vm, instr.a, arr.aval[i])
        else:
          setReg(vm, instr.a, makeNil())
      elif getTag(arr) == TAG_STRING and isInt(idx):
        # String indexing - return single character as char
        let i = getInt(idx)
        if i >= 0 and i < arr.sval.len:
          setReg(vm, instr.a, makeChar(arr.sval[i]))
        else:
          setReg(vm, instr.a, makeNil())
      else:
        setReg(vm, instr.a, makeNil())

    of ropSlice:
      # R[A] = R[B][R[C]:R[D]] where B is array/string, C is start, D is end
      # Since we only have 3 operands in ABC format, we need to handle this specially
      # We'll use a trick: D comes from the next register after C
      let arr = getReg(vm, instr.b)
      let startVal = getReg(vm, instr.c)
      let endVal = getReg(vm, instr.c + 1)  # End index is in the next register

      # Convert indices to integers, handling defaults
      let startIdx = if isInt(startVal): getInt(startVal) else: 0

      if getTag(arr) == TAG_STRING:
        let endIdx = if isInt(endVal):
          let val = getInt(endVal)
          if val < 0: arr.sval.len else: int(val)  # -1 means "until end"
        else: arr.sval.len
        let actualStart = max(0, min(int(startIdx), arr.sval.len))
        let actualEnd = max(actualStart, min(int(endIdx), arr.sval.len))

        if actualStart >= actualEnd:
          var res: V
          res.data = TAG_STRING shl 48
          res.sval = ""
          setReg(vm, instr.a, res)
        else:
          var res: V
          res.data = TAG_STRING shl 48
          res.sval = arr.sval[actualStart..<actualEnd]
          setReg(vm, instr.a, res)
      elif getTag(arr) == TAG_ARRAY:
        let endIdx = if isInt(endVal):
          let val = getInt(endVal)
          if val < 0: arr.aval.len else: int(val)  # -1 means "until end"
        else: arr.aval.len
        let actualStart = max(0, min(int(startIdx), arr.aval.len))
        let actualEnd = max(actualStart, min(int(endIdx), arr.aval.len))

        if actualStart >= actualEnd:
          var res: V
          res.data = TAG_ARRAY shl 48
          res.aval = @[]
          setReg(vm, instr.a, res)
        else:
          var res: V
          res.data = TAG_ARRAY shl 48
          res.aval = arr.aval[actualStart..<actualEnd]
          setReg(vm, instr.a, res)
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndex:
      var arr = getReg(vm, instr.a)
      let idx = getReg(vm, instr.b)
      let val = getReg(vm, instr.c)
      if getTag(arr) == TAG_ARRAY and isInt(idx):
        let i = getInt(idx)
        if i >= 0:
          if i >= arr.aval.len:
            arr.aval.setLen(i + 1)
          arr.aval[i] = val
          setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropGetIndexI:
      let arr = getReg(vm, uint8(instr.bx and 0xFF))
      let idx = int(instr.bx shr 8)
      if getTag(arr) == TAG_ARRAY and idx < arr.aval.len:
        setReg(vm, instr.a, arr.aval[idx])
      elif getTag(arr) == TAG_STRING and idx < arr.sval.len:
        setReg(vm, instr.a, makeChar(arr.sval[idx]))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndexI:
      var arr = getReg(vm, instr.a)
      let idx = int(instr.bx and 0xFF)
      let val = getReg(vm, uint8(instr.bx shr 8))
      if getTag(arr) == TAG_ARRAY:
        if idx >= arr.aval.len:
          arr.aval.setLen(idx + 1)
        arr.aval[idx] = val
        setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropLen:
      let val = getReg(vm, instr.b)
      if verbose:
        echo "[REGVM] ropLen: getting length of reg", instr.b, " tag=", getTag(val),
             " (", if getTag(val) == TAG_ARRAY: "Array"
                   elif getTag(val) == TAG_STRING: "String"
                   else: "Other", ")"
      if getTag(val) == TAG_ARRAY:
        let lenVal = makeInt(int64(val.aval.len))
        if verbose:
          echo "[REGVM] ropLen: array length = ", val.aval.len, " -> reg", instr.a
        setReg(vm, instr.a, lenVal)
      elif getTag(val) == TAG_STRING:
        let lenVal = makeInt(int64(val.sval.len))
        if verbose:
          echo "[REGVM] ropLen: string length = ", val.sval.len, " -> reg", instr.a
        setReg(vm, instr.a, lenVal)
      else:
        if verbose:
          echo "[REGVM] ropLen: not array/string, setting 0 -> reg", instr.a
        setReg(vm, instr.a, makeInt(0))

    # --- Objects/Tables ---
    of ropNewTable:
      # Create a new empty table
      setReg(vm, instr.a, makeTable())
      if verbose:
        echo "[REGVM] ropNewTable: created new table in reg ", instr.a

    of ropGetField:
      # Get field from table: R[A] = R[B][K[C]]
      let table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        if table.tval.hasKey(fieldName):
          setReg(vm, instr.a, table.tval[fieldName])
        else:
          setReg(vm, instr.a, makeNil())
          if verbose:
            echo "[REGVM] ropGetField: field '", fieldName, "' not found in table"
      else:
        setReg(vm, instr.a, makeNil())
        if verbose:
          echo "[REGVM] ropGetField: ERROR - reg ", instr.b, " is not a table"

    of ropSetField:
      # Set field in table: R[B][K[C]] = R[A]
      var table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        let value = getReg(vm, instr.a)
        table.tval[fieldName] = value
        setReg(vm, instr.b, table)
        if verbose:
          echo "[REGVM] ropSetField: set field '", fieldName, "' in table"
      else:
        if verbose:
          echo "[REGVM] ropSetField: ERROR - reg ", instr.b, " is not a table"

    # --- Control Flow ---
    of ropJmp:
      pc += int(instr.sbx)

    of ropTest:
      let val = getReg(vm, instr.a)
      let isTrue = getTag(val) != TAG_NIL and
                    not (getTag(val) == TAG_BOOL and (val.data and 1) == 0)
      if verbose:
        echo "[REGVM] ropTest: reg", instr.a, " val=", $val, " isTrue=", isTrue, " expected=", instr.c != 0, " skip=", isTrue != (instr.c != 0)
      if isTrue != (instr.c != 0):
        inc pc

    of ropTestSet:
      let val = getReg(vm, instr.b)
      let isTrue = getTag(val) != TAG_NIL and
                    not (getTag(val) == TAG_BOOL and (val.data and 1) == 0)
      if isTrue == (instr.c != 0):
        setReg(vm, instr.a, val)
      else:
        inc pc

    # --- Loops (Optimized) ---
    of ropForLoop:
      # Increment loop variable and test
      let idx = getReg(vm, instr.a)
      let limit = getReg(vm, instr.a + 1)
      let step = getReg(vm, instr.a + 2)

      # Debug output
      when defined(debugRegVM):
        echo "ForLoop: idx=", (if isInt(idx): $getInt(idx) else: "nil/non-int"),
             " limit=", (if isInt(limit): $getInt(limit) else: "nil/non-int"),
             " step=", (if isInt(step): $getInt(step) else: "nil/non-int"),
             " sbx=", instr.sbx
        echo "  -> reg[", instr.a, "] type tag = ", getTag(idx)
        echo "  -> reg[", instr.a+1, "] type tag = ", getTag(limit)
        echo "  -> reg[", instr.a+2, "] type tag = ", getTag(step)

      if isInt(idx) and isInt(limit) and isInt(step):
        let newIdx = getInt(idx) + getInt(step)
        setReg(vm, instr.a, makeInt(newIdx))

        if getInt(step) > 0:
          if newIdx < getInt(limit):  # Changed from <= to < for exclusive end
            pc += int(instr.sbx)  # Continue loop
        else:
          if newIdx > getInt(limit):  # Changed from >= to > for backward loops
            pc += int(instr.sbx)  # Continue loop

    of ropForPrep:
      # Prepare for loop - adjust initial value and check if loop should run
      let idx = getReg(vm, instr.a)
      let limit = getReg(vm, instr.a + 1)
      let step = getReg(vm, instr.a + 2)

      # Debug output
      when defined(debugRegVM):
        echo "ForPrep: idx=", (if isInt(idx): $getInt(idx) else: "?"),
             " limit=", (if isInt(limit): $getInt(limit) else: "?"),
             " step=", (if isInt(step): $getInt(step) else: "?"),
             " sbx=", instr.sbx

      if isInt(idx) and isInt(limit) and isInt(step):
        # Check if loop should run at all based on initial values
        let stepVal = getInt(step)
        let idxVal = getInt(idx)
        let limitVal = getInt(limit)

        when defined(debugRegVM):
          echo "  -> Initial idx=", idxVal, " limit=", limitVal, " step=", stepVal

        if stepVal > 0:
          if idxVal >= limitVal:
            # Skip loop entirely (e.g., for i in 5..<5)
            pc += int(instr.sbx)
        else:
          if idxVal <= limitVal:
            # Skip loop entirely (backward loop)
            pc += int(instr.sbx)
        # Otherwise continue to loop body

    # --- Function Calls ---
    of ropCall:
      let funcReg = instr.a
      let numArgs = instr.b
      let numResults = instr.c

      # Get function name from the register
      let funcNameVal = getReg(vm, funcReg)
      if verbose:
        echo "[REGVM] ropCall: funcReg=", funcReg, " numArgs=", numArgs, " numResults=", numResults
        if getTag(funcNameVal) == TAG_STRING:
          echo "[REGVM] ropCall: funcName='", funcNameVal.sval, "'"
        else:
          echo "[REGVM] ropCall: ERROR - funcReg doesn't contain a string!"
      if getTag(funcNameVal) != TAG_STRING:
        # Not a valid function name
        setReg(vm, funcReg, makeNil())
        continue

      let funcName = funcNameVal.sval

      # Check for C FFI functions first - try to call through the registry
      if callCFFIFunction(vm, funcName, funcReg, numArgs):
        if verbose:
          echo "[REGVM] Called C FFI function: ", funcName
        continue

      # If not in registry but in cffiInfo, it means the library wasn't loaded
      if vm.program.cffiInfo.hasKey(funcName):
        let cffiInfo = vm.program.cffiInfo[funcName]
        if verbose:
          echo "[REGVM] C FFI function not loaded: ", funcName, " (library: ", cffiInfo.library, ")"
        setReg(vm, funcReg, makeNil())
        continue

      # Check for user-defined functions
      elif vm.program.functions.hasKey(funcName):
        let funcInfo = vm.program.functions[funcName]

        if verbose:
          echo "[REGVM] Calling user function ", funcName, " at ", funcInfo.startPos, " with ", numArgs, " args, result reg=", funcReg

        # Debugger hook - push stack frame
        if vm.debugger != nil:
          let debugger = cast[RegEtchDebugger](vm.debugger)
          # Get debug info from the first instruction of the function being called
          let funcFirstInstr = if funcInfo.startPos < vm.program.instructions.len:
            vm.program.instructions[funcInfo.startPos]
          else:
            instr
          let targetFile = if funcFirstInstr.debug.sourceFile.len > 0:
            funcFirstInstr.debug.sourceFile
          else:
            "main"
          let targetLine = if funcFirstInstr.debug.line > 0:
            funcFirstInstr.debug.line
          else:
            1  # Default to line 1 if no debug info
          debugger.pushStackFrame(funcName, targetFile, targetLine, false)

        # Create new frame for the function
        var newFrame = RegisterFrame()
        newFrame.returnAddr = pc + 1  # Save position AFTER this call instruction
        newFrame.baseReg = funcReg     # Save result register

        # Copy arguments to new frame's registers starting at R0
        for i in 0'u8..<numArgs:
          let argVal = getReg(vm, funcReg + 1'u8 + i)
          newFrame.regs[i] = argVal
          if verbose:
            echo "[REGVM] Copying arg ", i, " from reg ", funcReg + 1'u8 + i, " to new frame reg ", i,
                 " tag=", getTag(argVal),
                 if getTag(argVal) == TAG_ARRAY: " (Array len=" & $argVal.aval.len & ")"
                 elif getTag(argVal) == TAG_INT: " (Int=" & $getInt(argVal) & ")"
                 else: ""

        # Push frame
        vm.frames.add(newFrame)
        vm.currentFrame = addr vm.frames[^1]

        # Jump to function
        pc = funcInfo.startPos
        continue

      # Handle builtin functions inline for performance
      # For builtin and C FFI functions, we need to handle both the mangled
      # names (with type info) and base names for compatibility

      # Debugger hook - track builtin function call
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        let currentFile = if instr.debug.sourceFile.len > 0: instr.debug.sourceFile else: "main"
        debugger.pushStackFrame(funcName, currentFile, instr.debug.line, true)  # isBuiltIn = true

      case funcName:
      of "seed":
        if numArgs == 1:
          let seedVal = getReg(vm, funcReg + 1)
          if isInt(seedVal):
            c_srand(cuint(getInt(seedVal)))
          setReg(vm, funcReg, makeNil())

      of "rand":
        if numArgs == 1:
          # Single argument: rand(max) means rand from 0 to max
          let maxVal = getReg(vm, funcReg + 1)
          if isInt(maxVal):
            let maxInt = getInt(maxVal)
            if maxInt > 0:
              let randVal = c_rand() mod cint(maxInt)
              setReg(vm, funcReg, makeInt(int64(randVal)))
            else:
              setReg(vm, funcReg, makeInt(0))
        elif numArgs == 2:
          # Arguments: rand(max, min) in Etch becomes rand(arg1=max, arg2=min)
          let maxVal = getReg(vm, funcReg + 1)  # First argument is max
          let minVal = getReg(vm, funcReg + 2)  # Second argument is min
          if isInt(minVal) and isInt(maxVal):
            let minInt = getInt(minVal)
            let maxInt = getInt(maxVal)
            let range = maxInt - minInt
            if range > 0:
              let randVal = (c_rand() mod cint(range)) + cint(minInt)
              setReg(vm, funcReg, makeInt(int64(randVal)))
            else:
              setReg(vm, funcReg, makeInt(minInt))

      of "print":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Build the string to print
          let output = if isInt(val):
            $getInt(val)
          elif isFloat(val):
            $getFloat(val)
          elif isChar(val):
            $getChar(val)
          elif getTag(val) == TAG_BOOL:
            if (val.data and 1) != 0: "true" else: "false"
          elif getTag(val) == TAG_STRING:
            val.sval
          elif getTag(val) == TAG_ARRAY:
            # Print array elements
            var res = "["
            for i, elem in val.aval:
              if i > 0: res.add(", ")
              if isInt(elem): res.add($getInt(elem))
              elif isFloat(elem): res.add($getFloat(elem))
              elif getTag(elem) == TAG_STRING: res.add("\"" & elem.sval & "\"")
              elif getTag(elem) == TAG_BOOL:
                res.add(if (elem.data and 1) != 0: "true" else: "false")
              else: res.add("nil")
            res.add("]")
            res
          else:
            "nil"

          # Use unified print handler
          vmPrint(vm, output, outputBuffer, outputCount)

          # Flush if buffer is getting large or we have many lines
          if outputBuffer.len >= BUFFER_SIZE or outputCount >= 100:
            flushOutput()

          setReg(vm, funcReg, makeNil())

      of "toString":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          var res: V
          res.data = TAG_STRING shl 48
          if isInt(val):
            res.sval = $getInt(val)
          elif isFloat(val):
            res.sval = $getFloat(val)
          elif isChar(val):
            res.sval = $getChar(val)
          elif getTag(val) == TAG_BOOL:
            res.sval = if (val.data and 1) != 0: "true" else: "false"
          elif getTag(val) == TAG_STRING:
            res.sval = val.sval
          else:
            res.sval = "nil"
          setReg(vm, funcReg, res)

      # Mock C functions for testing
      of "c_add":
        if numArgs == 2:
          let a = getReg(vm, funcReg + 1)
          let b = getReg(vm, funcReg + 2)
          if isInt(a) and isInt(b):
            setReg(vm, funcReg, makeInt(getInt(a) + getInt(b)))
          else:
            setReg(vm, funcReg, makeNil())

      of "c_multiply":
        if numArgs == 2:
          let a = getReg(vm, funcReg + 1)
          let b = getReg(vm, funcReg + 2)
          if isInt(a) and isInt(b):
            setReg(vm, funcReg, makeInt(getInt(a) * getInt(b)))
          else:
            setReg(vm, funcReg, makeNil())

      # Reference operations
      of "new":
        if numArgs == 1:
          # For now, just pass through the value (references are not truly implemented)
          # In a real implementation, this would allocate heap memory
          let val = getReg(vm, funcReg + 1)
          setReg(vm, funcReg, val)
        else:
          setReg(vm, funcReg, makeNil())

      of "deref":
        if numArgs == 1:
          # For now, just pass through the value (references are not truly implemented)
          # In a real implementation, this would dereference the pointer
          let val = getReg(vm, funcReg + 1)
          setReg(vm, funcReg, val)
        else:
          setReg(vm, funcReg, makeNil())

      # File I/O operations
      of "readFile":
        if numArgs == 1:
          let pathVal = getReg(vm, funcReg + 1)
          if isString(pathVal):
            try:
              let content = readFile(pathVal.sval)
              setReg(vm, funcReg, makeString(content))
            except:
              setReg(vm, funcReg, makeString(""))
          else:
            setReg(vm, funcReg, makeString(""))
        else:
          setReg(vm, funcReg, makeString(""))

      # Parsing functions
      of "parseInt":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            try:
              let intVal = parseInt(strVal.sval)
              # Return Some(intVal)
              setReg(vm, funcReg, makeSome(makeInt(int64(intVal))))
            except:
              # Return None
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      of "parseFloat":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            try:
              let floatVal = parseFloat(strVal.sval)
              # Return Some(floatVal)
              setReg(vm, funcReg, makeSome(makeFloat(floatVal)))
            except:
              # Return None
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      of "parseBool":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            if strVal.sval == "true":
              setReg(vm, funcReg, makeSome(makeBool(true)))
            elif strVal.sval == "false":
              setReg(vm, funcReg, makeSome(makeBool(false)))
            else:
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      # Option/Result type checking
      of "isSome":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Some tag
          setReg(vm, funcReg, makeBool(isSome(val)))
        else:
          setReg(vm, funcReg, makeBool(false))

      of "isNone":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the None tag
          setReg(vm, funcReg, makeBool(isNone(val)))
        else:
          setReg(vm, funcReg, makeBool(true))

      of "isOk":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Ok tag
          setReg(vm, funcReg, makeBool(isOk(val)))
        else:
          setReg(vm, funcReg, makeBool(false))

      of "isErr":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Err tag
          setReg(vm, funcReg, makeBool(isErr(val)))
        else:
          setReg(vm, funcReg, makeBool(true))

      else:
        # Check if it's an unimplemented builtin that just returns the function name
        # (This is a placeholder for unimplemented builtins)
        if verbose:
          echo "[REGVM] Unknown function: ", funcName, " - returning function name as string"
        var res: V
        res.data = TAG_STRING shl 48
        res.sval = funcName
        setReg(vm, funcReg, res)

      # Debugger hook - pop builtin function frame
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        debugger.popStackFrame()

    of ropReturn:
      # Return from function
      let numResults = instr.a
      let firstResultReg = instr.b

      if verbose:
        echo "[REGVM] ropReturn: numResults=", numResults, " firstResultReg=", firstResultReg, " frames.len=", vm.frames.len

      # Debugger hook - pop stack frame
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        debugger.popStackFrame()

      # Check if we're returning from main (only 1 frame)
      if vm.frames.len <= 1:
        # Flush output buffer before exiting
        flushOutput()
        stdout.flushFile()
        return 0

      # Get return value (if any)
      var returnValue = makeNil()
      if numResults > 0:
        returnValue = getReg(vm, firstResultReg)

      # Pop frame
      let returnAddr = vm.currentFrame.returnAddr
      let resultReg = vm.currentFrame.baseReg
      discard vm.frames.pop()

      # Restore previous frame
      if vm.frames.len > 0:
        vm.currentFrame = addr vm.frames[^1]
        # Store return value in the result register (only if function returns a value)
        if numResults > 0:
          setReg(vm, resultReg, returnValue)
        # Continue execution after the call
        # Note: pc will be incremented at the start of the loop, so we need to decrement by 1
        pc = returnAddr - 1
        continue
      else:
        # No more frames, exit
        return 0

    # --- Fused Instructions (Aggressive Optimization) ---
    of ropAddAdd:
      # R[A] = R[B] + R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) + getInt(c) + getInt(d)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropMulAdd:
      # R[A] = R[B] * R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) * getInt(c) + getInt(d)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropCmpJmp:
      # Combined compare and jump
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)

      if doLt(b, c):
        pc += int(jmpOffset)

    of ropIncTest:
      # Increment and test (common loop pattern)
      var val = getReg(vm, instr.a)
      if isInt(val):
        let newVal = getInt(val) + 1
        setReg(vm, instr.a, makeInt(newVal))
        if newVal < int64(instr.bx):
          pc += int(instr.sbx)

    else:
      # Unimplemented instructions
      discard

  # Flush any remaining buffered output
  flushOutput()
  # Ensure all output is written to terminal
  stdout.flushFile()
  return 0

# Run a register-based program
proc runRegProgram*(prog: RegBytecodeProgram, verbose: bool = false): int =
  let vm = newRegisterVM(prog)
  return vm.execute(verbose)