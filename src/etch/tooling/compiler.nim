# compiler.nim
# Etch compiler: compilation and execution orchestration

import std/[os, tables, times, strformat, hashes, options, strutils]
import ../common/[constants, types, cffi, errors, logging]
import ../core/[vm_execution, vm_cffi, vm_types]
import ../bytecode/[compiler, serialize, modules, comptime, libraries]
import ../bytecode/frontend/[ast, lexer, parser, visitor]
import ../bytecode/ast_passes/[base, inlining, cleanup]  # AST optimization passes
import ../bytecode/typechecker/[core, types, statements, inference]
import ../bytecode/prover/core


type
  CompilerResult* = object
    success*: bool
    exitCode*: int
    error*: string


# Forward declarations
proc hasImpureCall(expr: Expression): bool


proc getBytecodeFileName*(sourceFile: string): string =
  ## Get the bytecode filename for a source file in bytecode subfolder
  let (dir, name, _) = splitFile(sourceFile)
  let etchDir = joinPath(dir, BYTECODE_CACHE_DIR)
  joinPath(etchDir, name & BYTECODE_FILE_EXTENSION)


proc hashSourceAndFlags*(source: string, options: CompilerOptions): string =
  ## Generate a hash of the source code + compiler options for cache validation
  let optimizeLevel = if options.debug: 0 else: 1
  let combinedHash = hashes.hash(&"{source} {COMPILER_BUILD_HASH} {BYTECODE_VERSION} {optimizeLevel}")
  $combinedHash


proc shouldRecompileBytecode*(sourceFile, bytecodeFile: string, source: string, options: CompilerOptions): bool =
  ## Check if bytecode needs recompilation
  ## Validates: file existence, modification time, and source hash (which includes version and flags)
  if options.force:
    logCompiler(options.verbose, "  -> Force recompilation requested")
    return true

  if not fileExists(bytecodeFile):
    logCompiler(options.verbose, "  -> Bytecode file does not exist")
    return true

  # Check modification times
  let sourceTime = getLastModificationTime(sourceFile)
  let bytecodeTime = getLastModificationTime(bytecodeFile)
  if sourceTime > bytecodeTime:
    logCompiler(options.verbose, "  -> Source file is newer than bytecode")
    return true

  # Read and validate bytecode header
  let header = readBytecodeHeader(bytecodeFile)
  if not header.valid:
    logCompiler(options.verbose, "  -> Bytecode header is invalid")
    return true

  # Compare hash
  let currentHash = hashSourceAndFlags(source, options)
  if header.sourceHash != currentHash:
    logCompiler(options.verbose, &"  -> Hash mismatch (stored: {header.sourceHash}, current: {currentHash})")
    return true

  # Bytecode is up to date
  logCompiler(options.verbose, "  -> Bytecode is up to date")
  return false


proc shouldRecompileC*(sourceFile, cFile, exeFile: string): bool =
  ## Check if C backend output needs recompilation
  if not fileExists(cFile) or not fileExists(exeFile):
    return true

  let sourceTime = getLastModificationTime(sourceFile)
  let exeTime = getLastModificationTime(exeFile)
  if sourceTime > exeTime:
    return true

  return false


proc ensureMainInst(prog: Program) =
  ## Ensure main function instance exists if main template is non-generic
  let mainOverloads = prog.getFunctionOverloads(MAIN_FUNCTION_NAME)
  if mainOverloads.len == 0:
    return

  # For main, we expect only one overload with no arguments
  var mainFunc: FunctionDeclaration = nil
  for overload in mainOverloads:
    if overload.typarams.len == 0 and overload.params.len == 0:
      mainFunc = overload
      break

  if mainFunc == nil or prog.funInstances.hasKey(MAIN_FUNCTION_NAME):
    return

  prog.funInstances[MAIN_FUNCTION_NAME] = FunctionDeclaration(
    name: MAIN_FUNCTION_NAME,
    typarams: @[],
    params: mainFunc.params,
    ret: mainFunc.ret,
    hasExplicitReturnType: mainFunc.hasExplicitReturnType,
    body: mainFunc.body,
    isExported: mainFunc.isExported,
    isCFFI: mainFunc.isCFFI,
    isHost: mainFunc.isHost,
    isBuiltin: mainFunc.isBuiltin,
    pos: mainFunc.pos)


proc returnsResultType(retType: EtchType): bool =
  if retType.isNil:
    return false
  case retType.kind
  of tkResult:
    true
  of tkCoroutine:
    retType.inner != nil and retType.inner.kind == tkResult
  else:
    false


proc resetResultPropagationState(fd: FunctionDeclaration) =
  fd.usesResultPropagation = false
  fd.resultPropagationInner = nil
  fd.resultPropagationPos = none(Pos)


proc wrapReturnsWithOk(stmts: var seq[Statement]; resultType: EtchType)


proc wrapReturnsWithOk(stmt: var Statement; resultType: EtchType) =
  case stmt.kind
  of skReturn:
    if stmt.re.isSome and not resultType.inner.isNil:
      let expr = stmt.re.get()
      if expr.typ.isNil or expr.typ.kind == tkResult:
        return
      if not canAssignDistinct(resultType.inner, expr.typ):
        raise newTypecheckError(expr.pos, &"return type mismatch: expected {resultType.inner}, got {expr.typ}")
      let wrapped = Expression(kind: ekResultOk, okExpression: expr, pos: expr.pos)
      wrapped.okExpression.typ = expr.typ
      wrapped.typ = resultType
      stmt.re = some(wrapped)
  of skIf:
    wrapReturnsWithOk(stmt.thenBody, resultType)
    for branch in mitems(stmt.elifChain):
      wrapReturnsWithOk(branch.body, resultType)
    wrapReturnsWithOk(stmt.elseBody, resultType)
  of skWhile:
    wrapReturnsWithOk(stmt.wbody, resultType)
  of skFor:
    wrapReturnsWithOk(stmt.fbody, resultType)
  of skComptime:
    wrapReturnsWithOk(stmt.cbody, resultType)
  of skDefer:
    wrapReturnsWithOk(stmt.deferBody, resultType)
  of skBlock:
    wrapReturnsWithOk(stmt.blockBody, resultType)
  else:
    discard


proc wrapReturnsWithOk(stmts: var seq[Statement]; resultType: EtchType) =
  for stmt in mitems(stmts):
    wrapReturnsWithOk(stmt, resultType)


proc returnTypesFromInfos(infos: seq[ReturnInfo]): seq[EtchType] =
  result = @[]
  for info in infos:
    if info.hasValue:
      result.add(info.typ)
    else:
      result.add(tVoid())


proc finalizeFunctionReturnType(fd: FunctionDeclaration; returnInfos: seq[ReturnInfo]) =
  if fd.isBuiltin or fd.isHost or fd.isAsync or fd.isCFFI:
    return

  let returnTypes = returnTypesFromInfos(returnInfos)

  proc applyInferredResultType() =
    let inferredResultType = tResult(fd.resultPropagationInner)
    wrapReturnsWithOk(fd.body, inferredResultType)
    fd.ret = inferredResultType

  if fd.ret.isNil:
    if not fd.resultPropagationInner.isNil:
      applyInferredResultType()
    elif returnTypes.len > 0:
      let firstReturnPos = if returnInfos.len > 0: returnInfos[0].pos else: fd.pos
      fd.ret = inferReturnType(returnTypes, firstReturnPos)
    else:
      fd.ret = tVoid()
  elif fd.ret.kind == tkVoid and not fd.resultPropagationInner.isNil:
    applyInferredResultType()
  elif not fd.hasExplicitReturnType and not returnsResultType(fd.ret) and not fd.resultPropagationInner.isNil:
    applyInferredResultType()

  if fd.ret.kind != tkVoid and returnInfos.len == 0:
    let errPos = if fd.resultPropagationPos.isSome: fd.resultPropagationPos.get() else: fd.pos
    var msg = &"function '{fd.name}' must return a value of type {fd.ret}"
    if fd.usesResultPropagation:
      msg.add(" (add 'return ok(...)' on the success path when using '?')")
    raise newTypecheckError(errPos, msg)


proc ensureResultPropagationCompatibility(fd: FunctionDeclaration) =
  if not fd.usesResultPropagation:
    return
  if returnsResultType(fd.ret):
    return
  let errPos = if fd.resultPropagationPos.isSome: fd.resultPropagationPos.get() else: fd.pos
  raise newTypecheckError(errPos, "? operator can only be used inside functions returning result[T]")


proc ensureMainReturnRules(fd: FunctionDeclaration) =
  if fd.name != MAIN_FUNCTION_NAME:
    return

  var retType = fd.ret
  if retType.isNil:
    retType = tVoid()

  if retType.kind in {tkVoid, tkInt}:
    return

  let errPos = if fd.resultPropagationPos.isSome: fd.resultPropagationPos.get() else: fd.pos
  let msg = &"main cannot return other than void or int, returning '{retType}'"
  raise newTypecheckError(errPos, msg)


proc functionContainsYield(fun: FunctionDeclaration): bool =
  ## Helper function: Check if a function contains any yields
  let ctx = ASTVisitorContext(skipLambdas: true, skipComptime: true)
  for stmt in fun.body:
    if visitStatement(stmt, proc(e: Expression): bool = e.kind == ekYield, ctx):
      return true
  return false


proc determineCoroutineInnerType(fun: FunctionDeclaration): EtchType =
  ## Determine coroutine inner type from typed yields/returns and enforce invariants
  let yieldTypes = collectYieldTypesFromTypedAST(fun.body)
  let returnInfos = collectReturnTypesFromTypedAST(fun.body)

  var innerType: EtchType = tVoid()

  if yieldTypes.len > 0:
    let firstYieldType = yieldTypes[0]
    for i in 1..<yieldTypes.len:
      if not typeEq(firstYieldType, yieldTypes[i]):
        raise newCompileError(fun.pos, &"conflicting yield types in function {fun.name}: {firstYieldType} and {yieldTypes[i]}")
    innerType = firstYieldType

  var valuedReturnTypes: seq[EtchType] = @[]
  for info in returnInfos:
    if info.hasValue:
      valuedReturnTypes.add(info.typ)

  if valuedReturnTypes.len > 0:
    let firstReturnType = valuedReturnTypes[0]
    for i in 1..<valuedReturnTypes.len:
      if not typeEq(firstReturnType, valuedReturnTypes[i]):
        raise newCompileError(fun.pos, &"conflicting return types in function {fun.name}: {firstReturnType} and {valuedReturnTypes[i]}")

    if yieldTypes.len > 0:
      if not typeEq(innerType, firstReturnType):
        raise newCompileError(fun.pos, &"yield type {innerType} and return type {firstReturnType} in coroutine {fun.name} must match")
    else:
      innerType = firstReturnType

  if innerType.kind != tkVoid:
    if valuedReturnTypes.len == 0:
      raise newCompileError(fun.pos, &"coroutine {fun.name} yields {innerType} but never returns a {innerType} value")
    for info in returnInfos:
      if not info.hasValue:
        raise newCompileError(info.pos, &"coroutine returning {innerType} cannot use 'return;' without a value")

  return innerType

proc findFirstYieldPos(fun: FunctionDeclaration): Option[Pos] =
  ## Find position of first yield expression in function body
  var resultPos: Option[Pos] = none(Pos)
  let ctx = ASTVisitorContext(skipLambdas: true, skipComptime: true)
  for stmt in fun.body:
    discard visitStatement(stmt, proc(e: Expression): bool =
      if e.kind == ekYield and resultPos.isNone:
        resultPos = some(e.pos)
      return false  # Continue searching
    , ctx)
    if resultPos.isSome:
      break
  return resultPos


proc syncInstanceReturnTypes(prog: Program; templ: FunctionDeclaration) =
  ## Ensure previously instantiated versions of a template use the latest return metadata
  for key, inst in prog.funInstances.mpairs:
    if inst.body == templ.body:
      inst.ret = templ.ret
      inst.isAsync = templ.isAsync


proc tryTypecheckTemplateFunction(prog: Program; f: FunctionDeclaration; options: CompilerOptions; subst: var Table[string, EtchType]): bool =
  ## Try type checking a template function without an explicit return type.
  ## Returns true on success, false if dependencies are still pending.
  var sc = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: prog.types, prog: prog)

  for p in f.params:
    sc.types[p.name] = p.typ

  for v in prog.globals:
    if v.kind == skVar:
      sc.types[v.vname] = v.vtype
      sc.flags[v.vname] = v.vflag

  resetResultPropagationState(f)

  try:
    if functionContainsYield(f):
      f.ret = tCoroutine(tVoid())
      f.isAsync = true

      for s in f.body:
        typecheckStatement(prog, f, sc, s, subst)

      let innerType = determineCoroutineInnerType(f)
      f.ret = tCoroutine(innerType)
      logTypecheck(options.verbose, &"Coroutine template {f.name} inferred inner type {innerType}")
    else:
      for s in f.body:
        typecheckStatement(prog, f, sc, s, subst)
      let returnInfos = collectReturnTypesFromTypedAST(f.body)
      finalizeFunctionReturnType(f, returnInfos)
    syncInstanceReturnTypes(prog, f)
    return true
  except ReturnTypePendingError as pending:
    logTypecheck(options.verbose, &"Deferring type inference for {f.name}: waiting on '{pending.missingFunction}'")
    return false


proc ensureAllNonGenericInst(prog: Program, options: CompilerOptions) =
  ## Instantiate all non-generic functions so they're available for comptime evaluation
  for _, overloads in prog.funs:
    for f in overloads:
      if f.typarams.len != 0 or f.name == MAIN_FUNCTION_NAME:
        # Non-generic function, skip main (handled separately)
        continue

      # Generate unique key for overload
      let key = generateOverloadSignature(f)
      if prog.funInstances.hasKey(key):
        continue

      logCompiler(options.verbose, &"Creating function instance: {key} for {f.name}")

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

      # Check if function contains yields and validate return type
      var finalRet = resolvedRet
      var isAsync = f.isAsync
      if functionContainsYield(f):
        isAsync = true
        if finalRet != nil:
          # If return type was explicitly specified, it must be a coroutine type
          if finalRet.kind != tkCoroutine:
            var finalPos = f.pos
            let yieldPosOpt = findFirstYieldPos(f)
            if yieldPosOpt.isSome:
              finalPos = yieldPosOpt.get
            raise newCompileError(finalPos, &"function {f.name} contains 'yield' but has non-coroutine return type {finalRet}. Use '-> coroutine[{finalRet}]' instead.")
        else:
          # Function returns void, so wrap in coroutine[void]
          finalRet = tCoroutine(tVoid())

      prog.funInstances[key] = FunctionDeclaration(
        name: key,
        typarams: @[],
        params: resolvedParams,
        ret: finalRet,
        hasExplicitReturnType: f.hasExplicitReturnType,
        body: f.body,
        isExported: f.isExported,
        isCFFI: f.isCFFI,
        isHost: f.isHost,
        isAsync: isAsync,
        isBuiltin: f.isBuiltin,
        pos: f.pos)


proc hasImpureCall(expr: Expression): bool =
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


proc compileProgramWithGlobals*(prog: Program, sourceHash: string, evaluatedGlobals: Table[string, GlobalValue], sourceFile: string = "", options: CompilerOptions, moduleRegistry: ModuleRegistry, cffiRegistry: CFFIRegistry): BytecodeProgram =
  ## Compile an AST program to register VM bytecode and attach CFFI metadata

  # Use optimization level 0 in debug mode, 1 in release mode
  let optimizeLevel = if options.debug: 0 else: 1
  result = compileProgram(prog, optimizeLevel = optimizeLevel, verbose = options.verbose, debug = options.debug)

  if cffiRegistry != nil:
    result.cffiRegistry = cffiRegistry
    result.updateCFFIFunctions(options.verbose, cffiRegistry, updateExisting = true)


proc parseAndTypecheck*(options: CompilerOptions): (Program, string, Table[string, GlobalValue], ModuleRegistry, CFFIRegistry) =
  ## Parse source file and perform type checking, return AST, hash, evaluated globals,
  ## the module registry and the per-compilation CFFI registry
  logCompiler(options.verbose, &"Starting compilation of {options.sourceFile}")

  var moduleRegistry = newModuleRegistry()
  var cffiRegistry: CFFIRegistry = nil

  # Get source code - either from string or file
  let src = if options.sourceString.isSome:
    let sourceCode = options.sourceString.get()
    logCompiler(options.verbose, &"Compiling from string ({sourceCode.len} characters)")
    sourceCode
  else:
    let content = readFile(options.sourceFile)
    logCompiler(options.verbose, &"Read source file ({content.len} characters)")
    content

  let srcHash = hashSourceAndFlags(src, options)
  logCompiler(options.verbose, &"Source hash: {srcHash}")

  let toks = lex(src, options.sourceFile)
  logCompiler(options.verbose, &"Lexed {toks.len} tokens")

  var prog = parseProgram(toks, options.sourceFile)
  logCompiler(options.verbose, &"Parsed AST with {prog.funs.len} functions and {prog.globals.len} globals")

  # Process imports - load modules and FFI functions
  logCompiler(options.verbose, "Processing imports")
  moduleRegistry.processImports(cffiRegistry, prog, options.sourceFile)
  logCompiler(options.verbose, &"After imports: {prog.funs.len} functions and {prog.globals.len} globals")

  # Register destructors with their types
  logCompiler(options.verbose, "Registering destructors")
  for name, overloads in prog.funs:
    # Check if this is a destructor (name starts with ~)
    if not name.startsWith("~") or name.len <= 1:
      continue

    let typeName = name[1..^1]  # Remove ~ prefix
    if prog.types.hasKey(typeName):
      # Set the destructor field on the type
      prog.types[typeName].destructor = some(name)
      logCompiler(options.verbose, &"Registered destructor ~{typeName} for type {typeName}")

      # Also add destructor to funInstances so it gets compiled into bytecode
      # Destructors are never explicitly called in user code, so they won't be
      # instantiated automatically - we need to do it manually
      if overloads.len > 0:
        let destructor = overloads[0]  # Destructors don't have overloads
        prog.funInstances[name] = destructor
        logCompiler(options.verbose, &"Added destructor {name} to funInstances for bytecode compilation")

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
  var pendingTemplates: seq[FunctionDeclaration] = @[]
  for name, overloads in prog.funs:
    discard name
    for f in overloads:
      if f.typarams.len != 0 or f.ret != nil:
        continue
      pendingTemplates.add(f)

  while pendingTemplates.len > 0:
    var deferred: seq[FunctionDeclaration] = @[]
    var progress = false
    for f in pendingTemplates:
      logTypecheck(options.verbose, &"Type-checking template function {f.name} with {f.params.len} params")
      if tryTypecheckTemplateFunction(prog, f, options, subst):
        progress = true
      else:
        deferred.add(f)
    if not progress:
      var blockedNames: seq[string] = @[]
      for f in deferred:
        blockedNames.add(f.name)
      let blockedList = blockedNames.join(", ")
      let errPos = deferred[0].pos
      raise newTypecheckError(errPos, &"could not infer return types for functions: {blockedList}. Add explicit return types to break the dependency cycle")
    pendingTemplates = deferred

  # Collect keys first to avoid modifying table while iterating
  var instanceKeys: seq[string] = @[]
  for k in keys(prog.funInstances): instanceKeys.add(k)

  for k in instanceKeys:
    let f = prog.funInstances[k]

    logTypecheck(options.verbose, &"Type-checking instantiated function {f.name} with {f.params.len} params")

    var sc = Scope(types: initTable[string, EtchType](), flags: initTable[string, VarFlag](), userTypes: prog.types, prog: prog)

    for p in f.params:
      sc.types[p.name] = p.typ

    for v in prog.globals:
      if v.kind == skVar:
        sc.types[v.vname] = v.vtype
        sc.flags[v.vname] = v.vflag

    resetResultPropagationState(f)

    let containsYield = functionContainsYield(f)
    if containsYield:
      f.isAsync = true
      if f.ret == nil:
        f.ret = tCoroutine(tVoid())

    for s in f.body: typecheckStatement(prog, f, sc, s, subst)

    if containsYield:
      # After type checking, collect yield and return types and update coroutine return type
      let innerType = determineCoroutineInnerType(f)
      f.ret = tCoroutine(innerType)
      logTypecheck(options.verbose, &"Coroutine instance {f.name} inferred inner type {innerType}")
    else:
      let returnInfos = collectReturnTypesFromTypedAST(f.body)
      finalizeFunctionReturnType(f, returnInfos)

    ensureResultPropagationCompatibility(f)
    ensureMainReturnRules(f)

  # Second fold pass for compiles{...} expressions now that type environment is available
  logCompiler(options.verbose, "Folding compiles expressions with type environment")
  foldCompilesExpressions(prog, prog)

  # Evaluate global variables with full expression support
  logCompiler(options.verbose, "Evaluating global variables")
  let evaluatedGlobals = evaluateGlobalVariables(prog)
  logCompiler(options.verbose, &"Evaluated {evaluatedGlobals.len} global variables")

  # Run AST optimization passes (inlining, cleanup, etc.) only in release mode
  # VERY conservative inlining (max 2 statements) to avoid register overflow
  if not options.debug:
    logCompiler(options.verbose, "Running AST optimization passes")
    let astPasses: seq[tuple[name: string, pass: PassFunction]] = @[
      (name: "function-inlining", pass: inliningPass),
      (name: "cleanup", pass: cleanupPass)
    ]
    let passStats = runPassesOnProgram(astPasses, prog, options.verbose)
    logCompiler(options.verbose, &"AST optimization complete: {passStats.functionsInlined} functions inlined, {passStats.deadCodeEliminated} dead statements removed")
  else:
    logCompiler(options.verbose, "Skipping AST optimization passes (debug mode)")

  # Run safety prover to ensure all variables are initialized
  logCompiler(options.verbose, "Running safety prover")
  prove(prog, options.sourceFile, options)
  logCompiler(options.verbose, "Safety proof complete")

  logCompiler(options.verbose, "Parse and typecheck phase complete")
  return (prog, srcHash, evaluatedGlobals, moduleRegistry, cffiRegistry)


proc runBytecode*(bytecodeFile: string, verbose: bool = false, profile: bool = false, perfetto: bool = false, perfettoOutput: string = ""): CompilerResult =
  try:
    let prog = loadBytecode(bytecodeFile)

    # Rebuild CFFI registry for this cached bytecode using the function
    # metadata stored in prog.functions, and attach it to prog so the VM
    # can use it just like in the fresh compilation path.
    var registry = newCFFIRegistry()

    for funcName, funcInfo in prog.functions:
      if funcInfo.kind == fkCFFI:
        if funcInfo.library notin registry.libraries:
          let (normalizedName, actualPath) = resolveLibraryPath(funcInfo.library)

          var loaded = false
          if actualPath != "":
            try:
              discard registry.loadLibrary(normalizedName, actualPath)
              loaded = true
            except:
              let foundPath = findLibraryInSearchPaths(actualPath)
              if foundPath != "":
                try:
                  discard registry.loadLibrary(normalizedName, foundPath)
                  loaded = true
                except:
                  discard

          if not loaded:
            raise newException(IOError, &"Failed to load library: {funcInfo.library}")

        var paramSpecs: seq[cffi.ParamSpec] = @[]
        for i, paramType in funcInfo.paramTypes:
          paramSpecs.add(cffi.ParamSpec(name: &"arg {i}", typ: etchTypeFromString(paramType)))

        let signature = cffi.FunctionSignature(
          params: paramSpecs,
          returnType: etchTypeFromString(funcInfo.returnType)
        )

        registry.loadFunction(funcInfo.library, funcName, funcInfo.symbol, signature)

    prog.cffiRegistry = registry

    let (exitCode, _) = if profile:
      runProgramWithProfiler(prog, verbose)
    elif perfetto:
      runProgramWithPerfetto(prog, perfettoOutput, verbose)
    else:
      runProgram(prog, verbose)

    return CompilerResult(success: true, exitCode: exitCode)
  except Exception as e:
    return CompilerResult(success: false, error: &"Failed to run cached bytecode: {e.msg}")


proc saveBytecodeToCache*(regProg: BytecodeProgram, bytecodeFile: string, sourceHash: string, sourceFile: string, options: CompilerOptions) =
  try:
    let bytecodeDir = bytecodeFile.splitFile.dir
    if not dirExists(bytecodeDir):
      createDir(bytecodeDir)

    # Prepare compiler flags
    let optimizeLevel = if options.debug: 0 else: 1
    let flags = CompilerFlags(verbose: options.verbose, debug: options.debug, optimizeLevel: optimizeLevel)

    saveBytecode(regProg, bytecodeFile, sourceHash, PROGRAM_VERSION, sourceFile, flags)

    stderr.writeLine &"Cached bytecode to: {bytecodeFile}"
  except Exception as e:
    stderr.writeLine &"Warning: Failed to cache bytecode: {e.msg}"


proc compileAndRun*(options: CompilerOptions): CompilerResult =
  ## Main compilation and execution function
  stderr.writeLine &"Compiling: {options.sourceFile}"
  logCompiler(options.verbose, &"Compilation options: runVirtualMachine={options.runVirtualMachine}, verbose={options.verbose}")

  # Collect for error reporting
  var sourceLines = if options.sourceString.isSome:
      let sourceCode = options.sourceString.get()
      sourceCode.splitLines()
    else:
      @[]

  try:
    # Parse and typecheck
    let (prog, srcHash, evaluatedGlobals, moduleRegistry, cffiRegistry) = parseAndTypecheck(options)

    # Compile to register VM bytecode
    logCompiler(options.verbose, "Compiling to register VM bytecode")
    var regProg = compileProgramWithGlobals(prog, srcHash, evaluatedGlobals, options.sourceFile, options, moduleRegistry, cffiRegistry)
    logCompiler(options.verbose, &"Register VM bytecode compilation complete ({regProg.instructions.len} instructions)")

    # Save bytecode to cache
    let bytecodeFile = getBytecodeFileName(options.sourceFile)
    logCompiler(options.verbose, &"Saving bytecode cache to: {bytecodeFile}")
    saveBytecodeToCache(regProg, bytecodeFile, srcHash, options.sourceFile, options)

    # Check if we should run the VM
    if options.runVirtualMachine:
      return runBytecode(bytecodeFile, options.verbose, options.profile, options.perfetto, options.perfettoOutput)

    logCompiler(options.verbose, "Compilation completed successfully")
    return CompilerResult(success: true, exitCode: 0)

  except EtchError as e:
    let errorMessage = formatError(e.pos, e.msg, sourceLines)
    return CompilerResult(success: false, error: errorMessage, exitCode: 1)

  except IOError as e:
    return CompilerResult(success: false, error: &"File error: {e.msg}", exitCode: 1)

  except Exception as e:
    return CompilerResult(success: false, error: &"Internal compiler error: {e.msg}", exitCode: 2)


proc tryRunCachedOrCompile*(options: CompilerOptions): CompilerResult =
  ## Try to run cached bytecode, fall back to compilation if needed
  let bytecodeFile = getBytecodeFileName(options.sourceFile)

  logCompiler(options.verbose, &"Checking for cached bytecode at: {bytecodeFile}")

  # Check if we can use cached bytecode
  if options.runVirtualMachine:
    # Read source to compute hash for validation
    let src = if options.sourceString.isSome:
      options.sourceString.get()
    else:
      try:
        readFile(options.sourceFile)
      except IOError:
        ""

    if src != "" and not shouldRecompileBytecode(options.sourceFile, bytecodeFile, src, options):
      echo &"Using cached bytecode: {bytecodeFile}"
      return runBytecode(bytecodeFile, options.verbose, options.profile, options.perfetto, options.perfettoOutput)

  # Compile from source
  logCompiler(options.verbose, "Compiling from source")
  return compileAndRun(options)
