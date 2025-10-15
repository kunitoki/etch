# Package
version       = "0.1.0"
author        = "kunitoki"
description   = "Define once, Etch forever."
license       = "MIT"
srcDir        = "src"
bin           = @["etch"]

# Dependencies
requires "nim >= 2.2.4"

# Tasks
task test, "Run all tests":
  echo "===== Building etch binary ====="
  exec "nim c -d:release -o:etch src/etch.nim"
  echo "===== Running core tests ====="
  exec "nim c -r tests/test_debug_basic.nim"
  exec "nim c -r tests/test_debugger_simple.nim"
  exec "nim c -r tests/test_debugger_crash.nim"
  exec "nim c -r tests/test_debugger_for.nim"
  exec "nim c -r tests/test_debugger_while.nim"
  exec "nim c -r tests/test_dump_bytecode.nim"
  exec "nim c -r tests/test_step_in_test.nim"
  exec "nim c -r tests/test_stepinto_issue.nim"
  exec "nim c -r tests/test_stepout_issue.nim"
  exec "nim c -r tests/test_stepover_from_test.nim"
  exec "nim c -r tests/test_variables_display.nim"
