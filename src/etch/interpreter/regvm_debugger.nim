# regvm_debugger.nim
# Debugger implementation for register-based VM

import std/[tables, json, options, sequtils]
import ../common/constants
import ../frontend/ast

type
  StepMode* = enum
    smContinue,     # Continue execution
    smStepInto,     # Step into function calls
    smStepOver,     # Step over function calls
    smStepOut       # Step out of current function

  Breakpoint* = object
    file*: string
    line*: int
    enabled*: bool
    condition*: Option[string]

  # Register-based debug stack frame
  RegDebugStackFrame* = object
    functionName*: string
    fileName*: string
    line*: int
    isBuiltIn*: bool
    # Register snapshot for this frame
    registers*: seq[tuple[index: uint8, value: string]]  # Only non-nil registers
    # Local variable mapping (name -> register index)
    varToReg*: Table[string, uint8]

  RegEtchDebugger* = ref object
    # Breakpoint management
    breakpoints*: Table[string, seq[Breakpoint]]  # file -> breakpoints

    # Stack frame tracking for register frames
    stackFrames*: seq[RegDebugStackFrame]

    # Execution control
    stepMode*: StepMode
    stepTarget*: int        # Target instruction for step operations
    userCallDepth*: int     # Depth of user-defined function calls only
    stepCallDepth*: int     # User call depth when step was initiated
    callSiteLine*: int      # Line where we made the function call (to skip on return)

    # State
    paused*: bool
    lastFile*: string
    lastLine*: int
    lastPC*: int            # Last program counter where we stopped
    currentPC*: int         # Current program counter

    # Event callback for communication with debug adapter
    onDebugEvent*: proc(event: string, data: JsonNode) {.gcsafe.}

    # Reference to the VM for inspection (kept as pointer to avoid circular deps)
    vm*: pointer  # Will be cast to RegisterVM* in regvm_exec

proc newRegEtchDebugger*(): RegEtchDebugger =
  RegEtchDebugger(
    breakpoints: initTable[string, seq[Breakpoint]](),
    stackFrames: @[],
    stepMode: smContinue,
    stepTarget: -1,
    userCallDepth: 0,
    stepCallDepth: 0,
    callSiteLine: -1,
    paused: false,
    lastFile: "",
    lastLine: 0,
    lastPC: -1,
    currentPC: 0,
    onDebugEvent: nil,
    vm: nil
  )

proc addBreakpoint*(debugger: RegEtchDebugger, file: string, line: int, condition: Option[string] = none(string)) =
  let breakpoint = Breakpoint(
    file: file,
    line: line,
    enabled: true,
    condition: condition
  )

  if not debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file] = @[]
  debugger.breakpoints[file].add(breakpoint)

proc removeBreakpoint*(debugger: RegEtchDebugger, file: string, line: int) =
  if debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file].keepItIf(it.line != line)

proc hasBreakpoint*(debugger: RegEtchDebugger, file: string, line: int): bool =
  if not debugger.breakpoints.hasKey(file):
    return false
  for bp in debugger.breakpoints[file]:
    if bp.line == line and bp.enabled:
      return true
  return false

proc pushStackFrame*(debugger: RegEtchDebugger, functionName: string, fileName: string,
                     line: int, isBuiltIn: bool = false) =
  # Demangle the function name for display
  let displayName = functionNameFromSignature(functionName)

  var frame = RegDebugStackFrame(
    functionName: displayName,
    fileName: fileName,
    line: line,
    isBuiltIn: isBuiltIn,
    registers: @[],
    varToReg: initTable[string, uint8]()
  )

  debugger.stackFrames.add(frame)

  if not isBuiltIn:
    # When entering a function during stepping, save the call site line
    if debugger.stepMode != smContinue and debugger.userCallDepth == debugger.stepCallDepth:
      debugger.callSiteLine = debugger.lastLine
    debugger.userCallDepth += 1

proc popStackFrame*(debugger: RegEtchDebugger) =
  if debugger.stackFrames.len > 0:
    let frame = debugger.stackFrames.pop()
    if not frame.isBuiltIn:
      debugger.userCallDepth -= 1

proc getCurrentStackFrame*(debugger: RegEtchDebugger): RegDebugStackFrame =
  if debugger.stackFrames.len > 0:
    return debugger.stackFrames[^1]
  else:
    return RegDebugStackFrame(
      functionName: MAIN_FUNCTION_NAME,
      fileName: "",
      line: 0,
      isBuiltIn: false,
      registers: @[],
      varToReg: initTable[string, uint8]()
    )

proc updateStackFrameRegisters*(debugger: RegEtchDebugger, registers: seq[tuple[index: uint8, value: string]]) =
  if debugger.stackFrames.len > 0:
    debugger.stackFrames[^1].registers = registers

proc step*(debugger: RegEtchDebugger, mode: StepMode) =
  debugger.stepMode = mode
  debugger.stepCallDepth = debugger.userCallDepth
  debugger.paused = false

proc continueExecution*(debugger: RegEtchDebugger) =
  debugger.stepMode = smContinue
  debugger.paused = false

proc pause*(debugger: RegEtchDebugger) =
  debugger.paused = true

proc shouldBreak*(debugger: RegEtchDebugger, pc: int, file: string, line: int): bool =
  debugger.currentPC = pc
  if debugger.hasBreakpoint(file, line):
    return true

  # Check if we should break BEFORE updating lastPC
  var shouldBreakNow = false

  case debugger.stepMode
  of smContinue:
    discard

  of smStepInto:
    # Break on new line OR when PC jumps backward (loop iteration)
    # NOTE: Do NOT skip call site line - we want to stop there when returning from a function
    # NOTE: Break even if line is 0 (e.g., compiler-generated instructions like CALL)
    if (line > 0 or debugger.lastLine > 0) and (file != debugger.lastFile or line != debugger.lastLine or (pc < debugger.lastPC and debugger.lastPC >= 0)):
      shouldBreakNow = true

  of smStepOver:
    if debugger.userCallDepth <= debugger.stepCallDepth:
      # Break on new line OR when PC jumps backward (loop iteration)
      # NOTE: Do NOT skip call site line - we want to stop there when returning from a function
      # NOTE: Break even if line is 0 (e.g., compiler-generated instructions like CALL)
      if (line > 0 or debugger.lastLine > 0) and (file != debugger.lastFile or line != debugger.lastLine or (pc < debugger.lastPC and debugger.lastPC >= 0)):
        shouldBreakNow = true

  of smStepOut:
    # Break when we return to caller (depth < stepDepth) at any line
    # NOTE: Do NOT skip call site line - we want to stop there when returning
    # NOTE: Break even if line is 0 (e.g., compiler-generated instructions like RETURN)
    if debugger.userCallDepth < debugger.stepCallDepth:
      shouldBreakNow = true

  # Update lastPC after checking for breaks (for next iteration detection)
  if line > 0:
    debugger.lastPC = pc

  return shouldBreakNow

proc attachToVM*(debugger: RegEtchDebugger, vm: pointer) =
  debugger.vm = vm

proc getCallStack*(debugger: RegEtchDebugger): seq[string] =
  result = @[]
  for frame in debugger.stackFrames:
    var line = frame.functionName
    if frame.fileName != "":
      line &= " at " & frame.fileName & ":" & $frame.line
    if frame.isBuiltIn:
      line &= " [builtin]"
    result.add(line)

proc sendDebugEvent*(debugger: RegEtchDebugger, event: string, data: JsonNode) =
  if debugger.onDebugEvent != nil:
    debugger.onDebugEvent(event, data)

proc sendBreakpointHit*(debugger: RegEtchDebugger, file: string, line: int) =
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack()
  }
  debugger.sendDebugEvent("breakpoint", data)

proc sendStepComplete*(debugger: RegEtchDebugger, file: string, line: int) =
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack(),
    "mode": $debugger.stepMode
  }
  debugger.sendDebugEvent("step", data)
