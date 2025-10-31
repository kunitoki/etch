# types.nim
# Common types used across the Etch implementation

import std/[tables, options]


type
  CompilerOptions* = object
    sourceFile*: string
    sourceString*: Option[string]  ## Optional: compile from string instead of file
    runVM*: bool
    verbose*: bool
    debug*: bool  ## Include debug info; if false, compile in release mode with optimizations
    profile*: bool  ## Enable VM profiling
    force*: bool  ## Force recompilation, bypassing cache

  Pos* = object
    line*, col*: int
    filename*: string

  TypeKind* = enum
    tkVoid, tkBool, tkChar, tkInt, tkFloat, tkString, tkArray, tkObject, tkUnion,
    tkRef, tkWeak, tkGeneric, tkOption, tkResult, tkUserDefined, tkDistinct, tkInferred

  GlobalValue* = object
    kind*: TypeKind
    ival*: int64
    fval*: float64
    bval*: bool
    sval*: string
    cval*: char
    refId*: int
    aval*: seq[GlobalValue]
    hasValue*: bool
    wrappedVal*: ref GlobalValue
    oval*: Table[string, GlobalValue]
    unionTypeIdx*: int
    unionVal*: ref GlobalValue


# Branch prediction hints for performance optimization
template likely*(cond: untyped): untyped =
  when defined(gcc) or defined(clang):
    {.emit: "__builtin_expect((" & astToStr(cond) & "), 1)".}
    cond
  else:
    cond


template unlikely*(cond: untyped): untyped =
  when defined(gcc) or defined(clang):
    {.emit: "__builtin_expect((" & astToStr(cond) & "), 0)".}
    cond
  else:
    cond
