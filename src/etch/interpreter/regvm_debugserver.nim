# regvm_debug_server.nim
# Debug server for register VM communicating with VSCode Debug Adapter Protocol

import std/[json, sequtils, tables, os, hashes, algorithm, strutils]
import ../common/[constants]
import regvm, regvm_exec, regvm_debugger, regvm_lifetime

# Helper function to format a register value for display in debugger
proc formatRegisterValue(val: V): string =
  if val.isNil():
    return "nil"

  if val.isInt():
    return $val.ival
  elif val.isFloat():
    return $val.fval
  elif val.isString():
    return "\"" & val.sval & "\""
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
  elif val.isErr():
    # Extract the error value
    let inner = val.wrapped[]
    return "error(" & formatRegisterValue(inner) & ")"
  elif val.isArray():
    if val.aval.len == 0:
      return "[]"
    elif val.aval.len <= 3:
      var items: seq[string] = @[]
      for item in val.aval:
        items.add(formatRegisterValue(item))
      return "[" & items.join(", ") & "]"
    else:
      return "[" & formatRegisterValue(val.aval[0]) & ", ... (" & $val.aval.len & " items)]"
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
    return "Option"
  elif val.isNone():
    return "Option"
  elif val.isOk():
    return "Result"
  elif val.isErr():
    return "Result"
  elif val.isArray():
    return "array"
  elif val.isTable():
    return "table"
  else:
    return "unknown"

type
  RegDebugServer* = ref object
    vm*: RegisterVM
    debugger*: RegEtchDebugger
    running*: bool
    sourceFile*: string  # Source file being debugged
    # Store variable references for expandable variables
    variableRefs*: Table[int, string]  # variablesReference -> variable name
    nextVarRef*: int
    # Variable tracking
    currentFunctionName*: string  # Current function for lifetime data lookup
    lifetimeData*: ptr FunctionLifetimeData  # Current function's lifetime data

proc newRegDebugServer*(program: RegBytecodeProgram, sourceFile: string): RegDebugServer =
  ## Create a new debug server instance for register VM
  let debuggerInstance = newRegEtchDebugger()
  let vmInstance = newRegisterVMWithDebugger(program, debuggerInstance)

  result = RegDebugServer(
    vm: vmInstance,
    debugger: debuggerInstance,
    running: false,
    sourceFile: sourceFile,
    variableRefs: initTable[int, string](),
    nextVarRef: 2  # Start at 2, since 1 is reserved for local scope
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

proc executeUntilBreak(server: RegDebugServer, maxInstructions: int = 10000): bool =
  ## Execute VM until next break or completion

  # Unpause the debugger before executing
  server.debugger.paused = false

  # Call the main execute loop - it will return when paused or completed
  let exitCode = execute(server.vm, verbose = false)

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

proc handleDebugRequest*(server: RegDebugServer, request: JsonNode): JsonNode =
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
        "supportsTerminateRequest": true
      }
    }

  of "launch":
    # Handle launch request - start the program in paused state if stopOnEntry
    let args = request["arguments"]
    let stopOnEntry = args{"stopOnEntry"}.getBool(false)

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
          let firstInstr = server.vm.program.instructions[server.vm.program.entryPoint]
          if firstInstr.debug.line > 0:
            startLine = firstInstr.debug.line
          else:
            startLine = 1  # Default to line 1 for global scope
        else:
          startLine = 1

    # Set initial debugger position based on first instruction
    if server.vm.program.instructions.len > server.vm.program.entryPoint:
      let firstInstr = server.vm.program.instructions[server.vm.program.entryPoint]
      if firstInstr.debug.line > 0:
        server.debugger.lastFile = firstInstr.debug.sourceFile
        server.debugger.lastLine = firstInstr.debug.line
        startLine = firstInstr.debug.line
      else:
        server.debugger.lastFile = server.sourceFile
        server.debugger.lastLine = startLine
    else:
      server.debugger.lastFile = server.sourceFile
      server.debugger.lastLine = startLine

    # Push initial function frame to the debugger's stack
    let debugger = cast[RegEtchDebugger](server.debugger)
    debugger.currentPC = server.vm.program.entryPoint  # Initialize to entry point
    debugger.pushStackFrame(startFunctionName, server.sourceFile, startLine, false)

    # Load function metadata
    server.currentFunctionName = startFunctionName

    # Load lifetime data for the starting function if available
    if server.vm.program.lifetimeData.hasKey(startFunctionName):
      let rawPointer = server.vm.program.lifetimeData[startFunctionName]
      if rawPointer != nil:
        server.lifetimeData = cast[ptr FunctionLifetimeData](rawPointer)
      else:
        server.lifetimeData = nil
    else:
      server.lifetimeData = nil

    if stopOnEntry:
      # Pause at entry point
      server.debugger.pause()
      server.running = true

      # Send stopped event to indicate we're paused at entry
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "entry",
          "threadId": 1,
          "allThreadsStopped": true
        }
      }
      echo $stoppedEvent
      stdout.flushFile()
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
    let path = args["path"].getStr()
    let lines = args["lines"].getElems()

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

    # Run VM until next break or completion
    let stillRunning = executeUntilBreak(server)

    if not stillRunning:
      # Program terminated
      server.running = false
      let terminatedEvent = %*{
        "type": "event",
        "event": "terminated",
        "body": {}
      }
      echo $terminatedEvent
      stdout.flushFile()
    elif server.debugger.paused:
      # Hit a breakpoint
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "breakpoint",
          "threadId": 1,
          "allThreadsStopped": true
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "next":
    # Step over - update lastFile/lastLine to current position before stepping
    # This ensures we'll break on the NEXT line, not the current one
    if server.vm.currentFrame != nil and server.vm.currentFrame.pc < server.vm.program.instructions.len:
      let instr = server.vm.program.instructions[server.vm.currentFrame.pc]
      if instr.debug.line > 0:
        server.debugger.lastFile = instr.debug.sourceFile
        server.debugger.lastLine = instr.debug.line

    server.debugger.step(smStepOver)

    stderr.writeLine("DEBUG: next - starting step, lastFile=" & server.debugger.lastFile &
                     " lastLine=" & $server.debugger.lastLine &
                     " stepCallDepth=" & $server.debugger.stepCallDepth)
    stderr.flushFile()

    # Execute until we step
    let stillRunning = executeUntilBreak(server)

    if not stillRunning:
      # Program terminated
      server.running = false
      let terminatedEvent = %*{
        "type": "event",
        "event": "terminated",
        "body": {}
      }
      echo $terminatedEvent
      stdout.flushFile()
    elif server.debugger.paused:
      # Stopped at next line
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "stepIn":
    # Step into functions
    server.debugger.step(smStepInto)

    # Execute until we step
    let stillRunning = executeUntilBreak(server)

    if not stillRunning:
      # Program terminated
      server.running = false
      let terminatedEvent = %*{
        "type": "event",
        "event": "terminated",
        "body": {}
      }
      echo $terminatedEvent
      stdout.flushFile()
    elif server.debugger.paused:
      # Stopped at next line
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "stepOut":
    # Step out of current function
    server.debugger.step(smStepOut)

    # Execute until function return
    let stillRunning = executeUntilBreak(server)

    if not stillRunning:
      # Program terminated
      server.running = false
      let terminatedEvent = %*{
        "type": "event",
        "event": "terminated",
        "body": {}
      }
      echo $terminatedEvent
      stdout.flushFile()
    elif server.debugger.paused:
      # Stopped after return
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "allThreadsStopped": true
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "pause":
    server.debugger.pause()
    return %*{"success": true}

  of "stackTrace":
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

    if server.vm.currentFrame != nil and pcToUse < server.vm.program.instructions.len:
      let instr = server.vm.program.instructions[pcToUse]
      if instr.debug.line > 0:
        currentLine = instr.debug.line
        currentFile = if instr.debug.sourceFile.len > 0:
                        instr.debug.sourceFile
                      else:
                        server.sourceFile

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
    # Update current function context for variable tracking
    if server.debugger.stackFrames.len > 0:
      let topFrame = server.debugger.stackFrames[^1]
      if topFrame.functionName != server.currentFunctionName:
        server.currentFunctionName = topFrame.functionName

        # Update lifetime data for the new function
        if server.vm.program.lifetimeData.hasKey(server.currentFunctionName):
          let rawPointer = server.vm.program.lifetimeData[server.currentFunctionName]
          if rawPointer != nil:
            server.lifetimeData = cast[ptr FunctionLifetimeData](rawPointer)
          else:
            server.lifetimeData = nil
        else:
          server.lifetimeData = nil

    # Return scopes for the current frame
    return %*{
      "success": true,
      "body": {
        "scopes": [
          %*{
            "name": "Local Variables",
            "variablesReference": 1,
            "expensive": false
          },
          %*{
            "name": "Globals",
            "variablesReference": 2,
            "expensive": false
          },
          %*{
            "name": "Registers (Debug)",
            "variablesReference": 3,
            "expensive": false
          }
        ]
      }
    }

  of "variables":
    let reference = request["arguments"]["variablesReference"].getInt()
    var variables: seq[JsonNode] = @[]

    # Update current function context for variable tracking if needed
    if server.debugger.stackFrames.len > 0:
      let topFrame = server.debugger.stackFrames[^1]
      if topFrame.functionName != server.currentFunctionName:
        server.currentFunctionName = topFrame.functionName

        # Update lifetime data for the new function
        if server.vm.program.lifetimeData.hasKey(server.currentFunctionName):
          let rawPointer = server.vm.program.lifetimeData[server.currentFunctionName]
          if rawPointer != nil:
            server.lifetimeData = cast[ptr FunctionLifetimeData](rawPointer)
          else:
            server.lifetimeData = nil
        else:
          server.lifetimeData = nil

    if reference == 1:
      # Local Variables - show only defined variables using lifetime data
      if server.vm.currentFrame != nil:
        let currentPC = server.vm.currentFrame.pc

        # Build a list of variables to show using lifetime data
        var varsToShow: seq[tuple[name: string, reg: uint8]] = @[]

        # Use lifetime data to filter variables by scope
        if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
          let lifetimeData = server.lifetimeData[]
          for lifetime in lifetimeData.ranges:
            # Check if variable is in scope and defined at this PC
            if lifetime.startPC <= currentPC and
               (lifetime.endPC == -1 or lifetime.endPC >= currentPC) and
               lifetime.defPC != -1 and lifetime.defPC <= currentPC:
              varsToShow.add((lifetime.varName, lifetime.register))

        # Sort variables alphabetically
        varsToShow.sort(proc(a, b: tuple[name: string, reg: uint8]): int = cmp(a.name, b.name))

        # Add variables to response
        for (varName, regIndex) in varsToShow:
          let reg = server.vm.currentFrame.regs[regIndex]

          # Check if this variable's definition PC is the current PC
          # If so, the instruction hasn't executed yet, so the value is stale
          var isStale = false
          if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
            try:
              # Safely access the lifetime data
              let lifetimeDataPtr = server.lifetimeData
              if lifetimeDataPtr == nil:
                raise newException(NilAccessDefect, "Lifetime data pointer is nil")

              let lifetimeData = lifetimeDataPtr[]  # Dereference the pointer

              for lifetime in lifetimeData.ranges:
                if lifetime.varName == varName and lifetime.defPC == currentPC:
                  # We're at the definition point but haven't executed yet
                  isStale = true
                  break
            except Exception:
              discard  # Ignore errors, isStale remains false

          let displayValue = if isStale:
            "<uninitialized>"
          else:
            formatRegisterValue(reg)

          variables.add(%*{
            "name": varName,
            "value": displayValue,
            "type": if isStale: "pending" else: getValueType(reg),
            "variablesReference": 0
          })
    elif reference == 2:
      # Global variables
      for name, value in server.vm.globals:
        variables.add(%*{
          "name": name,
          "value": formatRegisterValue(value),
          "type": getValueType(value),
          "variablesReference": 0
        })
    elif reference == 3:
      # Registers (Debug) - show raw registers for VM debugging
      if server.vm.currentFrame != nil:
        let currentPC = server.vm.currentFrame.pc
        for i in 0'u8..15'u8:  # Show first 16 registers
          let reg = server.vm.currentFrame.regs[i]
          if not reg.isNil():
            # Show which variable is using this register
            var varInfo = ""
            if server.lifetimeData != nil and cast[int](server.lifetimeData) != 0:
              let lifetimeData = server.lifetimeData[]
              for lifetime in lifetimeData.ranges:
                if lifetime.register == i and
                   lifetime.startPC <= currentPC and
                   (lifetime.endPC == -1 or lifetime.endPC >= currentPC):
                  varInfo = " (" & lifetime.varName & ")"
                  break
            variables.add(%*{
              "name": "R" & $i & varInfo,
              "value": formatRegisterValue(reg),
              "type": "register",
              "variablesReference": 0
            })

    return %*{
      "success": true,
      "body": {
        "variables": variables
      }
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

proc runRegDebugServer*(program: RegBytecodeProgram, sourceFile: string) =
  ## Run the debug server for register VM, handling DAP messages
  let server = newRegDebugServer(program, sourceFile)
  server.running = false  # VM not running until launched

  stderr.writeLine("DEBUG: Debug server started for register VM")
  stderr.flushFile()

  var serverAlive = true  # Keep server alive for communication

  # Main message loop
  while serverAlive:
    try:
      let input = stdin.readLine()
      if input.len == 0:
        break

      let request = parseJson(input)
      let response = server.handleDebugRequest(request)

      # Add request ID to response
      if request.hasKey("seq"):
        response["request_seq"] = request["seq"]
      response["type"] = %"response"
      response["command"] = request["command"]

      echo $response
      stdout.flushFile()

      # Check if we should exit after disconnect
      if request["command"].getStr() == "disconnect":
        serverAlive = false

    except EOFError:
      break
    except:
      let error = getCurrentExceptionMsg()
      stderr.writeLine("DEBUG: Debug server error: " & error)
      stderr.flushFile()

      # Send error response
      let errorResponse = %*{
        "type": "response",
        "success": false,
        "message": error
      }
      echo $errorResponse
      stdout.flushFile()

  stderr.writeLine("DEBUG: Debug server stopped")
  stderr.flushFile()