import std/[unittest, json, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

suite "Register VM Debugger - Variables Display":
  test "Variables display correctly during execution":
    # Compile the example
    discard execProcess("./etch --compile examples/float_test.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/float_test.etcx")
    let server = newRegDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/float_test.etch"}
    })

    # Step to main and then to first variable declaration
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get stack trace to verify position
    let stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
    let frames = stackResp["body"]["stackFrames"].getElems()
    check frames.len > 0
    check frames[0]["name"].getStr() == "main"

  test "Scopes are available during execution":
    # Compile the example
    discard execProcess("./etch --compile examples/float_test.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/float_test.etcx")
    let server = newRegDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/float_test.etch"}
    })

    # Step to main
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get scopes
    let scopesResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "scopes", "arguments": {"frameId": 0}})
    let scopes = scopesResp["body"]["scopes"].getElems()

    check scopes.len >= 2  # At least Local and Globals
    check scopes[0]["name"].getStr() == "Local Variables"

  test "Local variables are accessible":
    # Compile the example
    discard execProcess("./etch --compile examples/float_test.etch")

    # Load and create debug server
    let prog = loadRegBytecode("examples/__etch__/float_test.etcx")
    let server = newRegDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopOnEntry": true, "program": "examples/float_test.etch"}
    })

    # Step through to first variable declaration
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get local variables (reference 1 is always Local Variables from scopes)
    let varsResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "variables", "arguments": {"variablesReference": 1}})
    let variables = varsResp["body"]["variables"].getElems()

    check variables.len > 0
    check variables[0]["name"].getStr().len > 0
    check variables[0]["value"].getStr().len > 0
