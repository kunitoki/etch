# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strformat, strutils, tables, times, algorithm, osproc]
import ./etch/[ast, lexer, parser, typecheck, prover, vm, builtins, bytecode, globals, errors]

proc ensureMainInst(prog: Program) =
  # if 'main' template exists with no typarams, synthesize an instance key 'main'
  if prog.funs.hasKey("main") and prog.funs["main"].typarams.len == 0:
    let key = "main"
    if not prog.funInstances.hasKey(key):
      let f = prog.funs["main"]
      prog.funInstances[key] = FunDecl(
        name: key, typarams: @[], params: f.params, ret: f.ret, body: f.body)

proc getBytecodeFileName(sourceFile: string): string =
  ## Get the .etcx filename for a source file in __etch__ subfolder
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, "__etch__")
  joinPath(etchDir, name & ".etcx")

proc shouldRecompile(sourceFile, bytecodeFile: string, includeDebugInfo: bool): bool =
  ## Check if source file is newer than bytecode or if hash/flags don't match
  if not fileExists(bytecodeFile):
    return true

  # Check modification times
  let sourceTime = getLastModificationTime(sourceFile)
  let bytecodeTime = getLastModificationTime(bytecodeFile)
  if sourceTime > bytecodeTime:
    return true

  # Check source hash + compiler flags
  try:
    let sourceContent = readFile(sourceFile)
    let flags = CompilerFlags(includeDebugInfo: includeDebugInfo)
    let currentHash = hashSourceAndFlags(sourceContent, flags)
    let prog = loadBytecode(bytecodeFile)
    return prog.sourceHash != currentHash
  except:
    return true  # Recompile if we can't read bytecode

proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run] [--emit:c out.c] [--debug] file.etch"
  echo "  etch --test [directory]"
  echo "Options:"
  echo "  --run         Execute the program (with bytecode caching)"
  echo "  --debug       Include debug information in bytecode"
  echo "  --test        Run tests in directory (default: examples/)"
  echo "                Tests need .result (expected output) or .error (expected failure)"
  quit 1

type
  TestResult* = object
    name*: string
    passed*: bool
    expected*: string
    actual*: string
    error*: string

proc normalizeOutput(output: string): string =
  ## Normalize output for comparison (remove extra whitespace, normalize line endings)
  output.strip().replace("\r\n", "\n").replace("\r", "\n")

type
  ExecutionResult = object
    stdout: string
    stderr: string
    exitCode: int
    isCompilerError: bool

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
       (trimmed.startsWith("Failed to") and not foundProgramOutput):
      continue

    # Once we find any output that looks like program output,
    # include everything from that point forward
    foundProgramOutput = true
    lines.add(line)

  # If no program output found but we have runtime error in stderr
  if lines.len == 0 and execResult.stderr.contains("Runtime error:"):
    return normalizeOutput(execResult.stderr)

  normalizeOutput(lines.join("\n"))

proc runSingleTest(testFile: string): TestResult =
  ## Run a single test file and compare output with expected result
  let baseName = testFile.splitFile.name
  let testDir = testFile.splitFile.dir
  let resultFile = testDir / baseName & ".result"
  let errorFile = testDir / baseName & ".error"

  result = TestResult(name: baseName, passed: false)

  # Check if we have a .result file (success case) or .error file (expected failure)
  let hasResultFile = fileExists(resultFile)
  let hasErrorFile = fileExists(errorFile)

  if not hasResultFile and not hasErrorFile:
    result.error = "No .result or .error file found"
    return

  if hasResultFile and hasErrorFile:
    result.error = "Both .result and .error files found - use only one"
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
  let cmd = fmt"{etchExe} --run {testFile}"
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
        result.error = fmt"Unexpected compilation failure: {normalizeOutput(execResult.stderr)}"
      else:
        result.error = fmt"Unexpected runtime error (exit code {execResult.exitCode})"
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
      result.passed = result.expected == result.actual
      if not result.passed:
        result.error = "Output mismatch"

proc findTestFiles(directory: string): seq[string] =
  ## Find all .etch files in directory that have corresponding .result or .error files
  result = @[]

  if not dirExists(directory):
    echo fmt"Test directory '{directory}' does not exist"
    return

  for file in walkFiles(directory / "*.etch"):
    let baseName = file.splitFile.name
    let resultFile = directory / baseName & ".result"
    let errorFile = directory / baseName & ".error"
    if fileExists(resultFile) or fileExists(errorFile):
      result.add(file)

  result.sort()

proc runTests(directory: string = "examples"): int =
  ## Run all tests in the specified directory
  echo fmt"Running tests in directory: {directory}"

  let testFiles = findTestFiles(directory)
  if testFiles.len == 0:
    echo "No test files found (looking for .etch files with corresponding .result or .error files)"
    return 1

  echo fmt"Found {testFiles.len} test files"
  echo ""

  var passed = 0
  var failed = 0
  var results: seq[TestResult] = @[]

  for testFile in testFiles:
    echo fmt"Running {testFile.splitFile.name}... "
    let res = runSingleTest(testFile)
    results.add(res)

    if res.passed:
      echo "✓ PASSED"
      inc passed
    else:
      echo "✗ FAILED"
      inc failed
      echo fmt"  Error: {res.error}"
      if res.expected != res.actual:
        echo "  Expected:"
        for line in res.expected.splitLines:
          echo fmt"    {line}"
        echo "  Actual:"
        for line in res.actual.splitLines:
          echo fmt"    {line}"
      echo ""

  echo fmt"Test Summary: {passed} passed, {failed} failed, {testFiles.len} total"

  if failed > 0:
    echo ""
    echo "Failed tests:"
    for r in results:
      if not r.passed:
        echo fmt"  - {r.name}: {r.error}"
    return 1

  return 0


proc compileProgramWithGlobals(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, V], sourceFile: string = "", includeDebugInfo: bool = false): BytecodeProgram =
  ## Compile an AST program to bytecode with pre-evaluated global values
  # Start with standard compilation
  result = compileProgram(prog, sourceHash, sourceFile, includeDebugInfo)

  # Override global values with evaluated ones
  for name, value in evaluatedGlobals:
    result.globalValues[name] = convertVMValueToGlobalValue(value)

when isMainModule:
  if paramCount() < 1: usage()

  # Check for test mode first
  if paramCount() >= 1 and paramStr(1) == "--test":
    let testDir = if paramCount() >= 2: paramStr(2) else: "examples"
    quit runTests(testDir)

  var runVm = false
  var emitC = false
  var includeDebugInfo = false
  var cOut = ""
  var files: seq[string] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--run": runVm = true
    elif a == "--debug": includeDebugInfo = true
    else:
      files.add a
    inc i
  if files.len != 1: usage()

  let sourceFile = files[0]
  let bytecodeFile = getBytecodeFileName(sourceFile)

  # Check if we can use cached bytecode
  if runVm and not emitC and not shouldRecompile(sourceFile, bytecodeFile, includeDebugInfo):
    echo "Using cached bytecode: ", bytecodeFile
    try:
      let prog = loadBytecode(bytecodeFile)
      let vm = newBytecodeVM(prog)
      let exitCode = vm.runBytecode()
      quit exitCode
    except Exception as e:
      echo "Failed to run cached bytecode: ", e.msg
      echo "Recompiling..."

  # Compile from source
  echo "Compiling: ", sourceFile
  try:
    # Set up error reporting context
    errors.loadSourceLines(sourceFile)

    let src = readFile(sourceFile)
    let flags = CompilerFlags(includeDebugInfo: includeDebugInfo)
    let srcHash = hashSourceAndFlags(src, flags)
    let toks = lex(src)
    var prog = parseProgram(toks, sourceFile)

    # For this MVP, instantiation occurs when functions are called during typecheck inference.
    # We need a shallow pass to trigger calls in bodies:
    typecheck(prog)

    # Force monomorphization for main if it is non-generic:
    ensureMainInst(prog)

    # Fold compile-time expressions BEFORE final type checking so injected variables are available
    foldComptime(prog, prog)

    # Now do full type checking with injected variables available
    # Build a trivial scope and walk each instance
    var subst: Table[string, EtchType]

    # First handle template functions (non-generic functions that need return type inference)
    for name, f in prog.funs:
      if f.typarams.len == 0 and f.ret == nil:
        var sc = Scope(types: initTable[string, EtchType]())
        for p in f.params: sc.types[p.name] = p.typ
        for v in prog.globals:
          if v.kind == skVar: sc.types[v.vname] = v.vtype
        let returnTypes = collectReturnTypes(prog, f, sc, f.body, subst)
        f.ret = inferReturnType(returnTypes)

    # Collect keys first to avoid modifying table while iterating
    var instanceKeys: seq[string] = @[]
    for k in keys(prog.funInstances): instanceKeys.add(k)

    for k in instanceKeys:
      let f = prog.funInstances[k]
      var sc = Scope(types: initTable[string, EtchType]())
      for p in f.params: sc.types[p.name] = p.typ
      for v in prog.globals:
        if v.kind == skVar: sc.types[v.vname] = v.vtype

      # If return type is not specified, infer it from return statements
      if f.ret == nil:
        let returnTypes = collectReturnTypes(prog, f, sc, f.body, subst)
        f.ret = inferReturnType(returnTypes)

      for s in f.body: typecheckStmt(prog, f, sc, s, subst)

    # Evaluate global variables with full expression support
    let evaluatedGlobals = evaluateGlobalVariables(prog)

    # Run safety prover to ensure all variables are initialized
    prove(prog, files[0])

    # Generate bytecode if running VM or if C emission needs it
    var bytecodeGenerated = false
    var bytecodeProg: BytecodeProgram

    if runVm:
      bytecodeProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, sourceFile, includeDebugInfo)
      bytecodeGenerated = true

      # Save bytecode to cache
      try:
        # Ensure __etch__ directory exists
        let bytecodeDir = bytecodeFile.splitFile.dir
        if not dirExists(bytecodeDir):
          createDir(bytecodeDir)
        saveBytecode(bytecodeProg, bytecodeFile)
        echo "Cached bytecode to: ", bytecodeFile
      except Exception as e:
        echo "Warning: Failed to cache bytecode: ", e.msg

      # Run the bytecode
      let vm = newBytecodeVM(bytecodeProg)
      let exitCode = vm.runBytecode()
      quit exitCode

  except EtchError as e:
    # Show clean error message without Nim stacktrace
    echo e.msg
    quit 1

  except IOError as e:
    echo "File error: ", e.msg
    quit 1

  except Exception as e:
    # Unexpected error - show with context
    echo "Internal compiler error: ", e.msg
    echo "  This is likely a bug in the compiler."
    quit 2
