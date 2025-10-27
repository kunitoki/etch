import std/[unittest, json, osproc, strformat, tables]
import ../src/etch/interpreter/[regvm, regvm_serialize, regvm_debugserver]
import test_utils

suite "Register VM Debugger - Function Order Stepping":
  let etchExe = findEtchExecutable()

  test "Program structure is correct":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load bytecode
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")

    # Verify functions exist
    check prog.functions.hasKey("<global>")
    check prog.functions.hasKey("main")
    check prog.entryPoint >= 0

  test "Launch initializes debugger correctly":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # Initialize
    let initResp = server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    check initResp["success"].getBool() == true

    # Launch with stopOnEntry
    let launchResp = server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
    })
    check launchResp["success"].getBool() == true

  test "Initial stack shows global init":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
    })

    # Get initial stack trace
    let stackResp = server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len == 1
    check frames[0]["name"].getStr() == "<global>"

  test "Stepping transitions from global to main":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
    })

    # Step over to next line
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step over again to reach main
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get stack trace
    let stackResp = server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["name"].getStr() == "main"
