# test_debug_basic.nim
# Basic sanity tests for the register VM debugger

import std/[unittest, os, strutils]
import test_utils

suite "Register VM Debugger - Basic Sanity":
  let etchExe = findEtchExecutable()

  test "Debug server responds to initialize":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, "fn main() -> void { var x: int = 1; print(x); }")
    defer: removeFile(testProg)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 2)

    check output.contains("\"success\":true")
    check output.contains("supportsStepInRequest")

  test "Debug server can launch program":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, "fn main() -> void { var x: int = 1; print(x); }")
    defer: removeFile(testProg)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 2)

    # Should see both responses
    check output.contains("\"command\":\"initialize\"")
    check output.contains("\"command\":\"launch\"")
    check output.contains("\"event\":\"stopped\"")

  test "Debug server provides variable information":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, """
fn main() -> void {
    var a: int = 10;
    var b: int = 20;
    print(a + b);
}
""")
    defer: removeFile(testProg)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":5,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                        "{\"seq\":6,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                        "{\"seq\":7,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Should see scopes with Local Variables
    check output.contains("Local Variables")

    # Should see variables response
    check output.contains("\"command\":\"variables\"")

    # Should have a valid variables response with success=true
    var hasValidResponse = false
    for line in output.splitLines():
      if line.contains("\"command\":\"variables\"") and line.contains("\"success\":true"):
        hasValidResponse = true
        break
    check hasValidResponse

  test "Debug server supports stepping":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 1;
    var y: int = 2;
    print(x + y);
}
""")
    defer: removeFile(testProg)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Should see step response
    check output.contains("\"command\":\"next\"")
    check output.contains("\"success\":true")

    # Should see multiple stopped events (one for entry, one for step)
    let stoppedCount = output.count("\"event\":\"stopped\"")
    check stoppedCount >= 2