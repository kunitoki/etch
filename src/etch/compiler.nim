# compiler.nim
# Etch compiler: compilation and execution orchestration

import std/[os, tables, times]
import ast, lexer, parser, typecheck, prover, vm, builtins, bytecode, globals, errors

type
  CompilerResult* = object
    success*: bool
    exitCode*: int
    error*: string

  CompilerOptions* = object
    sourceFile*: string
    runVM*: bool
    includeDebugInfo*: bool
    cOutFile*: string

proc getBytecodeFileName*(sourceFile: string): string =
  ## Get the .etcx filename for a source file in __etch__ subfolder
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, "__etch__")
  joinPath(etchDir, name & ".etcx")

proc shouldRecompile*(sourceFile, bytecodeFile: string, includeDebugInfo: bool): bool =
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

proc ensureMainInst(prog: Program) =
  ## Ensure main function instance exists if main template is non-generic
  if prog.funs.hasKey("main") and prog.funs["main"].typarams.len == 0:
    let key = "main"
    if not prog.funInstances.hasKey(key):
      let f = prog.funs["main"]
      prog.funInstances[key] = FunDecl(
        name: key, typarams: @[], params: f.params, ret: f.ret, body: f.body)

proc ensureAllNonGenericInst(prog: Program) =
  ## Instantiate all non-generic functions so they're available for comptime evaluation
  for name, f in prog.funs:
    if f.typarams.len == 0:  # Non-generic function
      if not prog.funInstances.hasKey(name):
        prog.funInstances[name] = FunDecl(
          name: name, typarams: @[], params: f.params, ret: f.ret, body: f.body)

proc compileProgramWithGlobals(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, V], sourceFile: string = "", includeDebugInfo: bool = false): BytecodeProgram =
  ## Compile an AST program to bytecode with pre-evaluated global values
  # Start with standard compilation
  result = compileProgram(prog, sourceHash, sourceFile, includeDebugInfo)

  # Override global values with evaluated ones
  for name, value in evaluatedGlobals:
    result.globalValues[name] = convertVMValueToGlobalValue(value)

proc parseAndTypecheck*(sourceFile: string, includeDebugInfo: bool): (Program, string, Table[string, V]) =
  ## Parse source file and perform type checking, return AST, hash, and evaluated globals
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

  # Instantiate all non-generic functions so they're available for comptime evaluation
  ensureAllNonGenericInst(prog)

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
  prove(prog, sourceFile)

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
  echo "Compiling: ", options.sourceFile

  try:
    # Parse and typecheck
    let (prog, srcHash, evaluatedGlobals) = parseAndTypecheck(options.sourceFile, options.includeDebugInfo)

    # Compile to bytecode
    let bytecodeProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, options.sourceFile, options.includeDebugInfo)

    # Save bytecode to cache
    let bytecodeFile = getBytecodeFileName(options.sourceFile)
    saveBytecodeToCache(bytecodeProg, bytecodeFile)

    # Check if we should run the VM
    var exitCode = 0
    if options.runVM:
      let vm = newBytecodeVM(bytecodeProg)
      exitCode = vm.runBytecode()

    return CompilerResult(success: true, exitCode: 0)

  except EtchError as e:
    return CompilerResult(success: false, error: e.msg, exitCode: 1)

  except IOError as e:
    return CompilerResult(success: false, error: "File error: " & e.msg, exitCode: 1)

  except Exception as e:
    return CompilerResult(success: false, error: "Internal compiler error: " & e.msg, exitCode: 2)

proc tryRunCachedOrCompile*(options: CompilerOptions): CompilerResult =
  ## Try to run cached bytecode, fall back to compilation if needed
  let bytecodeFile = getBytecodeFileName(options.sourceFile)

  # Check if we can use cached bytecode
  if options.runVM and not shouldRecompile(options.sourceFile, bytecodeFile, options.includeDebugInfo):
    let cachedResult = runCachedBytecode(bytecodeFile)
    if cachedResult.success:
      return cachedResult
    else:
      echo cachedResult.error
      echo "Recompiling..."

  # Compile from source
  return compileAndRun(options)