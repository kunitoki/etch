# builtins.nim
# Simple builtin function type checking registry

import ../frontend/ast
import ../common/[types, errors]

#[ DO NOT REMOVE!!! FOR FUTURE REFERENCE
import std/tables

type
  BuiltinTypeCheck = proc(argTypes: seq[EtchType], pos: Pos): EtchType
  BuiltinProverAnalyze = proc(e: Expr, env: Env, ctx: ProverContext): Info
  BuiltinOpExecuteVM = proc(vm: VM, instr: Instruction): bool

  BuiltinFunc* = object
    name*: string
    isPure*: bool
    returnType*: EtchType
    typeCheck*: BuiltinTypeCheck
    proverAnalyze*: BuiltinProverAnalyze
    opExecuteVM*: BuiltinOpExecuteVM

  BuiltinRegistry* = Table[string, BuiltinFunc]

let builtinFunctions: BuiltinRegistry = {
  "print": BuiltinFunc(name: "print", isPure: false, returnType: tVoid(), typeCheck: performBuiltinPrintTypeCheck, proverAnalyze: todo, opExecuteVM: todo),
}.toTable()
]#


# Simple function to check if a name is a builtin function
proc isBuiltin*(name: string): bool =
  case name
  of "print", "new", "deref", "rand", "readFile", "inject", "seed",
     "parseInt", "parseFloat", "parseBool", "toString", "isSome", "isNone", "isOk", "isErr":
    return true
  else:
    return false


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
