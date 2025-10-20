# test_debugger_simple.nim
# Simple test for the register VM debugger

import std/[unittest, json, os, strutils]
import test_utils

suite "Register VM Debugger - Basic":
  # Ensure etch binary is built before running tests
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()

  test "Debug server starts and responds to initialize":
    # Create a simple test program
    let testProgram = getTestTempDir() / "test_debug.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    print(x);
}
""")
    defer: removeFile(testProgram)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProgram, inputCommands, timeoutSecs = 2)

    # Check that we got a response
    check output.contains("\"success\":true")
    check output.contains("\"command\":\"initialize\"")
    check output.contains("supportsStepInRequest")

  test "Debug server processes multiple commands":
    let testProgram = getTestTempDir() / "test_step.etch"
    writeFile(testProgram, """
fn main() -> void {
    var a: int = 10;
    var b: int = 20;
    var c: int = a + b;
    print(c);
}
""")
    defer: removeFile(testProgram)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProgram & "\",\"stopOnEntry\":true}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"threads\",\"arguments\":{}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProgram, inputCommands, timeoutSecs = 3)

    # Check key responses
    check output.contains("\"success\":true")
    check output.contains("\"command\":\"initialize\"")
    check output.contains("\"command\":\"launch\"")
    check output.contains("\"command\":\"threads\"")
    check output.contains("\"name\":\"main\"")

    # Check stopped event (from stopOnEntry)
    check output.contains("\"event\":\"stopped\"")

  test "Debug server tracks line numbers":
    let testProgram = getTestTempDir() / "test_lines.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    var y: int = 2;
    var z: int = 3;
    print(x + y + z);
}
""")
    defer: removeFile(testProgram)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProgram & "\",\"stopOnEntry\":true}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProgram, inputCommands, timeoutSecs = 2)

    # Parse output to find stackTrace response
    var foundStackTrace = false
    for line in output.splitLines():
      if line.contains("\"command\":\"stackTrace\"") and line.contains("\"type\":\"response\""):
        let response = parseJson(line)
        if response["body"]["stackFrames"].len > 0:
          let lineNum = response["body"]["stackFrames"][0]["line"].getInt()
          check lineNum == 2  # Should start at line 2 (first line inside main)
          foundStackTrace = true
          break

    check foundStackTrace

  test "Variables show correct values after stepping":
    let testProgram = getTestTempDir() / "test_values.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 5;
    var y: int = 10;
    var z: int = x + y;
    print(z);
}
""")
    defer: removeFile(testProgram)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProgram & "\",\"stopOnEntry\":true}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                        "{\"seq\":5,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":6,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                        "{\"seq\":7,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                        "{\"seq\":8,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":9,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                        "{\"seq\":10,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                        "{\"seq\":11,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":12,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                        "{\"seq\":13,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                        "{\"seq\":14,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProgram, inputCommands, timeoutSecs = 4)

    # Parse variable responses
    var varResponses: seq[JsonNode] = @[]
    for line in output.splitLines():
      if line.contains("\"command\":\"variables\"") and line.contains("\"type\":\"response\""):
        try:
          varResponses.add(parseJson(line))
        except CatchableError:
          discard

    check varResponses.len >= 3  # Should have at least 3 variable responses

    if varResponses.len >= 3:
      # After first step (x = 5)
      var foundX = false
      for v in varResponses[1]["body"]["variables"]:
        if v["name"].getStr() == "x":
          check v["value"].getStr() == "5"
          foundX = true
      check foundX

      # After second step (y = 10)
      var foundY = false
      for v in varResponses[2]["body"]["variables"]:
        if v["name"].getStr() == "y":
          check v["value"].getStr() == "10"
          foundY = true
      check foundY

      # After third step (z = 15)
      if varResponses.len > 3:
        var foundZ = false
        for v in varResponses[3]["body"]["variables"]:
          if v["name"].getStr() == "z":
            check v["value"].getStr() == "15"
            foundZ = true
        check foundZ
