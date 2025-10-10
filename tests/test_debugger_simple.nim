# test_debugger_simple.nim
# Simple test for the register VM debugger

import std/[unittest, json, osproc, streams, os, strutils, sequtils]

suite "Register VM Debugger - Basic":
  test "Debug server starts and responds to initialize":
    # Create a simple test program
    let testProgram = getTempDir() / "test_debug.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    print(x);
}
""")
    defer: removeFile(testProgram)

    # Start debug server and send commands via stdin
    let (output, exitCode) = execCmdEx(
      "echo '{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}' | timeout 1 ./etch --debug-server " & testProgram & " 2>&1 || true"
    )

    # Check that we got a response
    check output.contains("\"success\":true")
    check output.contains("\"command\":\"initialize\"")
    check output.contains("supportsStepInRequest")

  test "Debug server processes multiple commands":
    let testProgram = getTempDir() / "test_step.etch"
    writeFile(testProgram, """
fn main() -> void {
    var a: int = 10;
    var b: int = 20;
    var c: int = a + b;
}
""")
    defer: removeFile(testProgram)

    # Create input file with DAP commands (note: no scopes needed before variables)
    let inputFile = getTempDir() / "debug_input.txt"
    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProgram),
      """{"seq":3,"type":"request","command":"threads","arguments":{}}""",
      """{"seq":4,"type":"request","command":"disconnect","arguments":{}}"""
    ]
    writeFile(inputFile, commands.join("\n"))
    defer: removeFile(inputFile)

    let (output, exitCode) = execCmdEx(
      "timeout 2 ./etch --debug-server " & testProgram & " < " & inputFile & " 2>&1 | grep -v '^DEBUG' || true"
    )

    # Check key responses
    check output.contains("\"success\":true")
    check output.contains("\"command\":\"initialize\"")
    check output.contains("\"command\":\"launch\"")
    check output.contains("\"command\":\"threads\"")
    check output.contains("\"name\":\"main\"")

    # Check stopped event (from stopOnEntry)
    check output.contains("\"event\":\"stopped\"")

  test "Debug server tracks line numbers":
    let testProgram = getTempDir() / "test_lines.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    var y: int = 2;
    var z: int = 3;
}
""")
    defer: removeFile(testProgram)

    # Create input to get stack trace
    let inputFile = getTempDir() / "debug_lines_input.txt"
    writeFile(inputFile, """{"seq":1,"type":"request","command":"initialize","arguments":{}}
{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}
{"seq":3,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":4,"type":"request","command":"disconnect","arguments":{}}""".format(testProgram))
    defer: removeFile(inputFile)

    let (output, exitCode) = execCmdEx(
      "timeout 1 ./etch --debug-server " & testProgram & " < " & inputFile & " 2>&1 | grep -v '^DEBUG' || true"
    )

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
    let testProgram = getTempDir() / "test_values.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 5;
    var y: int = 10;
    var z: int = x + y;
}
""")
    defer: removeFile(testProgram)

    # Commands to step through and check variables
    let inputFile = getTempDir() / "debug_values_input.txt"
    writeFile(inputFile, """{"seq":1,"type":"request","command":"initialize","arguments":{}}
{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}
{"seq":3,"type":"request","command":"scopes","arguments":{"frameId":0}}
{"seq":4,"type":"request","command":"variables","arguments":{"variablesReference":1}}
{"seq":5,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":6,"type":"request","command":"scopes","arguments":{"frameId":0}}
{"seq":7,"type":"request","command":"variables","arguments":{"variablesReference":1}}
{"seq":8,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":9,"type":"request","command":"scopes","arguments":{"frameId":0}}
{"seq":10,"type":"request","command":"variables","arguments":{"variablesReference":1}}
{"seq":11,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":12,"type":"request","command":"scopes","arguments":{"frameId":0}}
{"seq":13,"type":"request","command":"variables","arguments":{"variablesReference":1}}
{"seq":14,"type":"request","command":"disconnect","arguments":{}}""".format(testProgram))
    defer: removeFile(inputFile)

    let (output, exitCode) = execCmdEx(
      "timeout 2 ./etch --debug-server " & testProgram & " < " & inputFile & " 2>&1 | grep -v '^DEBUG' || true"
    )

    # Parse variable responses
    var varResponses: seq[JsonNode] = @[]
    for line in output.splitLines():
      if line.contains("\"command\":\"variables\"") and line.contains("\"type\":\"response\""):
        try:
          varResponses.add(parseJson(line))
        except:
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