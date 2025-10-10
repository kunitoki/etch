import unittest
import std/[osproc, json, strutils, os, sequtils]

proc parseJsonLines(output: string): seq[JsonNode] =
  ## Parse JSON objects from output lines, ignoring non-JSON lines
  result = @[]
  for line in output.splitLines():
    if line.len > 0 and line.startsWith("{"):
      try:
        result.add(parseJson(line))
      except:
        discard

proc runDebugCommands(program: string, commands: seq[JsonNode]): string =
  ## Run debug server with given commands and return output
  let cmdFile = getTempDir() / "debug_crash_test.txt"
  writeFile(cmdFile, commands.mapIt($it).join("\n"))
  defer: removeFile(cmdFile)

  let cmd = "timeout 2 ./etch --debug-server " & program & " < " & cmdFile & " 2>&1 || true"
  let (output, _) = execCmdEx(cmd)
  return output

suite "Debugger Crash Tests":
  test "Variables request should not crash":
    # Create a simple test program
    let testProgram = getTempDir() / "test_crash.etch"
    writeFile(testProgram, """
fn main() {
    let a: int = 10;
    var b: int = 0;
    let c: int = 20;
    b = a + c;
    let arr: array[int] = [1, 2, 3];
    print(b);
    print(arr[0]);
}
""")
    defer: removeFile(testProgram)

    # Create debug commands that previously caused a crash
    let commands = @[
      %*{
        "seq": 1,
        "type": "request",
        "command": "initialize",
        "arguments": {}
      },
      %*{
        "seq": 2,
        "type": "request",
        "command": "launch",
        "arguments": {
          "program": testProgram,
          "stopOnEntry": true
        }
      },
      %*{
        "seq": 3,
        "type": "request",
        "command": "scopes",
        "arguments": {
          "frameId": 0
        }
      },
      %*{
        "seq": 4,
        "type": "request",
        "command": "variables",
        "arguments": {
          "variablesReference": 1  # Local variables
        }
      },
      %*{
        "seq": 5,
        "type": "request",
        "command": "disconnect",
        "arguments": {}
      }
    ]

    # Run the commands - this should not crash
    let output = runDebugCommands(testProgram, commands)

    # Check that we didn't get a segfault
    check not output.contains("SIGSEGV")
    check not output.contains("Illegal storage access")

    # Parse the output and check for success
    let responses = parseJsonLines(output)

    # We should have at least some responses
    check responses.len > 0

    # Check for successful variables response
    var hasVariablesResponse = false
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "variables":
        hasVariablesResponse = true
        check resp.hasKey("success")
        if resp["success"].getBool():
          check resp.hasKey("body")
          check resp["body"].hasKey("variables")

    check hasVariablesResponse

  test "Variables with lifetime data":
    # Test that lifetime data is properly handled
    let testProgram = getTempDir() / "test_lifetime.etch"
    writeFile(testProgram, """
fn main() {
    let x: int = 10;
    let y: int = 20;
    let z: int = x + y;
}
""")
    defer: removeFile(testProgram)

    let commands = @[
      %*{
        "seq": 1,
        "type": "request",
        "command": "initialize",
        "arguments": {}
      },
      %*{
        "seq": 2,
        "type": "request",
        "command": "launch",
        "arguments": {
          "program": testProgram,
          "stopOnEntry": true
        }
      },
      %*{
        "seq": 3,
        "type": "request",
        "command": "variables",
        "arguments": {
          "variablesReference": 1
        }
      },
      %*{
        "seq": 4,
        "type": "request",
        "command": "disconnect",
        "arguments": {}
      }
    ]

    let output = runDebugCommands(testProgram, commands)

    # Check that we didn't crash
    check not output.contains("SIGSEGV")
    check not output.contains("Illegal storage access")

    # Parse the output
    let responses = parseJsonLines(output)
    check responses.len > 0

    # Check for successful variables response
    for resp in responses:
      if resp.hasKey("command") and resp["command"].getStr() == "variables":
        check resp.hasKey("success")
        # Variables should be filtered based on lifetime
        if resp["success"].getBool():
          check resp["body"].hasKey("variables")