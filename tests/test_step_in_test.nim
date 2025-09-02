import std/[unittest, json, strutils]
import ../src/etch/common/constants
import ../src/etch/bytecode/serialize
import ../src/etch/capabilities/debugserver
import test_utils

suite "Register VM Debugger - Step Into Functionality":
  let etchExe = findEtchExecutable()

  test "Step into test function works correctly":
    # Compile the example
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/fn_order.etcx")
    let server = newDebugServer(prog, "examples/fn_order.etch")

    # Initialize
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})

    # Launch with stopAtEntry
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/fn_order.etch"}
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
    # Verify function names are demangled
    let funcName = frames[0]["name"].getStr()
    check not (FUNCTION_NAME_SEPARATOR_STRING in funcName and funcName != "__global__")

  test "Step over from inside function works correctly":
    # Compile the example
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/fn_order.etcx")
    let server = newDebugServer(prog, "examples/fn_order.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/fn_order.etch"}
    })

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step into test
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})

    # Step over from inside test
    discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    var stackResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["line"].getInt() > 0

  test "Step into from inside test continues stepping":
    # Compile the example
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/fn_order.etcx")
    let server = newDebugServer(prog, "examples/fn_order.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/fn_order.etch"}
    })

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Step into test
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})

    # Step into again while in test
    discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
    var stackResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    check frames[0]["line"].getInt() > 0
