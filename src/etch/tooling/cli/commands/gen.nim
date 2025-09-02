# cli_gen.nim
# Generate command implementation

import std/[os, osproc, strformat, strutils, sequtils, tables]
import ../../../core/vm_types
import ../../../bytecode/serialize
import ../../../bytecode/backend/c/generator
import ../../../common/[constants, logging, errors]
import ../../compiler
import ../options


proc compileToBytecode*(options: CliOptions): BytecodeProgram =
  try:
    let compilerOpts = makeCompilerOptions(options.files[0], runVirtualMachine = false, options)
    let (prog, sourceHash, evaluatedGlobals, moduleRegistry, cffiRegistry) = parseAndTypecheck(compilerOpts)
    result = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, options.files[0], compilerOpts, moduleRegistry, cffiRegistry)
  except EtchError as e:
    stderr.writeLine formatError(e.pos, e.msg, @[])
    quit 1
  except OverflowDefect as e:
    stderr.writeLine &"Internal compiler error: {e.msg}"
    quit 1
  except Exception as e:
    stderr.writeLine e.msg
    quit 1


proc generateOrUseCachedBytecode*(options: CliOptions): BytecodeProgram =
  ## Generate bytecode using caching logic similar to run command
  let sourceFile = options.files[0]
  let bytecodeFile = getBytecodeFileName(sourceFile)

  # Read source to compute hash for validation
  let src = readFile(sourceFile)
  let compilerOpts = makeCompilerOptions(sourceFile, runVirtualMachine = false, options)

  logCLI(options.verbose, &"Checking for cached bytecode at: {bytecodeFile}")

  # Check if we can use cached bytecode
  if not shouldRecompileBytecode(sourceFile, bytecodeFile, src, compilerOpts):
    logCLI(options.verbose, "Using cached bytecode")
    result = loadBytecode(bytecodeFile)
  else:
    logCLI(options.verbose, "Compiling from source")
    result = compileToBytecode(options)
    logCLI(options.verbose, "Saving bytecode to cache")
    let (_, sourceHash, _, _, _) = parseAndTypecheck(compilerOpts)
    saveBytecodeToCache(result, bytecodeFile, sourceHash, sourceFile, compilerOpts)


proc generateCCodeToFile*(bytecode: BytecodeProgram, sourceFile: string): string =
  let (dir, name, _) = splitFile(sourceFile)
  let outputFile = joinPath(dir, name & ".c")
  let cCode = generateCCode(bytecode)
  writeFile(outputFile, cCode)
  return outputFile


proc compileCBackend*(bytecode: BytecodeProgram, sourceFile: string, options: CliOptions): int =
  let (dir, name, _) = splitFile(sourceFile)

  let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
  createDir(etchDir)

  let cFile = joinPath(etchDir, name & ".c")
  let exeFile = joinPath(etchDir, name & "_c")
  let cCode = generateCCode(bytecode)
  writeFile(cFile, cCode)

  logCLI(options.verbose, &"Generated C code: {cFile}")

  # Collect unique library directories from CFFI info
  var libDirs: seq[string] = @[]

  for funcName, funcInfo in bytecode.functions:
    if funcInfo.kind == fkCFFI:
      let libName = funcInfo.library

      if options.verbose:
        stderr.writeLine(&"CFFI Function: {funcName}")
        stderr.writeLine(&"  Library: {libName}")
        stderr.writeLine(&"  Library Path: {funcInfo.libraryPath}")

      # Skip standard system libraries (they don't need -L or -rpath)
      if libName in ["c", "cmath", "math", "m", "pthread", "dl"]:
        continue

      # If we have a library path, extract its directory
      if funcInfo.libraryPath != "":
        let libDir = parentDir(funcInfo.libraryPath)
        if options.verbose:
          stderr.writeLine(&"  Library Dir: {libDir}")
        if libDir != "" and libDir notin libDirs:
          libDirs.add(libDir)

  if options.verbose and libDirs.len > 0:
    stderr.writeLine("Library directories found:")
    for libDir in libDirs:
      stderr.writeLine(&"  {libDir}")

  # Build compilation command as seq[string]
  var compileArgs: seq[string] = @[]

  when defined(macosx) or defined(macos):
    compileArgs.add("xcrun")
    compileArgs.add("clang")
  else:
    compileArgs.add("clang")

  if not options.debug:
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
  for funcName, funcInfo in bytecode.functions:
    if funcInfo.kind == fkCFFI:
      let libName = funcInfo.library
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
  logCLI(options.verbose, &"Compiling: {compileCmd}")

  let (compileOutput, compileExitCode) = execCmdEx(compileCmd)
  if compileExitCode != 0:
    stderr.writeLine("C compilation failed:")
    stderr.writeLine(compileOutput)
    return 1

  return 0


proc genCommand*(options: CliOptions): int =
  if options.files.len != 1:
    usage()
    return 1

  let sourceFile = options.files[0]
  validateFile(sourceFile)

  # Handle code generation mode
  if options.backend == "vm" or options.backend == "":
    discard generateOrUseCachedBytecode(options)
  elif options.backend == "c":
    let bytecodeProgram = generateOrUseCachedBytecode(options)
    return compileCBackend(bytecodeProgram, sourceFile, options)
  else:
    stderr.writeLine(&"Error: Unknown backend for 'gen' command: {options.backend}")
    return 1

  return 0
