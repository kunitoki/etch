# test_debugger_integration.nim
# Integration tests for the register VM debugger with DAP protocol

import std/[unittest, json, osproc, os, strutils, sequtils, times]

proc cleanEtchCache(dir: string) =
  ## Clean etch cache files in a directory
  let cacheDir = dir / "__etch__"
  if dirExists(cacheDir):
    for file in walkFiles(cacheDir / "*.etcx"):
      removeFile(file)

proc runDebugServer(program: string, commands: seq[string], timeout: int = 2): string =
  ## Run debug server with given commands and return output
  let cmdFile = getTempDir() / "debug_commands.txt"
  writeFile(cmdFile, commands.join("\n"))
  defer: removeFile(cmdFile)

  let cmd = "timeout " & $timeout & " ./etch --debug-server " & program & " < " & cmdFile & " 2>/dev/null || true"
  let (output, _) = execCmdEx(cmd)
  return output

proc parseJsonLines(output: string): seq[JsonNode] =
  ## Parse JSON objects from output lines
  result = @[]
  for line in output.splitLines():
    if line.len > 0 and line.startsWith("{"):
      try:
        result.add(parseJson(line))
      except:
        discard

proc hasResponse(responses: seq[JsonNode], command: string): bool =
  ## Check if a response for a specific command exists
  for resp in responses:
    if resp.hasKey("command") and resp["command"].getStr() == command:
      return true
  return false

proc hasEvent(responses: seq[JsonNode], event: string): bool =
  ## Check if a specific event exists
  for resp in responses:
    if resp.hasKey("event") and resp["event"].getStr() == event:
      return true
  return false

suite "Register VM Debugger Integration":
  setup:
    # Clean any cached bytecode
    cleanEtchCache(getTempDir())

  test "Initialize and capabilities":
    let testProg = getTempDir() / "init_test.etch"
    writeFile(testProg, "fn main() -> void { var x: int = 1; print(x); }")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands, 1)
    let responses = parseJsonLines(output)

    check responses.len > 0
    check hasResponse(responses, "initialize")

    # Check capabilities
    var hasCapabilities = false
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "initialize":
        if resp.hasKey("body"):
          check resp["body"].hasKey("supportsStepInRequest")
          check resp["body"]["supportsStepInRequest"].getBool() == true
          check resp["body"]["supportsContinueRequest"].getBool() == true
          hasCapabilities = true
          break
    check hasCapabilities

  test "Launch and stop on entry":
    let testProg = getTempDir() / "launch_test.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 42;
    print(x);
}
""")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      """{"seq":3,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands)
    let responses = parseJsonLines(output)

    check hasResponse(responses, "launch")
    check hasEvent(responses, "stopped")

    # Verify stopped reason is "entry"
    for resp in responses:
      if resp.hasKey("event") and resp["event"].getStr() == "stopped":
        check resp["body"]["reason"].getStr() == "entry"
        break

  test "Stack trace shows correct line":
    let testProg = getTempDir() / "stack_test.etch"
    writeFile(testProg, """
fn main() -> void {
    var a: int = 10;
    var b: int = 20;
    print(a + b);
}
""")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      """{"seq":3,"type":"request","command":"stackTrace","arguments":{"threadId":1}}""",
      """{"seq":4,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands)
    let responses = parseJsonLines(output)

    # Find stackTrace response
    var foundStackTrace = false
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "stackTrace":
        check resp["body"].hasKey("stackFrames")
        let frames = resp["body"]["stackFrames"]
        check frames.len > 0
        check frames[0]["line"].getInt() == 2  # Should be at first line inside main
        check frames[0]["name"].getStr() == "main"
        foundStackTrace = true
        break
    check foundStackTrace

  test "Variables show correct values":
    let testProg = getTempDir() / "vars_test.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 100;
    var y: int = 200;
    var z: int = x + y;
    print(z);
}
""")
    defer: removeFile(testProg)

    # Step through and check variable values
    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      # Get initial variables (all should be 0)
      """{"seq":3,"type":"request","command":"scopes","arguments":{"frameId":0}}""",
      """{"seq":4,"type":"request","command":"variables","arguments":{"variablesReference":1}}""",
      # Step to line 3 (after x = 100)
      """{"seq":5,"type":"request","command":"next","arguments":{"threadId":1}}""",
      """{"seq":6,"type":"request","command":"scopes","arguments":{"frameId":0}}""",
      """{"seq":7,"type":"request","command":"variables","arguments":{"variablesReference":1}}""",
      # Step to line 4 (after y = 200)
      """{"seq":8,"type":"request","command":"next","arguments":{"threadId":1}}""",
      """{"seq":9,"type":"request","command":"scopes","arguments":{"frameId":0}}""",
      """{"seq":10,"type":"request","command":"variables","arguments":{"variablesReference":1}}""",
      """{"seq":11,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands, 3)
    let responses = parseJsonLines(output)

    # Collect all variable responses
    var varResponses: seq[JsonNode] = @[]
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "variables":
        if resp.hasKey("body") and resp["body"].hasKey("variables"):
          varResponses.add(resp)

    check varResponses.len >= 2  # At least initial and after first step

    if varResponses.len >= 2:
      # After first step, x should be 100
      var foundX = false
      for v in varResponses[1]["body"]["variables"]:
        if v["name"].getStr() == "x":
          check v["value"].getStr() == "100"
          foundX = true
      check foundX

  test "Stepping works correctly":
    let testProg = getTempDir() / "step_test.etch"
    writeFile(testProg, """
fn main() -> void {
    var a: int = 1;
    var b: int = 2;
    var c: int = 3;
    print(a + b + c);
}
""")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      """{"seq":3,"type":"request","command":"next","arguments":{"threadId":1}}""",
      """{"seq":4,"type":"request","command":"next","arguments":{"threadId":1}}""",
      """{"seq":5,"type":"request","command":"next","arguments":{"threadId":1}}""",
      """{"seq":6,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands)
    let responses = parseJsonLines(output)

    # Count stopped events (should be at least 4: entry + 3 steps)
    var stoppedCount = 0
    for resp in responses:
      if resp.hasKey("event") and resp["event"].getStr() == "stopped":
        stoppedCount += 1

    check stoppedCount >= 4

  test "Continue runs to completion":
    let testProg = getTempDir() / "continue_test.etch"
    writeFile(testProg, """
fn main() -> void {
    var x: int = 10;
    print(x);
}
""")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      """{"seq":3,"type":"request","command":"continue","arguments":{"threadId":1}}""",
      """{"seq":4,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands)
    let responses = parseJsonLines(output)

    check hasResponse(responses, "continue")
    check hasEvent(responses, "terminated")

  test "Threads request returns main thread":
    let testProg = getTempDir() / "threads_test.etch"
    writeFile(testProg, "fn main() -> void { print(1); }")
    defer: removeFile(testProg)

    let commands = @[
      """{"seq":1,"type":"request","command":"initialize","arguments":{}}""",
      """{"seq":2,"type":"request","command":"launch","arguments":{"program":"$1","stopOnEntry":true}}""".format(testProg),
      """{"seq":3,"type":"request","command":"threads","arguments":{}}""",
      """{"seq":4,"type":"request","command":"disconnect","arguments":{}}"""
    ]

    let output = runDebugServer(testProg, commands)
    let responses = parseJsonLines(output)

    # Find threads response
    var foundThreads = false
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "threads":
        check resp["body"].hasKey("threads")
        let threads = resp["body"]["threads"]
        check threads.len == 1
        check threads[0]["id"].getInt() == 1
        check threads[0]["name"].getStr() == "main"
        foundThreads = true
        break
    check foundThreads

# Run a summary at the end
when isMainModule:
  echo "\n===== Debugger Integration Test Summary ====="
  echo "These tests validate that the register VM debugger:"
  echo "  - Responds to DAP protocol requests"
  echo "  - Stops at the correct lines"
  echo "  - Shows variables with correct names and values"
  echo "  - Steps through code line by line"
  echo "  - Continues execution to completion"
  echo "\nIf tests fail, check:"
  echo "  1. The etch compiler is built (nim c src/etch.nim)"
  echo "  2. No syntax errors in test programs"
  echo "  3. Debug server output format hasn't changed"