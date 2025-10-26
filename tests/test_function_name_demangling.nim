import std/[unittest, json, osproc, strutils]
import ../src/etch/common/constants
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

suite "Register VM Debugger - Function Name Demangling":
  test "Function names are properly demangled in stack traces":
    # Compile the example
    discard execProcess("./etch --compile examples/fn_order.etch")

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

    # Get initial stack (should be <global>)
    var stackResp = server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    var frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    let globalName = frames[0]["name"].getStr()
    check globalName == "<global>"
    check not (FUNCTION_NAME_SEPARATOR_STRING in globalName)

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get stack (should show main)
    stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    frames = stackResp["body"]["stackFrames"].getElems()

    check frames.len > 0
    let mainName = frames[0]["name"].getStr()
    check mainName == "main"
    check not (FUNCTION_NAME_SEPARATOR_STRING in mainName and mainName != "__global__")

  test "Demangled names in nested function calls":
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

    # Get stack with nested functions
    let stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()

    # Verify all function names are demangled
    for frame in frames:
      let funcName = frame["name"].getStr()
      check not (FUNCTION_NAME_SEPARATOR_STRING in funcName and funcName != "__global__")
