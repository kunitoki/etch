# regvm_exec.nim
# Execution engine for register-based VM with aggressive optimizations

import std/[tables, macros, math, strutils, times]
import ../common/[constants, cffi, values, logging]
import regvm, regvm_debugger, regvm_profiler, regvm_replay, regvm_lifetime

# Global table to store values injected during comptime execution
var comptimeInjections*: Table[string, V] = initTable[string, V]()

# Cross-platform deterministic PRNG using Xorshift64*
# This ensures consistent random number generation across Linux, macOS, and Windows
# Algorithm: https://en.wikipedia.org/wiki/Xorshift
# Period: 2^64 - 1, excellent statistical properties


# Logging helper for VM execution
macro log(verbose: untyped, msg: untyped): untyped =
  result = quote do:
    if `verbose`:
      logCompiler(true, `msg`)


proc etch_srand(vm: RegisterVM, seed: uint64) {.inline.} =
  # Initialize RNG state with seed
  # Avoid zero state (would produce all zeros)
  vm.rngState = if seed == 0: 1'u64 else: seed


proc etch_rand(vm: RegisterVM): uint64 {.inline.} =
  # Xorshift64* algorithm
  let oldState = vm.rngState
  var x = vm.rngState
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  vm.rngState = x

  # Replay engine hook - record RNG state change
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      engine.recordDelta(ExecutionDelta(
        instructionIndex: vm.currentFrame.pc,
        kind: dkRNGChange,
        oldRNG: oldState,
        newRNG: x
      ))

  result = x * 0x2545F4914F6CDD1D'u64  # Multiplication constant for better distribution


# Create new VM instance
proc newRegisterVM*(prog: RegBytecodeProgram): RegisterVM =
  result = RegisterVM(
    frames: @[RegisterFrame()],
    program: prog,
    constants: prog.constants,
    globals: initTable[string, V](),
    debugger: nil,  # No debugger by default - zero cost
    isDebugging: false,  # Not in debug mode
    cffiRegistry: cast[pointer](globalCFFIRegistry),  # Use global C FFI registry
    rngState: 1'u64,  # Initialize RNG with default seed
    profiler: nil,  # No profiler by default - zero cost
    isProfiling: false,  # Not profiling by default
    replayEngine: nil,  # No replay engine by default - zero cost
    isReplaying: false  # Not replaying by default
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
    cffiRegistry: cast[pointer](globalCFFIRegistry),  # Use global C FFI registry
    rngState: 1'u64,  # Initialize RNG with default seed
    profiler: nil,  # No profiler by default - zero cost
    isProfiling: false,  # Not profiling by default
    replayEngine: nil,  # No replay engine by default - zero cost
    isReplaying: false  # Not replaying by default
  )
  result.currentFrame = addr result.frames[0]
  # Attach the debugger to this VM
  if debugger != nil:
    debugger.attachToVM(cast[pointer](result))


proc newRegisterVMWithProfiler*(prog: RegBytecodeProgram): RegisterVM =
  let profiler = newProfiler()
  GC_ref(profiler)  # Keep profiler alive
  result = RegisterVM(
    frames: @[RegisterFrame()],
    program: prog,
    constants: prog.constants,
    globals: initTable[string, V](),
    debugger: nil,
    isDebugging: false,
    cffiRegistry: cast[pointer](globalCFFIRegistry),
    rngState: 1'u64,
    profiler: cast[pointer](profiler),
    isProfiling: true,
    replayEngine: nil,  # No replay engine by default - zero cost
    isReplaying: false  # Not replaying by default
  )
  result.currentFrame = addr result.frames[0]


# Fast register access macros
template getReg(vm: RegisterVM, idx: uint8): V =
  vm.currentFrame.regs[idx]

template setReg(vm: RegisterVM, idx: uint8, val: sink V) =
  vm.currentFrame.regs[idx] = val

template getConst(vm: RegisterVM, idx: uint16): V =
  vm.constants[idx]

# Debugger helper functions that need access to V type
proc formatRegisterValue*(v: V): string =
  case v.kind
  of vkInt:
    result = $v.ival
  of vkFloat:
    result = formatFloat(v.fval, ffDefault, -1)
  of vkBool:
    result = $v.bval
  of vkNil:
    result = "nil"
  of vkChar:
    result = "'" & $v.cval & "'"
  of vkString:
    result = "\"" & v.sval & "\""
  of vkArray:
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
  of vkTable:
    result = "{table:" & $v.tval.len & " entries}"
  of vkSome:
    let inner = v.wrapped[]
    result = "some(" & formatRegisterValue(inner) & ")"
  of vkNone:
    result = "none"
  of vkOk:
    let inner = v.wrapped[]
    result = "ok(" & formatRegisterValue(inner) & ")"
  of vkErr:
    let inner = v.wrapped[]
    result = "error(" & formatRegisterValue(inner) & ")"

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
    var res = newStringOfCap(v.aval.len * 8)
    res.add("[")
    for i, elem in v.aval:
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
  else:
    result = "nil"

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
  case v.kind
  of vkInt:
    result = "int"
  of vkFloat:
    result = "float"
  of vkBool:
    result = "bool"
  of vkNil:
    result = "nil"
  of vkChar:
    result = "char"
  of vkString:
    result = "string"
  of vkArray:
    result = "array[" & $v.aval.len & "]"
  of vkTable:
    result = "table"
  of vkSome:
    result = "option"
  of vkNone:
    result = "option"
  of vkOk:
    result = "result"
  of vkErr:
    result = "result"

# Optimized arithmetic operations with type specialization
template doAdd(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival + b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval + b.fval)
  elif a.kind == vkString and b.kind == vkString:
    var resultStr = newStringOfCap(a.sval.len + b.sval.len)
    resultStr.add(a.sval)
    resultStr.add(b.sval)
    makeString(ensureMove(resultStr))
  elif a.kind == vkArray and b.kind == vkArray:
    var resultArr = newSeqOfCap[V](a.aval.len + b.aval.len)
    resultArr.add(a.aval)
    resultArr.add(b.aval)
    makeArray(ensureMove(resultArr))
  else:
    makeNil()

template doSub(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival - b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval - b.fval)
  else:
    makeNil()

template doMul(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival * b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval * b.fval)
  else:
    makeNil()

template doDiv(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival div b.ival)
  elif a.kind == vkFloat and b.kind == vkFloat:
    makeFloat(a.fval / b.fval)
  else:
    makeNil()

template doMod(a, b: V): V =
  if a.kind == vkInt and b.kind == vkInt:
    makeInt(a.ival mod b.ival)
  else:
    makeNil()

template doLt(a, b: V): bool =
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

template doLe(a, b: V): bool =
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

template doEq(a, b: V): bool =
  if a.kind != b.kind:
    false
  elif a.kind == vkInt:
    a.ival == b.ival
  elif a.kind == vkFloat:
    a.fval == b.fval
  elif a.kind == vkBool:
    a.bval == b.bval
  elif a.kind == vkChar:
    a.cval == b.cval
  elif a.kind == vkString:
    a.sval == b.sval
  elif a.kind == vkNil:
    true
  else:
    false

# Converter between V type (VM value) and Value type (C FFI value)
proc toValue(v: V): Value =
  ## Convert VM value to C FFI Value type
  case v.kind
  of vkInt:
    result = Value(kind: vkInt, intVal: v.ival)
  of vkFloat:
    result = Value(kind: vkFloat, floatVal: v.fval)
  of vkChar:
    # Convert char to int for C FFI
    result = Value(kind: vkInt, intVal: int64(v.cval))
  of vkString:
    result = Value(kind: vkString, stringVal: v.sval)
  of vkBool:
    result = Value(kind: vkBool, boolVal: v.bval)
  of vkArray:
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
    let res = registry.callFunction(funcName, args)
    setReg(vm, funcReg, fromValue(res))
    return true
  except:
    # On error, set result to nil
    setReg(vm, funcReg, makeNil())
    return true  # We handled it, even if it errored

# Unified output handling for consistent behavior between debug and normal execution
proc vmPrint(vm: RegisterVM, output: string, outputBuffer: var string, outputCount: var int) =
  ## Unified print function that handles output consistently
  if vm.isDebugging:
    # In debug mode, use output callback if available
    if vm.outputCallback != nil:
      vm.outputCallback(output & "\n")
    else:
      # Fallback to stderr if no callback (shouldn't happen in normal debug flow)
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

# Main execution loop - highly optimized with computed goto if available
proc execute*(vm: RegisterVM, verbose: bool = false): int =
  # When debugging, resume from where we left off; otherwise start from entry point
  var pc = if vm.isDebugging and vm.currentFrame.pc >= 0: vm.currentFrame.pc else: vm.program.entryPoint
  let instructions = vm.program.instructions
  let maxInstr = instructions.len
  vm.currentFrame.pc = pc  # Initialize PC in frame

  # Track entry function (typically "main") for profiling
  if vm.profiler != nil and not vm.isDebugging:
    let profiler = cast[RegVMProfiler](vm.profiler)
    # Find which function contains the entry point
    for funcName, funcInfo in vm.program.functions:
      if pc >= funcInfo.startPos and pc <= funcInfo.endPos:
        profiler.enterFunction(funcName)
        break

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

    # Replay engine hook - statement-level snapshots (BEFORE instruction)
    var shouldTakeSnapshot = false
    var statementToSnapshot = 0
    if vm.replayEngine != nil:
      let engine = cast[ReplayEngine](vm.replayEngine)
      if engine.isRecording:
        let debug = instr.debug
        # Detect statement changes (new source line)
        if debug.line > 0 and (debug.line != engine.lastSourceLine or debug.sourceFile != engine.lastSourceFile):
          engine.currentStatement += 1
          engine.lastSourceLine = debug.line
          engine.lastSourceFile = debug.sourceFile
          # Debug: print what statements we're counting
          if false:  # Set to true for debugging
            echo "Statement ", engine.currentStatement, ": line ", debug.line, " in ", debug.functionName
          # Mark that we should take a snapshot AFTER this instruction executes
          if engine.currentStatement mod engine.snapshotInterval == 0:
            shouldTakeSnapshot = true
            statementToSnapshot = engine.currentStatement

    # Profiler hook - before instruction
    if vm.profiler != nil:
      let profiler = cast[RegVMProfiler](vm.profiler)
      let debug = instr.debug
      profiler.recordInstructionStart(instr.op, debug.sourceFile, debug.line, debug.functionName)

    # Debugger hook - before instruction
    if vm.debugger != nil:
      let debugger = cast[RegEtchDebugger](vm.debugger)
      let debug = instr.debug
      if debug.line > 0:  # Valid debug info
        if debugger.shouldBreak(pc, debug.sourceFile, debug.line):
          # Update last position AFTER we decide to break
          debugger.lastFile = debug.sourceFile
          debugger.lastLine = debug.line
          debugger.lastPC = pc
          debugger.pause()
          # Send break event
          debugger.sendBreakpointHit(debug.sourceFile, debug.line)
          # Return to debug server - it will call execute() again when continuing
          # NOTE: We DON'T execute the instruction at this PC yet. When we resume,
          # we'll start from this PC and execute it then.
          flushOutput()
          return -1  # Special return code: paused for debugging

    if verbose:
      log(verbose, "[" & $pc & "] " & $instr.op & " a=" & $instr.a &
            (if instr.opType == 0: " b=" & $instr.b & " c=" & $instr.c
            elif instr.opType == 1: " bx=" & $instr.bx
            elif instr.opType == 2: " sbx=" & $instr.sbx
            else: " ax=" & $instr.ax))
      log(verbose, "PC=" & $pc & " op=" & $instr.op)

    inc pc

    # Use computed goto table for maximum performance
    # (Nim doesn't support computed goto, so we use case)
    case instr.op:

    # --- Move and Load Instructions ---
    of ropMove:
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, val)
      log(verbose, "ropMove: reg" & $instr.b & " -> reg" & $instr.a &  " value kind=" & $val.kind &
          (if val.isInt(): " int=" & $val.ival else: ""))

    of ropLoadK:
      # Handle both ABx (constant pool) and AsBx (immediate) formats
      if instr.opType == 1:  # ABx format - load from constant pool
        log(verbose, "ropLoadK: loading const[" & $instr.bx & "] to reg " & $instr.a)
        setReg(vm, instr.a, getConst(vm, instr.bx))
      elif instr.opType == 2:  # AsBx format - immediate integer
        log(verbose, "ropLoadK: loading immediate " & $instr.sbx & " to reg " & $instr.a)
        setReg(vm, instr.a, makeInt(int64(instr.sbx)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropLoadBool:
      setReg(vm, instr.a, makeBool(instr.b != 0))
      if instr.c != 0:
        inc pc  # Skip next instruction

    of ropLoadNil:
      log(verbose, "ropLoadNil: setting reg" & $instr.a & ".." & $instr.b & " to nil")
      let nilValue = makeNil()
      for i in instr.a..instr.b:
        setReg(vm, i, nilValue)

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
        # Record delta for replay
        if vm.replayEngine != nil:
          let engine = cast[ReplayEngine](vm.replayEngine)
          if engine.isRecording:
            let oldValue = if vm.globals.hasKey(name): vm.globals[name] else: makeNil()
            let newValue = getReg(vm, instr.a)
            engine.recordDelta(ExecutionDelta(
              instructionIndex: pc,
              kind: dkGlobalWrite,
              globalName: name,
              oldGlobal: oldValue,
              newGlobal: newValue
            ))
        vm.globals[name] = getReg(vm, instr.a)

    of ropInitGlobal:
      # Initialize global only if not already set (used in <global> function)
      # This allows C API to override compile-time initialization
      if instr.opType == 1 and int(instr.bx) < vm.constants.len:
        let name = vm.constants[instr.bx].sval
        if not vm.globals.hasKey(name):
          # Only set if not already present
          if vm.replayEngine != nil:
            let engine = cast[ReplayEngine](vm.replayEngine)
            if engine.isRecording:
              engine.recordDelta(ExecutionDelta(
                instructionIndex: pc,
                kind: dkGlobalWrite,
                globalName: name,
                oldGlobal: makeNil(),
                newGlobal: getReg(vm, instr.a)
              ))
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
      if isInt(reg):
        # Reinterpret unsigned 8-bit value as signed using two's complement
        let imm8 = uint8((instr.bx shr 8) and 0xFF)
        let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
        setReg(vm, instr.a, makeInt(getInt(reg) + imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSubI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      if isInt(reg):
        # Reinterpret unsigned 8-bit value as signed using two's complement
        let imm8 = uint8((instr.bx shr 8) and 0xFF)
        let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
        setReg(vm, instr.a, makeInt(getInt(reg) - imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropMulI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      if isInt(reg):
        # Reinterpret unsigned 8-bit value as signed using two's complement
        let imm8 = uint8((instr.bx shr 8) and 0xFF)
        let imm = int64(if imm8 < 128: int(imm8) else: int(imm8) - 256)
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
      log(verbose, "ropEq: reg" & $instr.b & " kind=" & $b.kind & " reg" & $instr.c & " kind=" & $c.kind &
          " equal=" & $isEqual & " skipIfNot=" & $skipIfNot & " willSkip=" & $(isEqual != skipIfNot))
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
      log(verbose, "ropLtStore: reg" & $instr.a & " = reg" & $instr.b & "(" & $b & ") < reg" & $instr.c & "(" & $c & ") = " & $res)
      setReg(vm, instr.a, res)

    of ropLeStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let res = makeBool(doLe(b, c))
      log(verbose, "ropLeStore: reg" & $instr.a & " = reg" & $instr.b & "(" & $b & ") <= reg" & $instr.c & "(" & $c & ") = " & $res)
      setReg(vm, instr.a, res)

    # --- Logical Operations ---
    of ropNot:
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeBool(val.kind == vkNil or (val.kind == vkBool and not val.bval)))

    of ropAnd:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      log(verbose, "ropAnd: reg" & $instr.b & " kind=" & $b.kind & " AND reg" & $instr.c & " kind=" & $c.kind)
      # Both values should be booleans - perform logical AND
      if b.kind == vkBool and c.kind == vkBool:
        let bVal = b.bval
        let cVal = c.bval
        setReg(vm, instr.a, makeBool(bVal and cVal))
        log(verbose, "ropAnd: " & $bVal & " AND " & $cVal & " = " & $(bVal and cVal))
      else:
        # Fallback to old behavior for non-boolean values
        if b.kind == vkNil or (b.kind == vkBool and not b.bval):
          setReg(vm, instr.a, b)
        else:
          setReg(vm, instr.a, c)

    of ropOr:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      if b.kind != vkNil and not (b.kind == vkBool and not b.bval):
        setReg(vm, instr.a, b)
      else:
        setReg(vm, instr.a, c)

    # --- Membership operators ---
    of ropIn:
      let needle = getReg(vm, instr.b)
      let haystack = getReg(vm, instr.c)
      var found = false

      if isArray(haystack):
        # Check if needle is in array
        for i in 0..<haystack.aval.len:
          if doEq(needle, haystack.aval[i]):
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

    of ropNotIn:
      let needle = getReg(vm, instr.b)
      let haystack = getReg(vm, instr.c)
      var found = false

      if isArray(haystack):
        # Check if needle is in array
        for i in 0..<haystack.aval.len:
          if doEq(needle, haystack.aval[i]):
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

    # --- Type conversions ---
    of ropCast:
      let val = getReg(vm, instr.b)
      let castType = VKind(instr.c)  # Cast to VKind enum
      var res: V

      case castType:
      of vkInt:  # To int
        if isInt(val):
          res = val
        elif isFloat(val):
          res = makeInt(int64(getFloat(val)))
        elif isString(val):
          try:
            res = makeInt(int64(parseInt(val.sval)))
          except:
            res = makeNil()
        else:
          res = makeNil()

      of vkFloat:  # To float
        if isFloat(val):
          res = val
        elif isInt(val):
          res = makeFloat(float64(getInt(val)))
        elif isString(val):
          try:
            res = makeFloat(parseFloat(val.sval))
          except:
            res = makeNil()
        else:
          res = makeNil()

      of vkString:  # To string
        if isInt(val):
          res = makeString($getInt(val))
        elif isFloat(val):
          let fv = getFloat(val)
          if fv == float64(int64(fv)):
            res = makeString(formatFloat(fv, ffDecimal, 1))
          else:
            let fstr = formatFloat(fv, ffDefault, -1)
            if '.' notin fstr and 'e' notin fstr and 'E' notin fstr:
              res = makeString(fstr & ".0")
            else:
              res = makeString(fstr)
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
      # Wrap value as some
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeSome(val))

    of ropLoadNone:
      # Load none value
      setReg(vm, instr.a, makeNone())

    of ropWrapOk:
      # Wrap value as ok
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeOk(val))

    of ropWrapErr:
      # Wrap value as error
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeErr(val))

    of ropTestTag:
      # Test if register has specific tag
      # Skip next instruction if tags MATCH (for match expressions)
      let val = getReg(vm, instr.a)
      let expectedKind = VKind(instr.b)
      let actualKind = val.kind
      log(verbose, "ropTestTag: reg=" & $instr.a & " expected=" & $expectedKind & " actual=" & $actualKind & " match=" & $(actualKind == expectedKind))
      if actualKind == expectedKind:
        log(verbose, "ropTestTag: tags match, skipping next instruction (PC " & $pc & " -> " & $(pc + 1) & ")")
        inc pc  # Skip next instruction if tags match

    of ropUnwrapOption:
      # Unwrap Option value
      let val = getReg(vm, instr.b)
      if val.isSome():
        let unwrapped = val.unwrapOption()
        setReg(vm, instr.a, unwrapped)
        log(verbose, "ropUnwrapOption: unwrapped some value to reg " & $instr.a & " value: " &
            (if unwrapped.isInt(): $unwrapped.ival
             elif unwrapped.isFloat(): $unwrapped.fval
             elif unwrapped.isString(): unwrapped.sval
             else: "unknown"))
      else:
        setReg(vm, instr.a, makeNil())
        log(verbose, "ropUnwrapOption: value was none, set nil in reg " & $instr.a)

    of ropUnwrapResult:
      # Unwrap Result value
      let val = getReg(vm, instr.b)
      if val.isOk() or val.isErr():
        setReg(vm, instr.a, val.unwrapResult())
      else:
        setReg(vm, instr.a, makeNil())

    # --- Arrays ---
    of ropNewArray:
      # Create array with actual size, initialized to nil
      var nilSeq = newSeq[V](instr.bx)
      let nilValue = makeNil()
      for i in 0 ..< nilSeq.len:
        nilSeq[i] = nilValue
      setReg(vm, instr.a, makeArray(ensureMove(nilSeq)))
      log(verbose, "ropNewArray: created array of size " & $instr.bx & " in reg " & $instr.a)

    of ropGetIndex:
      let arr = getReg(vm, instr.b)
      let idx = getReg(vm, instr.c)
      if arr.kind == vkArray and idx.isInt():
        let i = idx.ival
        if i >= 0 and i < arr.aval.len:
          setReg(vm, instr.a, arr.aval[i])
        else:
          setReg(vm, instr.a, makeNil())
      elif arr.kind == vkString and idx.isInt():
        # String indexing - return single character as char
        let i = idx.ival
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
          setReg(vm, instr.a, makeString(ensureMove(slicedStr)))
      elif arr.kind == vkArray:
        let endIdx = if endVal.isInt():
          let val = endVal.ival
          if val < 0: arr.aval.len else: int(val)  # -1 means "until end"
        else: arr.aval.len
        let actualStart = max(0, min(int(startIdx), arr.aval.len))
        let actualEnd = max(actualStart, min(int(endIdx), arr.aval.len))

        if actualStart >= actualEnd:
          var emptyArr: seq[V] = @[]
          setReg(vm, instr.a, makeArray(ensureMove(emptyArr)))
        else:
          var slicedArr = arr.aval[actualStart..<actualEnd]
          setReg(vm, instr.a, makeArray(ensureMove(slicedArr)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndex:
      var arr = getReg(vm, instr.a)
      let idx = getReg(vm, instr.b)
      if arr.kind == vkArray and idx.isInt():
        let i = idx.ival
        if i >= 0:
          if i >= arr.aval.len:
            arr.aval.setLen(i + 1)
          arr.aval[i] = getReg(vm, instr.c)
          setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropGetIndexI:
      let arr = getReg(vm, uint8(instr.bx and 0xFF))
      let idx = int(instr.bx shr 8)
      if arr.kind == vkArray and idx < arr.aval.len:
        setReg(vm, instr.a, arr.aval[idx])
      elif arr.kind == vkString and idx < arr.sval.len:
        setReg(vm, instr.a, makeChar(arr.sval[idx]))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndexI:
      var arr = getReg(vm, instr.a)
      if arr.kind == vkArray:
        let idx = int(instr.bx and 0xFF)
        if idx >= arr.aval.len:
          arr.aval.setLen(idx + 1)
        arr.aval[idx] = getReg(vm, uint8(instr.bx shr 8))
        setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropLen:
      let val = getReg(vm, instr.b)
      if val.kind == vkArray:
        let lenVal = makeInt(int64(val.aval.len))
        log(verbose, "ropLen: array length = " & $val.aval.len & " -> reg" & $instr.a)
        setReg(vm, instr.a, lenVal)
      elif val.kind == vkString:
        let lenVal = makeInt(int64(val.sval.len))
        log(verbose, "ropLen: string length = " & $val.sval.len & " -> reg" & $instr.a)
        setReg(vm, instr.a, lenVal)
      else:
        log(verbose, "ropLen: not array/string, setting 0 -> reg" & $instr.a)
        setReg(vm, instr.a, makeInt(0))

    # --- Objects/Tables ---
    of ropNewTable:
      # Create a new empty table
      setReg(vm, instr.a, makeTable())
      log(verbose, "ropNewTable: created new table in reg " & $instr.a)

    of ropGetField:
      # Get field from table: R[A] = R[B][K[C]]
      let table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        if table.tval.hasKey(fieldName):
          setReg(vm, instr.a, table.tval[fieldName])
        else:
          setReg(vm, instr.a, makeNil())
          log(verbose, "ropGetField: field '" & fieldName & "' not found in table")
      else:
        setReg(vm, instr.a, makeNil())
        log(verbose, "ropGetField: ERROR - reg " & $instr.b & " is not a table")

    of ropSetField:
      # Set field in table: R[B][K[C]] = R[A]
      var table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        table.tval[fieldName] = getReg(vm, instr.a)
        setReg(vm, instr.b, table)
        log(verbose, "ropSetField: set field '" & fieldName & "' in table")
      else:
        log(verbose, "ropSetField: ERROR - reg " & $instr.b & " is not a table")

    # --- Control Flow ---
    of ropJmp:
      pc += int(instr.sbx)

    of ropTest:
      let val = getReg(vm, instr.a)
      let isTrue = val.kind != vkNil and not (val.kind == vkBool and not val.bval)
      log(verbose, "ropTest: reg" & $instr.a & " val=" & $val & " isTrue=" & $isTrue & " expected=" & $(instr.c != 0) & " skip=" & $(isTrue != (instr.c != 0)))
      if isTrue != (instr.c != 0):
        inc pc

    of ropTestSet:
      let val = getReg(vm, instr.b)
      let isTrue = val.kind != vkNil and not (val.kind == vkBool and not val.bval)
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
      if verbose:
        log(verbose, "ForLoop: idx=" & (if idx.isInt(): $idx.ival else: "nil/non-int") &
              " limit=" & (if limit.isInt(): $limit.ival else: "nil/non-int") &
              " step=" & (if step.isInt(): $step.ival else: "nil/non-int") &
              " sbx=" & $instr.sbx)
        log(verbose, "  -> reg[" & $instr.a & "] type kind = " & $idx.kind)
        log(verbose, "  -> reg[" & $(instr.a + 1) & "] type kind = " & $limit.kind)
        log(verbose, "  -> reg[" & $(instr.a + 2) & "] type kind = " & $step.kind)

      if idx.isInt() and limit.isInt() and step.isInt():
        let newIdx = idx.ival + step.ival
        setReg(vm, instr.a, makeInt(newIdx))

        if step.ival > 0:
          if newIdx < limit.ival:  # Changed from <= to < for exclusive end
            pc += int(instr.sbx)  # Continue loop
        else:
          if newIdx > limit.ival:  # Changed from >= to > for backward loops
            pc += int(instr.sbx)  # Continue loop

    of ropForPrep:
      # Prepare for loop - adjust initial value and check if loop should run
      let idx = getReg(vm, instr.a)
      let limit = getReg(vm, instr.a + 1)
      let step = getReg(vm, instr.a + 2)

      # Debug output
      log(verbose,
        "ForPrep: idx=" & (if idx.isInt(): $idx.ival else: "?") &
        " limit=" & (if limit.isInt(): $limit.ival else: "?") &
        " step=" & (if step.isInt(): $step.ival else: "?") &
        " sbx=" & $instr.sbx)

      if idx.isInt() and limit.isInt() and step.isInt():
        # Check if loop should run at all based on initial values
        let stepVal = step.ival
        let idxVal = idx.ival
        let limitVal = limit.ival

        log(verbose, "  -> Initial idx=" & $idxVal & " limit=" & $limitVal & " step=" & $stepVal)

        if likely(stepVal > 0):
          if unlikely(idxVal >= limitVal):
            pc += int(instr.sbx)  # Skip loop
        else:
          if unlikely(idxVal <= limitVal):
            pc += int(instr.sbx)  # Skip loop

    # --- Function Calls ---
    of ropCall:
      # Function call using function table index
      # Defensive check: ensure this instruction has opType=4
      if instr.opType != 4:
        log(verbose, "ropCall: ERROR - instruction has opType=" & $instr.opType & ", expected 4")
        pc = pc + 1
        continue

      let resultReg = instr.a
      let funcIdx = instr.funcIdx
      let numArgs = instr.numArgs
      let numResults = instr.numResults

      # Validate function index
      if funcIdx >= uint16(vm.program.functionTable.len):
        log(verbose, "ropCall: ERROR - funcIdx " & $funcIdx & " out of range (max: " & $(vm.program.functionTable.len - 1) & ")")
        setReg(vm, resultReg, makeNil())
        continue

      let funcName = vm.program.functionTable[int(funcIdx)]
      log(verbose, "ropCall: funcIdx=" & $funcIdx & " funcName='" & funcName & "' numArgs=" & $numArgs & " numResults=" & $numResults)

      # Check for C FFI functions first
      if callCFFIFunction(vm, funcName, resultReg, numArgs):
        log(verbose, "Called C FFI function: " & funcName)
        continue

      # If not in registry but in cffiInfo, it means the library wasn't loaded
      if vm.program.cffiInfo.hasKey(funcName):
        let cffiInfo = vm.program.cffiInfo[funcName]
        log(verbose, "C FFI function not loaded: " & funcName & " (library: " & cffiInfo.library & ")")
        setReg(vm, resultReg, makeNil())
        continue

      # Check for user-defined functions
      elif vm.program.functions.hasKey(funcName):
        let funcInfo = vm.program.functions[funcName]
        log(verbose, "Calling user function " & funcName & " at " & $funcInfo.startPos &
            " with " & $numArgs & " args, result reg=" & $resultReg)

        # Debugger hook - push stack frame
        if vm.debugger != nil:
          let debugger = cast[RegEtchDebugger](vm.debugger)
          let funcFirstInstr = if funcInfo.startPos < vm.program.instructions.len:
            vm.program.instructions[funcInfo.startPos]
          else:
            instr
          let targetFile = if funcFirstInstr.debug.sourceFile.len > 0:
            funcFirstInstr.debug.sourceFile
          else:
            MAIN_FUNCTION_NAME
          let targetLine = if funcFirstInstr.debug.line > 0:
            funcFirstInstr.debug.line
          else:
            1

          # Special case: calling main from <global> is a transition, not a nested call
          if funcName == MAIN_FUNCTION_NAME and debugger.stackFrames.len > 0 and
             debugger.stackFrames[^1].functionName == GLOBAL_INIT_FUNCTION_NAME:
            debugger.popStackFrame()

          debugger.pushStackFrame(funcName, targetFile, targetLine, false)

        # Profiler hook - enter function
        if vm.profiler != nil:
          let profiler = cast[RegVMProfiler](vm.profiler)
          profiler.enterFunction(funcName)

        # Create new frame for the function
        var newFrame = RegisterFrame()
        newFrame.returnAddr = pc + 1
        newFrame.baseReg = resultReg

        # Copy arguments to new frame's registers
        for i in 0'u8..<numArgs:
          let argVal = getReg(vm, resultReg + 1'u8 + i)
          newFrame.regs[i] = argVal
          log(verbose, "Copying arg " & $i & " from reg " & $(resultReg + 1'u8 + i) &
              " to new frame reg " & $i & " kind=" & $argVal.kind)

        # Push frame
        vm.frames.add(newFrame)
        vm.currentFrame = addr vm.frames[^1]

        # Replay engine hook - record frame push
        if vm.replayEngine != nil:
          let engine = cast[ReplayEngine](vm.replayEngine)
          if engine.isRecording:
            engine.recordDelta(ExecutionDelta(
              instructionIndex: pc,
              kind: dkFramePush,
              pushedFrame: newFrame
            ))

        # Jump to function
        pc = funcInfo.startPos
        continue

      # Handle builtin functions
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        let currentFile = if instr.debug.sourceFile.len > 0: instr.debug.sourceFile else: MAIN_FUNCTION_NAME
        debugger.pushStackFrame(funcName, currentFile, instr.debug.line, true)

      case funcName:
      of "seed":
        if numArgs == 1:
          let seedVal = getReg(vm, resultReg + 1)
          if isInt(seedVal):
            etch_srand(vm, uint64(getInt(seedVal)))
          setReg(vm, resultReg, makeNil())

      of "rand":
        if numArgs == 1:
          let maxVal = getReg(vm, resultReg + 1)
          if isInt(maxVal):
            let maxInt = getInt(maxVal)
            if maxInt > 0:
              let randVal = int64(etch_rand(vm) mod uint64(maxInt))
              setReg(vm, resultReg, makeInt(randVal))
            else:
              setReg(vm, resultReg, makeInt(0))
        elif numArgs == 2:
          let minVal = getReg(vm, resultReg + 1)
          let maxVal = getReg(vm, resultReg + 2)
          if isInt(minVal) and isInt(maxVal):
            let minInt = getInt(minVal)
            let maxInt = getInt(maxVal)
            let range = maxInt - minInt
            if range > 0:
              let randVal = int64(etch_rand(vm) mod uint64(range)) + minInt
              setReg(vm, resultReg, makeInt(randVal))
            else:
              setReg(vm, resultReg, makeInt(minInt))

      of "print":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          let output = formatValueForPrint(val)
          vmPrint(vm, output, outputBuffer, outputCount)
          if outputBuffer.len >= BUFFER_SIZE or outputCount >= 100:
            flushOutput()
          setReg(vm, resultReg, makeNil())

      of "toString":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          let resStr = formatValueForPrint(val)
          setReg(vm, resultReg, makeString(resStr))

      of "new":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, val)
        else:
          setReg(vm, resultReg, makeNil())

      of "deref":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, val)
        else:
          setReg(vm, resultReg, makeNil())

      of "arrayNew":
        if numArgs == 2:
          let sizeVal = getReg(vm, resultReg + 1)
          let defaultVal = getReg(vm, resultReg + 2)
          if sizeVal.isInt():
            let size = sizeVal.ival
            var newArray = newSeq[V](size)
            for i in 0 ..< size:
              newArray[i] = defaultVal
            setReg(vm, resultReg, makeArray(ensureMove(newArray)))
          else:
            setReg(vm, resultReg, makeArray(@[]))
        else:
          setReg(vm, resultReg, makeArray(@[]))

      of "readFile":
        if numArgs == 1:
          let pathVal = getReg(vm, resultReg + 1)
          if isString(pathVal):
            try:
              let content = readFile(pathVal.sval)
              setReg(vm, resultReg, makeString(content))
            except:
              setReg(vm, resultReg, makeString(""))
          else:
            setReg(vm, resultReg, makeString(""))
        else:
          setReg(vm, resultReg, makeString(""))

      of "inject":
        # inject(name: string, type: string, value: any) -> void
        # Stores the value in comptimeInjections table for later retrieval
        if numArgs == 3:
          let nameVal = getReg(vm, resultReg + 1)
          let typeVal = getReg(vm, resultReg + 2)
          let valueVal = getReg(vm, resultReg + 3)
          if isString(nameVal) and isString(typeVal):
            # Store the value with its name as key
            comptimeInjections[nameVal.sval] = valueVal
        # inject returns void
        setReg(vm, resultReg, makeInt(0))

      of "parseInt":
        if numArgs == 1:
          let strVal = getReg(vm, resultReg + 1)
          if isString(strVal):
            try:
              let intVal = parseInt(strVal.sval)
              setReg(vm, resultReg, makeSome(makeInt(int64(intVal))))
            except:
              setReg(vm, resultReg, makeNone())
          else:
            setReg(vm, resultReg, makeNone())
        else:
          setReg(vm, resultReg, makeNone())

      of "parseFloat":
        if numArgs == 1:
          let strVal = getReg(vm, resultReg + 1)
          if isString(strVal):
            try:
              let floatVal = parseFloat(strVal.sval)
              setReg(vm, resultReg, makeSome(makeFloat(floatVal)))
            except:
              setReg(vm, resultReg, makeNone())
          else:
            setReg(vm, resultReg, makeNone())
        else:
          setReg(vm, resultReg, makeNone())

      of "parseBool":
        if numArgs == 1:
          let strVal = getReg(vm, resultReg + 1)
          if isString(strVal):
            if strVal.sval == "true":
              setReg(vm, resultReg, makeSome(makeBool(true)))
            elif strVal.sval == "false":
              setReg(vm, resultReg, makeSome(makeBool(false)))
            else:
              setReg(vm, resultReg, makeNone())
          else:
            setReg(vm, resultReg, makeNone())
        else:
          setReg(vm, resultReg, makeNone())

      of "isSome":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, makeBool(isSome(val)))
        else:
          setReg(vm, resultReg, makeBool(false))

      of "isNone":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, makeBool(isNone(val)))
        else:
          setReg(vm, resultReg, makeBool(true))

      of "isOk":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, makeBool(isOk(val)))
        else:
          setReg(vm, resultReg, makeBool(false))

      of "isErr":
        if numArgs == 1:
          let val = getReg(vm, resultReg + 1)
          setReg(vm, resultReg, makeBool(isErr(val)))
        else:
          setReg(vm, resultReg, makeBool(true))

      else:
        log(verbose, "Unknown function: " & funcName & " - returning nil")
        setReg(vm, resultReg, makeNil())

      # Debugger hook - pop builtin function frame
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        debugger.popStackFrame()

    of ropReturn:
      # Return from function
      let numResults = instr.a
      let firstResultReg = instr.b
      log(verbose, "ropReturn: numResults=" & $numResults & " firstResultReg=" & $firstResultReg & " frames.len=" & $vm.frames.len)

      # Debugger hook - pop stack frame
      if vm.debugger != nil:
        let debugger = cast[RegEtchDebugger](vm.debugger)
        debugger.popStackFrame()

      # Profiler hook - exit function
      if vm.profiler != nil:
        let profiler = cast[RegVMProfiler](vm.profiler)
        profiler.exitFunction()

      # Check if we're returning from main (only 1 frame)
      if vm.frames.len <= 1:
        # Flush output buffer before exiting
        flushOutput()
        stdout.flushFile()

        # Generate profiler report if profiling is enabled
        if vm.isProfiling and vm.profiler != nil:
          let profiler = cast[RegVMProfiler](vm.profiler)
          # Capture execution end time before report generation
          profiler.executionEndTime = getTime()
          let report = profiler.generateReport()
          echo report

        return 0

      # Get return value (if any)
      var returnValue = makeNil()
      if numResults > 0:
        returnValue = getReg(vm, firstResultReg)

      # Pop frame
      let returnAddr = vm.currentFrame.returnAddr
      let resultReg = vm.currentFrame.baseReg
      let poppedFrame = vm.frames[^1]  # Save for replay
      discard vm.frames.pop()

      # Replay engine hook - record frame pop
      if vm.replayEngine != nil:
        let engine = cast[ReplayEngine](vm.replayEngine)
        if engine.isRecording:
          engine.recordDelta(ExecutionDelta(
            instructionIndex: pc,
            kind: dkFramePop,
            poppedFrame: poppedFrame
          ))

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
        # Generate profiler report if profiling is enabled
        if vm.isProfiling and vm.profiler != nil:
          let profiler = cast[RegVMProfiler](vm.profiler)
          # Capture execution end time before report generation
          profiler.executionEndTime = getTime()
          let report = profiler.generateReport()
          echo report

        return 0

    of ropPushDefer:
      # Register a defer block by pushing its PC location to the defer stack
      let deferBodyOffset = instr.sbx
      let deferBodyPC = pc + deferBodyOffset
      vm.currentFrame.deferStack.add(deferBodyPC)
      log(verbose, "ropPushDefer: registered defer at PC " & $deferBodyPC)

    of ropExecDefers:
      # Execute all registered defers in reverse order (LIFO)
      log(verbose, "ropExecDefers: executing " & $vm.currentFrame.deferStack.len & " defers")
      if vm.currentFrame.deferStack.len > 0:
        # Pop the first defer and jump to it
        let deferPC = vm.currentFrame.deferStack.pop()
        log(verbose, "  Executing defer at PC " & $deferPC)

        # Save current PC to return after defer execution
        vm.currentFrame.deferReturnPC = pc
        # Jump to defer body (subtract 1 because pc will be incremented)
        pc = deferPC - 1

    of ropDeferEnd:
      # End of defer body - check if there are more defers to execute
      if vm.currentFrame.deferStack.len > 0:
        # More defers to execute - pop and jump to next one
        let deferPC = vm.currentFrame.deferStack.pop()
        log(verbose, "ropDeferEnd: executing next defer at PC " & $deferPC)
        pc = deferPC - 1
      else:
        # No more defers - return to saved PC
        log(verbose, "ropDeferEnd: all defers executed, returning to PC " & $vm.currentFrame.deferReturnPC)
        pc = vm.currentFrame.deferReturnPC

    # --- Fused Instructions (Aggressive Optimization) ---
    of ropAddAdd:
      # R[A] = R[B] + R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) + getInt(c) + getInt(d)))
      elif isFloat(b) and isFloat(c) and isFloat(d):
        setReg(vm, instr.a, makeFloat(getFloat(b) + getFloat(c) + getFloat(d)))
      elif isString(b) and isString(c) and isString(d):
        setReg(vm, instr.a, makeString(b.sval & c.sval & d.sval))
      else:
        # Mixed types or unsupported - fall back to nil
        setReg(vm, instr.a, makeNil())

    of ropMulAdd:
      # R[A] = R[B] * R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) * getInt(c) + getInt(d)))
      elif isFloat(b) and isFloat(c) and isFloat(d):
        setReg(vm, instr.a, makeFloat(getFloat(b) * getFloat(c) * getFloat(d)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropCmpJmp:
      # Combined compare and jump
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      if doLt(b, c):
        let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)
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

    # Profiler hook - after instruction
    if vm.profiler != nil:
      let profiler = cast[RegVMProfiler](vm.profiler)
      profiler.recordInstructionEnd(instr.op)

    # Replay engine hook - take snapshot AFTER instruction (if needed)
    if shouldTakeSnapshot and vm.replayEngine != nil:
      let engine = cast[ReplayEngine](vm.replayEngine)
      engine.takeSnapshot(statementToSnapshot)

  # Flush any remaining buffered output
  flushOutput()
  # Ensure all output is written to terminal
  stdout.flushFile()

  # Generate profiler report if profiling is enabled
  if vm.isProfiling and vm.profiler != nil:
    let profiler = cast[RegVMProfiler](vm.profiler)
    # Exit the entry function (main)
    profiler.exitFunction()
    # Capture execution end time before report generation
    profiler.executionEndTime = getTime()
    let report = profiler.generateReport()
    echo report

  return 0

# Run a register-based program
proc runRegProgram*(prog: RegBytecodeProgram, verbose: bool = false): int =
  let vm = newRegisterVM(prog)
  return vm.execute(verbose)

# Run a register-based program with profiling
proc runRegProgramWithProfiler*(prog: RegBytecodeProgram, verbose: bool = false): int =
  let vm = newRegisterVMWithProfiler(prog)
  return vm.execute(verbose)


# ===== Replay API =====

# Enable replay recording on a VM
proc enableReplayRecording*(vm: RegisterVM, snapshotInterval: int = DEFAULT_SNAPSHOT_INTERVAL) =
  let engine = newReplayEngine(vm, snapshotInterval)
  vm.replayEngine = cast[pointer](engine)
  GC_ref(engine)  # Keep engine alive
  engine.startRecording()


# Stop replay recording
proc stopReplayRecording*(vm: RegisterVM) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.stopRecording()


# Seek to a specific statement index
proc seekToStatement*(vm: RegisterVM, stmtIdx: int) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.seekTo(stmtIdx)


# Seek to a specific time (in seconds from start)
proc seekToTime*(vm: RegisterVM, targetTime: float) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.seekToTime(targetTime)


# Get current replay progress (0.0 to 1.0)
proc getReplayProgress*(vm: RegisterVM): float =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getProgress()
  return 0.0


# Get total duration of recorded execution
proc getReplayDuration*(vm: RegisterVM): float =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getTotalDuration()
  return 0.0


# Get replay statistics
proc getReplayStats*(vm: RegisterVM): tuple[snapshots: int, deltas: int,
                                            statements: int, duration: float] =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getStats()
  return (0, 0, 0, 0.0)


# Print replay statistics
proc printReplayStats*(vm: RegisterVM) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.printStats()


# Print current VM state (for replay visualization)
proc printVMState*(vm: RegisterVM, showEmpty: bool = false) =
  if vm.frames.len == 0:
    echo "  [No active frames]"
    return

  let frame = vm.currentFrame[]
  let pc = frame.pc

  # Get current instruction debug info and function name
  var functionName = ""
  if pc >= 0 and pc < vm.program.instructions.len:
    let instr = vm.program.instructions[pc]
    let debug = instr.debug
    functionName = debug.functionName
    echo "  Function: ", functionName, " (line ", debug.line, ")"
    echo "  PC: ", pc
  else:
    echo "  PC: ", pc, " (invalid)"

  # Get variables that are alive at the current PC
  var aliveVars: seq[string] = @[]
  if functionName != "" and vm.program.lifetimeData.hasKey(functionName):
    let lifetimeData = cast[ptr regvm_lifetime.FunctionLifetimeData](vm.program.lifetimeData[functionName])[]
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
