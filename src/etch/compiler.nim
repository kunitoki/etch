# compiler.nim
# Etch compiler: compilation and execution orchestration

import std/[os, tables, times, strformat, hashes, options]
import common/[constants, types, errors, logging, cffi, library_resolver]
import frontend/[ast, lexer, parser]
import interpreter/[regvm, regvm_compiler, regvm_exec, regvm_serialize]  # Register VM
import prover/[core]
import typechecker/[core, types as tctypes, statements, inference]
import ./[comptime, modules]

type
  CompilerResult* = object
    success*: bool
    exitCode*: int
    error*: string

proc getBytecodeFileName*(sourceFile: string): string =
  ## Get the bytecode filename for a source file in bytecode subfolder
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
  joinPath(etchDir, name & BYTECODE_FILE_EXTENSION)

proc hashSourceAndFlags*(source: string, options: CompilerOptions): string =
  ## Generate a hash of the source code + compiler options for cache validation
  let sourceHash = hashes.hash(source)
  $sourceHash

proc shouldRecompile*(sourceFile, bytecodeFile: string, options: CompilerOptions): bool =
  ## Check if source file is newer than bytecode or if hash/flags don't match
  if not fileExists(bytecodeFile):
    return true

  # Check modification times
  let sourceTime = getLastModificationTime(sourceFile)
  let bytecodeTime = getLastModificationTime(bytecodeFile)
  if sourceTime > bytecodeTime:
    return true

  # Bytecode is up to date
  return false

proc ensureMainInst(prog: Program) =
  ## Ensure main function instance exists if main template is non-generic
  let mainOverloads = prog.getFunctionOverloads(MAIN_FUNCTION_NAME)
  if mainOverloads.len > 0:
    # For main, we expect only one overload with no arguments
    var mainFunc: FunDecl = nil
    for overload in mainOverloads:
      if overload.typarams.len == 0 and overload.params.len == 0:
        mainFunc = overload
        break

    if mainFunc != nil:
      let key = MAIN_FUNCTION_NAME
      if not prog.funInstances.hasKey(key):
        prog.funInstances[key] = FunDecl(
          name: key, typarams: @[], params: mainFunc.params, ret: mainFunc.ret, body: mainFunc.body,
          isExported: mainFunc.isExported, isCFFI: mainFunc.isCFFI)

proc ensureAllNonGenericInst(prog: Program, options: CompilerOptions) =
  ## Instantiate all non-generic functions so they're available for comptime evaluation
  for name, overloads in prog.funs:
    for f in overloads:
      if f.typarams.len == 0 and f.name != MAIN_FUNCTION_NAME:  # Non-generic function, skip main (handled separately)
        # Generate unique key for overload
        let key = generateOverloadSignature(f)
        if options.verbose:
          echo &"[COMPILER] Creating function instance: {key} for {f.name}"
        if not prog.funInstances.hasKey(key):
          # Resolve user-defined types in parameters and return type
          var resolvedParams: seq[Param] = @[]
          for param in f.params:
            var resolvedType = param.typ
            if resolvedType.kind == tkUserDefined:
              if prog.types.hasKey(resolvedType.name):
                resolvedType = prog.types[resolvedType.name]
            resolvedParams.add(Param(name: param.name, typ: resolvedType, defaultValue: param.defaultValue))

          var resolvedRet = f.ret
          if resolvedRet != nil and resolvedRet.kind == tkUserDefined:
            if prog.types.hasKey(resolvedRet.name):
              resolvedRet = prog.types[resolvedRet.name]

          prog.funInstances[key] = FunDecl(
            name: key, typarams: @[], params: resolvedParams, ret: resolvedRet, body: f.body,
            isExported: f.isExported, isCFFI: f.isCFFI)

# Forward declarations
proc hasImpureCall(expr: Expr): bool

proc hasImpureCall(expr: Expr): bool =
  ## Simple check for expressions with side effects
  case expr.kind
  of ekCall:
    # Known impure built-in functions
    if expr.fname in ["print", "readFile", "rand", "println"]:
      return true
    # Check arguments first
    for arg in expr.args:
      if hasImpureCall(arg):
        return true
    return false
  of ekBin:
    return hasImpureCall(expr.lhs) or hasImpureCall(expr.rhs)
  else:
    return false

proc evaluateGlobalVariables(prog: Program): Table[string, GlobalValue] =
  ## Skip compile-time evaluation of globals for now (register VM only)
  ## All global initialization will happen at runtime
  return initTable[string, GlobalValue]()

proc compileProgramWithGlobals*(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, GlobalValue], sourceFile: string = "", options: CompilerOptions): RegBytecodeProgram =
  ## Compile an AST program to register VM bytecode
  # Compile directly to register VM without needing old bytecode
  # Use optimization level 1 in debug mode, 2 in release mode
  let optimizeLevel = if options.debug: 1 else: 2
  result = regvm_compiler.compileProgram(prog, optimizeLevel = optimizeLevel, verbose = options.verbose, debug = options.debug)

  # Fill in CFFI details from the global registry
  for funcName, cffiInfo in result.cffiInfo:
    if globalCFFIRegistry.functions.hasKey(funcName):
      let cffiFunc = globalCFFIRegistry.functions[funcName]

      # Update the CFFIInfo with actual library and type information
      result.cffiInfo[funcName].library = cffiFunc.library
      result.cffiInfo[funcName].symbol = cffiFunc.symbol

      # Convert parameter types to strings
      result.cffiInfo[funcName].paramTypes = @[]
      for param in cffiFunc.signature.params:
        result.cffiInfo[funcName].paramTypes.add($param.typ.kind)

      # Convert return type to string
      result.cffiInfo[funcName].returnType = $cffiFunc.signature.returnType.kind

proc parseAndTypecheck*(options: CompilerOptions): (Program, string, Table[string, GlobalValue]) =
  ## Parse source file and perform type checking, return AST, hash, and evaluated globals
  logCompiler(options.verbose, "Starting compilation of " & options.sourceFile)

  # Get source code - either from string or file
  let src = if options.sourceString.isSome:
    let sourceCode = options.sourceString.get()
    logCompiler(options.verbose, "Compiling from string (" & $sourceCode.len & " characters)")
    # Cache source lines for string compilation (not on disk, so must cache upfront)
    errors.loadSourceLinesFromString(sourceCode, options.sourceFile)
    sourceCode
  else:
    let content = readFile(options.sourceFile)
    logCompiler(options.verbose, "Read source file (" & $content.len & " characters)")
    # For file compilation, source lines will be lazily loaded on error in formatError()
    content

  let srcHash = hashSourceAndFlags(src, options)
  logCompiler(options.verbose, "Source hash: " & srcHash)

  let toks = lex(src, options.sourceFile)
  logCompiler(options.verbose, "Lexed " & $toks.len & " tokens")

  var prog = parseProgram(toks, options.sourceFile)
  logCompiler(options.verbose, "Parsed AST with " & $prog.funs.len & " functions and " & $prog.globals.len & " globals")

  # Process imports - load modules and FFI functions
  logCompiler(options.verbose, "Processing imports")
  globalModuleRegistry.processImports(prog, options.sourceFile)
  logCompiler(options.verbose, "After imports: " & $prog.funs.len & " functions and " & $prog.globals.len & " globals")

  # For this MVP, instantiation occurs when functions are called during typecheck inference
  logCompiler(options.verbose, "Starting type checking phase")
  typecheck(prog)
  logCompiler(options.verbose, "Type checking complete")

  # Force monomorphization for main if it is non-generic:
  logCompiler(options.verbose, "Ensuring main function instance")
  ensureMainInst(prog)

  # Instantiate all non-generic functions so they're available for comptime evaluation
  logCompiler(options.verbose, "Instantiating non-generic functions")
  ensureAllNonGenericInst(prog, options)

  # Fold compile-time expressions BEFORE final type checking so injected variables are available
  logCompiler(options.verbose, "Folding compile-time expressions")
  foldComptime(prog, prog)

  # Now do full type checking with injected variables available
  var subst: Table[string, EtchType]

  # First handle template functions (non-generic functions that need return type inference)
  for name, overloads in prog.funs:
    for f in overloads:
      if f.typarams.len == 0 and f.ret == nil:
        var sc = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: prog.types, prog: prog)
        for p in f.params: sc.types[p.name] = p.typ
        for v in prog.globals:
          if v.kind == skVar:
            sc.types[v.vname] = v.vtype
            sc.flags[v.vname] = v.vflag
        let returnTypes = collectReturnTypes(prog, f, sc, f.body, subst)
        f.ret = inferReturnType(returnTypes)

  # Collect keys first to avoid modifying table while iterating
  var instanceKeys: seq[string] = @[]
  for k in keys(prog.funInstances): instanceKeys.add(k)

  for k in instanceKeys:
    let f = prog.funInstances[k]
    var sc = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: prog.types, prog: prog)
    for p in f.params: sc.types[p.name] = p.typ
    for v in prog.globals:
      if v.kind == skVar:
        sc.types[v.vname] = v.vtype
        sc.flags[v.vname] = v.vflag

    # If return type is not specified, infer it from return statements
    if f.ret == nil:
      let returnTypes = collectReturnTypes(prog, f, sc, f.body, subst)
      f.ret = inferReturnType(returnTypes)

    for s in f.body: typecheckStmt(prog, f, sc, s, subst)

  # Evaluate global variables with full expression support
  logCompiler(options.verbose, "Evaluating global variables")
  let evaluatedGlobals = evaluateGlobalVariables(prog)
  logCompiler(options.verbose, "Evaluated " & $evaluatedGlobals.len & " global variables")

  # Run safety prover to ensure all variables are initialized
  logCompiler(options.verbose, "Running safety prover")
  prove(prog, options.sourceFile, options)
  logCompiler(options.verbose, "Safety proof complete")

  logCompiler(options.verbose, "Parse and typecheck phase complete")
  return (prog, srcHash, evaluatedGlobals)

proc runCachedBytecode*(bytecodeFile: string): CompilerResult =
  echo "Using cached bytecode: ", bytecodeFile
  try:
    let prog = loadRegBytecode(bytecodeFile)

    for funcName, cffiInfo in prog.cffiInfo:
      if cffiInfo.library notin globalCFFIRegistry.libraries:
        let (normalizedName, actualPath) = resolveLibraryPath(cffiInfo.library)

        var loaded = false
        if actualPath != "":
          try:
            discard globalCFFIRegistry.loadLibrary(normalizedName, actualPath)
            loaded = true
          except:
            let foundPath = findLibraryInSearchPaths(actualPath)
            if foundPath != "":
              try:
                discard globalCFFIRegistry.loadLibrary(normalizedName, foundPath)
                loaded = true
              except:
                discard

        if not loaded:
          raise newException(IOError, "Failed to load library: " & cffiInfo.library)

      var paramSpecs: seq[cffi.ParamSpec] = @[]
      for i, paramType in cffiInfo.paramTypes:
        let typ = case paramType
          of "tkBool": tBool()
          of "tkChar": tChar()
          of "tkInt": tInt()
          of "tkFloat": tFloat()
          of "tkString": tString()
          of "tkVoid": tVoid()
          else: tVoid()
        paramSpecs.add(cffi.ParamSpec(name: "arg" & $i, typ: typ))

      let retType = case cffiInfo.returnType
        of "tkBool": tBool()
        of "tkChar": tChar()
        of "tkInt": tInt()
        of "tkFloat": tFloat()
        of "tkString": tString()
        of "tkVoid": tVoid()
        else: tVoid()

      let signature = cffi.FunctionSignature(
        params: paramSpecs,
        returnType: retType
      )

      globalCFFIRegistry.loadFunction(cffiInfo.library, funcName, cffiInfo.symbol, signature)

    let exitCode = runRegProgram(prog, verbose = false)
    return CompilerResult(success: true, exitCode: exitCode)
  except Exception as e:
    return CompilerResult(success: false, error: "Failed to run cached bytecode: " & e.msg)

proc saveBytecodeToCache*(regProg: RegBytecodeProgram, bytecodeFile: string) =
  try:
    let bytecodeDir = bytecodeFile.splitFile.dir
    if not dirExists(bytecodeDir):
      createDir(bytecodeDir)
    saveRegBytecode(regProg, bytecodeFile)
    echo "Cached bytecode to: ", bytecodeFile
  except Exception as e:
    echo "Warning: Failed to cache bytecode: ", e.msg

proc compileAndRun*(options: CompilerOptions): CompilerResult =
  ## Main compilation and execution function
  echo "Compiling: ", options.sourceFile
  logCompiler(options.verbose, "Compilation options: runVM=" & $options.runVM & ", verbose=" & $options.verbose)

  try:
    # Parse and typecheck
    let (prog, srcHash, evaluatedGlobals) = parseAndTypecheck(options)

    # Compile to register VM bytecode
    logCompiler(options.verbose, "Compiling to register VM bytecode")
    var regProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, options.sourceFile, options)
    logCompiler(options.verbose, "Register VM bytecode compilation complete (" & $regProg.instructions.len & " instructions)")

    # Add CFFI info from the registry
    for funcName, cffiFunc in globalCFFIRegistry.functions:
      var paramTypes: seq[string] = @[]
      for param in cffiFunc.signature.params:
        paramTypes.add($param.typ.kind)

      # Get the actual library path from the registry
      let libraryPath = if cffiFunc.library in globalCFFIRegistry.libraries:
        let path = globalCFFIRegistry.libraries[cffiFunc.library].path
        logCompiler(options.verbose, "CFFI function " & funcName & " uses library " & cffiFunc.library & " at path: " & path)
        path
      else:
        logCompiler(options.verbose, "CFFI function " & funcName & " library " & cffiFunc.library & " NOT in registry!")
        ""

      regProg.cffiInfo[funcName] = regvm.CFFIInfo(
        library: cffiFunc.library,
        libraryPath: libraryPath,
        symbol: cffiFunc.symbol,
        baseName: cffiFunc.symbol,
        paramTypes: paramTypes,
        returnType: $cffiFunc.signature.returnType.kind
      )

    # Save bytecode to cache
    let bytecodeFile = getBytecodeFileName(options.sourceFile)
    logCompiler(options.verbose, "Saving bytecode cache to: " & bytecodeFile)
    saveBytecodeToCache(regProg, bytecodeFile)

    # Check if we should run the VM
    var exitCode = 0
    if options.runVM:
      logCompiler(options.verbose, "Starting Register VM execution")
      exitCode = runRegProgram(regProg, options.verbose)
      logCompiler(options.verbose, "Register VM execution finished with exit code: " & $exitCode)

    logCompiler(options.verbose, "Compilation completed successfully")
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

  logCompiler(options.verbose, "Checking for cached bytecode at: " & bytecodeFile)

  # Check if we can use cached bytecode
  if options.runVM and not shouldRecompile(options.sourceFile, bytecodeFile, options):
    logCompiler(options.verbose, "Using cached bytecode")
    let cachedResult = runCachedBytecode(bytecodeFile)
    if cachedResult.success:
      logCompiler(options.verbose, "Cached bytecode execution successful")
      return cachedResult
    else:
      logCompiler(options.verbose, "Cached bytecode execution failed: " & cachedResult.error)
      echo cachedResult.error
      echo "Recompiling..."

  # Compile from source
  logCompiler(options.verbose, "Compiling from source")
  return compileAndRun(options)