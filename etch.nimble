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
  echo "===== Running core tests ====="
  exec "nim c -r tests/test_debug_basic.nim"
  exec "nim c -r tests/test_debugger_crash.nim"
  echo "\n===== Running example tests ====="
  exec "nim r src/etch.nim --test examples/"
