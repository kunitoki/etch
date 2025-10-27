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
  echo "===== Building etch binary in release mode ====="
  mkDir "bin"
  exec "nim c -d:release -o:bin/etch src/etch.nim"
  echo "===== Running core tests ====="
  mkDir "tests/bin"
  exec "nim c -r -o:tests/bin/test_debugger_basic tests/test_debugger_basic.nim"
  exec "nim c -r -o:tests/bin/test_debugger_simple tests/test_debugger_simple.nim"
  exec "nim c -r -o:tests/bin/test_debugger_integration tests/test_debugger_integration.nim"
  exec "nim c -r -o:tests/bin/test_debugger_crash tests/test_debugger_crash.nim"
  exec "nim c -r -o:tests/bin/test_debugger_for tests/test_debugger_for.nim"
  exec "nim c -r -o:tests/bin/test_debugger_while tests/test_debugger_while.nim"
  exec "nim c -r -o:tests/bin/test_dump_bytecode tests/test_dump_bytecode.nim"
  exec "nim c -r -o:tests/bin/test_step_in_test tests/test_step_in_test.nim"
  exec "nim c -r -o:tests/bin/test_stepinto_issue tests/test_stepinto_issue.nim"
  exec "nim c -r -o:tests/bin/test_stepout_issue tests/test_stepout_issue.nim"
  exec "nim c -r -o:tests/bin/test_stepover_from_test tests/test_stepover_from_test.nim"
  exec "nim c -r -o:tests/bin/test_variables_display tests/test_variables_display.nim"
  exec "nim c -r -o:tests/bin/test_replay tests/test_replay.nim"
  exec "nim c -r -o:tests/bin/test_for_loop_debug tests/test_for_loop_debug.nim"
  exec "nim c -r -o:tests/bin/test_normal_var_debug tests/test_normal_var_debug.nim"
  exec "nim c -r -o:tests/bin/test_setvariable tests/test_setvariable.nim"
  exec "nim c -r -o:tests/bin/test_setvar_array tests/test_setvar_array.nim"

task perf, "Run performance benchmarks":
  echo "===== Building etch binary in release mode ====="
  mkDir "bin"
  exec "nim c -d:release -o:bin/etch src/etch.nim"
  echo "===== Running performance benchmarks ====="
  exec "./bin/etch --perf"
