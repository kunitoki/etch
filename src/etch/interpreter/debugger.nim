# simple_debugger.nim
# Simple debugger implementation without interfaces

import std/[tables, json, options, sequtils]
import ../common/constants

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

  DebugStackFrame* = object
    functionName*: string
    fileName*: string
    line*: int
    isBuiltIn*: bool        # True for built-in functions
    variables*: Table[string, string]  # variable name -> display value

  EtchDebugger* = ref object
    # Breakpoint management
    breakpoints*: Table[string, seq[Breakpoint]]  # file -> breakpoints

    # Stack frame tracking for variable scope and stepping
    stackFrames*: seq[DebugStackFrame]

    # Execution control
    stepMode*: StepMode
    stepTarget*: int        # Target instruction for step operations
    userCallDepth*: int     # Depth of user-defined function calls only
    stepCallDepth*: int     # User call depth when step was initiated

    # State
    paused*: bool
    lastFile*: string
    lastLine*: int

    # Event callback for communication with debug adapter
    onDebugEvent*: proc(event: string, data: JsonNode) {.gcsafe.}

# Forward declare VM types to avoid circular imports
type
  VM* = ref object
  V* = object

proc newEtchDebugger*(): EtchDebugger =
  ## Create a new debugger instance
  EtchDebugger(
    breakpoints: initTable[string, seq[Breakpoint]](),
    stackFrames: @[],
    stepMode: smContinue,
    stepTarget: -1,
    userCallDepth: 0,
    stepCallDepth: 0,
    paused: false,
    lastFile: "",
    lastLine: 0,
    onDebugEvent: nil
  )

proc addBreakpoint*(debugger: EtchDebugger, file: string, line: int, condition: Option[string] = none(string)) =
  ## Add a breakpoint at the specified file and line
  let breakpoint = Breakpoint(
    file: file,
    line: line,
    enabled: true,
    condition: condition
  )

  if not debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file] = @[]
  debugger.breakpoints[file].add(breakpoint)

proc removeBreakpoint*(debugger: EtchDebugger, file: string, line: int) =
  ## Remove breakpoint at the specified file and line
  if debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file].keepItIf(it.line != line)

proc hasBreakpoint*(debugger: EtchDebugger, file: string, line: int): bool =
  ## Check if there's an enabled breakpoint at the specified location
  if not debugger.breakpoints.hasKey(file):
    return false

  for bp in debugger.breakpoints[file]:
    if bp.line == line and bp.enabled:
      return true
  return false

proc pushStackFrame*(debugger: EtchDebugger, functionName: string, fileName: string, line: int, isBuiltIn: bool = false) =
  ## Push a new stack frame for function call tracking
  let frame = DebugStackFrame(
    functionName: functionName,
    fileName: fileName,
    line: line,
    isBuiltIn: isBuiltIn,
    variables: initTable[string, string]()
  )
  debugger.stackFrames.add(frame)

  # Only count user-defined functions for step depth tracking
  if not isBuiltIn:
    debugger.userCallDepth += 1

proc popStackFrame*(debugger: EtchDebugger) =
  ## Pop the top stack frame
  if debugger.stackFrames.len > 0:
    let frame = debugger.stackFrames.pop()
    if not frame.isBuiltIn:
      debugger.userCallDepth -= 1

proc getCurrentStackFrame*(debugger: EtchDebugger): DebugStackFrame =
  ## Get the current (top) stack frame
  if debugger.stackFrames.len > 0:
    return debugger.stackFrames[^1]
  else:
    # Return main frame if no frames exist
    return DebugStackFrame(
      functionName: MAIN_FUNCTION_NAME,
      fileName: "",
      line: 0,
      isBuiltIn: false,
      variables: initTable[string, string]()
    )

proc updateStackFrameVariables*(debugger: EtchDebugger, variables: Table[string, string]) =
  ## Update variables in the current stack frame
  if debugger.stackFrames.len > 0:
    debugger.stackFrames[^1].variables = variables

proc step*(debugger: EtchDebugger, mode: StepMode) =
  ## Set up step operation
  debugger.stepMode = mode
  debugger.stepCallDepth = debugger.userCallDepth  # Use user call depth only
  debugger.paused = false

proc continueExecution*(debugger: EtchDebugger) =
  ## Continue execution
  debugger.stepMode = smContinue
  debugger.paused = false

proc pause*(debugger: EtchDebugger) =
  ## Pause execution
  debugger.paused = true

# Note: The actual debugger implementation functions are in vm.nim
# to avoid circular imports. This file contains the debugger data structure
# and basic management functions.