# tester.nim
# Etch testing framework: test discovery, execution, and result reporting

import std/[os, strformat, strutils, osproc, options, sequtils]
import ../common/[constants, logging]


when compileOption("threads"):
  import std/locks


const threadsEnabled = compileOption("threads")


type
  TestResult* = object
    name*: string
    passed*: bool
    expected*: string
    actual*: string
    error*: string

  ExecutionResult* = object
    stdout*: string
    stderr*: string
    exitCode*: int
    isCompileError*: bool

  TestJob = object
    index: int
    file: string

  TestState = object
    testFiles: seq[string]
    backend: string
    verbose: bool
    release: bool
    failedResults: seq[TestResult]
    nextPrintIndex: int
    passed: int
    failed: int
    when threadsEnabled:
      jobsLock: Lock
      jobs: seq[TestJob]
      resultsLock: Lock
      results: seq[Option[TestResult]]
      remainingJobs: int
      workersShouldStop: bool


proc normalizeOutput*(output: string): string =
  output
    .strip()
    .replace("\r\n", "\n")
    .replace("\r", "\n")
    .replace("\\", "/")  # Normalize path separators for cross-platform compatibility
    .splitLines()
    .mapIt(it.strip(trailing = true, leading = false))  # Only strip trailing whitespace, preserve leading
    .filterIt(it.len > 0)
    .join("\n")


proc executeWithSeparateStreams*(cmd: string): ExecutionResult =
  ## Execute command with separate stdout/stderr capture
  var retries = 10

  while retries > 0:
    try:
      # Use execCmdEx for now (merges stdout/stderr)
      # We rely on smartFilterOutput to separate compiler diagnostics from program output
      let (stdout, exitCode) = execCmdEx(cmd)
      if exitCode == -1 or stdout == "":
        retries -= 1
        sleep(10)
        continue

      # Determine if this is a compiler error vs runtime error
      # Check for explicit compiler error indicators
      let hasRuntimeError = stdout.contains("Runtime error:")
      let hasCompileError = exitCode != 0 and not hasRuntimeError

      return ExecutionResult(
        stdout: stdout,
        stderr: "",  # Currently merged with stdout for compatibility
        exitCode: exitCode,
        isCompileError: hasCompileError
      )
    except IOError, OSError:
      retries -= 1
      sleep(10)
      continue

  return ExecutionResult(
    stdout: "",
    stderr: "Failed to execute command after multiple retries.",
    exitCode: -1,
    isCompileError: false
  )


proc smartFilterOutput*(execResult: ExecutionResult): string =
  ## Intelligently filter output based on execution context
  if execResult.isCompileError:
    # For compiler errors, filter and return stdout (since all output goes there)
    # We still need to filter out Nim compilation messages
    var lines: seq[string] = @[]
    for line in execResult.stdout.splitLines:
      let trimmed = line.strip()
      # Skip Nim compiler output but keep Etch compiler errors
      if trimmed.startsWith("Hint:") or
         trimmed.startsWith("Error: execution of an external program failed") or
         trimmed.startsWith("Compiling:"):
        continue
      lines.add(line)
    return normalizeOutput(lines.join("\n"))

  # For successful execution or runtime errors, filter stdout
  var lines: seq[string] = @[]
  var foundProgramOutput = false
  var inDebugBlock = false

  for line in execResult.stdout.splitLines:
    let trimmed = line.strip()

    # Skip empty lines at the beginning
    if not foundProgramOutput and trimmed == "":
      continue

    # Track debug blocks (like Variable Lifetimes)
    if trimmed.startsWith("=== Variable Lifetimes ===") or
       trimmed.startsWith("=== Destructor Points ==="):
      inDebugBlock = true
      continue

    # Exit debug block when we hit a non-indented line after entering one
    if inDebugBlock and not line.startsWith(" ") and trimmed.len > 0:
      inDebugBlock = false

    # Skip content inside debug blocks
    if inDebugBlock:
      continue

    # Common patterns that indicate compiler output (not program output)
    if trimmed.startsWith("Compiling:") or
       trimmed.startsWith("Cached bytecode to:") or
       trimmed.startsWith("Using cached bytecode:") or
       trimmed.startsWith("[CLI]") or
       trimmed.startsWith("[COMPILER]") or
       trimmed.startsWith("[VM]") or
       trimmed.startsWith("[PROVER]") or
       trimmed.startsWith("[OPTIMIZER]") or
       trimmed.startsWith("[HEAP]") or
       (trimmed.startsWith("Warning:") and not foundProgramOutput) or
       (trimmed.startsWith("Failed to open") and not foundProgramOutput) or
       (trimmed.startsWith("Failed to compile") and not foundProgramOutput):
      continue

    # Once we find any output that looks like program output,
    # include everything from that point forward
    foundProgramOutput = true
    lines.add(line)

  # If no program output found but we have runtime error in stderr
  if lines.len == 0 and execResult.stderr.contains("Runtime error:"):
    return normalizeOutput(execResult.stderr)

  normalizeOutput(lines.join("\n"))


proc compareOutputs*(expected, actual: string): tuple[match: bool, normalizedActual: string, errorMsg: string] =
  ## Compare outputs, tolerating leading compiler noise by matching only the trailing lines.
  let normalizedExpected = normalizeOutput(expected)
  let normalizedActual = normalizeOutput(actual)

  let expectedLines = normalizedExpected.splitLines().filterIt(it.strip().len > 0)
  let actualLines = normalizedActual.splitLines().filterIt(it.strip().len > 0)

  if expectedLines.len > 0 and actualLines.len >= expectedLines.len:
    let lastActualLines = actualLines[^expectedLines.len .. ^1]
    if expectedLines == lastActualLines:
      (true, normalizedActual, "")
    else:
      (false, lastActualLines.join("\n"), "Output mismatch (comparing last N lines)")
  else:
    if normalizedExpected == normalizedActual:
      (true, normalizedActual, "")
    else:
      (false, normalizedActual, "Output mismatch")


proc runSingleTestVariant(testFile: string, verbose: bool = false, release: bool = false, backend: string = ""): TestResult =
  ## Run a single test file variant (debug or release) and compare output with expected result
  let baseName = testFile.splitFile.name
  let testDir = testFile.splitFile.dir
  let resultFile = testDir / baseName & ".pass"
  let errorFile = testDir / baseName & ".fail"

  result = TestResult(name: baseName, passed: false)

  # Check if we have a .pass file (success case) or .fail file (expected failure)
  let hasResultFile = fileExists(resultFile)
  let hasErrorFile = fileExists(errorFile)

  if not hasResultFile and not hasErrorFile:
    result.error = "No .pass or .fail file found"
    return

  if hasResultFile and hasErrorFile:
    result.error = "Both .pass and .fail files found - use only one"
    return

  # Read expected output/error
  try:
    if hasResultFile:
      result.expected = normalizeOutput(readFile(resultFile))
    else:
      result.expected = normalizeOutput(readFile(errorFile))
  except:
    result.error = "Failed to read expected output file: " & getCurrentExceptionMsg()
    return

  # Execute the test
  let etchExe = getAppFilename()
  var flags = "--run"
  if backend != "":
    flags &= " " & backend
  if verbose: flags &= " --verbose"
  if release: flags &= " --release"
  let cmd = &"{etchExe} {flags} {testFile}"
  logCLI(verbose, &"Executing test command: {cmd}")
  let execResult = executeWithSeparateStreams(cmd)

  # Handle different types of outcomes
  if execResult.exitCode != 0:
    # Test failed - check if this was expected
    if hasErrorFile:
      # Expected failure - compare error output
      result.actual = smartFilterOutput(execResult)
      result.passed = result.expected == result.actual
      if not result.passed:
        result.error = "Error output mismatch"
    else:
      # Unexpected failure
      if execResult.isCompileError:
        result.error = &"Unexpected compilation failure: {normalizeOutput(execResult.stderr)}"
      else:
        result.error = &"Unexpected runtime error (exit code {execResult.exitCode})"
      result.actual = smartFilterOutput(execResult)
  else:
    # Test succeeded - check if this was expected
    if hasErrorFile:
      # Expected failure but got success
      result.error = "Expected test to fail but it succeeded"
      result.actual = smartFilterOutput(execResult)
    else:
      # Expected success - compare output
      result.actual = smartFilterOutput(execResult)

      let comparison = compareOutputs(result.expected, result.actual)
      result.passed = comparison.match
      result.actual = comparison.normalizedActual
      if not result.passed:
        result.error = comparison.errorMsg


proc clearCachedFiles*(testFile: string) =
  ## Clear all cached files for a given test file:
  ## - Bytecode (.etcx)
  ## - Generated C code (.c)
  ## - Compiled C executable (_c)
  let (dir, name, _) = testFile.splitFile
  let cacheDir = dir / BYTECODE_CACHE_DIR

  # Remove cached bytecode
  let bytecodeFile = cacheDir / name & BYTECODE_FILE_EXTENSION
  if fileExists(bytecodeFile):
    try:
      removeFile(bytecodeFile)
    except:
      discard  # Silently ignore errors

  # Remove cached C code
  let cFile = cacheDir / name & ".c"
  if fileExists(cFile):
    try:
      removeFile(cFile)
    except:
      discard

  # Remove cached C executable
  let cExeFile = cacheDir / name & "_c"
  if fileExists(cExeFile):
    try:
      removeFile(cExeFile)
    except:
      discard


proc initTestState(state: var TestState; numTests: int) =
  when threadsEnabled:
    initLock(state.jobsLock)
    initLock(state.resultsLock)
    state.jobs = @[]
    state.results = newSeq[Option[TestResult]](numTests)
    state.remainingJobs = numTests
    state.workersShouldStop = false

  state.testFiles = @[]
  state.failedResults = @[]
  state.nextPrintIndex = 0
  state.passed = 0
  state.failed = 0


proc shutdownTestState(state: var TestState) =
  when threadsEnabled:
    deinitLock(state.jobsLock)
    deinitLock(state.resultsLock)
  else:
    discard


when threadsEnabled:
  proc enqueueJob(state: var TestState; idx: int, file: string) =
    withLock state.jobsLock:
      state.jobs.insert(TestJob(index: idx, file: file), 0)

  proc tryDequeueJob(state: var TestState; job: var TestJob): bool =
    withLock state.jobsLock:
      if state.jobs.len == 0:
        return false
      job = state.jobs[^1]
      state.jobs.setLen(state.jobs.len - 1)
      return true

  proc storeResult(state: var TestState; idx: int, res: TestResult) {.gcsafe.} =
    withLock state.resultsLock:
      state.results[idx] = some(res)
      dec state.remainingJobs


proc runAllVariants(testFile: string, verbose: bool, backend: string): TestResult =
  clearCachedFiles(testFile)
  let debugFresh = runSingleTestVariant(testFile, verbose, release = false, backend = backend)
  let debugCached = runSingleTestVariant(testFile, verbose, release = false, backend = backend)

  clearCachedFiles(testFile)
  let releaseFresh = runSingleTestVariant(testFile, verbose, release = true, backend = backend)
  let releaseCached = runSingleTestVariant(testFile, verbose, release = true, backend = backend)

  var res: TestResult
  res.name = testFile.splitFile.name

  if debugFresh.passed and debugCached.passed and releaseFresh.passed and releaseCached.passed:
    res.passed = true
    res.expected = debugFresh.expected
    res.actual = debugFresh.actual
  else:
    res.passed = false
    if not debugFresh.passed:
      res.error = &"Debug fresh: {debugFresh.error}"
      res.expected = debugFresh.expected
      res.actual = debugFresh.actual
    elif not debugCached.passed:
      res.error = &"Debug cached: {debugCached.error}"
      res.expected = debugCached.expected
      res.actual = debugCached.actual
    elif not releaseFresh.passed:
      res.error = &"Release fresh: {releaseFresh.error}"
      res.expected = releaseFresh.expected
      res.actual = releaseFresh.actual
    else:
      res.error = &"Release cached: {releaseCached.error}"
      res.expected = releaseCached.expected
      res.actual = releaseCached.actual

  res


proc emitResult(state: var TestState; res: TestResult) =
  var output = ""
  output &= &"Running {res.name}... \n"

  if res.passed:
    output &= "\u2713 PASSED (debug + release, fresh + cached)\n"
    inc state.passed
  else:
    output &= "\u2717 FAILED\n"
    inc state.failed
    output &= &"  {res.error}\n"
    if res.expected != res.actual:
      output &= "  Expected:\n"
      for line in res.expected.splitLines:
        output &= &"    {line}\n"
      output &= "  Actual:\n"
      for line in res.actual.splitLines:
        output &= &"    {line}\n"
    state.failedResults.add(res)

  stdout.write(output)
  stdout.flushFile()
  inc state.nextPrintIndex


proc runTests*(testFiles: seq[string], verbose: bool = false, release: bool = false, backend: string = ""): int =
  ## Run tests - if path is a file/glob, run those tests; if directory, run all tests
  ## Each test is run 4 times: debug fresh, debug cached, release fresh, release cached
  ## The release parameter is ignored - we always test both debug and release

  # Now run the tests
  let backendMsg = if backend != "": &" with {backend} backend" else: ""
  if testFiles.len == 1:
    echo &"Running single test: {testFiles[0]}{backendMsg}"
  else:
    echo &"Running {testFiles.len} tests{backendMsg}"

  echo "Each test runs 4 times: debug fresh, debug cached, release fresh, release cached"
  echo ""

  # Local shared state (no globals)
  var state: TestState
  initTestState(state, testFiles.len)
  state.testFiles = testFiles
  state.backend = backend
  state.verbose = verbose
  state.release = release
  defer: shutdownTestState(state)

  when threadsEnabled:
    let numWorkers = max(1, countProcessors() div 2)
    var workers = newSeq[Thread[ptr TestState]](numWorkers)

    proc workerProc(s: ptr TestState) {.thread, nimcall.} =
      var job: TestJob
      while not s.workersShouldStop:
        if not tryDequeueJob(s[], job):
          sleep(1)
          continue
        let res = runAllVariants(job.file, s.verbose, s.backend)
        storeResult(s[], job.index, res)

    proc printerProc(s: ptr TestState) {.thread, nimcall.} =
      while s.nextPrintIndex < s.testFiles.len:
        var maybeRes: Option[TestResult]
        withLock s.resultsLock:
          maybeRes = s.results[s.nextPrintIndex]
        if maybeRes.isNone:
          sleep(10)
          continue
        emitResult(s[], maybeRes.get)

      s.workersShouldStop = true

    for i, testFile in testFiles:
      enqueueJob(state, i, testFile)

    var printerThread: Thread[ptr TestState]
    createThread(printerThread, printerProc, addr state)
    for i in 0 ..< numWorkers:
      createThread(workers[i], workerProc, addr state)

    for i in 0 ..< numWorkers:
      joinThread(workers[i])
    joinThread(printerThread)

  else:
    for testFile in testFiles:
      let res = runAllVariants(testFile, state.verbose, state.backend)
      emitResult(state, res)

  echo &"Test Summary: {state.passed} passed, {state.failed} failed, {state.testFiles.len} total"

  if state.failed > 0:
    echo ""
    echo "Failed tests:"
    for r in state.failedResults:
      echo &"  - {r.name}: {r.error}"

    return 1

  return 0
