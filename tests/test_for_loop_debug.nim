import std/[json, unittest, strformat, osproc, os, strutils]

suite "For Loop Debugging":
  test "Can step through for loop body":
    # Create command file with debug protocol requests
    let cmds = getTempDir() / "for_loop_test_cmds.txt"
    writeFile(cmds, """{"seq":1,"type":"request","command":"initialize","arguments":{}}
{"seq":2,"type":"request","command":"launch","arguments":{}}
{"seq":3,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":4,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":5,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":6,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":7,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":8,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":9,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":10,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":11,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":12,"type":"request","command":"disconnect","arguments":{}}""")
    defer: removeFile(cmds)

    let cmd = "timeout 2 ./etch --debug-server examples/for_string_test.etch < " & cmds & " 2>/dev/null"
    let (output, _) = execCmdEx(cmd)

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
    check line1 == 3  # Should start at first line with code (var nums)

    # After first step (seq 5)
    let line2 = getLineFromTrace(output, 5)
    echo fmt"After step 1: line {line2}"
    check line2 == 5  # Should be at print("Testing...")

    # After second step (seq 7)
    let line3 = getLineFromTrace(output, 7)
    echo fmt"After step 2: line {line3}"
    check line3 == 7  # Should be at for statement

    # After third step (seq 9) - THE CRITICAL TEST
    let line4 = getLineFromTrace(output, 9)
    echo fmt"After step 3: line {line4}"
    check line4 == 8  # Should be at print(x) in loop body

    # After fourth step (seq 11)
    let line5 = getLineFromTrace(output, 11)
    echo fmt"After step 4: line {line5}"
    check line5 in [8, 11]  # Either next iteration or done
