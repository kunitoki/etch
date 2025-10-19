# test_debug_basic.nim
# Basic sanity tests for the register VM debugger

import std/[unittest, osproc, os, strutils]
import test_utils

suite "Register VM Debugger - Basic Sanity":
  # Ensure etch binary is built before running tests
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()
  test "Debug server responds to initialize":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, "fn main() -> void { var x: int = 1; print(x); }")
    defer: removeFile(testProg)

    # Write command to file for cross-platform compatibility
    let cmds = getTestTempDir() / "init_cmd.txt"
    writeFile(cmds, "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}")
    defer: removeFile(cmds)

    # Use cross-platform stderr redirection
    let stderrRedir = when defined(windows): "2>NUL" else: "2>&1"
    let baseCmd = etchExe & " --debug-server " & testProg & " < " & cmds & " " & stderrRedir
    let cmd = wrapWithTimeout(baseCmd, 1)
    let (output, _) = execCmdEx(cmd)

    check output.contains("\"success\":true")
    check output.contains("supportsStepInRequest")

  test "Debug server can launch program":
    let testProg = getTestTempDir() / "test.etch"
    writeFile(testProg, "fn main() -> void { var x: int = 1; print(x); }")
    defer: removeFile(testProg)

    let cmds = getTestTempDir() / "cmds.txt"
    writeFile(cmds, "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                    "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}")
    defer: removeFile(cmds)

    # Use cross-platform stderr redirection
    let stderrRedir = when defined(windows): "2>NUL" else: "2>/dev/null"
    let baseCmd = etchExe & " --debug-server " & testProg & " < " & cmds & " " & stderrRedir
    let cmd = wrapWithTimeout(baseCmd, 1)
    let (output, _) = execCmdEx(cmd)

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

    let cmds = getTestTempDir() / "cmds.txt"
    writeFile(cmds, "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                    "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
                    "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                    "{\"seq\":4,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                    "{\"seq\":5,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":0}}\n" &
                    "{\"seq\":6,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":1}}\n" &
                    "{\"seq\":7,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}")
    defer: removeFile(cmds)

    # Use cross-platform stderr redirection
    let stderrRedir = when defined(windows): "2>NUL" else: "2>/dev/null"
    let baseCmd = etchExe & " --debug-server " & testProg & " < " & cmds & " " & stderrRedir
    let cmd = wrapWithTimeout(baseCmd, 1)
    let (output, _) = execCmdEx(cmd)

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

    let cmds = getTestTempDir() / "cmds.txt"
    writeFile(cmds, "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                    "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"" & testProg & "\",\"stopOnEntry\":true}}\n" &
                    "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                    "{\"seq\":4,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}")
    defer: removeFile(cmds)

    # Use cross-platform stderr redirection
    let stderrRedir = when defined(windows): "2>NUL" else: "2>/dev/null"
    let baseCmd = etchExe & " --debug-server " & testProg & " < " & cmds & " " & stderrRedir
    let cmd = wrapWithTimeout(baseCmd, 1)
    let (output, _) = execCmdEx(cmd)

    # Should see step response
    check output.contains("\"command\":\"next\"")
    check output.contains("\"success\":true")

    # Should see multiple stopped events (one for entry, one for step)
    let stoppedCount = output.count("\"event\":\"stopped\"")
    check stoppedCount >= 2