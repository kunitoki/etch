# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils, osproc, strformat]
import ./etch/[compiler, tester, debug_server]
import ./etch/interpreter/[bytecode, regvm_dump]
#import ./etch/backend/c/codegen


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run] [--verbose] [--emit c] [--clang] [--debug] file.etch"
  echo "  etch --test [directory]"
  echo "  etch --test-c [directory]"
  echo "Options:"
  echo "  --run         Execute the program (with bytecode caching)"
  echo "  --verbose     Enable verbose debug output"
  echo "  --release     Optimize and skip debug information in bytecode"
  echo "  --emit c      Emit C code instead of running"
  echo "  --clang       Compile and run the emitted C code (use with --emit c)"
  echo "  --debug-server Start debug server for VSCode integration"
  echo "  --dump-bytecode  Dump bytecode instructions with debug info"
  echo "  --test        Run tests in directory (default: tests/)"
  echo "  --test-c      Run tests using C backend in directory"
  echo "                Tests need .pass (expected output) or .fail (expected failure)"
  quit 1


when isMainModule:
  if paramCount() < 1: usage()

  # Parse flags first (before mode commands)
  var verbose = false
  var debug = true
  var mode = ""
  var modeArg = ""
  var runVm = false
  var emitC = false
  var useClang = false
  var files: seq[string] = @[]

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    # Parse flags first
    if a == "--verbose":
      verbose = true
    elif a == "--release":
      debug = false
    elif a == "--run":
      runVm = true
    elif a == "--clang":
      useClang = true
    # Then parse mode commands
    elif a == "--test":
      mode = "test"
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--test-c":
      mode = "test-c"
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--debug-server":
      mode = "debug-server"
      if i + 1 <= paramCount():
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--dump-bytecode":
      mode = "dump-bytecode"
      if i + 1 <= paramCount():
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--emit" and i + 1 <= paramCount() and paramStr(i + 1) == "c":
      emitC = true
      inc i  # Skip the "c" argument
    elif not a.startsWith("--"):
      files.add a
    inc i

  # Handle test mode
  if mode == "test":
    let testDir = if modeArg != "": modeArg else: "tests"
    quit runTests(testDir, verbose, not debug)

  if mode == "test-c":
    let testDir = if modeArg != "": modeArg else: "tests"
    quit runCTests(testDir)

  # Handle debug server mode
  if mode == "debug-server":
    if modeArg == "":
      echo "Error: --debug-server requires a file argument"
      quit 1
    let sourceFile = modeArg

    # Check if source file exists and is valid
    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    # Compile with debug info enabled
    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: true
    )

    try:
      # Parse, typecheck and compile to bytecode
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: true)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      # Debug server not yet updated for register VM
      echo "Debug server not yet available for register VM"
      discard bytecodeProgram
      # runDebugServer(bytecodeProgram, sourceFile)
    except Exception as e:
      # Send compilation error as JSON response for debug adapter
      sendCompilationError(e.msg)
      quit 1

    quit 0

  # Handle bytecode dump mode
  if mode == "dump-bytecode":
    if modeArg == "":
      echo "Error: --dump-bytecode requires a file argument"
      quit 1
    let sourceFile = modeArg

    # Check if source file exists and is valid
    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    # Compile with debug info enabled
    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug
    )

    try:
      # Parse, typecheck and compile to bytecode
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      # Use enhanced dump functionality
      dumpBytecodeProgram(bytecodeProgram, sourceFile)

    except Exception as e:
      echo "Error: ", e.msg
      quit 1

    quit 0

  # Regular file execution - ensure we have exactly one file
  if files.len != 1: usage()

  let sourceFile = files[0]

  # Handle C code generation
  if emitC:
    # Compile to bytecode first
    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug
    )

    try:
      # Parse, typecheck and compile to bytecode
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      # C code generation not yet updated for register VM
      echo "C code generation not yet available for register VM"
      discard bytecodeProgram
      quit 1
      # let cCode = generateC(bytecodeProgram, verbose)

      # Output C file name (replace .etch with .c)
      # let (dir, name, _) = splitFile(sourceFile)
      # let outputFile = joinPath(dir, name & ".c")

      # writeFile(outputFile, cCode)
      # if verbose:
      #   echo &"[C BACKEND] Generated C code written to {outputFile}"

      # Compile and run with clang if --clang flag is provided
      # if useClang:
      #   let exeFile = joinPath(dir, name & "_c")
      #   # Get macOS SDK path for proper compilation
      #   let sdkPathResult = execCmdEx("xcrun --show-sdk-path")
      #   let sdkPath = if sdkPathResult[1] == 0: sdkPathResult[0].strip() else: ""
      #
      #   # Build compile command with proper SDK path on macOS
      #   let compileCmd = if sdkPath.len > 0:
      #     &"clang -isysroot {sdkPath} -O2 -o {exeFile} {outputFile}"
      #   else:
      #     &"clang -O2 -o {exeFile} {outputFile}"
      #
      #   if verbose:
      #     echo &"[C BACKEND] Compiling with: {compileCmd}"
      #
      #   let compileResult = execCmd(compileCmd)
      #   if compileResult == 0:
      #     if verbose:
      #       echo &"[C BACKEND] Compiled to executable: {exeFile}"
      #     # Run the compiled program
      #     let runResult = execCmd(&"{exeFile}")
      #     quit runResult
      #   else:
      #     echo "Error: C compilation failed"
      #     quit 1

      # quit 0

    except Exception as e:
      echo "Error: ", e.msg
      quit 1

  # Normal execution path
  let options = CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVm,
    verbose: verbose,
    debug: debug,
    release: not debug
  )

  # Use the compiler module to handle compilation and execution
  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
