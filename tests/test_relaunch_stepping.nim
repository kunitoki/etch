import std/[unittest, json, osproc, strformat]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]
import test_utils

suite "Register VM Debugger - Relaunch and Stepping":
  let etchExe = findEtchExecutable()

  test "Program can be launched and stepped through":
    # Compile the example
    discard execProcess(etchExe & " --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # First launch
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

    # Get to main
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    frames = stackResp["body"]["stackFrames"].getElems()
    check frames[0]["name"].getStr() == "main"

  test "Step into works after multiple steps":
    # Compile the example
    discard execProcess("./etch --compile examples/fn_order.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
    let server = newRegDebugServer(prog, "examples/fn_order.etch")

    # Launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
    })

    # Step through globals
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Now step into a function
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})

    let stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["line"].getInt() > 0
