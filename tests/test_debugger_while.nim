import std/[json, unittest, strformat, os, strutils]
import test_utils

suite "While Loop Debugging":
  # Ensure etch binary is built before running tests
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()

  test "Stepping alternates between while statement and body":
    # Test that stepping through a while loop shows the while condition
    # on each iteration, not just after the first loop
    let testProg = getTestTempDir() / "while_break_test.etch"
    # Copy the example file to temp directory for testing
    copyFile("examples/while_break_test.etch", testProg)
    defer: removeFile(testProg)

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":5,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":6,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":7,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":8,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":9,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":10,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":11,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":12,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":13,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":14,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":15,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":16,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 2)

    # Helper to extract line number from stack trace response
    proc getLineFromTrace(output: string, seq: int): int =
      for line in output.splitLines():
        if line.contains("\"request_seq\":" & $seq) and line.contains("stackTrace"):
          let parsed = parseJson(line)
          if parsed.hasKey("body") and parsed["body"].hasKey("stackFrames"):
            let frames = parsed["body"]["stackFrames"]
            if frames.len > 0:
              return frames[0]["line"].getInt()
      return -1

    # Check initial position (seq 3)
    let line1 = getLineFromTrace(output, 3)
    echo fmt"Initial position: line {line1}"
    check line1 == 3  # Should start at print statement

    # After first step (seq 5)
    let line2 = getLineFromTrace(output, 5)
    echo fmt"After step 1: line {line2}"
    check line2 == 5  # Should be at var i = 0

    # After second step (seq 7) - SHOULD BE AT WHILE CONDITION
    let line3 = getLineFromTrace(output, 7)
    echo fmt"After step 2: line {line3}"
    check line3 == 6  # Should be at while i < 10 (FIRST TIME)

    # After third step (seq 9) - inside while body
    let line4 = getLineFromTrace(output, 9)
    echo fmt"After step 3: line {line4}"
    check line4 == 7  # Should be at if statement

    # After fourth step (seq 11) - skip if, go to print
    let line5 = getLineFromTrace(output, 11)
    echo fmt"After step 4: line {line5}"
    check line5 == 10  # Should be at print(i)

    # After fifth step (seq 13) - increment
    let line6 = getLineFromTrace(output, 13)
    echo fmt"After step 5: line {line6}"
    check line6 == 11  # Should be at i = i + 1

    # After sixth step (seq 15) - BACK TO WHILE CONDITION (2nd iteration)
    let line7 = getLineFromTrace(output, 15)
    echo fmt"After step 6: line {line7}"
    check line7 == 6  # Should be back at while i < 10 (SECOND TIME)

    echo "✓ While loop correctly shows condition on each iteration"
