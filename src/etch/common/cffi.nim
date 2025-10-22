# cffi.nim
# C FFI (Foreign Function Interface) for calling C library functions

import std/[dynlib, tables]
import ../common/types
import ../frontend/ast
import values


type
  CFunctionPtr = pointer

  ParamSpec* = object
    name*: string
    typ*: EtchType

  FunctionSignature* = object
    params*: seq[ParamSpec]
    returnType*: EtchType

  CFFIFunction* = object
    name*: string
    library*: string
    symbol*: string  # Symbol name in the shared library
    signature*: FunctionSignature
    funcPtr*: CFunctionPtr

  CFFILibrary* = object
    name*: string           # Normalized library name (e.g., "mathlib", "c")
    path*: string           # Actual file path used to load the library
    handle*: LibHandle
    functions*: Table[string, CFFIFunction]

  CFFIRegistry* = ref object
    libraries*: Table[string, CFFILibrary]
    functions*: Table[string, CFFIFunction]

var globalCFFIRegistry* = CFFIRegistry(
  libraries: initTable[string, CFFILibrary](),
  functions: initTable[string, CFFIFunction]()
)

proc loadLibrary*(registry: CFFIRegistry, name: string, path: string): CFFILibrary =
  ## Load a shared library
  let handle = loadLib(path)
  if handle == nil:
    raise newException(IOError, "Failed to load library: " & path)

  result = CFFILibrary(
    name: name,
    path: path,
    handle: handle,
    functions: initTable[string, CFFIFunction]()
  )

  registry.libraries[name] = result

proc getLibrary*(registry: CFFIRegistry, name: string): CFFILibrary =
  ## Get a loaded library by name
  if name notin registry.libraries:
    raise newException(ValueError, "Library not loaded: " & name)
  registry.libraries[name]

proc loadFunction*(registry: CFFIRegistry, library: string, funcName: string,
                  symbol: string, signature: FunctionSignature) =
  ## Load a function from a library
  var lib = registry.getLibrary(library)

  let funcPtr = lib.handle.symAddr(symbol)
  if funcPtr == nil:
    raise newException(ValueError, "Function not found in library: " & symbol)

  let cFunc = CFFIFunction(
    name: funcName,
    library: library,
    symbol: symbol,
    signature: signature,
    funcPtr: funcPtr
  )

  lib.functions[funcName] = cFunc
  registry.functions[funcName] = cFunc
  registry.libraries[library] = lib

proc callCFunction*(fn: CFFIFunction, args: seq[Value]): Value =
  ## Generic C function calling through FFI
  ## Uses type information to marshal arguments correctly

  if args.len != fn.signature.params.len:
    raise newException(ValueError,
      "Argument count mismatch for FFI function " & fn.name &
      ": expected " & $fn.signature.params.len & ", got " & $args.len)

  # For a generic implementation, we build the call based on the signature
  # This handles the most common cases: functions with basic types

  # Currently we support functions with 0-4 arguments of basic types
  # For full generality, we'd need libffi or code generation

  case args.len
  of 0:
    # No arguments
    case fn.signature.returnType.kind
    of tkVoid:
      type VoidFunc = proc() {.cdecl.}
      cast[VoidFunc](fn.funcPtr)()
      return Value(kind: vkVoid)
    of tkInt:
      type IntFunc = proc(): int64 {.cdecl.}
      let res = cast[IntFunc](fn.funcPtr)()
      return Value(kind: vkInt, intVal: res)
    of tkFloat:
      type FloatFunc = proc(): cdouble {.cdecl.}
      let res = cast[FloatFunc](fn.funcPtr)()
      return Value(kind: vkFloat, floatVal: res)
    else:
      raise newException(ValueError, "Unsupported return type for 0-arg FFI function")

  of 1:
    # One argument - detect types and cast appropriately
    let argType = fn.signature.params[0].typ.kind
    let retType = fn.signature.returnType.kind

    if argType == tkFloat and retType == tkFloat:
      # float -> float (common for math functions)
      type FloatToFloat = proc(a: cdouble): cdouble {.cdecl.}
      let res = cast[FloatToFloat](fn.funcPtr)(args[0].floatVal)
      return Value(kind: vkFloat, floatVal: res)
    elif argType == tkInt and retType == tkInt:
      # int -> int
      type IntToInt = proc(a: int64): int64 {.cdecl.}
      let res = cast[IntToInt](fn.funcPtr)(args[0].intVal)
      return Value(kind: vkInt, intVal: res)
    elif argType == tkString and retType == tkString:
      # string -> string
      type StrToStr = proc(a: cstring): cstring {.cdecl.}
      let res = cast[StrToStr](fn.funcPtr)(args[0].stringVal.cstring)
      return Value(kind: vkString, stringVal: $res)
    elif argType == tkInt and retType == tkVoid:
      # int -> void
      type IntToVoid = proc(a: int64) {.cdecl.}
      cast[IntToVoid](fn.funcPtr)(args[0].intVal)
      return Value(kind: vkVoid)
    else:
      raise newException(ValueError,
        "Unsupported type combination for 1-arg FFI: " & $argType & " -> " & $retType)

  of 2:
    # Two arguments
    let arg0Type = fn.signature.params[0].typ.kind
    let arg1Type = fn.signature.params[1].typ.kind
    let retType = fn.signature.returnType.kind

    if arg0Type == tkFloat and arg1Type == tkFloat and retType == tkFloat:
      # (float, float) -> float (e.g., pow)
      type Float2ToFloat = proc(a, b: cdouble): cdouble {.cdecl.}
      let res = cast[Float2ToFloat](fn.funcPtr)(args[0].floatVal, args[1].floatVal)
      return Value(kind: vkFloat, floatVal: res)
    elif arg0Type == tkInt and arg1Type == tkInt and retType == tkInt:
      # (int, int) -> int
      type Int2ToInt = proc(a, b: int64): int64 {.cdecl.}
      let res = cast[Int2ToInt](fn.funcPtr)(args[0].intVal, args[1].intVal)
      return Value(kind: vkInt, intVal: res)
    else:
      raise newException(ValueError,
        "Unsupported type combination for 2-arg FFI: (" &
        $arg0Type & ", " & $arg1Type & ") -> " & $retType)

  of 3:
    # Three arguments - add common patterns as needed
    raise newException(ValueError, "3-argument FFI calls not yet implemented")

  of 4:
    # Four arguments - add common patterns as needed
    raise newException(ValueError, "4-argument FFI calls not yet implemented")

  else:
    raise newException(ValueError,
      "FFI calls with more than 4 arguments not supported")

proc callFunction*(registry: CFFIRegistry, name: string, args: seq[Value]): Value =
  ## Call a registered C function by name
  if name in registry.functions:
    return callCFunction(registry.functions[name], args)
  else:
    raise newException(ValueError, "Unknown CFFI function: " & name)

