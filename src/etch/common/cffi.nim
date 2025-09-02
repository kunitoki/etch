# cffi.nim
# C FFI (Foreign Function Interface) for calling C library functions

import std/[dynlib, tables]
import ../common/[types, values, libffi]
import ../bytecode/frontend/ast


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


proc newCFFIRegistry*(): CFFIRegistry =
  ## Create a new, empty CFFI registry instance
  CFFIRegistry(
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


proc etchTypeToFFIType(typ: types.TypeKind): ptr libffi.Type =
  ## Convert Etch type to libffi type
  case typ
  of tkVoid:
    return addr type_void
  of tkInt:
    return addr type_sint64
  of tkFloat:
    return addr type_double
  of tkBool:
    return addr type_uint8
  of tkString:
    return addr type_pointer
  else:
    raise newException(ValueError, "Unsupported FFI type: " & $typ)


proc callCFunction*(fn: CFFIFunction, args: seq[Value]): Value =
  ## Generic C function calling through libffi
  ## Supports arbitrary number of parameters and various types

  if args.len != fn.signature.params.len:
    raise newException(ValueError,
      "Argument count mismatch for FFI function " & fn.name &
      ": expected " & $fn.signature.params.len & ", got " & $args.len)

  # Prepare FFI types for parameters
  var argTypes: ParamList
  for i, param in fn.signature.params:
    argTypes[i] = etchTypeToFFIType(param.typ.kind)

  # Prepare FFI type for return value
  let retType = etchTypeToFFIType(fn.signature.returnType.kind)

  # Prepare CIF (Call Interface)
  var cif: TCif
  let status = prep_cif(cif, DEFAULT_ABI, cuint(args.len), retType, argTypes)
  if status != OK:
    raise newException(ValueError, "Failed to prepare FFI call for " & fn.name)

  # Prepare argument values - we need to allocate storage for each argument
  # and point to it, as libffi expects pointers to argument values
  var argValues: ArgList
  # Use a fixed-size array for argument storage to ensure proper lifetime
  type ArgStorage = array[0..100, uint64]  # Enough to hold any basic type
  var argStorage: ArgStorage

  for i, arg in args:
    let paramType = fn.signature.params[i].typ.kind
    case paramType
    of tkInt:
      cast[ptr int64](addr argStorage[i])[] = arg.intVal
      argValues[i] = addr argStorage[i]
    of tkFloat:
      cast[ptr cdouble](addr argStorage[i])[] = arg.floatVal
      argValues[i] = addr argStorage[i]
    of tkBool:
      cast[ptr uint8](addr argStorage[i])[] = if arg.boolVal: 1'u8 else: 0'u8
      argValues[i] = addr argStorage[i]
    of tkString:
      cast[ptr cstring](addr argStorage[i])[] = arg.stringVal.cstring
      argValues[i] = addr argStorage[i]
    else:
      raise newException(ValueError, "Unsupported argument type for FFI: " & $paramType)

  # Prepare return value storage
  let retKind = fn.signature.returnType.kind
  case retKind
  of tkVoid:
    # Call with no return value
    call(cif, cast[pointer](fn.funcPtr), nil, argValues)
    return Value(kind: vkVoid)

  of tkInt:
    var retVal: int64
    call(cif, cast[pointer](fn.funcPtr), addr retVal, argValues)
    return Value(kind: vkInt, intVal: retVal)

  of tkFloat:
    var retVal: cdouble
    call(cif, cast[pointer](fn.funcPtr), addr retVal, argValues)
    return Value(kind: vkFloat, floatVal: retVal)

  of tkBool:
    var retVal: uint8
    call(cif, cast[pointer](fn.funcPtr), addr retVal, argValues)
    return Value(kind: vkBool, boolVal: retVal != 0)

  of tkString:
    var retVal: cstring
    call(cif, cast[pointer](fn.funcPtr), addr retVal, argValues)
    if retVal.isNil:
      return Value(kind: vkString, stringVal: "")
    else:
      return Value(kind: vkString, stringVal: $retVal)

  else:
    raise newException(ValueError, "Unsupported return type for FFI: " & $retKind)


proc callFunction*(registry: CFFIRegistry, name: string, args: seq[Value]): Value =
  ## Call a registered C function by name
  if name in registry.functions:
    let fn = registry.functions[name]
    ## Basic sanity logging can be added here if needed in the future.
    return callCFunction(fn, args)
  else:
    raise newException(ValueError, "Unknown CFFI function: " & name)
