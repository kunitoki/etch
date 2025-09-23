# compiler.nim
# Etch compiler: compilation and execution orchestration

import std/[os, tables, times, options, strformat]
import frontend/[ast, lexer, parser]
import typechecker/[core, types, statements, inference]
import interpreter/[vm, bytecode]
import prover/[core]
import comptime, errors

proc verboseLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[COMPILER] ", msg

type
  CompilerResult* = object
    success*: bool
    exitCode*: int
    error*: string

  CompilerOptions* = object
    sourceFile*: string
    runVM*: bool
    verbose*: bool

proc getBytecodeFileName*(sourceFile: string): string =
  ## Get the .etcx filename for a source file in __etch__ subfolder
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, "__etch__")
  joinPath(etchDir, name & ".etcx")

proc shouldRecompile*(sourceFile, bytecodeFile: string, options: CompilerOptions): bool =
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
    let flags = CompilerFlags(verbose: options.verbose)
    let currentHash = hashSourceAndFlags(sourceContent, flags)
    let prog = loadBytecode(bytecodeFile)
    return prog.sourceHash != currentHash
  except:
    return true  # Recompile if we can't read bytecode

proc ensureMainInst(prog: Program) =
  ## Ensure main function instance exists if main template is non-generic
  let mainOverloads = prog.getFunctionOverloads("main")
  if mainOverloads.len > 0:
    # For main, we expect only one overload with no arguments
    var mainFunc: FunDecl = nil
    for overload in mainOverloads:
      if overload.typarams.len == 0 and overload.params.len == 0:
        mainFunc = overload
        break

    if mainFunc != nil:
      let key = "main"
      if not prog.funInstances.hasKey(key):
        prog.funInstances[key] = FunDecl(
          name: key, typarams: @[], params: mainFunc.params, ret: mainFunc.ret, body: mainFunc.body)

proc ensureAllNonGenericInst(prog: Program, flags: CompilerFlags) =
  ## Instantiate all non-generic functions so they're available for comptime evaluation
  for name, overloads in prog.funs:
    for f in overloads:
      if f.typarams.len == 0 and f.name != "main":  # Non-generic function, skip main (handled separately)
        # Generate unique key for overload
        let key = generateOverloadSignature(f)
        if flags.verbose:
          echo &"[COMPILER] Creating function instance: {key} for {f.name}"
        if not prog.funInstances.hasKey(key):
          prog.funInstances[key] = FunDecl(
            name: key, typarams: @[], params: f.params, ret: f.ret, body: f.body)

proc evaluateGlobalVariables(prog: Program): Table[string, V] =
  ## Evaluate global variable initialization expressions using bytecode
  ## Returns a table of evaluated global values for bytecode compilation
  var globalVars = initTable[string, V]()

  # Evaluate each global variable in order (supports dependencies)
  for g in prog.globals:
    if g.kind == skVar and g.vinit.isSome():
      try:
        # Evaluate the initialization expression with access to previous globals
        let res = evalExprWithBytecode(prog, g.vinit.get(), globalVars)
        # Store the evaluated value for subsequent globals
        globalVars[g.vname] = res
      except:
        # TODO - should we log this ? at least in verbose mode ?
        # If evaluation fails, store default value (silently)
        # The actual error will be caught by the compiler's type checker
        globalVars[g.vname] = V(kind: tkInt, ival: 0)
    elif g.kind == skVar:
      # Default initialization for variables without initializers
      globalVars[g.vname] = V(kind: tkInt, ival: 0)

  return globalVars

proc compileProgramWithGlobals(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, V], sourceFile: string = "", flags: CompilerFlags = CompilerFlags()): BytecodeProgram =
  ## Compile an AST program to bytecode with pre-evaluated global values
  # Start with standard compilation
  result = compileProgram(prog, sourceHash, sourceFile, flags)

  # Override global values with evaluated ones
  for name, value in evaluatedGlobals:
    result.globalValues[name] = convertVMValueToGlobalValue(value)

proc parseAndTypecheck*(options: CompilerOptions): (Program, string, Table[string, V]) =
  ## Parse source file and perform type checking, return AST, hash, and evaluated globals
  let flags = CompilerFlags(verbose: options.verbose)

  verboseLog(flags, "Starting compilation of " & options.sourceFile)

  # Set up error reporting context
  errors.loadSourceLines(options.sourceFile)

  let src = readFile(options.sourceFile)
  verboseLog(flags, "Read source file (" & $src.len & " characters)")

  let srcHash = hashSourceAndFlags(src, flags)
  verboseLog(flags, "Source hash: " & srcHash)

  let toks = lex(src)
  verboseLog(flags, "Lexed " & $toks.len & " tokens")

  var prog = parseProgram(toks, options.sourceFile)
  verboseLog(flags, "Parsed AST with " & $prog.funs.len & " functions and " & $prog.globals.len & " globals")

  # For this MVP, instantiation occurs when functions are called during typecheck inference.
  # We need a shallow pass to trigger calls in bodies:
  verboseLog(flags, "Starting type checking phase")
  typecheck(prog)
  verboseLog(flags, "Type checking complete")

  # Force monomorphization for main if it is non-generic:
  verboseLog(flags, "Ensuring main function instance")
  ensureMainInst(prog)

  # Instantiate all non-generic functions so they're available for comptime evaluation
  verboseLog(flags, "Instantiating non-generic functions")
  ensureAllNonGenericInst(prog, flags)

  # Fold compile-time expressions BEFORE final type checking so injected variables are available
  verboseLog(flags, "Folding compile-time expressions")
  foldComptime(prog, prog)

  # Now do full type checking with injected variables available
  # Build a trivial scope and walk each instance
  var subst: Table[string, EtchType]

  # First handle template functions (non-generic functions that need return type inference)
  for name, overloads in prog.funs:
    for f in overloads:
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
  verboseLog(flags, "Evaluating global variables")
  let evaluatedGlobals = evaluateGlobalVariables(prog)
  verboseLog(flags, "Evaluated " & $evaluatedGlobals.len & " global variables")

  # Run safety prover to ensure all variables are initialized
  verboseLog(flags, "Running safety prover")
  prove(prog, options.sourceFile, flags)
  verboseLog(flags, "Safety proof complete")

  verboseLog(flags, "Parse and typecheck phase complete")
  return (prog, srcHash, evaluatedGlobals)

proc runCachedBytecode*(bytecodeFile: string): CompilerResult =
  ## Run cached bytecode if available
  echo "Using cached bytecode: ", bytecodeFile
  try:
    let prog = loadBytecode(bytecodeFile)
    let vm = newBytecodeVM(prog)
    let exitCode = vm.runBytecode()
    return CompilerResult(success: true, exitCode: exitCode)
  except Exception as e:
    return CompilerResult(success: false, error: "Failed to run cached bytecode: " & e.msg)

proc saveBytecodeToCache*(bytecodeProg: BytecodeProgram, bytecodeFile: string) =
  ## Save bytecode to cache file
  try:
    # Ensure __etch__ directory exists
    let bytecodeDir = bytecodeFile.splitFile.dir
    if not dirExists(bytecodeDir):
      createDir(bytecodeDir)
    saveBytecode(bytecodeProg, bytecodeFile)
    echo "Cached bytecode to: ", bytecodeFile
  except Exception as e:
    echo "Warning: Failed to cache bytecode: ", e.msg

proc compileAndRun*(options: CompilerOptions): CompilerResult =
  ## Main compilation and execution function
  let flags = CompilerFlags(verbose: options.verbose)

  echo "Compiling: ", options.sourceFile
  verboseLog(flags, "Compilation options: runVM=" & $options.runVM & ", verbose=" & $options.verbose)

  try:
    # Parse and typecheck
    let (prog, srcHash, evaluatedGlobals) = parseAndTypecheck(options)

    # Compile to bytecode
    verboseLog(flags, "Compiling to bytecode")
    let bytecodeProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, options.sourceFile, flags)
    verboseLog(flags, "Bytecode compilation complete (" & $bytecodeProg.instructions.len & " instructions)")

    # Save bytecode to cache
    let bytecodeFile = getBytecodeFileName(options.sourceFile)
    verboseLog(flags, "Saving bytecode cache to: " & bytecodeFile)
    saveBytecodeToCache(bytecodeProg, bytecodeFile)

    # Check if we should run the VM
    var exitCode = 0
    if options.runVM:
      verboseLog(flags, "Starting VM execution")
      let vm = newBytecodeVM(bytecodeProg)
      exitCode = vm.runBytecode()
      verboseLog(flags, "VM execution finished with exit code: " & $exitCode)

    verboseLog(flags, "Compilation completed successfully")
    return CompilerResult(success: true, exitCode: 0)

  except EtchError as e:
    return CompilerResult(success: false, error: e.msg, exitCode: 1)

  except IOError as e:
    return CompilerResult(success: false, error: "File error: " & e.msg, exitCode: 1)

  except Exception as e:
    return CompilerResult(success: false, error: "Internal compiler error: " & e.msg, exitCode: 2)

proc tryRunCachedOrCompile*(options: CompilerOptions): CompilerResult =
  ## Try to run cached bytecode, fall back to compilation if needed
  let flags = CompilerFlags(verbose: options.verbose)
  let bytecodeFile = getBytecodeFileName(options.sourceFile)

  verboseLog(flags, "Checking for cached bytecode at: " & bytecodeFile)

  # Check if we can use cached bytecode
  if options.runVM and not shouldRecompile(options.sourceFile, bytecodeFile, options):
    verboseLog(flags, "Using cached bytecode")
    let cachedResult = runCachedBytecode(bytecodeFile)
    if cachedResult.success:
      verboseLog(flags, "Cached bytecode execution successful")
      return cachedResult
    else:
      verboseLog(flags, "Cached bytecode execution failed: " & cachedResult.error)
      echo cachedResult.error
      echo "Recompiling..."

  # Compile from source
  verboseLog(flags, "Compiling from source")
  return compileAndRun(options)