# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils, osproc, tables]
import ./etch/[compiler, tester]
import ./etch/common/[types]
import ./etch/interpreter/[regvm_dump, regvm_debugserver]
import ./etch/backend/c/[generator]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run [BACKEND]] [--verbose] [--release] [--gen BACKEND] file.etch"
  echo "  etch --test [directory]"
  echo "  etch --test-c [directory]"
  echo "Options:"
  echo "  --run [BACKEND]  Execute the program (default: bytecode VM, optional: c)"
  echo "  --verbose        Enable verbose debug output"
  echo "  --release        Optimize and skip debug information in bytecode"
  echo "  --gen BACKEND    Generate code for specified backend (c)"
  echo "  --debug-server   Start debug server for VSCode integration"
  echo "  --dump-bytecode  Dump bytecode instructions with debug info"
  echo "  --test           Run tests in directory (default: tests/) with bytecode VM"
  echo "  --test-c         Run tests in directory (default: tests/) with C backend"
  echo "                   Tests need .pass (expected output) or .fail (expected failure)"
  quit 1


when isMainModule:
  if paramCount() < 1: usage()

  var verbose = false
  var debug = true
  var mode = ""
  var modeArg = ""
  var runVm = false
  var runBackend = ""
  var backend = ""
  var files: seq[string] = @[]

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)

    if a == "--verbose":
      verbose = true
    elif a == "--release":
      debug = false
    elif a == "--run":
      runVm = true
      # Check if there's an optional backend argument (not a file path)
      if i + 1 <= paramCount():
        let nextArg = paramStr(i + 1)
        if not nextArg.startsWith("--") and not nextArg.endsWith(".etch") and not ('/' in nextArg or '\\' in nextArg):
          runBackend = nextArg
          inc i
    elif a == "--gen":
      if i + 1 <= paramCount():
        backend = paramStr(i + 1)
        inc i
      else:
        echo "Error: --gen requires a backend argument (e.g., 'c')"
        quit 1

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
    elif not a.startsWith("--"):
      files.add a
    inc i

  if mode == "test":
    let testDir = if modeArg != "": modeArg else: "tests"
    quit runTests(testDir, verbose, not debug)

  if mode == "test-c":
    let testDir = if modeArg != "": modeArg else: "tests"
    quit runTests(testDir, verbose, not debug, "c")

  if mode == "debug-server":
    if modeArg == "":
      echo "Error: --debug-server requires a file argument"
      quit 1

    let sourceFile = modeArg

    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: true
    )

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: true)
      let regBytecode = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)
      runRegDebugServer(regBytecode, sourceFile)
    except Exception as e:
      sendCompilationError(e.msg)
      quit 1

    quit 0

  if mode == "dump-bytecode":
    if modeArg == "":
      echo "Error: --dump-bytecode requires a file argument"
      quit 1
    let sourceFile = modeArg

    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug
    )

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)
      dumpBytecodeProgram(bytecodeProgram, sourceFile)
    except OverflowDefect as e:
      echo "Error: Internal compiler error: ", e.msg
      quit 1
    except Exception as e:
      echo "Error: ", e.msg
      quit 1

    quit 0

  if files.len != 1: usage()

  let sourceFile = files[0]

  # Handle code generation mode
  if backend != "":
    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug,
      release: not debug
    )

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      case backend
      of "c":
        let cCode = generateCCode(bytecodeProgram)
        let (dir, name, _) = splitFile(sourceFile)
        let outputFile = joinPath(dir, name & ".c")
        writeFile(outputFile, cCode)
        echo "Generated C code: ", outputFile
      else:
        echo "Error: Unknown backend '", backend, "'. Available backends: c"
        quit 1
    except OverflowDefect as e:
      echo "Internal compiler error: ", e.msg
      quit 1
    except Exception as e:
      echo e.msg
      quit 1

    quit 0

  # Handle run with C backend
  if runVm and runBackend == "c":
    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug,
      release: not debug
    )

    try:
      # Compile to bytecode first
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      # Generate C code
      let cCode = generateCCode(bytecodeProgram)
      let (dir, name, _) = splitFile(sourceFile)
      let etchDir = joinPath(dir, "__etch__")
      createDir(etchDir)
      let cFile = joinPath(etchDir, name & ".c")
      let exeFile = joinPath(etchDir, name & "_c")

      writeFile(cFile, cCode)

      if verbose:
        echo "Generated C code: ", cFile

      # Collect CFFI libraries for linking
      var linkerFlags = " -lm"
      var libPaths = ""
      for funcName, cffiInfo in bytecodeProgram.cffiInfo:
        let libName = cffiInfo.library
        # Skip standard math library (already handled with -lm)
        if libName != "cmath" and libName != "math":
          # Add library path relative to source file directory
          let libDir = joinPath(dir, "clib")
          if not libPaths.contains(libDir):
            libPaths &= " -L" & libDir
          # Add library link flag (remove 'lib' prefix if present)
          let linkName = if libName.startsWith("lib"): libName[3..^1] else: libName
          if not linkerFlags.contains("-l" & linkName):
            linkerFlags &= " -l" & linkName

      # Compile C code (use xcrun on macOS to find proper SDK)
      let optFlags = if not debug: " -O3" else: ""
      when defined(macosx) or defined(macos):
        let compileCmd = "xcrun clang" & optFlags & " -o " & exeFile & " " & cFile & libPaths & linkerFlags & " 2>&1"
      else:
        let compileCmd = "clang" & optFlags & " -o " & exeFile & " " & cFile & libPaths & linkerFlags & " 2>&1"

      if verbose:
        echo "Compiling: ", compileCmd

      let (compileOutput, compileExitCode) = execCmdEx(compileCmd)
      if compileExitCode != 0:
        echo "C compilation failed:"
        echo compileOutput
        quit 1

      # Run the compiled executable
      if verbose:
        echo "Running: ", exeFile

      let (runOutput, runExitCode) = execCmdEx(exeFile)
      echo runOutput
      quit runExitCode

    except OverflowDefect as e:
      echo "Internal compiler error: ", e.msg
      quit 1
    except Exception as e:
      echo e.msg
      quit 1

  # Normal VM execution or compilation without running
  let options = CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVm,
    verbose: verbose,
    debug: debug,
    release: not debug
  )

  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
