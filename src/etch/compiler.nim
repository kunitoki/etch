# compiler.nim
# Etch compiler: compilation and execution orchestration

import std/[os, tables, times, options, strformat]
import frontend/[ast, lexer, parser]
import typechecker/[core, types, statements, inference]
import interpreter/[vm, bytecode, serialize]
import prover/[core]
import comptime, common/errors
import common/[constants, logging, cffi, library_resolver]
import module_system

type
  CompilerResult* = object
    success*: bool
    exitCode*: int
    error*: string

  CompilerOptions* = object
    sourceFile*: string
    runVM*: bool
    verbose*: bool
    debug*: bool

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
    let flags = CompilerFlags(verbose: options.verbose, debug: options.debug)
    let currentHash = hashSourceAndFlags(sourceContent, flags)
    let prog = loadBytecode(bytecodeFile)
    return prog.sourceHash != currentHash
  except:
    return true  # Recompile if we can't read bytecode

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

proc ensureAllNonGenericInst(prog: Program, flags: CompilerFlags) =
  ## Instantiate all non-generic functions so they're available for comptime evaluation
  for name, overloads in prog.funs:
    for f in overloads:
      if f.typarams.len == 0 and f.name != MAIN_FUNCTION_NAME:  # Non-generic function, skip main (handled separately)
        # Generate unique key for overload
        let key = generateOverloadSignature(f)
        if flags.verbose:
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
proc hasImpureCallInStmt(stmt: Stmt): bool

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

proc hasImpureCallInStmt(stmt: Stmt): bool =
  ## Check if a statement contains impure calls
  case stmt.kind
  of skExpr:
    return hasImpureCall(stmt.sexpr)
  of skReturn:
    if stmt.re.isSome:
      return hasImpureCall(stmt.re.get)
  of skVar:
    if stmt.vinit.isSome:
      return hasImpureCall(stmt.vinit.get)
  of skAssign:
    return hasImpureCall(stmt.aval)
  else:
    return false

proc hasImpureCallInFunction(fn: FunDecl): bool =
  ## Check if a function body contains impure calls
  for stmt in fn.body:
    if hasImpureCallInStmt(stmt):
      return true
  return false

proc canEvaluateAtCompileTime(expr: Expr, prog: Program): bool =
  ## Check if an expression should be evaluated at compile time
  ## Returns false for expressions with side effects
  case expr.kind
  of ekCall:
    # Check if this is a user-defined function with side effects
    if prog.funInstances.hasKey(expr.fname):
      let fn = prog.funInstances[expr.fname]
      if hasImpureCallInFunction(fn):
        return false
    # Also check if it's a built-in impure function
    return not hasImpureCall(expr)
  else:
    return not hasImpureCall(expr)

proc evaluateGlobalVariables(prog: Program): Table[string, V] =
  ## Evaluate global variable initialization expressions using bytecode
  ## Returns a table of evaluated global values for bytecode compilation
  ## For complex expressions, returns empty table to let runtime handle them
  var globalVars = initTable[string, V]()

  # Only evaluate expressions without side effects at compile time
  # Let expressions with side effects execute at runtime
  for g in prog.globals:
    if g.kind == skVar and g.vinit.isSome():
      # Check if this expression has side effects
      if canEvaluateAtCompileTime(g.vinit.get(), prog):
        try:
          # Evaluate pure expressions at compile time for optimization
          let res = evalExprWithBytecode(prog, g.vinit.get(), globalVars)
          globalVars[g.vname] = res
        except:
          # If evaluation fails, let runtime handle it
          discard
      # For expressions with side effects, don't pre-evaluate
      # Let the runtime bytecode handle the initialization so side effects occur at runtime
    # Don't set default values here - let the bytecode compilation handle defaults

  return globalVars

proc compileProgramWithGlobals*(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, V], sourceFile: string = "", flags: CompilerFlags = CompilerFlags(verbose: false, debug: false)): BytecodeProgram =
  ## Compile an AST program to bytecode with pre-evaluated global values
  # Start with standard compilation
  result = compileProgram(prog, sourceHash, sourceFile, flags)

  # Override global values with evaluated ones
  for name, value in evaluatedGlobals:
    result.globalValues[name] = convertVMValueToGlobalValue(value)

proc parseAndTypecheck*(options: CompilerOptions): (Program, string, Table[string, V]) =
  ## Parse source file and perform type checking, return AST, hash, and evaluated globals
  let flags = CompilerFlags(verbose: options.verbose, debug: options.debug)

  logCompiler(flags, "Starting compilation of " & options.sourceFile)

  # Set up error reporting context
  errors.loadSourceLines(options.sourceFile)

  let src = readFile(options.sourceFile)
  logCompiler(flags, "Read source file (" & $src.len & " characters)")

  let srcHash = hashSourceAndFlags(src, flags)
  logCompiler(flags, "Source hash: " & srcHash)

  let toks = lex(src)
  logCompiler(flags, "Lexed " & $toks.len & " tokens")

  var prog = parseProgram(toks, options.sourceFile)
  logCompiler(flags, "Parsed AST with " & $prog.funs.len & " functions and " & $prog.globals.len & " globals")

  # Process imports - load modules and FFI functions
  logCompiler(flags, "Processing imports")
  globalModuleRegistry.processImports(prog, options.sourceFile)
  logCompiler(flags, "After imports: " & $prog.funs.len & " functions and " & $prog.globals.len & " globals")

  # For this MVP, instantiation occurs when functions are called during typecheck inference.
  # We need a shallow pass to trigger calls in bodies:
  logCompiler(flags, "Starting type checking phase")
  typecheck(prog)
  logCompiler(flags, "Type checking complete")

  # Force monomorphization for main if it is non-generic:
  logCompiler(flags, "Ensuring main function instance")
  ensureMainInst(prog)

  # Instantiate all non-generic functions so they're available for comptime evaluation
  logCompiler(flags, "Instantiating non-generic functions")
  ensureAllNonGenericInst(prog, flags)

  # Fold compile-time expressions BEFORE final type checking so injected variables are available
  logCompiler(flags, "Folding compile-time expressions")
  foldComptime(prog, prog)

  # Now do full type checking with injected variables available
  # Build a trivial scope and walk each instance
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
  logCompiler(flags, "Evaluating global variables")
  let evaluatedGlobals = evaluateGlobalVariables(prog)
  logCompiler(flags, "Evaluated " & $evaluatedGlobals.len & " global variables")

  # Run safety prover to ensure all variables are initialized
  logCompiler(flags, "Running safety prover")
  prove(prog, options.sourceFile, flags)
  logCompiler(flags, "Safety proof complete")

  logCompiler(flags, "Parse and typecheck phase complete")
  return (prog, srcHash, evaluatedGlobals)

proc runCachedBytecode*(bytecodeFile: string): CompilerResult =
  ## Run cached bytecode if available
  echo "Using cached bytecode: ", bytecodeFile
  try:
    let prog = loadBytecode(bytecodeFile)

    # Re-register CFFI functions from cached info
    for cffiInfo in prog.cffiInfo:
      # Try to load the library if not already loaded
      if cffiInfo.library notin globalCFFIRegistry.libraries:
        # Use shared library resolver for consistent resolution
        let (normalizedName, actualPath) = resolveLibraryPath(cffiInfo.library)

        var loaded = false
        # Try with the resolved path first
        if actualPath != "":
          try:
            discard globalCFFIRegistry.loadLibrary(normalizedName, actualPath)
            loaded = true
          except:
            # Try searching in standard paths
            let foundPath = findLibraryInSearchPaths(actualPath)
            if foundPath != "":
              try:
                discard globalCFFIRegistry.loadLibrary(normalizedName, foundPath)
                loaded = true
              except:
                discard

        if not loaded:
          raise newException(IOError, "Failed to load library: " & cffiInfo.library)

      # Convert string type kinds back to EtchType
      var paramSpecs: seq[cffi.ParamSpec] = @[]
      for i, paramType in cffiInfo.paramTypes:
        let typ = case paramType
          of "tkFloat": tFloat()
          of "tkInt": tInt()
          of "tkBool": tBool()
          of "tkString": tString()
          of "tkVoid": tVoid()
          else: tVoid()
        paramSpecs.add(cffi.ParamSpec(name: "arg" & $i, typ: typ))

      let retType = case cffiInfo.returnType
        of "tkFloat": tFloat()
        of "tkInt": tInt()
        of "tkBool": tBool()
        of "tkString": tString()
        of "tkVoid": tVoid()
        else: tVoid()

      let signature = cffi.FunctionSignature(
        params: paramSpecs,
        returnType: retType
      )

      # Re-register the function
      globalCFFIRegistry.loadFunction(cffiInfo.library, cffiInfo.mangledName, cffiInfo.symbol, signature)

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
  let flags = CompilerFlags(verbose: options.verbose, debug: options.debug)

  echo "Compiling: ", options.sourceFile
  logCompiler(flags, "Compilation options: runVM=" & $options.runVM & ", verbose=" & $options.verbose)

  try:
    # Parse and typecheck
    let (prog, srcHash, evaluatedGlobals) = parseAndTypecheck(options)

    # Compile to bytecode
    logCompiler(flags, "Compiling to bytecode")
    var bytecodeProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, options.sourceFile, flags)
    logCompiler(flags, "Bytecode compilation complete (" & $bytecodeProg.instructions.len & " instructions)")

    # Add CFFI info from the registry
    for funcName, cffiFunc in globalCFFIRegistry.functions:
      var paramTypes: seq[string] = @[]
      for param in cffiFunc.signature.params:
        paramTypes.add($param.typ.kind)

      bytecodeProg.cffiInfo.add(CFFIInfo(
        library: cffiFunc.library,
        symbol: cffiFunc.symbol,
        mangledName: funcName,
        paramTypes: paramTypes,
        returnType: $cffiFunc.signature.returnType.kind
      ))

    # Save bytecode to cache
    let bytecodeFile = getBytecodeFileName(options.sourceFile)
    logCompiler(flags, "Saving bytecode cache to: " & bytecodeFile)
    saveBytecodeToCache(bytecodeProg, bytecodeFile)

    # Check if we should run the VM
    var exitCode = 0
    if options.runVM:
      logCompiler(flags, "Starting VM execution")
      let vm = newBytecodeVM(bytecodeProg)
      exitCode = vm.runBytecode()
      logCompiler(flags, "VM execution finished with exit code: " & $exitCode)

    logCompiler(flags, "Compilation completed successfully")
    return CompilerResult(success: true, exitCode: 0)

  except EtchError as e:
    return CompilerResult(success: false, error: e.msg, exitCode: 1)

  except IOError as e:
    return CompilerResult(success: false, error: "File error: " & e.msg, exitCode: 1)

  except Exception as e:
    return CompilerResult(success: false, error: "Internal compiler error: " & e.msg, exitCode: 2)

proc tryRunCachedOrCompile*(options: CompilerOptions): CompilerResult =
  ## Try to run cached bytecode, fall back to compilation if needed
  let flags = CompilerFlags(verbose: options.verbose, debug: options.debug)
  let bytecodeFile = getBytecodeFileName(options.sourceFile)

  logCompiler(flags, "Checking for cached bytecode at: " & bytecodeFile)

  # Check if we can use cached bytecode
  if options.runVM and not shouldRecompile(options.sourceFile, bytecodeFile, options):
    logCompiler(flags, "Using cached bytecode")
    let cachedResult = runCachedBytecode(bytecodeFile)
    if cachedResult.success:
      logCompiler(flags, "Cached bytecode execution successful")
      return cachedResult
    else:
      logCompiler(flags, "Cached bytecode execution failed: " & cachedResult.error)
      echo cachedResult.error
      echo "Recompiling..."

  # Compile from source
  logCompiler(flags, "Compiling from source")
  return compileAndRun(options)