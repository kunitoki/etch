# test_setvariable.nim
# Test that setVariable works correctly in the debugger

import std/[unittest, os, strutils]
import test_utils

suite "Set Variable Debugging":
  let etchExe = findEtchExecutable()

  test "Set integer variable":
    let testProg = getTestTempDir() / "test_setvar_int.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 10;
    print(x);
}
""")
    defer: removeFile(testProg)

    # Initialize, launch, step, get scopes, get variables, set variable, verify
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"x\",\"value\":\"42\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that initial value is 10
    check output.contains("\"value\":\"10\"") or output.contains("\"value\": \"10\"")
    # Check that setVariable succeeded
    check output.contains("\"setVariable\"")
    # Check that final value is 42
    check output.contains("\"value\":\"42\"") or output.contains("\"value\": \"42\"")

  test "Set float variable":
    let testProg = getTestTempDir() / "test_setvar_float.etch"
    writeFile(testProg, """
fn main() -> void {
    var y: float = 3.14;
    print(y);
}
""")
    defer: removeFile(testProg)

    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"y\",\"value\":\"2.71\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that initial value is 3.14
    check output.contains("\"value\":\"3.14\"") or output.contains("\"value\": \"3.14\"")
    # Check that final value is 2.71
    check output.contains("\"value\":\"2.71\"") or output.contains("\"value\": \"2.71\"")

  test "Set boolean variable":
    let testProg = getTestTempDir() / "test_setvar_bool.etch"
    writeFile(testProg, """
fn main() -> void {
    var flag: bool = true;
    print(flag);
}
""")
    defer: removeFile(testProg)

    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"flag\",\"value\":\"false\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that initial value is true
    check output.contains("\"value\":\"true\"") or output.contains("\"value\": \"true\"")
    # Check that final value is false
    check output.contains("\"value\":\"false\"") or output.contains("\"value\": \"false\"")

  test "Set string variable with quoted input":
    let testProg = getTestTempDir() / "test_setvar_string.etch"
    writeFile(testProg, """
fn main() -> void {
    var msg: string = "hello";
    print(msg);
}
""")
    defer: removeFile(testProg)

    # User must provide string WITH quotes (like Python debugpy)
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"msg\",\"value\":\"\\\"world\\\"\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that initial value is "hello" (with quotes in value field for display)
    check output.contains("\\\"hello\\\"")
    # Check that final value is "world" (with quotes)
    check output.contains("\\\"world\\\"")

  test "Set for loop variable":
    let testProg = getTestTempDir() / "test_setvar_forloop.etch"
    writeFile(testProg, """
fn main() -> void {
    for i in 0..3 {
        print(i);
    }
}
""")
    defer: removeFile(testProg)

    # Step into loop body, modify loop variable, verify
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":6,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"i\",\"value\":\"99\"}}\n" &
      "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
      "{\"seq\":8,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that loop variable 'i' can be modified
    check output.contains("\"name\":\"i\"") or output.contains("\"name\": \"i\"")
    check output.contains("\"value\":\"99\"") or output.contains("\"value\": \"99\"")

  test "Set string variable without quotes fails":
    let testProg = getTestTempDir() / "test_setvar_string_noquotes.etch"
    writeFile(testProg, """
fn main() -> void {
    var msg: string = "hello";
    print(msg);
}
""")
    defer: removeFile(testProg)

    # Test setting WITHOUT quotes (should fail like Python debugpy)
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"msg\",\"value\":\"world\"}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Should fail because string value must be quoted
    check output.contains("\"success\":false") or output.contains("must be quoted")

  test "Set variable type mismatch - int to string fails":
    let testProg = getTestTempDir() / "test_setvar_typemismatch.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 10;
    print(x);
}
""")
    defer: removeFile(testProg)

    # Try to set int variable to a string (should fail)
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"x\",\"value\":\"\\\"hello\\\"\"}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Should fail because type doesn't match
    check output.contains("\"success\":false") or output.contains("Invalid")

  test "Set variable error - variable not found":
    let testProg = getTestTempDir() / "test_setvar_notfound.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 10;
    print(x);
}
""")
    defer: removeFile(testProg)

    # Try to set a variable that doesn't exist
    let inputCommands =
      "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
      "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopAtEntry\":true}}\n" &
      "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
      "{\"seq\":4,\"type\":\"request\",\"command\":\"setVariable\",\"arguments\":{\"variablesReference\":1,\"name\":\"nonexistent\",\"value\":\"42\"}}\n" &
      "{\"seq\":5,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check that an error is returned
    check output.contains("\"success\":false") or output.contains("not found") or output.contains("not in scope")
