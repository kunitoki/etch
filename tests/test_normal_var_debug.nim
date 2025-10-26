# test_normal_var_debug.nim
# Test that normal variables appear in debugger

import std/[unittest, os, strutils]
import test_utils

suite "Normal Variable Debugging":
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()

  test "Normal var variable appears in local variables":
    let testProg = getTestTempDir() / "test_normal_var.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 10;
    print(x);
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step to variable declaration, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that the variable 'x' appears in the output
    check output.contains("\"name\":\"x\"") or output.contains("\"name\": \"x\"")

  test "Normal let variable appears in local variables":
    let testProg = getTestTempDir() / "test_normal_let.etch"
    writeFile(testProg, """
fn main() -> void {
    let y: int = 20;
    print(y);
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step to variable declaration, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that the variable 'y' appears in the output
    check output.contains("\"name\":\"y\"") or output.contains("\"name\": \"y\"")

  test "Normal variable value is correct":
    let testProg = getTestTempDir() / "test_normal_value.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 42;
    print(x);
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step to variable declaration, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that variable 'x' appears and has value 42
    check output.contains("\"name\":\"x\"") or output.contains("\"name\": \"x\"")
    check output.contains("\"value\":\"42\"") or output.contains("\"value\": \"42\"")
