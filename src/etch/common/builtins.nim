# builtins.nim
# Simple builtin function type checking registry

import ../frontend/ast
import ../common/[types, errors]

# Builtin function indices for ultra-fast VM dispatch
type
  BuiltinFuncId* = enum
    bfPrint = 0, bfNew, bfDeref, bfRand, bfSeed, bfReadFile,
    bfParseInt, bfParseFloat, bfParseBool, bfToString,
    bfIsSome, bfIsNone, bfIsOk, bfIsErr
    # Note: inject is excluded as it's a compiler directive, not a runtime function

# Builtin function name to ID mapping for fast lookup
const BUILTIN_NAMES*: array[BuiltinFuncId, string] = [
  bfPrint: "print",
  bfNew: "new",
  bfDeref: "deref",
  bfRand: "rand",
  bfSeed: "seed",
  bfReadFile: "readFile",
  bfParseInt: "parseInt",
  bfParseFloat: "parseFloat",
  bfParseBool: "parseBool",
  bfToString: "toString",
  bfIsSome: "isSome",
  bfIsNone: "isNone",
  bfIsOk: "isOk",
  bfIsErr: "isErr"
]

# Get builtin ID from function name (for bytecode generation)
proc getBuiltinId*(funcName: string): BuiltinFuncId =
  ## Get the builtin function ID for a function name, raises if not found
  for id, name in BUILTIN_NAMES:
    if name == funcName:
      return id
  raise newException(ValueError, "Unknown builtin function: " & funcName)

# Get all builtin names for automatic registration
proc getBuiltinNames*(): seq[string] =
  for id, name in BUILTIN_NAMES:
    result.add(name)

# Simple function to check if a name is a builtin function
proc isBuiltin*(name: string): bool =
  return name in getBuiltinNames()

proc getBuiltinSignature*(fname: string): (seq[EtchType], EtchType) =
  ## Get the parameter types and return type for a builtin function
  ## Returns empty seq and tVoid if not found or if it has variable signatures
  case fname
  of "print":
    return (@[tInferred()], tVoid())
  of "new":
    return (@[tInferred()], tInferred())
  of "deref":
    return (@[tInferred()], tInferred())
  of "rand":
    return (@[tInt()], tInt())
  of "seed":
    return (@[], tVoid())
  of "readFile":
    return (@[tString()], tString())
  of "parseInt":
    return (@[tString()], tOption(tInt()))
  of "parseFloat":
    return (@[tString()], tOption(tFloat()))
  of "parseBool":
    return (@[tString()], tOption(tBool()))
  of "toString":
    return (@[tInferred()], tString())
  of "isSome", "isNone":
    return (@[tOption(tInferred())], tBool())
  of "isOk", "isErr":
    return (@[tResult(tInferred())], tBool())
  else:
    return (@[], tVoid())

# Perform basic type checking for builtin functions
# This is simplified to avoid circular dependencies
proc performBuiltinTypeCheck*(funcName: string, argTypes: seq[EtchType], pos: Pos): EtchType =
  case funcName
  of "print":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "print expects 1 argument")
    if argTypes[0].kind notin {tkBool, tkInt, tkFloat, tkString, tkChar}:
      raise newTypecheckError(pos, "print supports bool/int/float/string/char")
    return tVoid()

  of "new":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "new expects 1 argument")
    return tRef(argTypes[0])

  of "deref":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "deref expects 1 argument")
    if argTypes[0].kind != tkRef:
      raise newTypecheckError(pos, "deref expects ref[...]")
    return argTypes[0].inner

  of "rand":
    if argTypes.len < 1 or argTypes.len > 2:
      raise newTypecheckError(pos, "rand expects 1 or 2 arguments")
    if argTypes[0].kind != tkInt:
      raise newTypecheckError(pos, "rand max argument must be int")
    if argTypes.len == 2 and argTypes[1].kind != tkInt:
      raise newTypecheckError(pos, "rand min argument must be int")
    return tInt()

  of "readFile":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "readFile expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "readFile expects string path")
    return tString()

  of "inject":
    if argTypes.len != 3:
      raise newTypecheckError(pos, "inject expects 3 arguments: name, type, value")
    if argTypes[0].kind != tkString or argTypes[1].kind != tkString:
      raise newTypecheckError(pos, "inject name and type arguments must be strings")
    return tVoid()

  of "seed":
    if argTypes.len > 1:
      raise newTypecheckError(pos, "seed expects 0 or 1 argument")
    if argTypes.len == 1 and argTypes[0].kind != tkInt:
      raise newTypecheckError(pos, "seed expects int argument")
    return tVoid()

  of "parseInt":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "parseInt expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "parseInt expects string argument")
    return tOption(tInt())

  of "parseFloat":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "parseFloat expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "parseFloat expects string argument")
    return tOption(tFloat())

  of "parseBool":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "parseBool expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "parseBool expects string argument")
    return tOption(tBool())

  of "toString":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "toString expects 1 argument")
    if argTypes[0].kind notin {tkBool, tkInt, tkFloat, tkChar}:
      raise newTypecheckError(pos, "toString supports bool/int/float/char")
    return tString()

  of "isSome":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "isSome expects 1 argument")
    if argTypes[0].kind != tkOption:
      raise newTypecheckError(pos, "isSome expects option[T] argument")
    return tBool()

  of "isNone":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "isNone expects 1 argument")
    if argTypes[0].kind != tkOption:
      raise newTypecheckError(pos, "isNone expects option[T] argument")
    return tBool()

  of "isOk":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "isOk expects 1 argument")
    if argTypes[0].kind != tkResult:
      raise newTypecheckError(pos, "isOk expects result[T] argument")
    return tBool()

  of "isErr":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "isErr expects 1 argument")
    if argTypes[0].kind != tkResult:
      raise newTypecheckError(pos, "isErr expects result[T] argument")
    return tBool()

  else:
    raise newTypecheckError(pos, "unknown builtin function: " & funcName)
