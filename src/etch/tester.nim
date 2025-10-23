# tester.nim
# Etch testing framework: test discovery, execution, and result reporting

import std/[os, strformat, strutils, algorithm, osproc, sequtils]
import ./common/constants

type
  TestResult* = object
    name*: string
    passed*: bool
    expected*: string
    actual*: string
    error*: string

  ExecutionResult = object
    stdout: string
    stderr: string
    exitCode: int
    isCompilerError: bool

proc normalizeOutput(output: string): string =
  output
    .strip()
    .replace("\r\n", "\n")
    .replace("\r", "\n")
    .replace("\\", "/")  # Normalize path separators for cross-platform compatibility
    .splitLines()
    .mapIt(it.strip(trailing = true, leading = false))  # Only strip trailing whitespace, preserve leading
    .filterIt(it.len > 0)
    .join("\n")

proc executeWithSeparateStreams(cmd: string): ExecutionResult =
  ## Execute command with separate stdout/stderr capture
  try:
    # Use execCmdEx and then try to separate compiler vs program output
    let (output, exitCode) = osproc.execCmdEx(cmd)

    # For now, treat all output as stdout (we'll filter it intelligently)
    # In a real implementation, we could modify the Etch CLI to separate outputs
    let stdout = output
    let stderr = ""

    # Determine if this is a compiler error vs runtime error
    let isCompilerError = exitCode != 0 and (
      output.contains("Error:") and not output.contains("Runtime error:") or
      output.contains("undeclared identifier") or
      output.contains("type mismatch") or
      output.contains("cannot open") or
      output.contains("No main") or
      output.contains("Compilation failed") or
      output.contains("failed to")
    )

    ExecutionResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      isCompilerError: isCompilerError
    )
  except:
    ExecutionResult(
      stdout: "",
      stderr: "Failed to execute: " & getCurrentExceptionMsg(),
      exitCode: -1,
      isCompilerError: true
    )

proc smartFilterOutput(execResult: ExecutionResult): string =
  ## Intelligently filter output based on execution context
  if execResult.isCompilerError:
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

  for line in execResult.stdout.splitLines:
    let trimmed = line.strip()

    # Skip empty lines at the beginning
    if not foundProgramOutput and trimmed == "":
      continue

    # Common patterns that indicate compiler output (not program output)
    if trimmed.startsWith("Compiling:") or
       trimmed.startsWith("Cached bytecode to:") or
       trimmed.startsWith("Using cached bytecode:") or
       trimmed.startsWith("Generated debug bytecode:") or
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

proc runSingleTest*(testFile: string, verbose: bool = false, release: bool = false, backend: string = ""): TestResult =
  ## Run a single test file and compare output with expected result
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
  # Register VM is now the default
  if release: flags &= " --release"
  let cmd = &"{etchExe} {flags} {testFile}"
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
      if execResult.isCompilerError:
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

      # Compare only the last N lines of actual output with expected output
      # This handles compile-time vs runtime output differences
      let actualLines = result.actual.splitLines().filterIt(it.strip().len > 0)
      let expectedLines = result.expected.splitLines().filterIt(it.strip().len > 0)

      if expectedLines.len > 0 and actualLines.len >= expectedLines.len:
        let lastActualLines = actualLines[^expectedLines.len .. ^1]
        result.passed = expectedLines == lastActualLines
        if not result.passed:
          result.actual = lastActualLines.join("\n")
          result.error = "Output mismatch (comparing last N lines)"
      else:
        result.passed = result.expected == result.actual
        if not result.passed:
          result.error = "Output mismatch"

proc clearCachedFiles(testFile: string) =
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

proc findTestFiles*(directory: string): seq[string] =
  ## Find all .etch files in directory that have corresponding .result or .error files
  result = @[]

  if not dirExists(directory):
    echo &"Test directory '{directory}' does not exist"
    return

  for file in walkFiles(directory / "*.etch"):
    let baseName = file.splitFile.name
    let resultFile = directory / baseName & ".pass"
    let errorFile = directory / baseName & ".fail"
    if fileExists(resultFile) or fileExists(errorFile):
      result.add(file)

  result.sort()

proc runTests*(path: string = "examples", verbose: bool = false, release: bool = false, backend: string = ""): int =
  ## Run tests - if path is a file, run single test; if directory, run all tests

  # Check if path is a file or directory
  if fileExists(path):
    # Single file test
    echo &"Running single test: {path}"
    if verbose: echo &"  verbose: {verbose}, release: {release}, backend: {backend}"

    let res = runSingleTest(path, verbose, release, backend)

    if res.passed:
      echo "✓ PASSED"
      return 0
    else:
      echo "✗ FAILED"
      echo &"  Error: {res.error}"
      if res.expected != res.actual:
        echo "  Expected:"
        for line in res.expected.splitLines:
          echo &"    {line}"
        echo "  Actual:"
        for line in res.actual.splitLines:
          echo &"    {line}"
      return 1

  elif dirExists(path):
    # Directory test - run each test twice: without and with cached bytecode
    let backendMsg = if backend != "": &" with {backend} backend" else: ""
    echo &"Running tests in directory: {path}{backendMsg}"
    echo "Each test runs twice: without cached bytecode, then with cached bytecode"

    let testFiles = findTestFiles(path)
    if testFiles.len == 0:
      echo "No test files found (looking for .etch files with corresponding .pass or .fail files)"
      return 1

    echo &"Found {testFiles.len} test files"
    echo ""

    var passed = 0
    var failed = 0
    var results: seq[TestResult] = @[]

    for testFile in testFiles:
      let testName = testFile.splitFile.name
      echo &"Running {testName}... "

      # Clear all cached files before first run (bytecode, C code, C executable)
      clearCachedFiles(testFile)

      # First run: without cached bytecode (fresh compilation)
      let res1 = runSingleTest(testFile, verbose, release, backend)

      # Second run: with cached bytecode (should use cache from first run)
      let res2 = runSingleTest(testFile, verbose, release, backend)

      # Both runs should independently pass their .pass/.fail validation
      # We don't compare fresh vs cached output (they may differ for comptime tests)
      if res1.passed and res2.passed:
        echo "✓ PASSED (fresh + cached)"
        inc passed
        results.add(res1)  # Store first result for summary
      else:
        echo "✗ FAILED"
        inc failed

        # Show which run(s) failed
        if not res1.passed and not res2.passed:
          echo "  Error in both fresh and cached compilation:"
          echo &"    Fresh: {res1.error}"
          echo &"    Cached: {res2.error}"
          results.add(res1)
        elif not res1.passed:
          echo "  Error in fresh compilation:"
          echo &"    {res1.error}"
          results.add(res1)
        else:
          echo "  Error in cached compilation:"
          echo &"    {res2.error}"
          results.add(res2)

        # Show expected vs actual for failed tests
        let failedRes = if not res1.passed: res1 else: res2
        if failedRes.expected != failedRes.actual:
          echo "  Expected:"
          for line in failedRes.expected.splitLines:
            echo &"    {line}"
          echo "  Actual (fresh):"
          for line in res1.actual.splitLines:
            echo &"    {line}"
          if res1.actual != res2.actual:
            echo "  Actual (cached):"
            for line in res2.actual.splitLines:
              echo &"    {line}"
        echo ""

    echo &"Test Summary: {passed} passed, {failed} failed, {testFiles.len} total"

    if failed > 0:
      echo ""
      echo "Failed tests:"
      for r in results:
        if not r.passed:
          echo &"  - {r.name}: {r.error}"
      return 1

    return 0

  else:
    echo &"Error: Path '{path}' does not exist"
    return 1
