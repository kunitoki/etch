# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils, osproc, tables, times]
import ./etch/[compiler, tester]
import ./etch/common/[types]
import ./etch/interpreter/[regvm, regvm_dump, regvm_debugserver]
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


proc validateFile(path: string) =
  if not fileExists(path):
    echo "Error: cannot open: ", path
    quit 1


proc makeCompilerOptions(sourceFile: string, runVM: bool, verbose: bool, debug: bool): CompilerOptions =
  CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVM,
    verbose: verbose,
    debug: debug,
    release: not debug
  )


proc compileToRegBytecode(options: CompilerOptions): RegBytecodeProgram =
  try:
    let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
    let flags = CompilerFlags(verbose: options.verbose, debug: options.debug)
    return compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, options.sourceFile, flags)
  except OverflowDefect as e:
    echo "Error: Internal compiler error: ", e.msg
    quit 1
  except Exception as e:
    echo "Error: ", e.msg
    quit 1


proc generateCCodeToFile(bytecode: RegBytecodeProgram, sourceFile: string): string =
  let cCode = generateCCode(bytecode)
  let (dir, name, _) = splitFile(sourceFile)
  let outputFile = joinPath(dir, name & ".c")
  writeFile(outputFile, cCode)
  return outputFile


proc compileAndRunCBackend(bytecode: RegBytecodeProgram, sourceFile: string, verbose: bool, debug: bool): int =
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, "__etch__")
  createDir(etchDir)
  let cFile = joinPath(etchDir, name & ".c")
  let exeFile = joinPath(etchDir, name & "_c")

  let cCode = generateCCode(bytecode)
  writeFile(cFile, cCode)

  if verbose:
    echo "Generated C code: ", cFile

  var linkerFlags = " -lm"
  var libPaths = ""
  for funcName, cffiInfo in bytecode.cffiInfo:
    let libName = cffiInfo.library
    if libName != "cmath" and libName != "math":
      let libDir = joinPath(dir, "clib")
      if not libPaths.contains(libDir):
        libPaths &= " -L" & libDir
      let linkName = if libName.startsWith("lib"): libName[3..^1] else: libName
      if not linkerFlags.contains("-l" & linkName):
        linkerFlags &= " -l" & linkName

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

  if verbose:
    echo "Running: ", exeFile

  let (runOutput, runExitCode) = execCmdEx(exeFile)
  echo runOutput
  return runExitCode


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

    validateFile(modeArg)
    let options = makeCompilerOptions(modeArg, runVM = false, verbose, debug = true)

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: true)
      let regBytecode = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, modeArg, flags)
      runRegDebugServer(regBytecode, modeArg)
    except Exception as e:
      sendCompilationError(e.msg)
      quit 1

    quit 0

  if mode == "dump-bytecode":
    if modeArg == "":
      echo "Error: --dump-bytecode requires a file argument"
      quit 1

    validateFile(modeArg)
    let options = makeCompilerOptions(modeArg, runVM = false, verbose, debug)
    let bytecodeProgram = compileToRegBytecode(options)
    dumpBytecodeProgram(bytecodeProgram, modeArg)
    quit 0

  if files.len != 1: usage()

  let sourceFile = files[0]

  # Handle code generation mode
  if backend != "":
    validateFile(sourceFile)
    let options = makeCompilerOptions(sourceFile, runVM = false, verbose, debug)
    let bytecodeProgram = compileToRegBytecode(options)

    case backend
    of "c":
      let outputFile = generateCCodeToFile(bytecodeProgram, sourceFile)
      echo "Generated C code: ", outputFile
    else:
      echo "Error: Unknown backend '", backend, "'. Available backends: c"
      quit 1

    quit 0

  # Handle run with C backend
  if runVm and runBackend == "c":
    validateFile(sourceFile)

    # Check if we can use cached executable
    let (dir, name, _) = splitFile(sourceFile)
    let etchDir = joinPath(dir, "__etch__")
    let exeFile = joinPath(etchDir, name & "_c")

    var needsRecompile = true
    if fileExists(exeFile):
      let sourceTime = getLastModificationTime(sourceFile)
      let exeTime = getLastModificationTime(exeFile)
      if not (sourceTime > exeTime):
        needsRecompile = false
        if verbose:
          echo "Using cached C executable: ", exeFile

        let (runOutput, runExitCode) = execCmdEx(exeFile)
        echo runOutput
        quit runExitCode

    # Need to compile
    let options = makeCompilerOptions(sourceFile, runVM = false, verbose, debug)
    let bytecodeProgram = compileToRegBytecode(options)
    let exitCode = compileAndRunCBackend(bytecodeProgram, sourceFile, verbose, debug)
    quit exitCode

  # Normal VM execution or compilation without running
  let options = makeCompilerOptions(sourceFile, runVm, verbose, debug)
  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
