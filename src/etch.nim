# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils, osproc, tables, times]
import ./etch/[compiler, tester]
import ./etch/common/[constants, types, cffi, logging]
import ./etch/interpreter/[regvm, regvm_dump, regvm_debugserver]
import ./etch/backend/c/[generator]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run [BACKEND]] [--verbose] [--release] [--gen BACKEND] file.etch"
  echo "  etch --test [directory]"
  echo "  etch --test-c [directory]"
  echo "  etch --perf [directory]"
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
  echo "  --perf           Run performance benchmarks (default: performance/) and generate report"
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
    debug: debug
  )


proc populateCFFIInfo(regProg: var RegBytecodeProgram, verbose: bool) =
  ## Populate CFFI info from the global registry into the bytecode program
  for funcName, cffiFunc in globalCFFIRegistry.functions:
    var paramTypes: seq[string] = @[]
    for param in cffiFunc.signature.params:
      paramTypes.add($param.typ.kind)

    # Get the actual library path from the registry
    let libraryPath = if cffiFunc.library in globalCFFIRegistry.libraries:
      let path = globalCFFIRegistry.libraries[cffiFunc.library].path
      logCompiler(verbose, "CFFI function " & funcName & " uses library " & cffiFunc.library & " at path: " & path)
      path
    else:
      logCompiler(verbose, "CFFI function " & funcName & " library " & cffiFunc.library & " NOT in registry!")
      ""

    regProg.cffiInfo[funcName] = regvm.CFFIInfo(
      library: cffiFunc.library,
      libraryPath: libraryPath,
      symbol: cffiFunc.symbol,
      baseName: cffiFunc.symbol,
      paramTypes: paramTypes,
      returnType: $cffiFunc.signature.returnType.kind
    )


proc compileToRegBytecode(options: CompilerOptions): RegBytecodeProgram =
  try:
    let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
    result = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, options.sourceFile, options)
    # Populate CFFI info from the global registry
    populateCFFIInfo(result, options.verbose)
  except OverflowDefect as e:
    echo "Internal compiler error: ", e.msg
    quit 1
  except Exception as e:
    echo e.msg
    quit 1


proc generateCCodeToFile(bytecode: RegBytecodeProgram, sourceFile: string): string =
  let cCode = generateCCode(bytecode)
  let (dir, name, _) = splitFile(sourceFile)
  let outputFile = joinPath(dir, name & ".c")
  writeFile(outputFile, cCode)
  return outputFile


proc compileAndRunCBackend(bytecode: RegBytecodeProgram, sourceFile: string, verbose: bool, debug: bool): int =
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
  createDir(etchDir)
  let cFile = joinPath(etchDir, name & ".c")
  let exeFile = joinPath(etchDir, name & "_c")

  let cCode = generateCCode(bytecode)
  writeFile(cFile, cCode)

  if verbose:
    echo "Generated C code: ", cFile

  var linkerFlags = " -lm"
  var libDirs: seq[string] = @[]  # Collect unique library directories

  # Extract library directories from actual library paths
  for funcName, cffiInfo in bytecode.cffiInfo:
    let libName = cffiInfo.library

    if verbose:
      echo "CFFI Function: ", funcName
      echo "  Library: ", libName
      echo "  Library Path: ", cffiInfo.libraryPath

    # Skip standard system libraries (they don't need -L or -rpath)
    if libName in ["c", "cmath", "math", "m", "pthread", "dl"]:
      continue

    # If we have a library path, extract its directory
    if cffiInfo.libraryPath != "":
      let libDir = parentDir(cffiInfo.libraryPath)
      if verbose:
        echo "  Library Dir: ", libDir
      if libDir != "" and libDir notin libDirs:
        libDirs.add(libDir)

    # Add linker flag for the library
    let linkName = if libName.startsWith("lib"): libName[3..^1] else: libName
    if not linkerFlags.contains("-l" & linkName):
      linkerFlags &= " -l" & linkName

  # Build -L flags for all unique library directories
  var libPaths = ""
  for libDir in libDirs:
    libPaths &= " -L" & libDir

  if verbose and libDirs.len > 0:
    echo "Library directories found:"
    for libDir in libDirs:
      echo "  ", libDir

  let optFlags = if not debug: " -O3" else: ""

  # Add rpath for dynamic library loading at runtime (macOS and Linux)
  # This tells the dynamic linker where to find shared libraries relative to the executable
  var rpathFlags = ""
  if libDirs.len > 0:
    # Build rpath entries for each unique library directory
    when defined(macosx) or defined(macos):
      # Use @executable_path to make path relative to executable location
      for libDir in libDirs:
        # Calculate relative path from executable to library directory
        let relPath = relativePath(libDir, etchDir)
        rpathFlags &= " -Wl,-rpath,@executable_path/" & relPath
    else:
      # Use $ORIGIN for Linux/Unix to make path relative to executable location
      # IMPORTANT: -z origin flag is required to enable $ORIGIN processing on Linux
      rpathFlags &= " -Wl,-z,origin"
      for libDir in libDirs:
        # Calculate relative path from executable to library directory
        let relPath = relativePath(libDir, etchDir)
        # Use $$ORIGIN (double $ escapes in Nim, becomes $ORIGIN in shell)
        # Single quotes protect the variable from shell expansion
        rpathFlags &= " '-Wl,-rpath,$$ORIGIN/" & relPath & "'"

  when defined(macosx) or defined(macos):
    let compileCmd = "xcrun clang" & optFlags & " -o " & exeFile & " " & cFile & libPaths & linkerFlags & rpathFlags & " 2>&1"
  else:
    let compileCmd = "clang" & optFlags & " -o " & exeFile & " " & cFile & libPaths & linkerFlags & rpathFlags & " 2>&1"

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


proc runPerformanceBenchmarks(perfDir: string = "performance"): int =
  echo "===== Running performance benchmarks ====="
  echo "Directory: ", perfDir
  echo "Generating markdown report: performance_report.md"
  echo ""

  if not dirExists(perfDir):
    echo "Error: ", perfDir, " directory not found"
    return 1

  # Discover all .etch files that have corresponding .py files
  var benchmarks: seq[string] = @[]
  for file in walkFiles(perfDir / "*.etch"):
    let (_, name, _) = splitFile(file)
    let pyFile = perfDir / name & ".py"
    if fileExists(pyFile):
      benchmarks.add(name)

  if benchmarks.len == 0:
    echo "No performance tests found!"
    return 1

  echo "Found ", benchmarks.len, " benchmarks:"
  for benchmark in benchmarks:
    echo "  - ", benchmark
  echo ""

  # Create report header
  var report = "# Etch Performance Benchmarks\n\n"
  report.add("**Generated**: " & $now() & "\n\n")
  report.add("**Directory**: `" & perfDir & "`\n\n")
  report.add("**Baseline**: C Backend (first result when available, otherwise VM)\n\n")
  report.add("## Detailed Results\n\n")

  var successCount = 0
  var failCount = 0

  for benchmark in benchmarks:
    echo "----- Benchmarking: ", benchmark, " -----"

    let etchFile = perfDir / benchmark & ".etch"
    let pyFile = perfDir / benchmark & ".py"
    let etchDir = perfDir / BYTECODE_CACHE_DIR
    let cExecutable = etchDir / benchmark & "_c"
    let mdOutput = etchDir / benchmark & "_bench.md"

    createDir(etchDir)

    # Try to compile C backend (silently)
    let etchExe = getAppFilename()
    let (_, exitCode) = execCmdEx(etchExe & " --run c --release " & etchFile & " > /dev/null 2>&1")

    # Check if C executable exists
    let hasCBackend = fileExists(cExecutable) and exitCode == 0

    # Run hyperfine based on whether C backend is available
    var hyperCmd: string
    if hasCBackend:
      echo "  Running: C backend + VM + Python"
      hyperCmd = "hyperfine --warmup 3 --export-markdown '" & mdOutput & "' " &
                 "'" & cExecutable & "' " &
                 "'" & etchExe & " --run --release " & etchFile & "' " &
                 "'python3 " & pyFile & "' 2>/dev/null"
    else:
      echo "  Running: VM + Python (C backend not available)"
      hyperCmd = "hyperfine --warmup 3 --export-markdown '" & mdOutput & "' " &
                 "'" & etchExe & " --run --release " & etchFile & "' " &
                 "'python3 " & pyFile & "' 2>/dev/null"

    let (_, _) = execCmdEx(hyperCmd)

    # Append results to report if available
    if fileExists(mdOutput):
      let mdContent = readFile(mdOutput)
      report.add("### " & benchmark & "\n\n" & mdContent & "\n\n")
      successCount.inc()
      echo "  ✓ Results added to report"
    else:
      failCount.inc()
      echo "  ✗ Benchmark failed"

  # Write report
  writeFile("performance_report.md", report)

  echo ""
  echo "===== Benchmark complete ====="
  echo "Success: ", successCount, "/", benchmarks.len
  if failCount > 0:
    echo "Failed:  ", failCount
  echo "Report saved to: performance_report.md"

  return if failCount > 0: 1 else: 0


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
    elif a == "--perf":
      mode = "perf"
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

  if mode == "perf":
    let perfDir = if modeArg != "": modeArg else: "performance"
    quit runPerformanceBenchmarks(perfDir)

  if mode == "debug-server":
    if modeArg == "":
      echo "Error: --debug-server requires a file argument"
      quit 1

    validateFile(modeArg)
    let options = makeCompilerOptions(modeArg, runVM = false, verbose, debug = true)

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let regBytecode = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, modeArg, options)
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
    let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
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
