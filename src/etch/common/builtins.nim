# builtins.nim
# Simple builtin function type checking registry

import std/[strformat]
import ../bytecode/frontend/ast
import ../common/[types, errors]

# Builtin function indices for ultra-fast VM dispatch
type
  BuiltinFuncId* = enum
    bfPrint = 0, bfNew, bfDeref, bfRand, bfSeed, bfReadFile,
    bfParseInt, bfParseFloat, bfParseBool,
    bfIsSome, bfIsNone, bfIsOk, bfIsErr, bfArrayNew,
    bfMakeClosure, bfInvokeClosure

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
  bfIsSome: "isSome",
  bfIsNone: "isNone",
  bfIsOk: "isOk",
  bfIsErr: "isError",
  bfArrayNew: "arrayNew",
  bfMakeClosure: "__make_closure",
  bfInvokeClosure: "__invoke_closure"
]

# Get builtin ID from function name (for bytecode generation)
proc getBuiltinId*(funcName: string): BuiltinFuncId =
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
  for id, builtinName in BUILTIN_NAMES:
    if builtinName == name:
      return true
  return false

## Get the parameter types and return type for a builtin function
proc getBuiltinSignature*(fname: string): (seq[EtchType], EtchType) =
  case fname
  of "print":
    return (@[tInferred()], tVoid())
  of "new":
    return (@[tInferred()], tInferred())
  of "arrayNew":
    return (@[tInt(), tInferred()], tArray(tInferred()))
  of "deref":
    return (@[tInferred()], tInferred())
  of "rand":
    return (@[tInt()], tInt())
  of "seed":
    return (@[], tVoid())
  of "readFile":
    return (@[tString()], tResult(tString()))
  of "parseInt":
    return (@[tString()], tResult(tInt()))
  of "parseFloat":
    return (@[tString()], tResult(tFloat()))
  of "parseBool":
    return (@[tString()], tResult(tBool()))
  of "isSome", "isNone":
    return (@[tOption(tInferred())], tBool())
  of "isOk", "isError":
    return (@[tResult(tInferred())], tBool())
  of "__make_closure":
    return (@[tInt(), tArray(tInferred())], tInferred())
  of "__invoke_closure":
    return (@[tInferred()], tInferred())
  else:
    return (@[], tVoid())

# Perform basic type checking for builtin functions
proc performBuiltinTypeCheck*(funcName: string, argTypes: seq[EtchType], pos: Pos): EtchType =
  case funcName
  of "print":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "print expects 1 argument")
    if argTypes[0].kind notin {tkBool, tkChar, tkInt, tkFloat, tkString, tkArray, tkEnum}:
      raise newTypecheckError(pos, &"print supports bool/int/float/string/char/enum, not {argTypes[0]}")
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
    if argTypes.len == 1 and argTypes[0].kind != tkInt:
      raise newTypecheckError(pos, "rand max argument must be int")
    elif argTypes.len == 2:
      if argTypes[0].kind != tkInt:
        raise newTypecheckError(pos, "rand min argument must be int")
      if argTypes[1].kind != tkInt:
        raise newTypecheckError(pos, "rand max argument must be int")
    return tInt()

  of "readFile":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "readFile expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "readFile expects string path")
    return tResult(tString())

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
    return tResult(tInt())

  of "parseFloat":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "parseFloat expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "parseFloat expects string argument")
    return tResult(tFloat())

  of "parseBool":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "parseBool expects 1 argument")
    if argTypes[0].kind != tkString:
      raise newTypecheckError(pos, "parseBool expects string argument")
    return tResult(tBool())

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

  of "isError":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "isError expects 1 argument")
    if argTypes[0].kind != tkResult:
      raise newTypecheckError(pos, "isError expects result[T] argument")
    return tBool()

  of "arrayNew":
    if argTypes.len != 2:
      raise newTypecheckError(pos, "arrayNew expects 2 arguments: size and default value")
    if argTypes[0].kind != tkInt:
      raise newTypecheckError(pos, "arrayNew size argument must be int")
    return tArray(argTypes[1])

  of "__make_closure":
    if argTypes.len != 2:
      raise newTypecheckError(pos, "__make_closure expects 2 arguments (function index, captures array)")
    if argTypes[0].kind != tkInt:
      raise newTypecheckError(pos, "__make_closure first argument must be int")
    if argTypes[1].kind != tkArray:
      raise newTypecheckError(pos, "__make_closure second argument must be array")
    return tInferred()

  of "__invoke_closure":
    if argTypes.len < 1:
      raise newTypecheckError(pos, "__invoke_closure expects at least a closure argument")
    return tInferred()

  else:
    raise newTypecheckError(pos, "unknown builtin function: " & funcName)
