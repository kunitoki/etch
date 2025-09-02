import std/[json, unittest, strformat, strutils]
import test_utils

suite "For Loop Debugging":
  # Ensure etch binary is built before running tests
  let etchExe = findEtchExecutable()

  test "Stepping alternates between for statement and body":
    # Test that stepping through a for loop alternates between:
    # line 7 (for statement) and line 8 (loop body) for each iteration
    let testProg = "examples/for_string_test.etch"

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

    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

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
    echo &"Initial position: line {line1}"
    check line1 == 3  # Should start at first line with code (var nums)

    # After first step (seq 5)
    let line2 = getLineFromTrace(output, 5)
    echo &"After step 1: line {line2}"
    check line2 == 5  # Should be at print("Testing...")

    # After second step (seq 7) - first time at for statement
    let line3 = getLineFromTrace(output, 7)
    echo &"After step 2: line {line3}"
    check line3 == 7  # Should be at for statement (1st iteration)

    # After third step (seq 9) - loop body, 1st iteration
    let line4 = getLineFromTrace(output, 9)
    echo &"After step 3: line {line4}"
    check line4 == 8  # Should be at print(x) in loop body

    # After fourth step (seq 11) - back to for statement, 2nd iteration
    let line5 = getLineFromTrace(output, 11)
    echo &"After step 4: line {line5}"
    check line5 == 7  # Should be at for statement (2nd iteration)

    # After fifth step (seq 13) - loop body, 2nd iteration
    let line6 = getLineFromTrace(output, 13)
    echo &"After step 5: line {line6}"
    check line6 == 8  # Should be at print(x) in loop body

    # After sixth step (seq 15) - back to for statement, 3rd iteration
    let line7 = getLineFromTrace(output, 15)
    echo &"After step 6: line {line7}"
    check line7 == 7  # Should be at for statement (3rd iteration)

    echo "✓ For loop correctly alternates between for statement and body"

  test "For loop executes all 7 iterations":
    # Test that verifies all 7 iterations execute
    # The string "ABCDEFG" has 7 characters, so we should see 7 outputs
    let testProg = "examples/for_string_test.etch"

    let inputCommands = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}\n" &
                        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{}}\n" &
                        "{\"seq\":3,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":4,\"type\":\"request\",\"command\":\"next\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":5,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":1}}\n" &
                        "{\"seq\":6,\"type\":\"request\",\"command\":\"disconnect\",\"arguments\":{}}\n"

    # Capture stdout to verify all 7 values are printed
    let (output, _) = runDebugServerWithInput(etchExe, testProg, inputCommands, timeoutSecs = 3)

    # Check for all 7 characters (A-G) being printed
    # Each should appear on its own line
    echo "Checking for 7 loop iterations (characters A-G)..."
    check output.contains("A")
    check output.contains("B")
    check output.contains("C")
    check output.contains("D")
    check output.contains("E")
    check output.contains("F")
    check output.contains("G")

    # Also verify the expected start and end messages
    check output.contains("Testing for loop with string:")
    check output.contains("Done")

    echo "✓ All 7 iterations confirmed!"
