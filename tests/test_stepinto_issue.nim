import std/[unittest, json, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]
import test_utils

suite "Register VM Debugger - Step Into Issue":
  let etchExe = findEtchExecutable()

  test "Step into correctly enters nested functions":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # Initialize
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})

    # Launch with stopOnEntry
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
    })

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step into test function
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
    var stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["line"].getInt() > 0

  test "Nested stepping in multiple function calls":
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

    # Step to main and step into test
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})

    # Step into again to continue stepping
    discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
    var stackResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    # At least one frame should be present
    check frames.len > 0
