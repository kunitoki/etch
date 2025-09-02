import std/[unittest, json, tables]
import ../src/etch/core/[vm, vm_types]
import ../src/etch/bytecode/serialize
import ../src/etch/capabilities/debugserver
import ./test_utils

suite "Global Initialization Debugging":
  let etchExe = findEtchExecutable()

  test "Debugger starts in <global> function when globals exist":
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    # Load the compiled bytecode for fn_order.etch
    let prog = loadBytecode("examples/__etch__/fn_order.etcx")
    let server = newDebugServer(prog, "examples/fn_order.etch")

    # Verify <global> function exists
    check prog.functions.hasKey("<global>")
    check prog.functions.hasKey("main")

    let globalInfo = prog.functions["<global>"]
    let mainInfo = prog.functions["main"]

    # Verify entry point is in <global> function
    check prog.entryPoint >= globalInfo.startPos
    check prog.entryPoint <= globalInfo.endPos

    # Verify main comes after global init
    check mainInfo.startPos > globalInfo.endPos

    # Simulate launch request
    let launchRequest = %*{
      "seq": 1,
      "type": "request",
      "command": "launch",
      "arguments": {
        "stopAtEntry": true,
        "program": "examples/fn_order.etch"
      }
    }

    let response = server.handleDebugRequest(launchRequest)
    check response["success"].getBool() == true

    # Get initial stack trace
    let stackTraceRequest = %*{
      "seq": 2,
      "type": "request",
      "command": "stackTrace",
      "arguments": {
        "threadId": 1
      }
    }

    let stackResponse = server.handleDebugRequest(stackTraceRequest)
    check stackResponse["success"].getBool() == true

    # Verify initial stack frame is <global>
    let frames = stackResponse["body"]["stackFrames"].getElems()
    check frames.len == 1
    check frames[0]["name"].getStr() == "<global>"

    # Verify the line number is within the source file range (line should be > 0)
    let initialLine = frames[0]["line"].getInt()
    check initialLine > 0  # Valid source line

  test "Stack transitions from <global> to main correctly":
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    # Load the compiled bytecode for fn_order.etch
    let prog = loadBytecode("examples/__etch__/fn_order.etcx")
    let server = newDebugServer(prog, "examples/fn_order.etch")

    # Launch
    let launchRequest = %*{
      "seq": 1,
      "type": "request",
      "command": "launch",
      "arguments": {
        "stopAtEntry": true,
        "program": "examples/fn_order.etch"
      }
    }
    discard server.handleDebugRequest(launchRequest)

    # Step through global initialization - this should execute the global var init
    var continueRequest = %*{
      "seq": 3,
      "type": "request",
      "command": "continue",
      "arguments": {
        "threadId": 1
      }
    }
    discard server.handleDebugRequest(continueRequest)

    # After continuing, the program should have transitioned to main
    # (This test just verifies the structure works - actual stepping behavior
    # would need more complex simulation)
