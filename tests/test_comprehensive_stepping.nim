import std/[unittest, json, osproc, strformat]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]
import test_utils

suite "Register VM Debugger - Comprehensive Stepping":
  let etchExe = findEtchExecutable()

  test "Comprehensive stepping through functions":
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

    # Check initial position
    var stackResp = server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()
    check frames[0]["name"].getStr() == "<global>"

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    frames = stackResp["body"]["stackFrames"].getElems()
    check frames[0]["name"].getStr() == "main"

    # Step into test
    discard server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
    stackResp = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    frames = stackResp["body"]["stackFrames"].getElems()
    check frames.len > 0
    check frames[0]["line"].getInt() > 0

  test "Step over from inside function returns correctly":
    # Compile the example
    discard execProcess("./etch --compile examples/fn_order.etch")

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

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step into test
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})

    # Step over from inside test
    discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Should return to main function
    let stackResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["name"].getStr() == "main"
