# types.nim
# Common types used across the Etch implementation

import std/[tables, options]


type
  CompilerOptions* = object
    sourceFile*: string            # Source file to compile
    sourceString*: Option[string]  # Optional: compile from string instead of file
    runVirtualMachine*: bool         # Run the VM after compilation
    verbose*: bool                 # Verbose logging during compilation
    debug*: bool                   # Include debug info; if false, compile in release mode with optimizations
    profile*: bool                 # Enable VM profiling
    perfetto*: bool                # Enable Perfetto tracing
    perfettoOutput*: string        # Perfetto output file path
    force*: bool                   # Force recompilation, bypassing cache
    gcCycleInterval*: Option[int]  # GC cycle detection interval in operations (none = use default 1000)

  Pos* = object
    line*, col*: int               # Line and column numbers (1-based)
    filename*: string              # Source filename
    originalFunction*: string      # For inlined code, tracks the original function name

  TypeKind* = enum
    tkVoid, tkBool, tkChar, tkInt, tkFloat, tkString, tkArray, tkObject, tkUnion,
    tkRef, tkWeak, tkGeneric, tkOption, tkResult, tkUserDefined, tkDistinct, tkInferred, tkTuple,
    tkCoroutine, tkChannel, tkEnum, tkFunction, tkTypeDesc

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
    typeDescName*: string


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


when defined(gcc) or defined(clang):
  proc builtinPrefetch*(address: pointer) {.importc: "__builtin_prefetch", cdecl, nodecl.}


proc computeStringHashId*(name: string): int64 =
  ## Deterministically compute an integer identifier for an enum type name.
  var hash: uint64 = 1469598103934665603'u64
  for ch in name:
    hash = (hash xor uint64(ord(ch))) * 1099511628211'u64
  result = int64(hash and 0x7FFFFFFFu64)
