# test_replay.nim
# Comprehensive tests for the register VM replay functionality

import std/[unittest, os, strutils, osproc]
import test_utils

suite "Register VM Replay - Basic Recording and Playback":
  # Ensure etch binary is built before running tests
  discard ensureEtchBinary()
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  setup:
    # Clean up any leftover replay files
    for file in walkFiles(tempDir / "*.replay"):
      removeFile(file)

  test "Record and replay simple program":
    let testProg = tempDir / "simple.etch"
    let replayFile = tempDir / "simple"

    writeFile(testProg, """
fn main() -> int {
    var x: int = 10;
    var y: int = 20;
    var result: int = x + y;
    print(result);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("30")
    check fileExists(replayFile & ".replay")

    # Replay execution - step through all statements
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Loading replay from:")
    check replayOutput.contains("Loaded")
    check replayOutput.contains("statements")
    check replayOutput.contains("Replay Complete")

  test "Replay with specific statement stepping":
    let testProg = tempDir / "stepping.etch"
    let replayFile = tempDir / "stepping"

    writeFile(testProg, """
fn main() -> int {
    var a: int = 1;
    var b: int = 2;
    var c: int = 3;
    var d: int = 4;
    var sum: int = a + b + c + d;
    print(sum);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (_, recordExitCode) = execCmdEx(recordCmd)
    check recordExitCode == 0

    # Replay with specific statement numbers
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step 0,2,4"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("statement 0")
    check replayOutput.contains("statement 2")
    check replayOutput.contains("statement 4")

  test "Replay shows variable state at each step":
    let testProg = tempDir / "variables.etch"
    let replayFile = tempDir / "variables"

    writeFile(testProg, """
fn main() -> int {
    var counter: int = 0;
    counter = counter + 1;
    counter = counter + 1;
    print(counter);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    check execCmdEx(recordCmd)[1] == 0

    # Replay and check variable states
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Local Variables:")
    check replayOutput.contains("counter")

  test "Error handling - nonexistent replay file":
    let replayCmd = etchExe & " --replay nonexistent.replay --step S"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode != 0
    check replayOutput.contains("does not exist") or replayOutput.contains("Error")

  test "Error handling - missing step argument":
    let testProg = tempDir / "missing_step.etch"
    let replayFile = tempDir / "missing_step"

    writeFile(testProg, "fn main() -> void { print(42); }")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record first
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    check execCmdEx(recordCmd)[1] == 0

    # Try to replay without --step
    let replayCmd = etchExe & " --replay " & replayFile & ".replay"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode != 0
    check replayOutput.contains("requires --step") or replayOutput.contains("Error")

suite "Register VM Replay - Loop Recording":
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  test "Record and replay program with while loop":
    let testProg = tempDir / "while_loop.etch"
    let replayFile = tempDir / "while_loop"

    writeFile(testProg, """
fn main() -> int {
    var counter: int = 0;
    while counter < 5 {
        print(counter);
        counter = counter + 1;
    }
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check fileExists(replayFile & ".replay")

    # Replay and verify loop iterations are captured
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("statements")
    # Should have multiple statements due to loop iterations

  test "Record and replay program with for loop":
    let testProg = tempDir / "for_loop.etch"
    let replayFile = tempDir / "for_loop"

    writeFile(testProg, """
fn main() -> int {
    var sum: int = 0;
    for i in 0..3 {
        sum = sum + i;
    }
    print(sum);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("6")  # sum = 0+1+2+3 = 6 (0..3 is inclusive)
    check fileExists(replayFile & ".replay")

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Replay Complete")

  test "Replay loop with specific iteration steps":
    let testProg = tempDir / "loop_steps.etch"
    let replayFile = tempDir / "loop_steps"

    writeFile(testProg, """
fn main() -> int {
    var i: int = 0;
    while i < 10 {
        i = i + 1;
    }
    print(i);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    check execCmdEx(recordCmd)[1] == 0

    # Replay specific iterations (step through every other statement)
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,1,3,5,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Seeking to statement")

suite "Register VM Replay - Function Call Recording":
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  test "Record and replay program with function calls":
    let testProg = tempDir / "functions.etch"
    let replayFile = tempDir / "functions"

    writeFile(testProg, """
fn add(a: int, b: int) -> int {
    return a + b;
}

fn main() -> int {
    var x: int = 5;
    var y: int = 10;
    var result: int = add(x, y);
    print(result);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("15")
    check fileExists(replayFile & ".replay")

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Function:")  # Should show function context

  test "Record and replay recursive function":
    let testProg = tempDir / "recursive.etch"
    let replayFile = tempDir / "recursive"

    writeFile(testProg, """
fn factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}

fn main() -> int {
    var result: int = factorial(5);
    print(result);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("120")  # 5! = 120
    check fileExists(replayFile & ".replay")

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("statements")

  test "Replay shows correct function names in call stack":
    let testProg = tempDir / "callstack.etch"
    let replayFile = tempDir / "callstack"

    writeFile(testProg, """
fn helper(x: int) -> int {
    return x * 2;
}

fn process(n: int) -> int {
    return helper(n) + 1;
}

fn main() -> int {
    var result: int = process(21);
    print(result);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("43")  # (21 * 2) + 1 = 43

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Function:")

suite "Register VM Replay - Seek Operations":
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  test "Seek to start (S)":
    let testProg = tempDir / "seek_start.etch"
    let replayFile = tempDir / "seek_start"

    writeFile(testProg, """
fn main() -> int {
    var a: int = 1;
    var b: int = 2;
    var c: int = 3;
    print(a + b + c);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record and replay
    check execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)[1] == 0

    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("statement 0")

  test "Seek to end (E)":
    let testProg = tempDir / "seek_end.etch"
    let replayFile = tempDir / "seek_end"

    writeFile(testProg, """
fn main() -> int {
    var x: int = 1;
    var y: int = 2;
    var z: int = 3;
    print(x + y + z);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record and replay
    check execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)[1] == 0

    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Seeking to statement")

  test "Seek forward and backward (S,10,E,S)":
    let testProg = tempDir / "seek_mixed.etch"
    let replayFile = tempDir / "seek_mixed"

    writeFile(testProg, """
fn main() -> int {
    var counter: int = 0;
    while counter < 20 {
        counter = counter + 1;
    }
    print(counter);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record and replay
    check execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)[1] == 0

    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,10,E,10,S"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("Seeking to statement")

  test "Warning for out-of-range statement numbers":
    let testProg = tempDir / "out_of_range.etch"
    let replayFile = tempDir / "out_of_range"

    writeFile(testProg, """
fn main() -> void {
    var x: int = 1;
    print(x);
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record and replay with out-of-range step (mixed with valid one)
    check execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)[1] == 0

    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step 0,999,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0  # Should still complete with valid steps
    check replayOutput.contains("Warning") or replayOutput.contains("out of range")

suite "Register VM Replay - Complex Programs":
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  test "Record program with arrays":
    let testProg = tempDir / "arrays.etch"
    let replayFile = tempDir / "arrays"

    writeFile(testProg, """
fn main() -> int {
    let arr: array[int] = [1, 2, 3, 4, 5];
    var sum: int = 0;
    for i in 0..4 {
        sum = sum + arr[i];
    }
    print(sum);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("15")  # 1+2+3+4+5 = 15
    check fileExists(replayFile & ".replay")

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0

  test "Record program with conditionals":
    let testProg = tempDir / "conditionals.etch"
    let replayFile = tempDir / "conditionals"

    writeFile(testProg, """
fn main() -> int {
    var x: int = 10;
    var result: int = 0;

    if x > 5 {
        result = 1;
    } else {
        result = 0;
    }

    print(result);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record and verify
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("1")
    check fileExists(replayFile & ".replay")

    # Replay and verify state
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0
    check replayOutput.contains("result")

  test "Record program with string operations":
    let testProg = tempDir / "strings.etch"
    let replayFile = tempDir / "strings"

    writeFile(testProg, """
fn main() -> void {
    var greeting: string = "Hello";
    var name: string = "World";
    var message: string = greeting + " " + name;
    print(message);
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let recordCmd = etchExe & " --run --record " & replayFile & " " & testProg
    let (recordOutput, recordExitCode) = execCmdEx(recordCmd)

    check recordExitCode == 0
    check recordOutput.contains("Hello World")

    # Replay execution
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"
    let (replayOutput, replayExitCode) = execCmdEx(replayCmd)

    check replayExitCode == 0

suite "Register VM Replay - File Integrity":
  let etchExe = findEtchExecutable()
  let tempDir = getTestTempDir()

  test "Replay file contains metadata":
    let testProg = tempDir / "metadata.etch"
    let replayFile = tempDir / "metadata"

    writeFile(testProg, "fn main() -> void { var x: int = 42; print(x); }")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record execution
    let (recordOut, recordExit) = execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)
    if recordExit != 0:
      echo "Record failed: ", recordOut
    check recordExit == 0

    # Verify file exists and is not empty
    check fileExists(replayFile & ".replay")
    if fileExists(replayFile & ".replay"):
      let fileInfo = getFileInfo(replayFile & ".replay")
      check fileInfo.size > 0

      # Replay should show source file
      let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S"
      let (replayOutput, _) = execCmdEx(replayCmd)
      check replayOutput.contains("Source file:")

  test "Multiple replay runs from same file":
    let testProg = tempDir / "multiple_replay.etch"
    let replayFile = tempDir / "multiple_replay"

    writeFile(testProg, """
fn main() -> int {
    var count: int = 0;
    while count < 3 {
        count = count + 1;
    }
    print(count);
    return 0;
}
""")
    defer: removeFile(testProg)
    defer: removeFile(replayFile & ".replay")

    # Record once
    check execCmdEx(etchExe & " --run --record " & replayFile & " " & testProg)[1] == 0

    # Replay multiple times - should work consistently
    let replayCmd = etchExe & " --replay " & replayFile & ".replay --step S,E"

    let (output1, exit1) = execCmdEx(replayCmd)
    check exit1 == 0

    let (output2, exit2) = execCmdEx(replayCmd)
    check exit2 == 0

    # Both replays should have same structure
    check output1.contains("Replay Complete")
    check output2.contains("Replay Complete")
