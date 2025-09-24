# debug_server.nim
# Debug server for communicating with VSCode Debug Adapter Protocol

import std/[json, sequtils, tables, strutils, os]
import interpreter/[vm, bytecode, debugger]

type
  DebugServer* = ref object
    vm*: vm.VM
    debugger*: debugger.EtchDebugger
    running*: bool

proc newDebugServer*(program: bytecode.BytecodeProgram): DebugServer =
  ## Create a new debug server instance
  let debuggerInstance = debugger.newEtchDebugger()
  let vmInstance = vm.newBytecodeVMWithDebugger(program, debuggerInstance)

  result = DebugServer(
    vm: vmInstance,
    debugger: debuggerInstance,
    running: false
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

proc handleDebugRequest*(server: DebugServer, request: JsonNode): JsonNode =
  ## Handle a debug request from VSCode
  let command = request["command"].getStr()

  case command:
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
      debugger.addBreakpoint(server.debugger, path, line)

    return %*{
      "success": true,
      "body": {
        "breakpoints": lines.mapIt(%*{"verified": true, "line": it.getInt()})
      }
    }

  of "continue":
    debugger.continueExecution(server.debugger)

    # Run VM until next break or completion
    while not server.debugger.paused and server.vm.pc < server.vm.program.instructions.len:
      if not vm.executeInstruction(server.vm):
        break

    return %*{"success": true}

  of "next":
    # Update debugger's current position before stepping
    if server.vm.pc < server.vm.program.instructions.len:
      let currentInstr = server.vm.program.instructions[server.vm.pc]
      server.debugger.lastFile = currentInstr.debug.sourceFile
      server.debugger.lastLine = currentInstr.debug.line

    debugger.step(server.debugger, debugger.smStepOver)

    stderr.writeLine("DEBUG: next - starting step, pc=" & $server.vm.pc &
                     " paused=" & $server.debugger.paused &
                     " lastLine=" & $server.debugger.lastLine)
    stderr.flushFile()

    # Execute one step
    var instructionCount = 0
    while not server.debugger.paused and server.vm.pc < server.vm.program.instructions.len:
      instructionCount += 1
      if instructionCount > 1000:  # Safety limit
        stderr.writeLine("DEBUG: Safety limit reached - too many instructions without pause")
        stderr.flushFile()
        break
      if not vm.executeInstruction(server.vm):
        break

    stderr.writeLine("DEBUG: next - executed " & $instructionCount & " instructions, " &
                     "pc=" & $server.vm.pc &
                     " paused=" & $server.debugger.paused &
                     " lastLine=" & $server.debugger.lastLine)
    stderr.flushFile()

    # Check if program finished
    if server.vm.pc >= server.vm.program.instructions.len:
      # Program terminated
      let terminatedEvent = %*{
        "type": "event",
        "event": "terminated",
        "body": {}
      }
      echo $terminatedEvent
      stdout.flushFile()
    elif server.debugger.paused and server.debugger.lastFile.len > 0:
      # Send stopped event if we're paused
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "file": server.debugger.lastFile,
          "line": server.debugger.lastLine
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "stepIn":
    debugger.step(server.debugger, debugger.smStepInto)

    # Execute one step
    while not server.debugger.paused and server.vm.pc < server.vm.program.instructions.len:
      if not vm.executeInstruction(server.vm):
        break

    # Send stopped event if we're paused
    if server.debugger.paused and server.debugger.lastFile.len > 0:
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "file": server.debugger.lastFile,
          "line": server.debugger.lastLine
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "stepOut":
    debugger.step(server.debugger, debugger.smStepOut)

    # Execute until we step out
    while not server.debugger.paused and server.vm.pc < server.vm.program.instructions.len:
      if not vm.executeInstruction(server.vm):
        break

    # Send stopped event if we're paused
    if server.debugger.paused and server.debugger.lastFile.len > 0:
      let stoppedEvent = %*{
        "type": "event",
        "event": "stopped",
        "body": {
          "reason": "step",
          "threadId": 1,
          "file": server.debugger.lastFile,
          "line": server.debugger.lastLine
        }
      }
      echo $stoppedEvent
      stdout.flushFile()

    return %*{"success": true}

  of "pause":
    debugger.pause(server.debugger)
    return %*{"success": true}

  of "stackTrace":
    # Return current stack frame based on debugger state
    var stackFrames: seq[JsonNode] = @[]

    stderr.writeLine("DEBUG: stackTrace request - debugger.paused=" & $server.debugger.paused &
                     " lastFile=" & server.debugger.lastFile &
                     " lastLine=" & $server.debugger.lastLine)
    stderr.flushFile()

    if server.debugger.paused and server.debugger.lastFile.len > 0 and server.debugger.lastLine > 0:
      # Create stack frame for current position
      let stackFrame = %*{
        "id": 1,
        "name": "main",
        "source": {
          "name": server.debugger.lastFile.split("/")[^1],  # Just filename
          "path": server.debugger.lastFile.absolutePath()  # Convert to absolute path
        },
        "line": server.debugger.lastLine,
        "column": 1,
        "variablesReference": 1  # Reference for variable scope
      }
      stackFrames.add(stackFrame)
      stderr.writeLine("DEBUG: Added stack frame: line=" & $server.debugger.lastLine & " file=" & server.debugger.lastFile.absolutePath())
      stderr.flushFile()
    else:
      stderr.writeLine("DEBUG: No stack frame created - conditions not met")
      stderr.flushFile()

    return %*{
      "success": true,
      "body": {
        "stackFrames": stackFrames,
        "totalFrames": stackFrames.len
      }
    }

  of "variables":
    # Return current variables in scope
    let args = request["arguments"]
    let variablesReference = if args.hasKey("variablesReference"): args["variablesReference"].getInt() else: 0

    var variables: seq[JsonNode] = @[]

    # For now, we handle the main scope (variablesReference = 1)
    if variablesReference == 1:
      let currentVars = vm.vmGetCurrentVariables(server.vm)
      for name, value in currentVars:
        variables.add(%*{
          "name": name,
          "value": value,
          "variablesReference": 0  # 0 means no nested variables
        })

    return %*{
      "success": true,
      "body": {
        "variables": variables
      }
    }

  of "scopes":
    # Return variable scopes for a stack frame
    let args = request["arguments"]
    let frameId = args["frameId"].getInt()

    var scopes: seq[JsonNode] = @[]

    if frameId == 1:  # Main frame
      scopes.add(%*{
        "name": "Local",
        "variablesReference": 1,
        "expensive": false
      })

    return %*{
      "success": true,
      "body": {
        "scopes": scopes
      }
    }

  else:
    return %*{
      "success": false,
      "message": "Unknown command: " & command
    }

proc sendDebugOutput(message: string, seq: int) =
  ## Send debug message as DAP output event
  let outputEvent = %*{
    "seq": seq,
    "type": "event",
    "event": "output",
    "body": {
      "category": "console",
      "output": "[ETCH DEBUG] " & message & "\n"
    }
  }
  echo $outputEvent
  stdout.flushFile()

proc runDebugServer*(program: BytecodeProgram, sourceFile: string) =
  ## Run the debug server that communicates with VSCode via stdio
  stderr.writeLine("DEBUG: Starting debug server for file: " & sourceFile)
  stderr.flushFile()

  let server = newDebugServer(program)
  var initialized = false
  var eventSeq = 1000  # Start event sequence numbers at 1000
  var responseSeq = 6  # Start response sequence numbers at 6

  stderr.writeLine("DEBUG: Debug server initialized, waiting for requests...")
  stderr.flushFile()

  # Handle Debug Adapter Protocol communication
  while true:
    try:
      stderr.writeLine("DEBUG: Waiting for input...")
      stderr.flushFile()

      # Ensure stdout is flushed before waiting for input
      stdout.flushFile()

      let line = readLine(stdin)
      stderr.writeLine("DEBUG: Received line: " & line)
      stderr.flushFile()

      if line.len == 0:
        stderr.writeLine("DEBUG: Empty line received, breaking")
        stderr.flushFile()
        break

      let request = parseJson(line)
      let command = request["command"].getStr()
      stderr.writeLine("DEBUG: Processing command: " & command)
      stderr.flushFile()

      # Send debug info for received commands (after initialization)
      if initialized:
        eventSeq += 1
        sendDebugOutput("Processing command: " & command, eventSeq)

      # Handle initialize request first
      if command == "initialize" and not initialized:
        let response = %*{
          "seq": 1,
          "type": "response",
          "request_seq": request["seq"],
          "success": true,
          "command": "initialize",
          "body": {
            "supportsConfigurationDoneRequest": true,
            "supportsEvaluateForHovers": false,
            "supportsStepBack": false,
            "supportsSetVariable": false,
            "supportsRestartFrame": false,
            "supportsGotoTargetsRequest": false,
            "supportsStepInTargetsRequest": false,
            "supportsCompletionsRequest": false,
            "supportsModulesRequest": false,
            "additionalModuleColumns": [],
            "supportedChecksumAlgorithms": [],
            "supportsRestartRequest": false,
            "supportsExceptionOptions": false,
            "supportsValueFormattingOptions": false,
            "supportsExceptionInfoRequest": false,
            "supportTerminateDebuggee": true,
            "supportsDelayedStackTraceLoading": false,
            "supportsLoadedSourcesRequest": false,
            "supportsLogPoints": false,
            "supportsTerminateThreadsRequest": false,
            "supportsSetExpression": false,
            "supportsTerminateRequest": true,
            "completionTriggerCharacters": [],
            "supportsBreakpointLocationsRequest": false
          }
        }
        echo $response
        stdout.flushFile()

        # Send initialized event after successful initialization
        let initEvent = %*{
          "seq": 2,
          "type": "event",
          "event": "initialized",
          "body": {}
        }
        echo $initEvent
        stdout.flushFile()

        # Send debug info to VS Code debug console
        eventSeq += 1
        sendDebugOutput("Debug server started for file: " & sourceFile, eventSeq)
        eventSeq += 1
        sendDebugOutput("Debug server initialized and ready for requests", eventSeq)

        initialized = true
        continue

      # Handle launch request
      if command == "launch":
        let response = %*{
          "seq": 3,
          "type": "response",
          "request_seq": request["seq"],
          "success": true,
          "command": "launch"
        }
        echo $response
        stdout.flushFile()

        # Initialize debugger state for entry
        server.debugger.paused = true
        server.debugger.stepMode = debugger.smContinue

        # Get the first instruction's debug info if available
        if server.vm.program.instructions.len > 0:
          let firstInstr = server.vm.program.instructions[0]
          server.debugger.lastFile = firstInstr.debug.sourceFile
          server.debugger.lastLine = firstInstr.debug.line
        else:
          # Fallback to source file
          server.debugger.lastFile = sourceFile
          server.debugger.lastLine = 1

        # Send stopped event to indicate we're ready for debugging
        let stoppedEvent = %*{
          "seq": 4,
          "type": "event",
          "event": "stopped",
          "body": {
            "reason": "entry",
            "threadId": 1,
            "allThreadsStopped": true,
            "file": server.debugger.lastFile,
            "line": server.debugger.lastLine
          }
        }
        echo $stoppedEvent
        continue

      # Handle configurationDone request
      if command == "configurationDone":
        let response = %*{
          "seq": 5,
          "type": "response",
          "request_seq": request["seq"],
          "success": true,
          "command": "configurationDone"
        }
        echo $response
        stdout.flushFile()
        continue

      # Handle other debug requests
      let response = server.handleDebugRequest(request)
      if request.hasKey("seq"):
        response["request_seq"] = request["seq"]
        response["type"] = %*"response"
        response["command"] = %*command
        if not response.hasKey("seq"):
          response["seq"] = %*responseSeq
          responseSeq += 1

      echo $response
      stdout.flushFile()

    except EOFError:
      stderr.writeLine("DEBUG: EOF reached, exiting debug server")
      stderr.flushFile()
      break
    except JsonParsingError as e:
      stderr.writeLine("DEBUG: JSON parsing error: " & e.msg)
      stderr.flushFile()
      echo %*{
        "seq": 999,
        "type": "response",
        "success": false,
        "message": "Invalid JSON: " & e.msg
      }
    except Exception as e:
      stderr.writeLine("DEBUG: Unexpected error: " & e.msg)
      stderr.writeLine("DEBUG: Exception type: " & $e.name)
      stderr.flushFile()
      echo %*{
        "seq": 999,
        "type": "response",
        "success": false,
        "message": "Error: " & e.msg
      }

  stderr.writeLine("DEBUG: Debug server exiting normally")
  stderr.flushFile()