import std/[unittest, os, strutils]
import test_utils

suite "Set Array Variable":
  let etchExe = findEtchExecutable()

  test "Set integer array":
    let testProg = getTestTempDir() / "test_setvar_array_int.etch"
    writeFile(testProg, """
fn main() -> void {
    var arr: array[int] = [1, 2, 3];
    print(string(arr[0]));
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step, get variables, set array
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"arr\",\"value\":\"[10, 20, 30]\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that setVariable succeeded with array type
    check output.contains("\"setVariable\"")
    check output.contains("\"type\":\"array\"") or output.contains("\"type\": \"array\"")

  test "Set string array":
    let testProg = getTestTempDir() / "test_setvar_array_string.etch"
    writeFile(testProg, """
fn main() -> void {
    var words: array[string] = ["hello", "world"];
    print(words[0]);
}
""")
    defer: removeFile(testProg)

    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"words\",\"value\":\"[\\\"foo\\\", \\\"bar\\\", \\\"baz\\\"]\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that setVariable succeeded with array type
    check output.contains("\"setVariable\"")
    check output.contains("\"type\":\"array\"") or output.contains("\"type\": \"array\"")

  test "Set empty array":
    let testProg = getTestTempDir() / "test_setvar_array_empty.etch"
    writeFile(testProg, """
fn main() -> void {
    var nums: array[int] = [1, 2];
    print(string(nums[0]));
}
""")
    defer: removeFile(testProg)

    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"nums\",\"value\":\"[]\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that setVariable succeeded and value is empty array
    check output.contains("\"setVariable\"")
    check output.contains("\"value\":\"[]\"") or output.contains("\"value\": \"[]\"")

  test "Set array with invalid syntax fails":
    let testProg = getTestTempDir() / "test_setvar_array_fail.etch"
    writeFile(testProg, """
fn main() -> void {
    var arr: array[int] = [1, 2];
    print(string(arr[0]));
}
""")
    defer: removeFile(testProg)

    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"arr\",\"value\":\"1, 2, 3\"}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that setVariable failed with bracket error
    check output.contains("\"success\":false") or output.contains("\"success\": false")
    check output.contains("bracket")
