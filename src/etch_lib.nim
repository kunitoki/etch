# etch_lib.nim
# Library entry point for building Etch as a shared/static library

import std/[tables, os, options, strutils]
import ./etch/common/[types, errors]
import ./etch/core/[vm, vm_execution, vm_types]
import ./etch/capabilities/[debugger, debugserver, debugserver_remote]
import ./etch/tooling/compiler


# C-compatible types
type
  # Opaque handles for C API
  EtchContext* = ptr EtchContextObj
  EtchValue* = ptr EtchValueObj
  EtchDebugServer* = ptr EtchDebugServerObj

  # Host function callback type
  # Returns an EtchValue, takes array of arguments and user data pointer
  EtchHostFunction* = proc(ctx: EtchContext,
                           args: ptr ptr EtchValueObj,
                           numArgs: cint,
                           userData: pointer): EtchValue {.cdecl.}

  # Instruction callback type for debugging/inspection
  # Called before each instruction is executed
  # Return 0 to continue, non-zero to stop execution
  EtchInstructionCallback* = proc(ctx: EtchContext, userData: pointer): cint {.cdecl.}

  # Context creation options (matches C header)
  EtchContextOptions* {.exportc.} = object
    verbose*: cint              # Enable verbose logging (0 = off, non-zero = on)
    debug*: cint                # Enable debug mode (0 = release/optimized, non-zero = debug)
    gcCycleInterval*: cint      # GC cycle detection interval in operations (0 = use default 1000)

  # Internal representation (not exposed to C)
  EtchContextObj = object
    vm: VirtualMachine
    program: BytecodeProgram
    lastError: string
    hostFunctions: Table[string, HostFunctionInfo]
    globalOverrides: Table[string, V]  # Globals set via C API before VM execution
    options: CompilerOptions
    instructionCallback: EtchInstructionCallback
    instructionCallbackUserData: pointer
    remoteDebugServer: RemoteDebugServer
    remoteDebugEnabled: bool
    remoteDebugPort: int
    remoteDebugTimeoutMs: int
    remoteDebugInitialWaitDone: bool
    processingDebugRequests: bool
    debugPollCounter: int

  HostFunctionInfo = object
    callback: EtchHostFunction
    userData: pointer

  EtchValueObj = object
    value: V

  EtchDebugServerObj = object
    server: DebugServer
    sourceFile: string


# ============================================================================
# Remote Debugging Helpers
# ============================================================================

const
  REMOTE_DEBUG_POLL_INTERVAL = 32


proc normalizeSourcePath(path: string): string =
  if path.len == 0:
    return path
  if path[0] == '<':  # synthetic sources like <string>
    return path
  try:
    if path.isAbsolute:
      return path
    return absolutePath(path)
  except OSError:
    return path


proc beginDebugRequestSection(ctx: EtchContext): bool =
  if ctx == nil:
    return false
  if ctx.processingDebugRequests:
    return false
  ctx.processingDebugRequests = true
  return true


proc endDebugRequestSection(ctx: EtchContext) =
  if ctx != nil:
    ctx.processingDebugRequests = false


proc remoteDebuggerAvailable(ctx: EtchContext): bool =
  ctx != nil and ctx.remoteDebugEnabled and ctx.remoteDebugServer != nil


proc remoteDebuggerConnected(ctx: EtchContext): bool =
  remoteDebuggerAvailable(ctx) and ctx.remoteDebugServer.isConnected()


proc getContextDebugger(ctx: EtchContext): RegEtchDebugger =
  if not remoteDebuggerAvailable(ctx) or ctx.remoteDebugServer.server.debugger == nil:
    return nil
  return cast[RegEtchDebugger](ctx.remoteDebugServer.server.debugger)


proc installDebuggerPollHook(ctx: EtchContext)


proc teardownRemoteDebugServer(ctx: EtchContext) =
  if ctx == nil:
    return
  let debugger = getContextDebugger(ctx)
  if debugger != nil:
    debugger.setPollCallback(nil)
  if ctx.remoteDebugServer != nil:
    ctx.remoteDebugServer.close()
    ctx.remoteDebugServer = nil
  ctx.debugPollCounter = 0


proc detectRemoteDebugSettings(ctx: EtchContext) =
  if ctx == nil:
    return

  ctx.remoteDebugEnabled = false
  ctx.remoteDebugPort = 0
  ctx.remoteDebugTimeoutMs = 0
  ctx.remoteDebugInitialWaitDone = false

  if not ctx.options.debug:
    return

  let debugPortEnv = getEnv("ETCH_DEBUG_PORT")
  if debugPortEnv.len == 0:
    return

  try:
    let port = parseInt(debugPortEnv)
    if port <= 0:
      raise newException(ValueError, "port must be positive")
    ctx.remoteDebugPort = port
  except ValueError as e:
    stderr.writeLine("WARNING: Invalid ETCH_DEBUG_PORT value: " & e.msg)
    stderr.flushFile()
    return

  try:
    ctx.remoteDebugTimeoutMs = parseInt(getEnv("ETCH_DEBUG_TIMEOUT", "5000"))
    if ctx.remoteDebugTimeoutMs < 0:
      ctx.remoteDebugTimeoutMs = 0
  except ValueError:
    ctx.remoteDebugTimeoutMs = 5000

  ctx.remoteDebugEnabled = true


proc setupVirtualMachine(ctx: EtchContext) =
  if ctx == nil:
    return

  if ctx.remoteDebugEnabled:
    teardownRemoteDebugServer(ctx)
    try:
      let remoteServer = newRemoteDebugServer(ctx.program, ctx.options.sourceFile, ctx.remoteDebugPort)
      remoteServer.server.setHostControlled(true)
      var started = remoteServer.startListening()
      if not started:
        if forceTerminateExistingServer(ctx.remoteDebugPort):
          stderr.writeLine("DEBUG: Existing debug server terminated, retrying bind on port " & $ctx.remoteDebugPort)
          stderr.flushFile()
          started = remoteServer.startListening()
      if not started:
        stderr.writeLine("WARNING: Failed to start remote debug server, continuing without debugger")
        stderr.flushFile()
        ctx.remoteDebugEnabled = false
        ctx.vm = newVirtualMachine(ctx.program)
      else:
        ctx.remoteDebugServer = remoteServer
        ctx.remoteDebugInitialWaitDone = false
        ctx.vm = remoteServer.server.vm
        ctx.debugPollCounter = 0
        installDebuggerPollHook(ctx)
    except Exception as e:
      stderr.writeLine("WARNING: Unable to initialize remote debugger: " & e.msg)
      stderr.flushFile()
      ctx.remoteDebugEnabled = false
      ctx.vm = newVirtualMachine(ctx.program)
  else:
    teardownRemoteDebugServer(ctx)
    ctx.vm = newVirtualMachine(ctx.program)
    ctx.debugPollCounter = 0


proc ensureInitialDebuggerWait(ctx: EtchContext) =
  if not remoteDebuggerAvailable(ctx) or ctx.remoteDebugInitialWaitDone:
    return

  ctx.remoteDebugInitialWaitDone = true

  if ctx.remoteDebugServer.connected:
    return

  if ctx.remoteDebugTimeoutMs > 0:
    stderr.writeLine("DEBUG: Waiting " & $ctx.remoteDebugTimeoutMs & "ms for debugger connection on port " & $ctx.remoteDebugPort)
    stderr.flushFile()
    if beginDebugRequestSection(ctx):
      try:
        discard ctx.remoteDebugServer.acceptConnection(ctx.remoteDebugTimeoutMs)
      finally:
        endDebugRequestSection(ctx)

  if not ctx.remoteDebugServer.connected:
    stderr.writeLine("DEBUG: No debugger connected, continuing execution (still listening)")
    stderr.flushFile()


proc pollDebuggerConnection(ctx: EtchContext, blocking: bool) =
  if not remoteDebuggerAvailable(ctx) or ctx.remoteDebugServer.connected:
    return
  if not beginDebugRequestSection(ctx):
    return
  try:
    if blocking:
      discard ctx.remoteDebugServer.acceptConnection(1)
    else:
      discard ctx.remoteDebugServer.tryAcceptConnection()
  finally:
    endDebugRequestSection(ctx)


proc drainDebuggerRequests(ctx: EtchContext, blocking: bool) =
  if not remoteDebuggerConnected(ctx):
    return
  if not beginDebugRequestSection(ctx):
    return
  try:
    let timeout = (if blocking: 1 else: -1)
    while ctx.remoteDebugServer.processRequests(timeoutMs = timeout):
      discard
  finally:
    endDebugRequestSection(ctx)


proc resumeWithoutDebugger(ctx: EtchContext) =
  if not remoteDebuggerAvailable(ctx) or ctx.remoteDebugServer.server.debugger == nil:
    return
  let debugger = cast[RegEtchDebugger](ctx.remoteDebugServer.server.debugger)
  debugger.continueExecution()


proc waitForDebuggerResume(ctx: EtchContext, sendPauseEvent: bool) =
  if not remoteDebuggerConnected(ctx):
    resumeWithoutDebugger(ctx)
    return

  if not beginDebugRequestSection(ctx):
    return

  try:
    if sendPauseEvent:
      ctx.remoteDebugServer.server.notifyExternalPause()

    let resumed = ctx.remoteDebugServer.processRequests(timeoutMs = 0, untilResume = true)
    if not resumed:
      resumeWithoutDebugger(ctx)
  finally:
    endDebugRequestSection(ctx)


proc executeVmWithDebug(ctx: EtchContext): int =
  if ctx == nil or ctx.vm == nil:
    return -1

  while true:
    let exitCode = ctx.vm.execute(ctx.options.verbose)
    if exitCode == -1:
      if remoteDebuggerAvailable(ctx):
        waitForDebuggerResume(ctx, true)
        continue
      else:
        return exitCode
    return exitCode


proc installDebuggerPollHook(ctx: EtchContext) =
  if not remoteDebuggerAvailable(ctx):
    return
  let debugger = getContextDebugger(ctx)
  if debugger == nil:
    return
  let weakCtx = ctx
  debugger.setPollCallback(proc() =
    if weakCtx == nil:
      return
    weakCtx.debugPollCounter.inc
    if weakCtx.debugPollCounter < REMOTE_DEBUG_POLL_INTERVAL:
      return
    weakCtx.debugPollCounter = 0
    pollDebuggerConnection(weakCtx, false)
    drainDebuggerRequests(weakCtx, false)
  )


proc callEtchFunctionByName(ctx: EtchContext, funcName: string, args: ptr ptr EtchValueObj, numArgs: cint): EtchValue =
  ## Call an Etch function by name with arguments (internal implementation)
  ## Returns: Result value or nil on error

  if ctx == nil or ctx.vm == nil:
    return nil

  var actualFuncName = funcName
  if not ctx.program.functions.hasKey(actualFuncName):
    # Debug: list available functions
    var availableFuncs: string = ""
    var exactFuncName: string = ""  # Will hold the corrected function name

    for name, funcInfo in ctx.program.functions:
      availableFuncs &= name & " "
      # Also check if the function name is in the functionTable (without signature)
      if name.startsWith(funcName & "::"):
        # This is the function we're looking for, use the exact name from the function table
        exactFuncName = name
        if ctx.options.verbose and funcInfo.kind == fkNative:
          echo "Found candidate: " & name & " at PC=" & $funcInfo.startPos
        break

    if exactFuncName == "":
      ctx.lastError = "Function '" & funcName & "' not found. Available functions: " & availableFuncs
      return nil

    # Use the exact function name for lookup
    if ctx.options.verbose:
      echo "Resolved '" & funcName & "' to '" & exactFuncName & "'"
    actualFuncName = exactFuncName

  let funcInfo = ctx.program.functions[actualFuncName]

  if ctx.options.verbose:
    if funcInfo.kind == fkNative:
      echo "Calling '" & actualFuncName & "' at PC=" & $funcInfo.startPos
    else:
      echo "Calling '" & actualFuncName & "' (kind=" & $funcInfo.kind & ")"

  # Create a new frame for the function call
  # Ensure we have enough registers for arguments AND nested function calls
  # Allocate enough for: function's own registers + arguments + space for nested calls
  let neededRegs = max(10, max(int(numArgs) + 1, funcInfo.maxRegister + 1))
  var newFrame = RegisterFrame()
  newFrame.regs = newSeq[V](neededRegs)
  newFrame.returnAddr = -1  # Special return address for C calls (stop execution)
  newFrame.baseReg = 0
  newFrame.deferStack = @[]
  newFrame.deferReturnPC = -1

  # Initialize all registers to nil
  for i in 0..<neededRegs:
    newFrame.regs[i] = V(kind: vkNil)

  # Copy arguments from C API format to VM registers
  if args != nil and numArgs > 0:
    # Access arguments through unsafeAddr to work with pointer arithmetic
    let argArray = cast[ptr UncheckedArray[ptr EtchValueObj]](args)
    for i in 0..<min(int(numArgs), neededRegs):
      let cArg = argArray[i]
      if cArg != nil:
        newFrame.regs[i] = cArg.value

  # Save current VM state
  let vm = ctx.vm
  let savedFrameIdx = vm.frames.len - 1
  let savedFrames = vm.frames
  let savedCurrentFrame = vm.currentFrame

  # Set up isolated execution context
  vm.frames = @[newFrame]
  vm.currentFrame = addr vm.frames[0]
  vm.currentFrame.pc = funcInfo.startPos

  var funcResult: EtchValue = nil
  try:
    ensureInitialDebuggerWait(ctx)
    pollDebuggerConnection(ctx, false)
    drainDebuggerRequests(ctx, false)
    let debugger = getContextDebugger(ctx)
    if debugger != nil and debugger.paused:
      waitForDebuggerResume(ctx, false)

    # Execute the function
    discard executeVmWithDebug(ctx)

    # Get the return value (should be in register 0)
    let returnVal = vm.currentFrame.regs[0]
    funcResult = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    funcResult.value = returnVal

  except Exception as e:
    ctx.lastError = "Error calling function '" & funcName & "': " & e.msg
    return nil

  finally:
    # Restore VM state
    vm.frames = savedFrames
    if savedFrameIdx >= 0 and savedFrameIdx < vm.frames.len:
      vm.currentFrame = addr vm.frames[savedFrameIdx]
    else:
      vm.currentFrame = savedCurrentFrame

  return funcResult


# ============================================================================
# Context Management
# ============================================================================

proc etch_context_new*(): EtchContext {.exportc, cdecl, dynlib.} =
  ## Create a new Etch context with default options (non-verbose, debug mode, GC interval = 1000)
  ## Returns: Pointer to context or nil on failure
  try:
    var ctx = cast[EtchContext](alloc0(sizeof(EtchContextObj)))
    ctx.hostFunctions = initTable[string, HostFunctionInfo]()
    ctx.globalOverrides = initTable[string, V]()
    ctx.options = CompilerOptions(
      sourceFile: "",
      sourceString: none(string),
      runVirtualMachine: false,
      verbose: false,
      debug: true,
      gcCycleInterval: none(int)  # Use default 1000
    )
    ctx.lastError = ""
    ctx.instructionCallback = nil
    ctx.instructionCallbackUserData = nil
    ctx.remoteDebugServer = nil
    ctx.remoteDebugEnabled = false
    ctx.remoteDebugPort = 0
    ctx.remoteDebugTimeoutMs = 0
    ctx.remoteDebugInitialWaitDone = false
    ctx.processingDebugRequests = false
    ctx.debugPollCounter = 0
    return ctx
  except Exception:
    return nil


proc etch_context_new_with_options*(options: ptr EtchContextOptions): EtchContext {.exportc, cdecl, dynlib.} =
  ## Create a new Etch context with specified options
  ## options: Context creation options (NULL for defaults)
  ## Returns: Pointer to context or nil on failure
  try:
    var ctx = cast[EtchContext](alloc0(sizeof(EtchContextObj)))
    ctx.hostFunctions = initTable[string, HostFunctionInfo]()
    ctx.globalOverrides = initTable[string, V]()

    # Use defaults if options is NULL
    let verbose = if options != nil and options.verbose != 0: true else: false
    let debug = if options != nil and options.debug != 0: true else: false
    let gcInterval = if options != nil and options.gcCycleInterval > 0:
                       some(int(options.gcCycleInterval))
                     else:
                       none(int)  # Use default 1000

    ctx.options = CompilerOptions(
      sourceFile: "",
      sourceString: none(string),
      runVirtualMachine: false,
      verbose: verbose,
      debug: debug,
      gcCycleInterval: gcInterval
    )
    ctx.lastError = ""
    ctx.instructionCallback = nil
    ctx.instructionCallbackUserData = nil
    ctx.remoteDebugServer = nil
    ctx.remoteDebugEnabled = false
    ctx.remoteDebugPort = 0
    ctx.remoteDebugTimeoutMs = 0
    ctx.remoteDebugInitialWaitDone = false
    ctx.processingDebugRequests = false
    ctx.debugPollCounter = 0
    return ctx
  except Exception:
    return nil


proc etch_context_free*(ctx: EtchContext) {.exportc, cdecl, dynlib.} =
  ## Free an Etch context and all associated resources
  if ctx != nil:
    if ctx.remoteDebugServer != nil:
      ctx.remoteDebugServer.close()
      ctx.remoteDebugServer = nil
    dealloc(ctx)


proc etch_context_set_verbose*(ctx: EtchContext, verbose: cint) {.exportc, cdecl, dynlib.} =
  ## Enable or disable verbose logging
  if ctx != nil:
    ctx.options.verbose = (verbose != 0)


proc etch_context_set_debug*(ctx: EtchContext, debug: cint) {.exportc, cdecl, dynlib.} =
  ## Enable or disable debug mode (affects optimization level)
  ## debug: 0 = release mode with optimizations, non-zero = debug mode
  if ctx != nil:
    ctx.options.debug = (debug != 0)


# ============================================================================
# Error Handling
# ============================================================================

proc etch_get_error*(ctx: EtchContext): cstring {.exportc, cdecl, dynlib.} =
  ## Get the last error message from the context (see etch.h for full docs)
  if ctx == nil:
    return nil
  if ctx.lastError == "":
    return nil
  return cstring(ctx.lastError)


proc etch_clear_error*(ctx: EtchContext) {.exportc, cdecl, dynlib.} =
  ## Clear the error state
  if ctx != nil:
    ctx.lastError = ""


# ============================================================================
# Compilation
# ============================================================================

proc etch_compile_string*(ctx: EtchContext, source: cstring, filename: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Compile Etch source code from a string
  ## Returns: 0 on success, non-zero on error
  if ctx == nil:
    return -1

  let srcStr = $source
  var fnameStr = if filename != nil: $filename else: "<string>"
  fnameStr = normalizeSourcePath(fnameStr)

  # Use context's compiler options
  ctx.options.sourceFile = fnameStr
  ctx.options.sourceString = some(srcStr)
  ctx.options.runVirtualMachine = false

  let sourceLines = srcStr.splitLines()

  try:
    let (prog, sourceHash, evaluatedGlobals, moduleRegistry, cffiRegistry) = parseAndTypecheck(ctx.options)
    ctx.program = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, fnameStr, ctx.options, moduleRegistry, cffiRegistry)

    detectRemoteDebugSettings(ctx)
    setupVirtualMachine(ctx)

    if ctx.vm == nil:
      ctx.lastError = "Failed to initialize VM"
      return 1

    # Connect the VM to the context's host functions table and context pointer
    ctx.vm.hostFunctions = cast[pointer](ctx.hostFunctions.addr)
    ctx.vm.context = cast[pointer](ctx)

    # Set heap options based on compiler options
    ctx.vm.setHeapVerbose(ctx.options.verbose)
    if ctx.options.gcCycleInterval.isSome:
      ctx.vm.setHeapCycleInterval(ctx.options.gcCycleInterval.get)

    ctx.lastError = ""
    return 0

  except EtchError as e:
    ctx.lastError = "Compilation error: " & formatError(e.pos, e.msg, sourceLines)
    return 1

  except Exception as e:
    ctx.lastError = "Compilation error: " & e.msg
    return 1


proc etch_compile_file*(ctx: EtchContext, path: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Compile Etch source code from a file
  ## Returns: 0 on success, non-zero on error
  if ctx == nil:
    return -1

  var pathStr = $path
  if not fileExists(pathStr):
    ctx.lastError = "File not found: " & pathStr
    return 1

  pathStr = normalizeSourcePath(pathStr)

  try:
    let source = readFile(pathStr)
    return etch_compile_string(ctx, cstring(source), cstring(pathStr))

  except EtchError as e:
    ctx.lastError = "Compilation error: " & formatError(e.pos, e.msg, @[])
    return 1

  except Exception as e:
    ctx.lastError = "Error reading file: " & e.msg
    return 1


# ============================================================================
# Execution
# ============================================================================

proc etch_execute*(ctx: EtchContext): cint {.exportc, cdecl, dynlib.} =
  ## Execute the compiled program (runs main function if it exists)
  ## Returns: 0 on success, non-zero on error
  if ctx == nil:
    return -1

  try:
    if ctx.vm == nil:
      ctx.lastError = "No program compiled"
      return 1

    # Apply global overrides set via C API before execution
    # opInitGlobal in <global> function will skip these since they're already set
    for name, value in ctx.globalOverrides:
      ctx.vm.globals[name] = value

    ensureInitialDebuggerWait(ctx)
    pollDebuggerConnection(ctx, false)
    drainDebuggerRequests(ctx, false)

    let debugger = getContextDebugger(ctx)
    if debugger != nil and debugger.paused:
      waitForDebuggerResume(ctx, false)

    let exitCode = executeVmWithDebug(ctx)
    ctx.lastError = ""
    return cint(exitCode)

  except Exception as e:
    ctx.lastError = "Execution error: " & e.msg
    stderr.writeLine("ERROR: " & e.msg)
    stderr.flushFile()
    return 1


proc etch_call_function*(ctx: EtchContext, name: cstring, args: ptr ptr EtchValueObj, numArgs: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Call a specific function by name with arguments
  ## Returns: Result value or nil on error
  if ctx == nil or name == nil:
    return nil

  try:
    let funcName = $name

    # Check if it's a host function
    if ctx.hostFunctions.hasKey(funcName):
      let hostFunc = ctx.hostFunctions[funcName]
      return hostFunc.callback(ctx, args, numArgs, hostFunc.userData)

    # Call Etch function by name with arguments
    return callEtchFunctionByName(ctx, funcName, args, numArgs)

  except Exception as e:
    ctx.lastError = "Function call error: " & e.msg
    return nil


# ============================================================================
# Value Creation
# ============================================================================

proc newValueHandle(val: sink V): EtchValue {.inline.} =
  ## Allocate a new EtchValue handle wrapping the provided VM value
  try:
    var handle = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    handle.value = ensureMove(val)
    return handle
  except Exception:
    return nil


proc etch_value_clone*(v: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Duplicate an EtchValue handle (deep copy where needed)
  if v == nil:
    return nil
  return newValueHandle(v.value)


proc etch_value_new_nil*(): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new nil value
  return newValueHandle(makeNil())


proc etch_value_new_char*(v: char): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new character value
  return newValueHandle(makeChar(v))


proc etch_value_new_bool*(v: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new boolean value (0 = false, non-zero = true)
  return newValueHandle(makeBool(v != 0))


proc etch_value_new_int*(v: int64): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new integer value
  return newValueHandle(makeInt(v))


proc etch_value_new_float*(v: cdouble): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new float value
  return newValueHandle(makeFloat(v))


proc etch_value_new_string*(v: cstring): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new string value (copies the string)
  if v == nil:
    return etch_value_new_nil()
  return newValueHandle(makeString($v))


proc etch_value_new_enum*(typeId: cint, intVal: int64): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create an enum value with type ID and integer value
  return newValueHandle(makeEnum(int(typeId), intVal, ""))


proc etch_value_new_enum_with_string*(typeId: cint, intVal: int64, stringVal: cstring): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create an enum value with type ID, integer value, and string representation
  return newValueHandle(makeEnum(int(typeId), intVal, $stringVal))


proc etch_value_new_array*(elements: ptr EtchValue, count: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create an array value from an optional list of EtchValue handles
  if count < 0:
    return nil

  try:
    var seqVals: seq[V] = @[]
    if count > 0:
      seqVals.setLen(count)
      if elements != nil:
        let elemArray = cast[ptr UncheckedArray[EtchValue]](elements)
        for i in 0..<int(count):
          let elem = elemArray[i]
          if elem == nil:
            seqVals[i] = makeNil()
          else:
            seqVals[i] = elem.value
      else:
        for i in 0..<int(count):
          seqVals[i] = makeNil()

    return newValueHandle(makeArray(seqVals))
  except Exception:
    return nil


proc etch_value_new_some*(inner: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Wrap a value into the option some variant
  let wrapped = if inner == nil: makeNil() else: inner.value
  return newValueHandle(makeSome(wrapped))


proc etch_value_new_none*(): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create an option none value
  return newValueHandle(makeNone())


proc etch_value_new_ok*(inner: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Wrap a value into the result ok variant
  let wrapped = if inner == nil: makeNil() else: inner.value
  return newValueHandle(makeOk(wrapped))


proc etch_value_new_err*(inner: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Wrap a value into the result err variant
  let wrapped = if inner == nil: makeNil() else: inner.value
  return newValueHandle(makeError(wrapped))


# ============================================================================
# Value Inspection
# ============================================================================

proc valueKindToPublicType(kind: VKind): cint =
  ## Convert internal VM kind identifiers to the public EtchValueType enum
  case kind
  of vkInt:
    return 0
  of vkFloat:
    return 1
  of vkBool:
    return 2
  of vkChar:
    return 3
  of vkNil:
    return 4
  of vkString:
    return 5
  of vkArray:
    return 6
  of vkTable:
    return 7
  of vkSome:
    return 8
  of vkNone:
    return 9
  of vkOk:
    return 10
  of vkErr:
    return 11
  of vkEnum:
    return 12
  else:
    return -1


proc etch_value_get_type*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Get the type of a value using the EtchValueType enum mapping
  if v == nil:
    return -1
  return valueKindToPublicType(v.value.kind)


proc etch_value_is_bool*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a boolean
  if v == nil:
    return 0
  return cint(v.value.kind == vkBool)


proc etch_value_is_char*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a char
  if v == nil:
    return 0
  return cint(v.value.kind == vkChar)


proc etch_value_is_int*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is an integer
  if v == nil:
    return 0
  return cint(v.value.kind == vkInt)


proc etch_value_is_float*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a float
  if v == nil:
    return 0
  return cint(v.value.kind == vkFloat)


proc etch_value_is_string*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a string
  if v == nil:
    return 0
  return cint(v.value.kind == vkString)


proc etch_value_is_enum*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is an enum
  if v == nil:
    return 0
  return cint(v.value.kind == vkEnum)


proc etch_value_is_nil*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is nil
  if v == nil:
    return 1
  return cint(v.value.kind == vkNil)


proc etch_value_is_array*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is an array
  if v == nil:
    return 0
  return cint(v.value.kind == vkArray)


proc etch_value_is_some*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is an option some variant
  if v == nil:
    return 0
  return cint(v.value.kind == vkSome)


proc etch_value_is_none*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is an option none variant
  if v == nil:
    return 0
  return cint(v.value.kind == vkNone)


proc etch_value_is_ok*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a result ok variant
  if v == nil:
    return 0
  return cint(v.value.kind == vkOk)


proc etch_value_is_err*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is a result err variant
  if v == nil:
    return 0
  return cint(v.value.kind == vkErr)


# ============================================================================
# Value Extraction
# ============================================================================

proc etch_value_to_bool*(v: EtchValue, outVal: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## Extract boolean value
  ## Returns: 0 on success, non-zero if value is not a boolean
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkBool:
    return 1
  outVal[] = cint(v.value.bval)
  return 0


proc etch_value_to_char*(v: EtchValue, outVal: ptr char): cint {.exportc, cdecl, dynlib.} =
  ## Extract character value
  ## Returns: 0 on success, non-zero if value is not a character
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkChar:
    return 1
  outVal[] = v.value.cval
  return 0


proc etch_value_to_int*(v: EtchValue, outVal: ptr int64): cint {.exportc, cdecl, dynlib.} =
  ## Extract integer value
  ## Returns: 0 on success, non-zero if value is not an integer
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkInt:
    return 1
  outVal[] = v.value.ival
  return 0


proc etch_value_to_float*(v: EtchValue, outVal: ptr cdouble): cint {.exportc, cdecl, dynlib.} =
  ## Extract float value
  ## Returns: 0 on success, non-zero if value is not a float
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkFloat:
    return 1
  outVal[] = v.value.fval
  return 0


proc etch_value_to_string*(v: EtchValue): cstring {.exportc, cdecl, dynlib.} =
  ## Extract string value (see etch.h for full docs)
  if v == nil:
    return nil
  if v.value.kind != vkString:
    return nil
  return cstring(v.value.sval)


proc etch_value_to_enum_type_id*(v: EtchValue, outVal: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## Extract enum type ID
  ## Returns: 0 on success, non-zero if value is not an enum
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkEnum:
    return 1
  outVal[] = cint(v.value.enumTypeId)
  return 0


proc etch_value_to_enum_int_val*(v: EtchValue, outVal: ptr int64): cint {.exportc, cdecl, dynlib.} =
  ## Extract enum integer value
  ## Returns: 0 on success, non-zero if value is not an enum
  if v == nil or outVal == nil:
    return -1
  if v.value.kind != vkEnum:
    return 1
  outVal[] = v.value.enumIntVal
  return 0


proc etch_value_to_enum_string*(v: EtchValue): cstring {.exportc, cdecl, dynlib.} =
  ## Extract enum string value (see etch.h for full docs)
  if v == nil:
    return nil
  if v.value.kind != vkEnum:
    return nil
  if v.value.enumStringVal.len > 0:
    return cstring(v.value.enumStringVal)
  return nil


# ============================================================================
# Array Helpers
# ============================================================================

proc etch_value_array_length*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Return the number of elements stored in an array value
  if v == nil or v.value.kind != vkArray or v.value.aval == nil:
    return -1
  return cint(v.value.aval[].len)


proc etch_value_array_get*(v: EtchValue, index: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Fetch an element from an array (caller owns returned handle)
  if v == nil or v.value.kind != vkArray or v.value.aval == nil:
    return nil

  let elems = v.value.aval[]
  if index < 0 or index >= elems.len:
    return nil

  return newValueHandle(elems[index])


proc etch_value_array_set*(v: EtchValue, index: cint, value: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Assign an element inside an Etch array
  if v == nil or v.value.kind != vkArray or v.value.aval == nil:
    return -1

  let arrRef = v.value.aval
  if index < 0 or index >= arrRef[].len:
    return 1

  arrRef[][index] = (if value == nil: makeNil() else: value.value)
  return 0


proc etch_value_array_push*(v: EtchValue, value: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Append a value to an Etch array
  if v == nil or v.value.kind != vkArray or v.value.aval == nil:
    return -1

  let newVal = (if value == nil: makeNil() else: value.value)
  v.value.aval[].add(newVal)
  return 0


# ============================================================================
# Option Helpers
# ============================================================================

proc etch_value_option_has_value*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Returns non-zero when the option is the some variant
  return etch_value_is_some(v)


proc etch_value_option_unwrap*(v: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Extract the inner value from an option some variant
  if v == nil or v.value.kind != vkSome or v.value.wrapped == nil:
    return nil
  return newValueHandle(v.value.wrapped[])


# ============================================================================
# Result Helpers
# ============================================================================

proc etch_value_result_is_ok*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Returns non-zero when the result is ok
  return etch_value_is_ok(v)


proc etch_value_result_is_err*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Returns non-zero when the result is err
  return etch_value_is_err(v)


proc etch_value_result_unwrap_ok*(v: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Extract the ok payload from a result value
  if v == nil or v.value.kind != vkOk or v.value.wrapped == nil:
    return nil
  return newValueHandle(v.value.wrapped[])


proc etch_value_result_unwrap_err*(v: EtchValue): EtchValue {.exportc, cdecl, dynlib.} =
  ## Extract the error payload from a result value
  if v == nil or v.value.kind != vkErr or v.value.wrapped == nil:
    return nil
  return newValueHandle(v.value.wrapped[])


# ============================================================================
# Value Cleanup
# ============================================================================

proc etch_value_free*(v: EtchValue) {.exportc, cdecl, dynlib.} =
  ## Free a value created by the API
  if v != nil:
    dealloc(v)


# ============================================================================
# Enum Helper Functions
# ============================================================================

proc etch_compute_enum_type_id*(typeName: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Compute the enum type ID for a given type name
  ## Returns: Integer type ID, or -1 if typeName is NULL
  if typeName == nil:
    return -1
  result = cint(computeStringHashId($typeName))


# ============================================================================
# Global Variables
# ============================================================================

proc etch_set_global*(ctx: EtchContext, name: cstring, value: EtchValue) {.exportc, cdecl, dynlib.} =
  ## Set a global variable in the Etch context
  ## This can be called before or after compilation.
  ## If called before execution, the value will override any compile-time initialization.
  if ctx == nil or name == nil or value == nil:
    return

  let nameStr = $name

  if ctx.vm != nil:
    # VM exists - set directly
    ctx.vm.globals[nameStr] = value.value
  else:
    # VM doesn't exist yet - store in overrides to be applied during execute
    ctx.globalOverrides[nameStr] = value.value


proc etch_get_global*(ctx: EtchContext, name: cstring): EtchValue {.exportc, cdecl, dynlib.} =
  ## Get a global variable from the Etch context
  ## Returns: Value or nil if not found
  if ctx == nil or name == nil:
    return nil
  if ctx.vm == nil:
    return nil

  let nameStr = $name
  if not ctx.vm.globals.hasKey(nameStr):
    return nil

  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = ctx.vm.globals[nameStr]
    return val
  except Exception:
    return nil


# ============================================================================
# Host Function Registration
# ============================================================================

proc etch_register_function*(ctx: EtchContext, name: cstring,
                             callback: EtchHostFunction,
                             userData: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Register a C function that can be called from Etch
  ## Returns: 0 on success, non-zero on error
  if ctx == nil or name == nil or callback == nil:
    return -1

  try:
    let nameStr = $name
    ctx.hostFunctions[nameStr] = HostFunctionInfo(
      callback: callback,
      userData: userData
    )
    return 0
  except Exception:
    return 1


# ============================================================================
# Instruction Callback and VM Inspection
# ============================================================================

proc etch_set_instruction_callback*(ctx: EtchContext, callback: EtchInstructionCallback,
                                     userData: pointer) {.exportc, cdecl, dynlib.} =
  ## Set a callback to be invoked before each instruction is executed
  ## Useful for debugging, profiling, or step-by-step execution
  ## callback: Function pointer called before each instruction (return 0 to continue, non-zero to stop)
  ## userData: User-defined data passed to the callback
  if ctx != nil:
    ctx.instructionCallback = callback
    ctx.instructionCallbackUserData = userData


proc etch_get_call_stack_depth*(ctx: EtchContext): cint {.exportc, cdecl, dynlib.} =
  ## Get the current call stack depth
  ## Returns: Number of active stack frames, or -1 on error
  if ctx == nil or ctx.vm == nil:
    return -1
  return cint(ctx.vm.frames.len)


proc etch_get_program_counter*(ctx: EtchContext): cint {.exportc, cdecl, dynlib.} =
  ## Get the current program counter (instruction index)
  ## Returns: Current PC, or -1 on error
  if ctx == nil or ctx.vm == nil or ctx.vm.currentFrame == nil:
    return -1
  return cint(ctx.vm.currentFrame.pc)


proc etch_get_register_count*(ctx: EtchContext): cint {.exportc, cdecl, dynlib.} =
  ## Get the number of registers in the current frame
  ## Returns: Return the current , or -1 on error
  if ctx == nil or ctx.vm == nil:
    return -1
  return cint(ctx.vm.currentFrame.regs.len)


proc etch_get_register*(ctx: EtchContext, regIndex: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Get the value of a register in the current frame
  ## regIndex: Register index (0-255)
  ## Returns: Register value, or nil on error
  if ctx == nil or ctx.vm == nil or ctx.vm.currentFrame == nil:
    return nil
  if regIndex < 0 or regIndex >= cint(ctx.vm.currentFrame.regs.len):
    return nil

  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = ctx.vm.currentFrame.regs[regIndex]
    return val
  except Exception:
    return nil


proc etch_get_instruction_count*(ctx: EtchContext): cint {.exportc, cdecl, dynlib.} =
  ## Get the total number of instructions in the program
  ## Returns: Instruction count, or -1 on error
  if ctx == nil or ctx.program.instructions.len == 0:
    return -1
  return cint(ctx.program.instructions.len)


proc etch_get_current_function*(ctx: EtchContext): cstring {.exportc, cdecl, dynlib.} =
  ## Get the name of the currently executing function (see etch.h for full docs)
  if ctx == nil or ctx.vm == nil or ctx.vm.currentFrame == nil:
    return nil

  # Find function at current PC
  let pc = ctx.vm.currentFrame.pc
  for funcName, funcInfo in ctx.program.functions:
    if pc >= funcInfo.startPos and pc < funcInfo.endPos:
      return cstring(funcName)

  return cstring("<unknown>")


# ============================================================================
# Frame Budget API for Game Engines
# ============================================================================

# Allows C/C++ game engines to control GC timing on a per-frame basis

type
  EtchGCFrameStats* = object
    gcTimeUs*: int64        # Microseconds spent on GC this frame
    budgetUs*: int64        # Total budget allocated for this frame
    dirtyObjects*: cint     # Number of objects modified since last GC

proc etch_begin_frame*(ctx: EtchContext, budgetUs: int64) {.exportc, cdecl, dynlib.} =
  ## Start a new frame with a GC time budget
  ## Call this at the start of each game frame
  ##
  ## Parameters:
  ##   ctx: The Etch context
  ##   budgetUs: Microseconds available for GC work this frame
  ##             e.g., 2000 for 2ms GC budget in a 16ms frame
  ##             Set to 0 to disable frame budgeting (use adaptive intervals)
  ##
  ## Example:
  ##   etch_begin_frame(ctx, 2000);  // 2ms GC budget
  if ctx != nil and ctx.vm != nil:
    beginFrameImpl(ctx.vm, budgetUs)


proc etch_needs_gc_frame*(ctx: EtchContext): bool {.exportc, cdecl, dynlib.} =
  ## Check if GC is backed up and needs a full frame
  ## Returns true if many dirty objects have accumulated
  ## Game engine can use this to skip rendering and give full frame to GC
  ##
  ## Example:
  ##   if (etch_needs_gc_frame(ctx)) {
  ##       etch_begin_frame(ctx, 16000);  // Give full 16ms frame to GC
  ##       // Skip rendering this frame
  ##   }
  if ctx != nil and ctx.vm != nil:
    return needsGCFrameImpl(ctx.vm)
  return false


proc etch_get_gc_stats*(ctx: EtchContext): EtchGCFrameStats {.exportc, cdecl, dynlib.} =
  ## Get GC statistics for the current frame
  ## Returns time spent on GC, budget, and dirty object count
  ##
  ## Example:
  ##   EtchGCFrameStats stats = etch_get_gc_stats(ctx);
  ##   printf("GC: %lldus / %lldus, dirty: %d\n",
  ##          stats.gcTimeUs, stats.budgetUs, stats.dirtyObjects);
  if ctx != nil and ctx.vm != nil:
    let (usedUs, budgetUs, dirtyCount) = getGCFrameStatsImpl(ctx.vm)
    return EtchGCFrameStats(
      gcTimeUs: usedUs,
      budgetUs: budgetUs,
      dirtyObjects: cint(dirtyCount)
    )
  return EtchGCFrameStats(gcTimeUs: 0, budgetUs: 0, dirtyObjects: 0)


proc etch_heap_needs_collection*(ctx: EtchContext): bool {.exportc, cdecl, dynlib.} =
  ## Check if heap has dirty objects that need cycle detection
  ## Returns true if cycle detection should run (when budget allows)
  if ctx != nil and ctx.vm != nil:
    let (_, _, dirtyCount) = getGCFrameStatsImpl(ctx.vm)
    return dirtyCount > 100  # Threshold for needing collection
  return false
