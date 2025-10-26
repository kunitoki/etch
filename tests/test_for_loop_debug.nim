# test_for_loop_debug.nim
# Test that for loop variables appear in debugger

import std/[unittest, os, strutils]
import test_utils

suite "For Loop Variable Debugging":
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()

  test "Numeric for loop variable appears in local variables":
    let testProg = getTestTempDir() / "test_for_numeric.etch"
    writeFile(testProg, """
fn main() -> void {
    for i in 0..3 {
        print(i);
    }
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step into loop body, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that the loop variable 'i' appears in the output
    check output.contains("\"name\":\"i\"") or output.contains("\"name\": \"i\"")

  test "Array for loop variable appears in local variables":
    let testProg = getTestTempDir() / "test_for_array.etch"
    writeFile(testProg, """
fn main() -> void {
    let arr: array[int] = [10, 20, 30];
    for item in arr {
        print(item);
    }
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step into loop body, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that the loop variable 'item' appears in the output
    check output.contains("\"name\":\"item\"") or output.contains("\"name\": \"item\"")

  test "For loop variable value is correct":
    let testProg = getTestTempDir() / "test_for_value.etch"
    writeFile(testProg, """
fn main() -> void {
    for i in 5..8 {
        print(i);
    }
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step into loop body, get variables
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that loop variable 'i' appears and has value 5 (first iteration)
    check output.contains("\"name\":\"i\"") or output.contains("\"name\": \"i\"")
    check output.contains("\"value\":\"5\"") or output.contains("\"value\": \"5\"")
