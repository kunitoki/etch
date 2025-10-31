# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils, osproc, tables, times, strformat, sequtils]
import ./etch/[compiler, tester]
import ./etch/common/[constants, types, cffi, logging]
import ./etch/interpreter/[regvm, regvm_dump, regvm_debugserver, regvm_exec, regvm_replay]
import ./etch/backend/c/[generator]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run [BACKEND]] [--record FILE] [--verbose] [--release] [--profile] [--force] [--gen BACKEND] file.etch"
  echo "  etch --replay FILE [--step N[,N..]]"
  echo "  etch --test [DIR|FILE]"
  echo "  etch --test-c [DIR|FILE]"
  echo "  etch --perf [DIR]"
  echo "Options:"
  echo "  --run [BACKEND]      Execute the program (default: bytecode VM, optional: c)"
  echo "  --record FILE        Record execution to FILE.replay (use with --run)"
  echo "  --replay FILE        Load and replay recorded execution from FILE.replay"
  echo "  --step N[,N..]       Step through specific statements (use with --replay)"
  echo "                       Special values: S=start, E=end (e.g., --step S,10,E,10,S)"
  echo "  --verbose            Enable verbose debug output"
  echo "  --release            Optimize and skip debug information in bytecode"
  echo "  --profile            Enable VM profiling (reports instruction timing and hotspots)"
  echo "  --force              Force recompilation, bypassing bytecode cache"
  echo "  --gen BACKEND        Generate code for specified backend (c)"
  echo "  --debug-server       Start debug server for VSCode integration"
  echo "  --dump-bytecode      Dump bytecode instructions with debug info"
  echo "  --test [DIR|FILE]    Run tests in directory (default: tests/) with bytecode VM"
  echo "  --test-c [DIR|FILE]  Run tests in directory (default: tests/) with C backend"
  echo "                       Tests need .pass (expected output) or .fail (expected failure)"
  echo "  --perf [DIR]         Run performance benchmarks (default: performance/) and generate report"
  quit 1


proc validateFile(path: string) =
  if not fileExists(path):
    echo &"Error: cannot open: {path}"
    quit 1


proc makeCompilerOptions(sourceFile: string, runVM: bool, verbose: bool, debug: bool, profile: bool = false, force: bool = false): CompilerOptions =
  CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVM,
    verbose: verbose,
    debug: debug,
    profile: profile,
    force: force
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
      logCompiler(verbose, &"CFFI function {funcName} uses library {cffiFunc.library} at path: {path}")
      path
    else:
      logCompiler(verbose, &"CFFI function {funcName} library {cffiFunc.library} NOT in registry!")
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
    populateCFFIInfo(result, options.verbose)
  except OverflowDefect as e:
    echo &"Internal compiler error: {e.msg}"
    quit 1
  except Exception as e:
    echo e.msg
    quit 1


proc generateCCodeToFile(bytecode: RegBytecodeProgram, sourceFile: string): string =
  let (dir, name, _) = splitFile(sourceFile)
  let outputFile = joinPath(dir, name & ".c")
  let cCode = generateCCode(bytecode)
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

  logCLI(verbose, &"Generated C code: {cFile}")

  # Collect unique library directories from CFFI info
  var libDirs: seq[string] = @[]

  for funcName, cffiInfo in bytecode.cffiInfo:
    let libName = cffiInfo.library

    if verbose:
      echo &"CFFI Function: {funcName}"
      echo &"  Library: {libName}"
      echo &"  Library Path: {cffiInfo.libraryPath}"

    # Skip standard system libraries (they don't need -L or -rpath)
    if libName in ["c", "cmath", "math", "m", "pthread", "dl"]:
      continue

    # If we have a library path, extract its directory
    if cffiInfo.libraryPath != "":
      let libDir = parentDir(cffiInfo.libraryPath)
      if verbose:
        echo &"  Library Dir: {libDir}"
      if libDir != "" and libDir notin libDirs:
        libDirs.add(libDir)

  if verbose and libDirs.len > 0:
    echo "Library directories found:"
    for libDir in libDirs:
      echo &"  {libDir}"

  # Build compilation command as seq[string]
  var compileArgs: seq[string] = @[]

  when defined(macosx) or defined(macos):
    compileArgs.add("xcrun")
    compileArgs.add("clang")
  else:
    compileArgs.add("clang")

  if not debug:
    compileArgs.add("-O3")
    compileArgs.add("-fomit-frame-pointer")
  #else:
  #  compileArgs.add("-g")

  compileArgs.add("-o")
  compileArgs.add(exeFile)
  compileArgs.add(cFile)

  # Add library paths
  for libDir in libDirs:
    compileArgs.add(&"-L{libDir}")

  # Add linker flags (already includes -lm and library names)
  compileArgs.add("-lm")
  for funcName, cffiInfo in bytecode.cffiInfo:
    let libName = cffiInfo.library
    if libName notin ["c", "cmath", "math", "m", "pthread", "dl"]:
      let linkName = if libName.startsWith("lib"): libName[3..^1] else: libName
      compileArgs.add(&"-l{linkName}")

  # Add rpath for dynamic library loading at runtime (macOS and Linux)
  if libDirs.len > 0:
    when defined(macosx) or defined(macos):
      for libDir in libDirs:
        let relPath = relativePath(libDir, etchDir)
        compileArgs.add(&"-Wl,-rpath,@executable_path/{relPath}")
    else:
      compileArgs.add("-Wl,-z,origin")
      for libDir in libDirs:
        let relPath = relativePath(libDir, etchDir)
        compileArgs.add(&"-Wl,-rpath,$ORIGIN/{relPath}")

  # Build shell command with proper quoting
  let compileCmd = compileArgs.map(quoteShell).join(" ") & " 2>&1"
  logCLI(verbose, &"Compiling: {compileCmd}")

  let (compileOutput, compileExitCode) = execCmdEx(compileCmd)
  if compileExitCode != 0:
    echo "C compilation failed:"
    echo compileOutput
    quit 1

  logCLI(verbose, &"Running: {exeFile}")

  var (runOutput, runExitCode) = execCmdEx(exeFile)
  runOutput.stripLineEnd
  echo runOutput
  return runExitCode


proc runPerformanceBenchmarks(perfPath: string = "performance"): int =
  echo "===== Running performance benchmarks ====="

  var perfDir: string
  var benchmarks: seq[string] = @[]
  var singleFile = false
  var resultFile = "performance_report.md"

  # Check if path is a file or directory
  if fileExists(perfPath):
    # Single file mode
    singleFile = true
    let (dir, name, ext) = splitFile(perfPath)
    if ext != SOURCE_FILE_EXTENSION:
      echo &"Error: {perfPath} must be a {SOURCE_FILE_EXTENSION} file"
      return 1
    perfDir = if dir == "": "." else: dir
    benchmarks.add(name)
    echo &"Running single benchmark: {name}"
  elif dirExists(perfPath):
    # Directory mode
    perfDir = perfPath

    # Discover all .etch files that have corresponding .py files
    for file in walkFiles(perfDir / &"*{SOURCE_FILE_EXTENSION}"):
      let (_, name, _) = splitFile(file)
      let pyFile = perfDir / name & ".py"
      if fileExists(pyFile):
        benchmarks.add(name)
  else:
    echo &"Error: {perfPath} not found (not a file or directory)"
    return 1

  echo &"Directory: {perfDir}"
  echo &"Generating markdown report: {resultFile}"
  echo ""

  if benchmarks.len == 0:
    echo "No performance tests found!"
    return 1

  echo &"Found {benchmarks.len} benchmarks:"
  for benchmark in benchmarks:
    echo &"  - {benchmark}"
  echo ""

  # Create report header
  var report = "# Etch Performance Benchmarks\n\n"
  report.add(&"**Generated**: {now()}\n\n")
  report.add(&"**Directory**: {perfDir}\n\n")
  report.add("**Baseline**: C Backend (first result when available, otherwise VM)\n\n")
  report.add("## Detailed Results\n\n")

  var successCount = 0
  var failCount = 0

  for benchmark in benchmarks:
    echo &"----- Benchmarking: {benchmark} -----"

    let etchFile = perfDir / benchmark & SOURCE_FILE_EXTENSION
    let pyFile = perfDir / benchmark & ".py"
    let etchDir = perfDir / BYTECODE_CACHE_DIR
    let cExecutable = etchDir / benchmark & "_c"
    let mdOutput = etchDir / benchmark & "_bench.md"

    createDir(etchDir)

    # Try to compile C backend (silently)
    let etchExe = getAppFilename()
    let compileTestCmd = &"{quoteShell(etchExe)} --run c --release {quoteShell(etchFile)} > /dev/null 2>&1"
    let (_, exitCode) = execCmdEx(compileTestCmd)

    # Check if C executable exists
    let hasCBackend = fileExists(cExecutable) and exitCode == 0

    # Run hyperfine based on whether C backend is available
    var hyperArgs: seq[string] = @["hyperfine", "--warmup", "3", "--export-markdown", mdOutput]

    if hasCBackend:
      echo "  Running: C backend + VM + Python"
      hyperArgs.add(cExecutable)
      hyperArgs.add(&"{etchExe} --run --release {etchFile}")
      hyperArgs.add(&"python3 {pyFile}")
    else:
      echo "  Running: VM + Python (C backend not available)"
      hyperArgs.add(&"{etchExe} --run --release {etchFile}")
      hyperArgs.add(&"python3 {pyFile}")

    let hyperCmd = hyperArgs.map(quoteShell).join(" ") & " 2>/dev/null"
    let (_, _) = execCmdEx(hyperCmd)

    # Append results to report if available
    if fileExists(mdOutput):
      let mdContent = readFile(mdOutput)
      report.add(&"### {benchmark}\n\n{mdContent}\n\n")
      successCount.inc()
      echo "  ✓ Results added to report"
    else:
      failCount.inc()
      echo "  ✗ Benchmark failed"

  # Write report
  writeFile(resultFile, report)

  echo ""
  echo "===== Benchmark complete ====="
  echo &"Success: {successCount}/{benchmarks.len}"
  if failCount > 0:
    echo &"Failed:  {failCount}"
  echo &"Report saved to: {resultFile}"

  return if failCount > 0: 1 else: 0


when isMainModule:
  if paramCount() < 1: usage()

  var verbose = false
  var debug = true
  var profile = false
  var force = false
  var mode = ""
  var modeArg = ""
  var stepArg = ""
  var recordFile = ""
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
    elif a == "--profile":
      profile = true
    elif a == "--force":
      force = true
    elif a == "--run":
      runVm = true
      # Check if there's an optional backend argument (not a file path)
      if i + 1 <= paramCount():
        let nextArg = paramStr(i + 1)
        if not nextArg.startsWith("--") and not nextArg.endsWith(SOURCE_FILE_EXTENSION) and not ('/' in nextArg or '\\' in nextArg):
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
    elif a == "--record":
      if i + 1 <= paramCount():
        recordFile = paramStr(i + 1)
        inc i
      else:
        echo "Error: --record requires a file argument"
        quit 1
    elif a == "--replay":
      mode = "replay"
      if i + 1 <= paramCount():
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--step":
      if i + 1 <= paramCount():
        stepArg = paramStr(i + 1)
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

  if mode == "replay":
    if modeArg == "":
      echo "Error: --replay requires a file argument"
      quit 1

    let replayFile = if modeArg.endsWith(".replay"): modeArg else: modeArg & ".replay"

    if not fileExists(replayFile):
      echo &"Error: Replay file not found: {replayFile}"
      quit 1

    echo &"Loading replay from: {replayFile}"

    # Load replay data (includes source file path)
    let replayData = loadFromFile(replayFile)
    let sourceFile = replayData.sourceFile

    if not fileExists(sourceFile):
      echo &"Error: Source file not found: {sourceFile}"
      echo &"Note: The replay was recorded from '{sourceFile}' which is no longer available"
      quit 1

    echo &"Source file: {sourceFile}"
    echo &"Loaded {replayData.totalStatements} statements ({replayData.snapshots.len} snapshots)"
    echo ""

    # Compile source to get bytecode
    let options = makeCompilerOptions(sourceFile, runVM = false, verbose, debug)
    let bytecodeProgram = compileToRegBytecode(options)
    let vm = newRegisterVM(bytecodeProgram)

    # Restore replay engine from loaded data
    let engine = restoreReplayEngine(vm, replayData.totalStatements, replayData.snapshotInterval, replayData.snapshots)
    vm.replayEngine = cast[pointer](engine)
    GC_ref(engine)

    # Parse step argument
    if stepArg == "":
      echo "Error: --replay requires --step argument"
      echo "Example: --step S,10,20,E  (S=start, E=end)"
      quit 1

    var steps: seq[int] = @[]
    for part in stepArg.split(','):
      let trimmed = part.strip()
      if trimmed == "S" or trimmed == "s":
        steps.add(0)  # Start
      elif trimmed == "E" or trimmed == "e":
        steps.add(replayData.totalStatements - 1)  # End
      else:
        try:
          let stmt = parseInt(trimmed)
          if stmt < 0 or stmt >= replayData.totalStatements:
            echo &"Warning: Statement {stmt} out of range (0..{replayData.totalStatements - 1})"
          else:
            steps.add(stmt)
        except ValueError:
          echo &"Error: Invalid step value: {trimmed}"
          quit 1

    if steps.len == 0:
      echo "Error: No valid steps provided"
      quit 1

    echo ""
    echo &"==== Stepping through {steps.len} statements ===="
    echo ""

    # Step through each statement
    for i, stmt in steps:
      echo &"[{i + 1}/{steps.len}] Seeking to statement {stmt} / {replayData.totalStatements - 1}..."
      vm.seekToStatement(stmt)
      vm.printVMState()
      echo ""

    echo "==== Replay Complete ===="

    # Clean up replay engine before exiting
    vm.cleanupReplayEngine()

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
      echo &"Generated C code: {outputFile}"
    else:
      echo &"Error: Unknown backend '{backend}'. Available backends: c"
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
        logCLI(verbose, &"Using cached C executable: {exeFile}")

        let (runOutput, runExitCode) = execCmdEx(exeFile)
        echo runOutput
        quit runExitCode

    # Need to compile
    let options = makeCompilerOptions(sourceFile, runVM = false, verbose, debug)
    let bytecodeProgram = compileToRegBytecode(options)
    let exitCode = compileAndRunCBackend(bytecodeProgram, sourceFile, verbose, debug)
    quit exitCode

  # Handle recording if requested
  if recordFile != "" and runVm:
    validateFile(sourceFile)
    let replayFile = recordFile & ".replay"

    logCLI(verbose, &"Recording execution of: {sourceFile}")
    logCLI(verbose, &"Output will be saved to: {replayFile}\n")

    # Compile and run the program with recording enabled
    let options = makeCompilerOptions(sourceFile, runVM = false, verbose, debug, profile, force)
    let bytecodeProgram = compileToRegBytecode(options)
    let vm = newRegisterVM(bytecodeProgram)
    vm.enableReplayRecording(snapshotInterval = 1)

    let exitCode = vm.execute(verbose = verbose)
    vm.stopReplayRecording()

    # Save replay data to file
    if vm.replayEngine != nil:
      let engine = cast[ReplayEngine](vm.replayEngine)
      try:
        engine.saveToFile(replayFile, sourceFile)
        if verbose:
          let stats = engine.getStats()
          logCLI(verbose, &"\nSaved {stats.statements} statements ({stats.snapshots} snapshots) to {replayFile}")
      except Exception as e:
        echo &"Error saving replay: {e.msg}"
        vm.cleanupReplayEngine()
        quit 1

    # Clean up replay engine after saving
    vm.cleanupReplayEngine()

    quit exitCode

  # Handle --record without --run
  if recordFile != "" and not runVm:
    echo "Error: --record requires --run to execute the program"
    quit 1

  # Normal VM execution or compilation without running
  let options = makeCompilerOptions(sourceFile, runVm, verbose, debug, profile, force)
  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
