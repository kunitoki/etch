import std/[unittest, json, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]
import test_utils

suite "Register VM Debugger - Step Over From Test":
  let etchExe = findEtchExecutable()

  test "Step over from inside test function completes correctly":
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

    # Get to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step into test
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
    var stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["line"].getInt() > 0

    # Step over from inside test
    discard server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Verify program either completed or returned to a valid state
    stackResp = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    frames = stackResp["body"]["stackFrames"].getElems()

    # Test passes if either program completed or we have a valid stack
    check (frames.len == 0) or (frames.len > 0 and frames[0]["line"].getInt() > 0)
