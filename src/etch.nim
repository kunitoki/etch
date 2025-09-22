# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/os
import ./etch/[compiler, tester]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run] [--verbose] [--emit:c out.c] [--debug] file.etch"
  echo "  etch --test [directory]"
  echo "Options:"
  echo "  --run         Execute the program (with bytecode caching)"
  echo "  --verbose     Enable verbose debug output"
  echo "  --debug       Include debug information in bytecode"
  echo "  --test        Run tests in directory (default: tests/)"
  echo "                Tests need .result (expected output) or .error (expected failure)"
  quit 1


when isMainModule:
  if paramCount() < 1: usage()

  # Check for test mode first
  if paramCount() >= 1 and paramStr(1) == "--test":
    let testDir = if paramCount() >= 2: paramStr(2) else: "tests"
    quit runTests(testDir)

  var runVm = false
  var verbose = false
  var files: seq[string] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--run": runVm = true
    elif a == "--verbose": verbose = true
    else:
      files.add a
    inc i
  if files.len != 1: usage()

  let sourceFile = files[0]

  # Set up compiler options
  let options = CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVm,
    verbose: verbose
  )

  # Use the compiler module to handle compilation and execution
  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
