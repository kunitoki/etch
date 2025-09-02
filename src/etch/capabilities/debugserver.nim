# regvm_debug_server.nim
# Debug server for register VM communicating with VSCode Debug Adapter Protocol

import std/[json, sequtils, tables, os, algorithm, strutils, strformat]
import ../common/constants
import ../bytecode/frontend/ast
import ../core/[vm, vm_execution, vm_types]
import debugger


type
  ScopeType = enum
    stLocals, stGlobals, stRegisters

  ScopeReference = object
    frameId: int
    scopeType: ScopeType

  DebugServer* = ref object
    vm*: VirtualMachine
    debugger*: RegEtchDebugger
    running*: bool
    sourceFile*: string  # Source file being debugged
    # Store variable references for scopes
    scopeRefs*: Table[int, ScopeReference]  # variablesReference -> scope info
    nextVarRef*: int
    # Variable tracking
    currentFunctionName*: string  # Current function for lifetime data lookup
    lifetimeData*: ptr FunctionLifetimeData  # Current function's lifetime data
    hostControlled*: bool          # True when execution is driven externally (C API)
    pendingPauseReason*: string    # Reason to report on next pause (host-controlled)
    sourceAliases*: Table[string, string]  # Maps absolute paths to in-program source paths

proc normalizeSourcePath(path: string): string =
  if path.len == 0:
    return path
  try:
    let absPath = absolutePath(path)
    return normalizedPath(absPath)
  except OSError:
    return path

proc registerSourceAlias(server: DebugServer, rawPath: string) =
  if rawPath.len == 0:
    return
  server.sourceAliases[rawPath] = rawPath
  let normalized = normalizeSourcePath(rawPath)
  if normalized.len > 0:
    server.sourceAliases[normalized] = rawPath

proc resolveSourcePath(server: DebugServer, candidate: string): string =
  if candidate.len == 0:
    return ""
  if server.sourceAliases.hasKey(candidate):
    return server.sourceAliases[candidate]
  let normalized = normalizeSourcePath(candidate)
  if server.sourceAliases.hasKey(normalized):
    return server.sourceAliases[normalized]
  return ""

proc resolveLifetimeData(server: DebugServer, logicalName: string): ptr FunctionLifetimeData =
  if logicalName.len == 0 or server.vm.program.lifetimeData.len == 0:
    return nil

  # First try exact match (some functions like <global> use canonical names)
  if server.vm.program.lifetimeData.hasKey(logicalName):
    let rawPointer = server.vm.program.lifetimeData[logicalName]
    if rawPointer != nil:
      return cast[ptr FunctionLifetimeData](rawPointer)

  # Fall back to demangling signatures to match user-friendly names
  for funcName, rawPointer in server.vm.program.lifetimeData:
    if rawPointer == nil:
      continue
    if functionNameFromSignature(funcName) == logicalName:
      return cast[ptr FunctionLifetimeData](rawPointer)

  return nil

proc setCurrentFunction*(server: DebugServer, logicalName: string) =
  server.currentFunctionName = logicalName
  server.lifetimeData = resolveLifetimeData(server, logicalName)

# Helper function to format a register value for display in debugger
proc formatRegisterValue(val: V): string =
  if val.isNil():
    return "nil"

  if val.isInt():
    return $val.ival
  elif val.isFloat():
    return $val.fval
  elif val.isString():
    return "\"" & val.sval & "\""  # Return with quotes for display
  elif val.isBool():
    return $val.bval
  elif val.isChar():
    return "'" & $val.cval & "'"
  elif val.isSome():
    # Extract the wrapped value
    let inner = val.wrapped[]
    return "some(" & formatRegisterValue(inner) & ")"
  elif val.isNone():
    return "none"
  elif val.isOk():
    # Extract the wrapped value
    let inner = val.wrapped[]
    return "ok(" & formatRegisterValue(inner) & ")"
  elif val.isError():
    # Extract the error value
    let inner = val.wrapped[]
    return "error(" & formatRegisterValue(inner) & ")"
  elif val.isArray():
    if val.aval[].len == 0:
      return "[]"
    else:
      var items: seq[string] = @[]
      for item in val.aval[]:
        items.add(formatRegisterValue(item))
      return "[" & items.join(", ") & "]"
  elif val.isTable():
    if val.tval.len == 0:
      return "{}"
    else:
      return "{...} (" & $val.tval.len & " entries)"
  else:
    return "<unknown>"

# Helper function to get the type of a register value for display
proc getValueType(val: V): string =
  if val.isNil():
    return "nil"
  elif val.isInt():
    return "int"
  elif val.isFloat():
    return "float"
  elif val.isString():
    return "string"
  elif val.isBool():
    return "bool"
  elif val.isChar():
    return "char"
  elif val.isSome():
    return "option"
  elif val.isNone():
    return "option"
  elif val.isOk():
    return "result"
  elif val.isError():
    return "result"
  elif val.isArray():
    return "array"
  elif val.isTable():
    return "table"
  else:
    return "unknown"

proc updateConsecutiveMoves(server: DebugServer, foundReg: int, newValue: V, currentPC: int) =
  ## Scan backwards to find CONSECUTIVE Move instructions from foundReg and update their destinations
  ## Stops when hitting a non-Move instruction (other operations might invalidate copies)
  ## This handles multi-argument calls: R[1]=R[0]; R[2]=R[0]; R[3]=R[0]; call(...)
  var scanPC = currentPC - 1
  while scanPC >= 0:
    let instr = server.vm.program.instructions[scanPC]
    # Stop if not a Move instruction (other operations might invalidate copies)
    if instr.op != opMove or instr.opType != ifmtABC:
      break
    # If Move is from our register, update destination
    if instr.b == uint8(foundReg):
      server.vm.currentFrame.regs[instr.a] = newValue
    scanPC -= 1

proc newDebugServer*(program: BytecodeProgram, sourceFile: string): DebugServer =
  ## Create a new debug server instance for register VM
  let debuggerInstance = newEtchDebugger()
  let vmInstance = newVirtualMachineWithDebugger(program, debuggerInstance)

  result = DebugServer(
    vm: vmInstance,
    debugger: debuggerInstance,
    running: false,
    sourceFile: sourceFile,
    scopeRefs: initTable[int, ScopeReference](),
    nextVarRef: 1,  # Start at 1 and increment for each scope
    hostControlled: false,
    pendingPauseReason: "",
    sourceAliases: initTable[string, string]()
  )

  # Set up debug event handler to communicate with VSCode
  debuggerInstance.onDebugEvent = proc(event: string, data: JsonNode) =
    # Send event to VSCode via stdout
    let eventMsg = %*{
      "type": "event",
      "event": event,
      "body": data
    }
    echo $eventMsg

  # Set up output callback to capture program output and send to VSCode Debug Console
  vmInstance.outputCallback = proc(output: string) =
    let outputBody = %*{
      "category": "stdout",
      "output": output
    }
    debuggerInstance.sendDebugEvent("output", outputBody)

  # Register known source files
  result.registerSourceAlias(sourceFile)
  for pc in 0 ..< program.instructions.len:
    let debug = program.getDebugInfo(pc)
    let src = debug.sourceFile
    if src.len > 0:
      result.registerSourceAlias(src)

proc setHostControlled*(server: DebugServer, value: bool) =
  server.hostControlled = value

proc markPendingPause*(server: DebugServer, reason: string) =
  server.pendingPauseReason = reason

proc nextPauseReason(server: DebugServer, override: string): string =
  if override.len > 0:
    return override
  if server.pendingPauseReason.len > 0:
    let r = server.pendingPauseReason
    server.pendingPauseReason = ""
    return r
  if server.debugger.stepMode != smContinue:
    return "step"
  return "breakpoint"

proc notifyExternalPause*(server: DebugServer, reason: string = "") =
  if server.debugger == nil:
    return
  let pauseReason = server.nextPauseReason(reason)
  server.debugger.sendDebugEvent("stopped", %*{
    "reason": pauseReason,
    "threadId": 1,
    "allThreadsStopped": true
  })

proc executeUntilBreak(server: DebugServer, maxInstructions: int = 10000): bool =
  ## Execute VM until next break or completion

  stderr.writeLine("DEBUG: executeUntilBreak - starting, paused=" & $server.debugger.paused)
  stderr.flushFile()

  # Unpause the debugger before executing
  server.debugger.paused = false

  stderr.writeLine("DEBUG: executeUntilBreak - calling execute()")
  stderr.flushFile()

  # Call the main execute loop - it will return when paused or completed
  let exitCode = execute(server.vm, verbose = false)

  stderr.writeLine("DEBUG: executeUntilBreak - execute returned exitCode=" & $exitCode & ", paused=" & $server.debugger.paused)
  stderr.flushFile()

  if exitCode == -1:
    # Paused for debugging
    return true  # Still running, just paused
  elif exitCode == 0:
    # Normal termination
    return false  # Program terminated
  else:
    # Error
    return false

proc sendCompilationError*(errorMsg: string) =
  ## Send compilation error as JSON response for debug adapter
  let errorResponse = %*{
    "seq": 999,
    "type": "event",
    "event": "output",
    "body": {
      "category": "stderr",
      "output": "Error: " & errorMsg & "\n"
    }
  }
  echo $errorResponse
  stdout.flushFile()

  # Send terminated event to signal end of debugging session
  let terminatedEvent = %*{
    "seq": 1000,
    "type": "event",
    "event": "terminated",
    "body": {}
  }
  echo $terminatedEvent
  stdout.flushFile()

proc handleDebugRequest*(server: DebugServer, request: JsonNode): JsonNode =
  ## Handle a debug request from VSCode
  let command = request["command"].getStr()

  case command:
  of "initialize":
    # Return capabilities
    return %*{
      "success": true,
      "body": {
        "supportsConfigurationDoneRequest": true,
        "supportsStepInRequest": true,
        "supportsStepOutRequest": true,
        "supportsContinueRequest": true,
        "supportsSetBreakpointsRequest": true,
        "supportsTerminateRequest": true,
        "supportsSetVariableRequest": true
      }
    }

  of "launch":
    # Handle launch request - start the program in paused state if stopAtEntry
    let args = request["arguments"]
    let stopAtEntry = args{"stopAtEntry"}.getBool(false)

    # Initialize VM state at entry point
    server.vm.currentFrame.pc = server.vm.program.entryPoint

    # Determine which function we're starting in (global init or main)
    var startFunctionName = MAIN_FUNCTION_NAME
    var startLine = 2  # Default to line 2 for main function body

    # Check if entry point is in <global> function (global initialization)
    if server.vm.program.functions.hasKey(GLOBAL_INIT_FUNCTION_NAME):
      let globalInfo = server.vm.program.functions[GLOBAL_INIT_FUNCTION_NAME]
      if server.vm.program.entryPoint >= globalInfo.startPos and
         server.vm.program.entryPoint <= globalInfo.endPos:
        startFunctionName = GLOBAL_INIT_FUNCTION_NAME
        # Use debug info from first instruction in global init
        if server.vm.program.instructions.len > server.vm.program.entryPoint:
          let firstDebug = server.vm.program.getDebugInfo(server.vm.program.entryPoint)
          if firstDebug.line > 0:
            startLine = firstDebug.line
          else:
            startLine = 1  # Default to line 1 for global scope
        else:
          startLine = 1

    # Set initial debugger position based on first instruction
    # NOTE: Only set lastFile/lastLine if NOT stopAtEntry, because when stopAtEntry=true
    if server.vm.program.instructions.len > server.vm.program.entryPoint:
      let firstDebug = server.vm.program.getDebugInfo(server.vm.program.entryPoint)
      if firstDebug.line > 0:
        startLine = firstDebug.line
        if not stopAtEntry:
          server.debugger.lastFile = firstDebug.sourceFile
          server.debugger.lastLine = firstDebug.line
      else:
        if not stopAtEntry:
          server.debugger.lastFile = server.sourceFile
          server.debugger.lastLine = startLine
    else:
      if not stopAtEntry:
        server.debugger.lastFile = server.sourceFile
        server.debugger.lastLine = startLine

    # Push initial function frame to the debugger's stack
    let debugger = cast[RegEtchDebugger](server.debugger)
    debugger.currentPC = server.vm.program.entryPoint  # Initialize to entry point
    debugger.pushStackFrame(startFunctionName, server.sourceFile, startLine, false)

    # Load function metadata
    server.setCurrentFunction(startFunctionName)

    if stopAtEntry:
      # Pause at entry point
      server.debugger.pause()
      server.running = true

      # Send stopped event to indicate we're paused at entry
      let stoppedEventBody = %*{
        "reason": "entry",
        "threadId": 1,
        "allThreadsStopped": true
      }
      server.debugger.sendDebugEvent("stopped", stoppedEventBody)
    else:
      server.running = true

    return %*{"success": true}

  of "configurationDone":
    # Configuration is complete, ready to run
    return %*{"success": true}

  of "threads":
    # Return single thread (Etch is single-threaded)
    return %*{
      "success": true,
      "body": {
        "threads": [
          %*{"id": 1, "name": MAIN_FUNCTION_NAME}
        ]
      }
    }

  of "setBreakpoints":
    let args = request["arguments"]
    let requestedPath = args["path"].getStr()
    let lines = args["lines"].getElems()
    let resolvedPath = server.resolveSourcePath(requestedPath)

    if resolvedPath.len == 0:
      stderr.writeLine("DEBUG: Ignoring breakpoints for unknown source: " & requestedPath)
      stderr.flushFile()
      return %*{
        "success": true,
        "body": {
          "breakpoints": lines.mapIt(%*{"verified": false, "line": it.getInt()})
        }
      }

    let path = resolvedPath

    # Clear existing breakpoints for this file
    if server.debugger.breakpoints.hasKey(path):
      server.debugger.breakpoints[path] = @[]

    # Add new breakpoints
    for lineNode in lines:
      let line = lineNode.getInt()
      server.debugger.addBreakpoint(path, line)

    return %*{
      "success": true,
      "body": {
        "breakpoints": lines.mapIt(%*{"verified": true, "line": it.getInt()})
      }
    }

  of "continue":
    server.debugger.continueExecution()

    if server.hostControlled:
      server.markPendingPause("breakpoint")
    else:
      # Run VM until next break or completion
      let stillRunning = executeUntilBreak(server)

      if not stillRunning:
        # Program terminated
        server.running = false
        server.debugger.sendDebugEvent("terminated", %*{})
      elif server.debugger.paused:
        # Hit a breakpoint
        server.debugger.sendDebugEvent("stopped", %*{
          "reason": "breakpoint",
          "threadId": 1,
          "allThreadsStopped": true
        })

    return %*{"success": true}

  of "next":
    # Step over - update lastFile/lastLine to current position before stepping
    # This ensures we'll break on the NEXT line, not the current one
    if server.vm.currentFrame != nil and server.vm.currentFrame.pc < server.vm.program.instructions.len:
      let debug = server.vm.program.getDebugInfo(server.vm.currentFrame.pc)
      if debug.line > 0:
        server.debugger.lastFile = debug.sourceFile
        server.debugger.lastLine = debug.line
      else:
        server.debugger.lastFile = server.sourceFile
        server.debugger.lastLine = 1

    server.debugger.step(smStepOver)

    stderr.writeLine("DEBUG: next - starting step, lastFile=" & server.debugger.lastFile &
                     " lastLine=" & $server.debugger.lastLine &
                     " stepCallDepth=" & $server.debugger.stepCallDepth)
    stderr.flushFile()

    if server.hostControlled:
      server.markPendingPause("step")
    else:
      # Execute until we step
      let stillRunning = executeUntilBreak(server)

      stderr.writeLine("DEBUG: next - after executeUntilBreak, stillRunning=" & $stillRunning &
                       " paused=" & $server.debugger.paused &
                       " running=" & $server.running)
      stderr.flushFile()

      if not stillRunning:
        # Program terminated
        server.running = false
        stderr.writeLine("DEBUG: next - sending terminated event")
        stderr.flushFile()
        server.debugger.sendDebugEvent("terminated", %*{})
      elif server.debugger.paused:
        # Stopped at next line
        stderr.writeLine("DEBUG: next - sending stopped event")
        stderr.flushFile()
        server.debugger.sendDebugEvent("stopped", %*{
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        })
      else:
        stderr.writeLine("DEBUG: next - WARNING: stillRunning but not paused!")
        stderr.flushFile()

    return %*{"success": true}

  of "stepIn":
    # Step into functions
    server.debugger.step(smStepInto)

    if server.hostControlled:
      server.markPendingPause("step")
    else:
      # Execute until we step
      let stillRunning = executeUntilBreak(server)

      if not stillRunning:
        # Program terminated
        server.running = false
        server.debugger.sendDebugEvent("terminated", %*{})
      elif server.debugger.paused:
        # Stopped at next line
        server.debugger.sendDebugEvent("stopped", %*{
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        })

    return %*{"success": true}

  of "stepOut":
    # Step out of current function
    server.debugger.step(smStepOut)

    if server.hostControlled:
      server.markPendingPause("step")
    else:
      # Execute until function return
      let stillRunning = executeUntilBreak(server)

      if not stillRunning:
        # Program terminated
        server.running = false
        server.debugger.sendDebugEvent("terminated", %*{})
      elif server.debugger.paused:
        # Stopped after return
        server.debugger.sendDebugEvent("stopped", %*{
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        })

    return %*{"success": true}

  of "pause":
    if server.hostControlled:
      server.markPendingPause("pause")
      server.debugger.requestPause()
    else:
      server.debugger.pause()
    return %*{"success": true}

  of "stackTrace":
    stderr.writeLine("[STACK TRACE] stackTrace command handler called")
    stderr.flushFile()

    # Get current call stack
    var stackFrames: seq[JsonNode] = @[]

    # Always include the current frame based on PC
    var currentLine = 1
    var currentFile = server.sourceFile

    # Use debugger.currentPC if available (for accurate stack traces during stepping)
    # Otherwise fall back to vm.currentFrame.pc
    let pcToUse = if server.debugger.currentPC >= 0:
                    server.debugger.currentPC
                  else:
                    server.vm.currentFrame.pc

    let vmPc = if server.vm.currentFrame != nil: server.vm.currentFrame.pc else: -1
    stderr.writeLine(&"[STACK TRACE] Using PC: {pcToUse} (debugger.currentPC={server.debugger.currentPC}, vm.currentFrame.pc={vmPc})")
    stderr.flushFile()

    if server.vm.currentFrame != nil and pcToUse < server.vm.program.instructions.len:
      let debug = server.vm.program.getDebugInfo(pcToUse)
      if debug.line > 0:
        currentLine = debug.line
        currentFile = if debug.sourceFile.len > 0:
                        debug.sourceFile
                      else:
                        server.sourceFile
        stderr.writeLine(&"[STACK TRACE] PC={pcToUse} -> line={currentLine} (from debug info)")
        stderr.flushFile()

    # Check if we have stack frames from the debugger
    if server.debugger.stackFrames.len > 0:
      # Get actual call stack with current frame
      # Iterate in reverse order: top frame (most recent) first, then callers
      for i in countdown(server.debugger.stackFrames.len - 1, 0):
        let frame = server.debugger.stackFrames[i]
        let frameId = server.debugger.stackFrames.len - 1 - i  # Reverse ID for VSCode

        if i == server.debugger.stackFrames.len - 1:
          # Top frame - use current line
          stackFrames.add(%*{
            "id": frameId,
            "name": frame.functionName,
            "source": {
              "path": currentFile,
              "name": currentFile.splitFile().name & currentFile.splitFile().ext
            },
            "line": currentLine,
            "column": 1
          })
        else:
          # Previous frames - use their stored line
          stackFrames.add(%*{
            "id": frameId,
            "name": frame.functionName,
            "source": {
              "path": frame.fileName,
              "name": frame.fileName.splitFile().name & frame.fileName.splitFile().ext
            },
            "line": frame.line,
            "column": 1
          })
    else:
      # If we're paused but have no stack frames, we're at entry or main
      stackFrames.add(%*{
        "id": 0,
        "name": MAIN_FUNCTION_NAME,
        "source": {
          "path": currentFile,
          "name": currentFile.splitFile().name & currentFile.splitFile().ext
        },
        "line": currentLine,
        "column": 1
      })

    return %*{
      "success": true,
      "body": {
        "stackFrames": stackFrames,
        "totalFrames": stackFrames.len
      }
    }

  of "scopes":
    # Get frameId from request
    let frameId = request["arguments"]["frameId"].getInt()

    # Update current function context for variable tracking
    if server.debugger.stackFrames.len > 0:
      let topFrame = server.debugger.stackFrames[^1]
      if topFrame.functionName != server.currentFunctionName:
        server.setCurrentFunction(topFrame.functionName)

    # Clear old scope references to prevent stale data
    # This is critical because we use incrementing IDs, and old references should be invalid
    server.scopeRefs.clear()

    # Use unique incrementing IDs for scopes to force VSCode to refresh variables
    # VSCode caches variables based on variablesReference, so we need new IDs on each step
    let localsRef = server.nextVarRef
    inc server.nextVarRef
    let globalsRef = server.nextVarRef
    inc server.nextVarRef
    let registersRef = server.nextVarRef
    inc server.nextVarRef

    # Update the scopeRefs table with current frame information
    server.scopeRefs[localsRef] = ScopeReference(frameId: frameId, scopeType: stLocals)
    server.scopeRefs[globalsRef] = ScopeReference(frameId: frameId, scopeType: stGlobals)
    server.scopeRefs[registersRef] = ScopeReference(frameId: frameId, scopeType: stRegisters)

    stderr.writeLine("DEBUG scopes: Created new refs - locals=" & $localsRef &
                     " globals=" & $globalsRef & " registers=" & $registersRef)
    stderr.flushFile()

    # Return scopes for the current frame with unique IDs
    return %*{
      "success": true,
      "body": {
        "scopes": [
          %*{
            "name": "Local Variables",
            "variablesReference": localsRef,
            "expensive": false
          },
          %*{
            "name": "Globals",
            "variablesReference": globalsRef,
            "expensive": false
          },
          %*{
            "name": "Registers (Debug)",
            "variablesReference": registersRef,
            "expensive": false
          }
        ]
      }
    }

  of "variables":
    stderr.writeLine("DEBUG variables: START handling variables request")
    stderr.flushFile()

    let reference = request["arguments"]["variablesReference"].getInt()
    var variables: seq[JsonNode] = @[]

    stderr.writeLine("DEBUG variables: variablesReference=" & $reference)
    stderr.flushFile()

    # Look up the scope reference to determine which scope to return
    if not server.scopeRefs.hasKey(reference):
      stderr.writeLine("DEBUG variables: Invalid variablesReference=" & $reference)
      stderr.writeLine("DEBUG variables: Valid references are: " & $server.scopeRefs.keys().toSeq())
      stderr.flushFile()
      return %*{
        "success": false,
        "message": "Invalid variablesReference: " & $reference & ". This reference is stale. Call 'scopes' first to get fresh references."
      }

    let scopeRef = server.scopeRefs[reference]
    stderr.writeLine("DEBUG variables: scopeType=" & $scopeRef.scopeType)
    stderr.flushFile()

    # Update current function context for variable tracking if needed
    if server.debugger.stackFrames.len > 0:
      let topFrame = server.debugger.stackFrames[^1]
      if topFrame.functionName != server.currentFunctionName:
        server.setCurrentFunction(topFrame.functionName)

    if scopeRef.scopeType == stLocals:
      # Local Variables - show only defined variables using lifetime data
      stderr.writeLine("DEBUG variables: Processing locals")
      stderr.flushFile()
      if server.vm.currentFrame != nil:
        # IMPORTANT: currentPC points to the NEXT instruction to execute.
        # When the debugger breaks, it breaks BEFORE executing that instruction.
        #
        # For SCOPE checks (startPC/endPC), we use the raw PC because the variable
        # enters scope at that instruction (even if not yet executed).
        #
        # For DEFINED checks (defPC), we need to check if the defining instruction
        # has already executed, which means checking rawPC - 1.
        let rawPC = server.vm.currentFrame.pc

        # Check if we're at the start of a function
        var atFunctionStart = false
        if server.vm.program.functions.hasKey(server.currentFunctionName):
          let funcInfo = server.vm.program.functions[server.currentFunctionName]
          if rawPC == funcInfo.startPos:
            atFunctionStart = true

        # For checking if variable is defined: use rawPC-1 (last executed instruction)
        # But at function start, use rawPC (no previous instruction in this function)
        let defCheckPC = if atFunctionStart: rawPC else: max(rawPC - 1, 0)

        stderr.writeLine("DEBUG variables: rawPC=" & $rawPC & " defCheckPC=" & $defCheckPC &
                       " atFunctionStart=" & $atFunctionStart & " currentFunction=" & server.currentFunctionName)
        stderr.flushFile()

        # Build a list of variables to show using lifetime data
        var varsToShow: seq[tuple[name: string, reg: uint8]] = @[]

        # Use lifetime data to filter variables by scope
        if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
          let lifetimeData = server.lifetimeData[]
          stderr.writeLine("DEBUG variables: lifetimeData has " & $lifetimeData.ranges.len & " ranges")
          stderr.flushFile()
          for lifetime in lifetimeData.ranges:
            stderr.writeLine("DEBUG variables:   var=" & lifetime.varName & " reg=" & $lifetime.register &
                           " startPC=" & $lifetime.startPC & " endPC=" & $lifetime.endPC &
                           " defPC=" & $lifetime.defPC)
            stderr.flushFile()
            # Check if variable is in scope (use raw PC)
            # Show the variable if it's in scope, even if not yet defined
            # We'll mark it as <uninitialized> later if defPC hasn't been reached
            if lifetime.startPC <= rawPC and
               (lifetime.endPC == -1 or lifetime.endPC >= rawPC):
              varsToShow.add((lifetime.varName, lifetime.register))
              stderr.writeLine("DEBUG variables:     -> ADDED to varsToShow")
              stderr.flushFile()
        else:
          stderr.writeLine("DEBUG variables: lifetimeData is nil")
          stderr.flushFile()

        # Sort variables alphabetically
        varsToShow.sort(proc(a, b: tuple[name: string, reg: uint8]): int = cmp(a.name, b.name))

        # Add variables to response
        for (varName, regIndex) in varsToShow:
          let reg = server.vm.currentFrame.regs[regIndex]

          # Check if this variable has been defined yet
          # A variable is uninitialized if its defPC hasn't been reached
          var isStale = false
          if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
            try:
              # Safely access the lifetime data
              let lifetimeDataPtr = server.lifetimeData
              if lifetimeDataPtr == nil:
                raise newException(NilAccessDefect, "Lifetime data pointer is nil")

              let lifetimeData = lifetimeDataPtr[]  # Dereference the pointer

              for lifetime in lifetimeData.ranges:
                if lifetime.varName == varName:
                  # Variable is stale if:
                  # 1. defPC is -1 (never defined, shouldn't happen)
                  # 2. defPC > defCheckPC (definition hasn't executed yet)
                  if lifetime.defPC == -1 or lifetime.defPC > defCheckPC:
                    isStale = true
                  break
            except Exception:
              discard  # Ignore errors, isStale remains false

          let displayValue = if isStale:
            "<uninitialized>"
          else:
            formatRegisterValue(reg)

          var varEntry = %*{
            "name": varName,
            "value": displayValue,
            "type": if isStale: "pending" else: getValueType(reg),
            "variablesReference": 0
          }

          # Add evaluateName for editable variables (not stale)
          if not isStale:
            varEntry["evaluateName"] = %varName

          variables.add(varEntry)
    elif scopeRef.scopeType == stGlobals:
      # Global variables
      stderr.writeLine("DEBUG variables: Processing globals, vm.globals has " & $server.vm.globals.len & " entries")
      stderr.flushFile()
      for name, value in server.vm.globals:
        stderr.writeLine("DEBUG variables:   global " & name & " = " & formatRegisterValue(value))
        stderr.flushFile()
        variables.add(%*{
          "name": name,
          "value": formatRegisterValue(value),
          "type": getValueType(value),
          "variablesReference": 0,
          "evaluateName": name
        })
    elif scopeRef.scopeType == stRegisters:
      # Registers (Debug) - show raw registers for VM debugging
      if server.vm.currentFrame != nil:
        let rawPC = server.vm.currentFrame.pc
        let regCount = min(server.vm.currentFrame.regs.len, int(MAX_REGISTERS))
        for i in 0..<regCount:
          let idx = uint8(i)
          let reg = server.vm.currentFrame.regs[idx]
          if not reg.isNil():
            # Show which variable is using this register
            var varInfo = ""
            if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
              let lifetimeData = server.lifetimeData[]
              for lifetime in lifetimeData.ranges:
                if lifetime.register == idx and
                   lifetime.startPC <= rawPC and
                   (lifetime.endPC == -1 or lifetime.endPC >= rawPC):
                  varInfo = " (" & lifetime.varName & ")"
                  break
            variables.add(%*{
              "name": "R" & $idx & varInfo,
              "value": formatRegisterValue(reg),
              "type": "register",
              "variablesReference": 0
            })

    stderr.writeLine("DEBUG variables: Returning " & $variables.len & " variables")
    stderr.flushFile()

    let varResponse = %*{
      "success": true,
      "body": {
        "variables": variables
      }
    }

    stderr.writeLine("DEBUG variables: Response JSON: " & $varResponse)
    stderr.flushFile()

    return varResponse

  of "setVariable":
    # Handle variable modification during debugging
    let args = request["arguments"]
    let variablesReference = args["variablesReference"].getInt()
    let name = args["name"].getStr()
    let value = args["value"].getStr()

    # Look up the scope reference
    if not server.scopeRefs.hasKey(variablesReference):
      return %*{
        "success": false,
        "message": "Invalid variablesReference: " & $variablesReference
      }

    let scopeRef = server.scopeRefs[variablesReference]

    # Currently only support setting local variables and globals
    if scopeRef.scopeType == stRegisters:
      return %*{
        "success": false,
        "message": "Cannot set register values directly"
      }

    # Find the variable in the current frame
    if server.vm.currentFrame == nil:
      return %*{
        "success": false,
        "message": "No active frame"
      }

    # Check if this is a global variable first
    var isGlobal = false
    if server.vm.globals.hasKey(name):
      isGlobal = true

    # Try to find the variable using lifetime data (for locals)
    var foundReg: int = -1
    let currentPC = server.vm.currentFrame.pc

    if not isGlobal:
      if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
        let lifetimeData = server.lifetimeData[]
        for lifetime in lifetimeData.ranges:
          if lifetime.varName == name and
             lifetime.startPC <= currentPC and
             (lifetime.endPC == -1 or lifetime.endPC >= currentPC) and
             lifetime.defPC != -1 and lifetime.defPC <= currentPC:
            foundReg = lifetime.register.int
            break

      if foundReg == -1:
        return %*{
          "success": false,
          "message": "Variable '" & name & "' not found or not in scope"
        }

    # Get current variable type for validation
    let currentValue = if isGlobal:
      server.vm.globals[name]
    else:
      server.vm.currentFrame.regs[foundReg]
    let currentType = getValueType(currentValue)

    # Parse and validate the new value based on current type
    # Like Python debugpy, we require proper syntax (strings need quotes)
    try:
      case currentType:
      of "int":
        # Try to parse as integer
        let intVal = parseInt(value)
        let newValue = makeInt(intVal)

        # Update both storage location and register
        if isGlobal:
          server.vm.globals[name] = newValue
        else:
          server.vm.currentFrame.regs[foundReg] = newValue
          updateConsecutiveMoves(server, foundReg, newValue, currentPC)

        return %*{
          "success": true,
          "body": {
            "value": value,
            "type": "int",
            "variablesReference": 0
          }
        }

      of "float":
        # Try to parse as float
        let floatVal = parseFloat(value)
        let newValue = makeFloat(floatVal)

        # Update both storage location and register
        if isGlobal:
          server.vm.globals[name] = newValue
        else:
          server.vm.currentFrame.regs[foundReg] = newValue
          updateConsecutiveMoves(server, foundReg, newValue, currentPC)

        return %*{
          "success": true,
          "body": {
            "value": value,
            "type": "float",
            "variablesReference": 0
          }
        }

      of "bool":
        # Parse boolean (only "true" or "false" allowed)
        if value == "true":
          let newValue = makeBool(true)

          # Update both storage location and register
          if isGlobal:
            server.vm.globals[name] = newValue
          else:
            server.vm.currentFrame.regs[foundReg] = newValue
            updateConsecutiveMoves(server, foundReg, newValue, currentPC)

          return %*{
            "success": true,
            "body": {
              "value": "true",
              "type": "bool",
              "variablesReference": 0
            }
          }
        elif value == "false":
          let newValue = makeBool(false)

          # Update both storage location and register
          if isGlobal:
            server.vm.globals[name] = newValue
          else:
            server.vm.currentFrame.regs[foundReg] = newValue
            updateConsecutiveMoves(server, foundReg, newValue, currentPC)

          return %*{
            "success": true,
            "body": {
              "value": "false",
              "type": "bool",
              "variablesReference": 0
            }
          }
        else:
          return %*{
            "success": false,
            "message": "Invalid boolean value. Use 'true' or 'false'"
          }

      of "string":
        # String must be quoted (like Python debugpy)
        if value.len < 2 or value[0] != '"' or value[^1] != '"':
          return %*{
            "success": false,
            "message": "String value must be quoted. Example: \"hello\""
          }

        # Check for unterminated string or other issues
        var strValue = value[1..^2]  # Strip outer quotes
        let newValue = makeString(strValue)

        # Update both storage location and register
        if isGlobal:
          server.vm.globals[name] = newValue
        else:
          server.vm.currentFrame.regs[foundReg] = newValue
          updateConsecutiveMoves(server, foundReg, newValue, currentPC)

        return %*{
          "success": true,
          "body": {
            "value": "\"" & strValue & "\"",  # Return WITH quotes for display
            "type": "string",
            "variablesReference": 0
          }
        }

      of "array":
        # Array syntax: [elem1, elem2, elem3]
        # Support int, float, string, and bool arrays
        if value.len < 2 or value[0] != '[' or value[^1] != ']':
          return %*{
            "success": false,
            "message": "Array value must be in brackets. Example: [1, 2, 3] or [\"a\", \"b\"]"
          }

        # Parse array elements
        let content = value[1..^2].strip()
        if content.len == 0:
          # Empty array
          let newValue = makeArray(@[])

          # Update both storage location and register
          if isGlobal:
            server.vm.globals[name] = newValue
          else:
            server.vm.currentFrame.regs[foundReg] = newValue
            updateConsecutiveMoves(server, foundReg, newValue, currentPC)

          return %*{
            "success": true,
            "body": {
              "value": "[]",
              "type": "array",
              "variablesReference": 0
            }
          }

        # Split by comma, but handle quoted strings properly
        var elements: seq[string] = @[]
        var current = ""
        var inString = false
        var i = 0
        while i < content.len:
          let c = content[i]
          if c == '"':
            inString = not inString
            current.add(c)
          elif c == ',' and not inString:
            elements.add(current.strip())
            current = ""
          else:
            current.add(c)
          inc i
        if current.len > 0:
          elements.add(current.strip())

        # Parse elements based on first element's type
        var arrayElements: seq[V] = @[]
        for elem in elements:
          if elem.len == 0:
            return %*{
              "success": false,
              "message": "Invalid array element (empty)"
            }

          # Determine element type
          if elem[0] == '"':
            # String element
            if elem.len < 2 or elem[^1] != '"':
              return %*{
                "success": false,
                "message": "String array element must be quoted: " & elem
              }
            let strVal = elem[1..^2]
            arrayElements.add(makeString(strVal))
          elif elem == "true":
            arrayElements.add(makeBool(true))
          elif elem == "false":
            arrayElements.add(makeBool(false))
          elif '.' in elem:
            # Float
            try:
              let floatVal = parseFloat(elem)
              arrayElements.add(makeFloat(floatVal))
            except ValueError:
              return %*{
                "success": false,
                "message": "Invalid float in array: " & elem
              }
          else:
            # Int
            try:
              let intVal = parseInt(elem)
              arrayElements.add(makeInt(intVal))
            except ValueError:
              return %*{
                "success": false,
                "message": "Invalid integer in array: " & elem
              }

        let newValue = makeArray(arrayElements)

        # Update both storage location and register
        if isGlobal:
          server.vm.globals[name] = newValue
        else:
          server.vm.currentFrame.regs[foundReg] = newValue
          updateConsecutiveMoves(server, foundReg, newValue, currentPC)

        return %*{
          "success": true,
          "body": {
            "value": formatRegisterValue(newValue),
            "type": "array",
            "variablesReference": 0
          }
        }

      else:
        return %*{
          "success": false,
          "message": "Cannot modify variable of type '" & currentType & "'"
        }

    except ValueError as e:
      return %*{
        "success": false,
        "message": "Invalid value: " & e.msg
      }
    except Exception as e:
      return %*{
        "success": false,
        "message": "Error setting variable: " & e.msg
      }

  of "disconnect":
    server.running = false
    # Note: serverAlive will be set to false after response is sent
    return %*{"success": true}

  of "terminate":
    server.running = false
    return %*{"success": true}

  else:
    return %*{
      "success": false,
      "message": "Unsupported command: " & command
    }

proc runDebugServer*(program: BytecodeProgram, sourceFile: string) =
  ## Run the debug server for register VM, handling DAP messages
  let server = newDebugServer(program, sourceFile)
  server.running = false  # VM not running until launched

  stderr.writeLine("DEBUG: Debug server started for register VM")
  stderr.flushFile()

  var serverAlive = true  # Keep server alive for communication

  # Main message loop
  while serverAlive:
    var request: JsonNode
    var requestCommand = ""
    var requestSeq = -1

    try:
      let input = stdin.readLine()
      if input.len == 0:
        break

      request = parseJson(input)

      # Extract command and seq for error reporting
      if request.hasKey("command"):
        requestCommand = request["command"].getStr()
      if request.hasKey("seq"):
        requestSeq = request["seq"].getInt()

      let response = server.handleDebugRequest(request)

      # Add request ID to response
      if requestSeq >= 0:
        response["request_seq"] = %requestSeq
      response["type"] = %"response"
      response["command"] = %requestCommand

      echo $response
      stdout.flushFile()

      # Check if we should exit after disconnect
      if requestCommand == "disconnect":
        serverAlive = false

    except EOFError:
      break
    except:
      let error = getCurrentExceptionMsg()
      let trace = getStackTrace()
      stderr.writeLine("DEBUG: Debug server error: " & error)
      stderr.writeLine("DEBUG: Stack trace: " & trace)
      stderr.flushFile()

      # Send error response with command if available
      var errorResponse = %*{
        "type": "response",
        "success": false,
        "message": error
      }

      if requestCommand != "":
        errorResponse["command"] = %requestCommand
      if requestSeq >= 0:
        errorResponse["request_seq"] = %requestSeq

      echo $errorResponse
      stdout.flushFile()

  stderr.writeLine("DEBUG: Debug server stopped")
  stderr.flushFile()
