import std/[unittest, json]
import ../src/etch/bytecode/serialize
import ../src/etch/capabilities/debugserver
import test_utils

suite "Register VM Debugger - Variables Display":
  let etchExe = findEtchExecutable()

  test "Variables display correctly during execution":
    # Compile the example
    check compileEtchFile(etchExe, "examples/float_test.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/float_test.etcx")
    let server = newDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/float_test.etch"}
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
    check compileEtchFile(etchExe, "examples/float_test.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/float_test.etcx")
    let server = newDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/float_test.etch"}
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
    check compileEtchFile(etchExe, "examples/float_test.etch")

    # Load and create debug server
    let prog = loadBytecode("examples/__etch__/float_test.etcx")
    let server = newDebugServer(prog, "examples/float_test.etch")

    # Initialize and launch
    discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
    discard server.handleDebugRequest(%*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"stopAtEntry": true, "program": "examples/float_test.etch"}
    })

    # Step through to first variable declaration
    discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
    discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

    # Get scopes first to retrieve the variablesReference for locals
    let scopesResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "scopes", "arguments": {"frameId": 0}})
    let scopes = scopesResp["body"]["scopes"].getElems()
    check scopes.len >= 2

    # Get the variablesReference for Local Variables (first scope)
    let localsRef = scopes[0]["variablesReference"].getInt()

    # Now get local variables using the proper reference
    let varsResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "variables", "arguments": {"variablesReference": localsRef}})
    let variables = varsResp["body"]["variables"].getElems()

    check variables.len > 0
    check variables[0]["name"].getStr().len > 0
    check variables[0]["value"].getStr().len > 0
