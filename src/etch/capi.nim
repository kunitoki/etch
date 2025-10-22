# c_api.nim
# C FFI interface for using Etch as an embedded scripting engine
# This module provides a clean C API that can be linked into C/C++ applications

import std/[tables, strutils, os, options, json]
import ./[compiler]
import ./common/[types, constants, errors]
import ./interpreter/[regvm, regvm_compiler, regvm_exec, regvm_debugserver]
import ./frontend/[ast, parser, lexer]
import ./typechecker/[core, types, statements, inference]

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

  # Internal representation (not exposed to C)
  EtchContextObj = object
    vm: RegisterVM
    program: RegBytecodeProgram
    lastError: string
    hostFunctions: Table[string, HostFunctionInfo]
    options: CompilerOptions
    instructionCallback: EtchInstructionCallback
    instructionCallbackUserData: pointer

  HostFunctionInfo = object
    callback: EtchHostFunction
    userData: pointer

  EtchValueObj = object
    value: V

  EtchDebugServerObj = object
    server: RegDebugServer
    sourceFile: string


# ============================================================================
# Context Management
# ============================================================================

proc etch_context_new*(): EtchContext {.exportc, cdecl, dynlib.} =
  ## Create a new Etch context with default options (non-verbose, debug mode)
  ## Returns: Pointer to context or nil on failure
  try:
    var ctx = cast[EtchContext](alloc0(sizeof(EtchContextObj)))
    ctx.hostFunctions = initTable[string, HostFunctionInfo]()
    ctx.options = CompilerOptions(
      sourceFile: "",
      sourceString: none(string),
      runVM: false,
      verbose: false,
      debug: true
    )
    ctx.lastError = ""
    ctx.instructionCallback = nil
    ctx.instructionCallbackUserData = nil
    return ctx
  except Exception:
    return nil

proc etch_context_new_with_options*(verbose: cint, debug: cint): EtchContext {.exportc, cdecl, dynlib.} =
  ## Create a new Etch context with specified compiler options
  ## verbose: Enable verbose logging (0 = off, non-zero = on)
  ## debug: Enable debug mode (0 = release with optimizations, non-zero = debug)
  ## Returns: Pointer to context or nil on failure
  try:
    var ctx = cast[EtchContext](alloc0(sizeof(EtchContextObj)))
    ctx.hostFunctions = initTable[string, HostFunctionInfo]()
    ctx.options = CompilerOptions(
      sourceFile: "",
      sourceString: none(string),
      runVM: false,
      verbose: (verbose != 0),
      debug: (debug != 0)
    )
    ctx.lastError = ""
    ctx.instructionCallback = nil
    ctx.instructionCallbackUserData = nil
    return ctx
  except Exception:
    return nil

proc etch_context_free*(ctx: EtchContext) {.exportc, cdecl, dynlib.} =
  ## Free an Etch context and all associated resources
  if ctx != nil:
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

  try:
    let srcStr = $source
    let fnameStr = if filename != nil: $filename else: "<string>"

    # Use context's compiler options
    ctx.options.sourceFile = fnameStr
    ctx.options.sourceString = some(srcStr)
    ctx.options.runVM = false

    let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(ctx.options)
    ctx.program = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, fnameStr, ctx.options)
    ctx.vm = newRegisterVM(ctx.program)

    ctx.lastError = ""
    return 0

  except Exception as e:
    ctx.lastError = "Compilation error: " & e.msg
    return 1

proc etch_compile_file*(ctx: EtchContext, path: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Compile Etch source code from a file
  ## Returns: 0 on success, non-zero on error
  if ctx == nil:
    return -1

  try:
    let pathStr = $path
    if not fileExists(pathStr):
      ctx.lastError = "File not found: " & pathStr
      return 1

    let source = readFile(pathStr)
    return etch_compile_string(ctx, cstring(source), path)

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

    let exitCode = ctx.vm.execute(ctx.options.verbose)
    ctx.lastError = ""
    return cint(exitCode)

  except Exception as e:
    ctx.lastError = "Execution error: " & e.msg
    return 1

proc etch_call_function*(ctx: EtchContext, name: cstring,
                         args: ptr ptr EtchValueObj, numArgs: cint): EtchValue {.exportc, cdecl, dynlib.} =
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

    # TODO: Implement calling Etch functions from C
    ctx.lastError = "Calling Etch functions from C not yet implemented"
    return nil

  except Exception as e:
    ctx.lastError = "Function call error: " & e.msg
    return nil


# ============================================================================
# Value Creation
# ============================================================================

proc etch_value_new_nil*(): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new nil value
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeNil()
    return val
  except Exception:
    return nil

proc etch_value_new_char*(v: char): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new character value
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeChar(v)
    return val
  except Exception:
    return nil

proc etch_value_new_bool*(v: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new boolean value (0 = false, non-zero = true)
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeBool(v != 0)
    return val
  except Exception:
    return nil

proc etch_value_new_int*(v: int64): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new integer value
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeInt(v)
    return val
  except Exception:
    return nil

proc etch_value_new_float*(v: cdouble): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new float value
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeFloat(v)
    return val
  except Exception:
    return nil

proc etch_value_new_string*(v: cstring): EtchValue {.exportc, cdecl, dynlib.} =
  ## Create a new string value (copies the string)
  if v == nil:
    return etch_value_new_nil()
  try:
    var val = cast[EtchValue](alloc0(sizeof(EtchValueObj)))
    val.value = makeString($v)
    return val
  except Exception:
    return nil


# ============================================================================
# Value Inspection
# ============================================================================

proc etch_value_get_type*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Get the type of a value
  ## Returns: Type enum (0=int, 1=float, 2=bool, 3=char, 4=nil, 5=string, 6=array, 7=table, etc.)
  if v == nil:
    return -1
  return cint(v.value.kind)

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

proc etch_value_is_nil*(v: EtchValue): cint {.exportc, cdecl, dynlib.} =
  ## Check if value is nil
  if v == nil:
    return 1
  return cint(v.value.kind == vkNil)


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


# ============================================================================
# Value Cleanup
# ============================================================================

proc etch_value_free*(v: EtchValue) {.exportc, cdecl, dynlib.} =
  ## Free a value created by the API
  if v != nil:
    dealloc(v)


# ============================================================================
# Global Variables
# ============================================================================

proc etch_set_global*(ctx: EtchContext, name: cstring, value: EtchValue) {.exportc, cdecl, dynlib.} =
  ## Set a global variable in the Etch context
  if ctx == nil or name == nil or value == nil:
    return
  if ctx.vm == nil:
    return

  let nameStr = $name
  ctx.vm.globals[nameStr] = value.value

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
  ## Returns: Always returns 256 (max registers), or -1 on error
  if ctx == nil or ctx.vm == nil:
    return -1
  return 256  # MAX_REGISTERS

proc etch_get_register*(ctx: EtchContext, regIndex: cint): EtchValue {.exportc, cdecl, dynlib.} =
  ## Get the value of a register in the current frame
  ## regIndex: Register index (0-255)
  ## Returns: Register value, or nil on error
  if ctx == nil or ctx.vm == nil or ctx.vm.currentFrame == nil:
    return nil
  if regIndex < 0 or regIndex >= 256:
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
# Debug Server API
# ============================================================================

proc etch_debug_server_new*(ctx: EtchContext, sourceFile: cstring): EtchDebugServer {.exportc, cdecl, dynlib.} =
  ## Create a new debug server from a compiled program
  ## ctx: Context with compiled program
  ## sourceFile: Source file path for debug info
  ## Returns: Debug server handle or nil on failure
  if ctx == nil or ctx.program.instructions.len == 0:
    return nil

  try:
    let srcFile = if sourceFile != nil: $sourceFile else: "<unknown>"
    let debugServer = newRegDebugServer(ctx.program, srcFile)

    var serverObj = cast[EtchDebugServer](alloc0(sizeof(EtchDebugServerObj)))
    serverObj.server = debugServer
    serverObj.sourceFile = srcFile
    return serverObj
  except Exception:
    return nil

proc etch_debug_server_free*(debugServer: EtchDebugServer) {.exportc, cdecl, dynlib.} =
  ## Free a debug server
  ## debugServer: Debug server to free
  if debugServer != nil:
    dealloc(debugServer)

proc etch_debug_server_handle_request*(debugServer: EtchDebugServer,
                                       requestJson: cstring,
                                       outResponseJson: ptr cstring): cint {.exportc, cdecl, dynlib.} =
  ## Handle a debug adapter protocol request (see etch.h for full docs)
  if debugServer == nil or requestJson == nil or outResponseJson == nil:
    return 1

  try:
    let request = parseJson($requestJson)
    let response = handleDebugRequest(debugServer.server, request)

    # Add request ID to response
    if request.hasKey("seq"):
      response["request_seq"] = request["seq"]
    response["type"] = %"response"
    response["command"] = request["command"]

    let responseStr = $response
    # Allocate and copy response string
    let responseLen = responseStr.len + 1
    let responseCStr = cast[cstring](alloc0(responseLen))
    copyMem(cast[pointer](responseCStr), unsafeAddr responseStr[0], responseStr.len)

    outResponseJson[] = responseCStr
    return 0
  except Exception as e:
    # Return error as JSON
    let errorResponse = %*{
      "type": "response",
      "success": false,
      "message": e.msg
    }
    let errorStr = $errorResponse
    let errorLen = errorStr.len + 1
    let errorCStr = cast[cstring](alloc0(errorLen))
    copyMem(cast[pointer](errorCStr), unsafeAddr errorStr[0], errorStr.len)
    outResponseJson[] = errorCStr
    return 1

proc etch_debug_server_is_running*(debugServer: EtchDebugServer): cint {.exportc, cdecl, dynlib.} =
  ## Check if the debug server is still running
  ## Returns: 1 if running, 0 if not
  if debugServer == nil or debugServer.server == nil:
    return 0
  return if debugServer.server.running: 1 else: 0

proc etch_free_string*(str: cstring) {.exportc, cdecl, dynlib.} =
  ## Free a string allocated by the Etch library (see etch.h for full docs)
  if str != nil:
    dealloc(cast[pointer](str))
