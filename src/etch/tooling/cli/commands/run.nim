# cli_run.nim
# Run command implementation

import std/[os, osproc, strformat, strutils, times]
import ../../../core/vm_types
import ../../../common/[constants, logging]
import ../../compiler
import ../options
import ./gen # For compileToBytecode


proc compileAndRunCBackend*(bytecode: BytecodeProgram, sourceFile: string, options: CliOptions): int =
  let compileExitCode = compileCBackend(bytecode, sourceFile, options)
  if compileExitCode != 0:
    return compileExitCode

  let (dir, name, _) = splitFile(sourceFile)

  let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
  createDir(etchDir)

  let exeFile = joinPath(etchDir, name & "_c")

  var (runOutput, runExitCode) = execCmdEx(exeFile)
  runOutput.stripLineEnd
  echo runOutput
  return runExitCode


proc runCommand*(options: CliOptions): int =
  if options.files.len != 1:
    usage()
    return 1

  let sourceFile = options.files[0]
  validateFile(sourceFile)

  if options.runBackend == "c":
    # Handle run with C backend
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
        logCLI(options.verbose, &"Using cached C executable: {exeFile}")
        let (runOutput, runExitCode) = execCmdEx(exeFile)
        echo runOutput
        return runExitCode

    let bytecodeProgram = compileToBytecode(options)
    return compileAndRunCBackend(bytecodeProgram, sourceFile, options)
  else:
    # Normal VM execution
    let compileOptions = makeCompilerOptions(sourceFile, runVirtualMachine = true, options)

    let compilerResult = tryRunCachedOrCompile(compileOptions)
    if not compilerResult.success:
        echo compilerResult.error
        return compilerResult.exitCode

    return compilerResult.exitCode