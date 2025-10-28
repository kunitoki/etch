# regvm.nim
# Register-based VM implementation (Lua-inspired architecture)
# This provides significant performance improvements over stack-based VMs

import std/tables


const
  MAX_REGISTERS* = 255  # Maximum number of registers per function frame (must fit in uint8)
  MAX_CONSTANTS* = 65536  # Maximum constants per function (16-bit index)

type
  # Register-based opcodes (3-address format like Lua)
  RegOpCode* = enum
    # Constants and moves
    ropMove,          # R[A] = R[B]
    ropLoadK,         # R[A] = K[Bx] (load constant)
    ropLoadBool,      # R[A] = bool(B), if C skip next
    ropLoadNil,       # R[A..B] = nil

    # Global access
    ropGetGlobal,     # R[A] = Globals[K[Bx]]
    ropSetGlobal,     # Globals[K[Bx]] = R[A]
    ropInitGlobal,    # Globals[K[Bx]] = R[A] (only if not already set - for <global> initialization)

    # Arithmetic (R[A] = R[B] op R[C])
    ropAdd, ropSub, ropMul, ropDiv, ropMod, ropPow,
    ropAddI,          # R[A] = R[B] + imm (immediate add for common case)
    ropSubI,          # R[A] = R[B] - imm
    ropMulI,          # R[A] = R[B] * imm
    ropUnm,           # R[A] = -R[B]

    # Comparisons (if (R[B] op R[C]) != A then skip)
    ropEq, ropLt, ropLe,
    ropEqI,           # R[B] == imm (immediate comparison)
    ropLtI,           # R[B] < imm
    ropLeI,           # R[B] <= imm

    # Store comparison results (R[A] = R[B] op R[C])
    ropEqStore, ropLtStore, ropLeStore,
    ropNeStore,       # R[A] = R[B] != R[C]

    # Logic
    ropNot,           # R[A] = not R[B]
    ropAnd,           # R[A] = R[B] and R[C]
    ropOr,            # R[A] = R[B] or R[C]

    # Membership
    ropIn,            # R[A] = R[B] in R[C] (check if element is in array/string)
    ropNotIn,         # R[A] = R[B] not in R[C]

    # Type conversions
    ropCast,          # R[A] = cast(R[B], type=C)

    # Option/Result wrapping
    ropWrapSome,      # R[A] = some(R[B])
    ropLoadNone,      # R[A] = none
    ropWrapOk,        # R[A] = ok(R[B])
    ropWrapErr,       # R[A] = error(R[B])
    ropTestTag,       # Test if R[A] has tag B, if not skip next
    ropUnwrapOption,  # R[A] = unwrap(Option R[B])
    ropUnwrapResult,  # R[A] = unwrap(Result R[B])

    # Arrays/Tables
    ropNewArray,      # R[A] = new array(size=B)
    ropGetIndex,      # R[A] = R[B][R[C]]
    ropSetIndex,      # R[A][R[B]] = R[C]
    ropGetIndexI,     # R[A] = R[B][imm] (immediate index)
    ropSetIndexI,     # R[A][imm] = R[C]
    ropLen,           # R[A] = len(R[B])
    ropSlice,         # R[A] = R[B][R[C]:R[D]] (slice operation)

    # Objects/Tables
    ropNewTable,      # R[A] = new table
    ropGetField,      # R[A] = R[B][K[C]] (field access with constant key)
    ropSetField,      # R[B][K[C]] = R[A] (field set with constant key)

    # Control flow
    ropJmp,           # pc += sBx (unconditional jump)
    ropTest,          # if not (R[A] == C) then skip
    ropTestSet,       # if (R[B] == C) then R[A]=R[B] else skip
    ropCall,          # R[A..A+C-2] = functionTable[funcIdx](R[A+1..A+B-1]) - function index call
    ropTailCall,      # tail call optimization
    ropReturn,        # return R[A..A+B-2]
    ropNoOp,          # No operation (used to maintain jump offsets)

    # Defer support
    ropPushDefer,     # Push defer body PC (at pc + sBx) to defer stack
    ropExecDefers,    # Execute all defers in reverse order
    ropDeferEnd,      # Mark end of defer body (returns from defer execution)

    # Loops (optimized for common patterns)
    ropForLoop,       # for loop increment and test
    ropForPrep,       # for loop preparation

    # Fused operations (aggressive fusion)
    ropAddAdd,        # R[A] = R[B] + R[C] + R[D] (triple add)
    ropMulAdd,        # R[A] = R[B] * R[C] + R[D] (multiply-add)
    ropCmpJmp,        # Compare and jump in one instruction
    ropIncTest,       # Increment and test (common loop pattern)
    ropLoadAddStore,  # Load, add, store pattern
    ropGetAddSet,     # Array[i] += value pattern

  # Debug information for instructions
  RegDebugInfo* = object
    line*: int
    col*: int
    sourceFile*: string
    functionName*: string
    localVars*: seq[string]

  RegInstruction* = object
    op*: RegOpCode
    a*: uint8         # Destination register (8-bit = 256 registers)
    case opType*: uint8
    of 0:  # ABC format (3 registers)
      b*: uint8
      c*: uint8
    of 1:  # ABx format (register + 16-bit constant/offset)
      bx*: uint16
    of 2:  # AsBx format (register + signed 16-bit offset)
      sbx*: int16
    of 3:  # Ax format (26-bit constant for large jumps)
      ax*: uint32
    of 4:  # Function call format (for ropCall)
      funcIdx*: uint16  # Function index into functionTable
      numArgs*: uint8   # Number of arguments
      numResults*: uint8  # Number of results
    else:
      discard
    debug*: RegDebugInfo  # Debug information for this instruction

  RegisterFrame* = object
    regs*: array[256, V]  # Register file (actual size 256, indexed 0-255)
    pc*: int                         # Program counter
    base*: int                       # Base register for current function
    returnAddr*: int                 # Return address for function calls
    baseReg*: uint8                  # Result register in calling frame
    deferStack*: seq[int]            # Stack of defer body PC locations to execute on scope exit
    deferReturnPC*: int              # PC to return to after executing a defer body

  RegisterVM* = ref object
    frames*: seq[RegisterFrame]     # Call stack of register frames
    currentFrame*: ptr RegisterFrame
    constants*: seq[V]               # Constant pool
    globals*: Table[string, V]      # Global variables
    program*: RegBytecodeProgram    # The program being executed
    debugger*: pointer               # Optional debugger (nil for production)
    isDebugging*: bool               # True when running in debug server mode
    outputCallback*: proc(output: string) {.closure.}  # Callback for capturing program output in debug mode
    cffiRegistry*: pointer           # C FFI registry for dynamic library functions
    rngState*: uint64                # RNG state for cross-platform deterministic random
    profiler*: pointer               # Optional profiler (nil for production)
    isProfiling*: bool               # True when profiling is enabled
    replayEngine*: pointer           # Optional replay engine (nil when not recording/replaying)
    isReplaying*: bool               # True when in replay mode (read-only execution)

  FunctionInfo* = object
    name*: string
    startPos*: int
    endPos*: int
    numParams*: int
    maxRegister*: int  # Maximum register number used in this function

  CFFIInfo* = object
    library*: string        # Normalized library name (e.g., "mathlib", "c", "cmath")
    libraryPath*: string    # Actual resolved library file path (e.g., "examples/clib/libmathlib.so")
    symbol*: string
    baseName*: string       # Base name without mangling (e.g., "sin")
    paramTypes*: seq[string]
    returnType*: string

  RegBytecodeProgram* = object
    instructions*: seq[RegInstruction]
    constants*: seq[V]
    entryPoint*: int
    functions*: Table[string, FunctionInfo]  # Function table (name -> info)
    functionTable*: seq[string]  # Function index table (index -> name for direct calls)
    cffiInfo*: Table[string, CFFIInfo]  # C FFI function metadata
    lifetimeData*: Table[string, pointer]  # Function -> Lifetime data (FunctionLifetimeData) for debugging/destructors
    varMaps*: Table[string, Table[string, uint8]]  # Function -> (variable name -> register) mapping for debugging

  # Optimized V type using discriminated union to reduce memory footprint
  # This significantly improves performance by:
  # 1. Reducing memory copies from 56+ bytes to 8-24 bytes depending on type
  # 2. Eliminating unnecessary reference counting operations
  # 3. Improving cache locality
  VKind* = enum
    vkInt, vkFloat, vkBool, vkChar, vkNil,
    vkString, vkArray, vkTable,
    vkSome, vkNone, vkOk, vkErr

  VBox* = ref V  # Boxed V for wrapped types (some/ok/error) to avoid recursion

  V* = object
    case kind*: VKind
    of vkInt:
      ival*: int64
    of vkFloat:
      fval*: float64
    of vkBool:
      bval*: bool
    of vkChar:
      cval*: char
    of vkNil, vkNone:
      discard
    of vkString:
      sval*: string
    of vkArray:
      aval*: seq[V]
    of vkTable:
      tval*: Table[string, V]
    of vkSome, vkOk, vkErr:
      wrapped*: VBox

# Fast value constructors using discriminated union
template makeInt*(val: int64): V =
  V(kind: vkInt, ival: val)

template makeFloat*(val: float64): V =
  V(kind: vkFloat, fval: val)

template makeBool*(val: bool): V =
  V(kind: vkBool, bval: val)

template makeNil*(): V =
  V(kind: vkNil)

template makeChar*(val: char): V =
  V(kind: vkChar, cval: val)

template makeString*(val: sink string): V =
  V(kind: vkString, sval: val)

template makeSome*(val: V): V =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkSome, wrapped: boxed)

template makeNone*(): V =
  V(kind: vkNone)

template makeOk*(val: V): V =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkOk, wrapped: boxed)

template makeErr*(val: V): V =
  var boxed = new(VBox)
  boxed[] = val
  V(kind: vkErr, wrapped: boxed)

template makeArray*(vals: sink seq[V]): V =
  V(kind: vkArray, aval: vals)

template makeTable*(): V =
  V(kind: vkTable, tval: initTable[string, V]())

# Type checking functions
template isInt*(v: V): bool =
  v.kind == vkInt

template isFloat*(v: V): bool =
  v.kind == vkFloat

template isChar*(v: V): bool =
  v.kind == vkChar

template isBool*(v: V): bool =
  v.kind == vkBool

template isNil*(v: V): bool =
  v.kind == vkNil

template isString*(v: V): bool =
  v.kind == vkString

template isArray*(v: V): bool =
  v.kind == vkArray

template isTable*(v: V): bool =
  v.kind == vkTable

template isSome*(v: V): bool =
  v.kind == vkSome

template isNone*(v: V): bool =
  v.kind == vkNone

template isOk*(v: V): bool =
  v.kind == vkOk

template isErr*(v: V): bool =
  v.kind == vkErr

# Value extraction functions
template getInt*(v: V): int64 =
  v.ival

template getFloat*(v: V): float64 =
  v.fval

template getBool*(v: V): bool =
  v.bval

template getChar*(v: V): char =
  v.cval

template unwrapOption*(v: V): V =
  if v.kind == vkSome:
    v.wrapped[]
  else:
    makeNil()

template unwrapResult*(v: V): V =
  if v.kind == vkOk or v.kind == vkErr:
    v.wrapped[]
  else:
    makeNil()

# Register allocation helper
type
  RegAllocator* = object
    nextReg*: uint8
    maxRegs*: uint8
    highWaterMark*: uint8  # Track the highest register number ever allocated
    regMap*: Table[string, uint8]  # Variable name to register mapping

proc allocReg*(ra: var RegAllocator, name: string = ""): uint8 =
  if name != "" and ra.regMap.hasKey(name):
    return ra.regMap[name]

  if ra.nextReg >= ra.maxRegs:
    # Debug information
    echo "Register allocation failed at register ", ra.nextReg, " (max: ", ra.maxRegs, ")"
    echo "Named registers: ", ra.regMap
    raise newException(ValueError, "Register allocation failed: out of registers")

  result = ra.nextReg
  inc ra.nextReg
  # Track the highest register number we've allocated
  if ra.nextReg > ra.highWaterMark:
    ra.highWaterMark = ra.nextReg
  if name != "":
    ra.regMap[name] = result

proc freeReg*(ra: var RegAllocator, reg: uint8) =
  # Simple register reuse - mark register as free if it's the most recently allocated
  # This works well for expression evaluation where we allocate/free in stack order
  # However, in debug mode, don't reuse registers that belong to named variables
  for name, varReg in ra.regMap:
    if varReg == reg:
      # This register belongs to a named variable, don't free it
      return

  if reg == ra.nextReg - 1:
    dec ra.nextReg

proc setNextReg*(ra: var RegAllocator, newNextReg: uint8) =
  # Set nextReg and automatically update highWaterMark if needed
  ra.nextReg = newNextReg
  if ra.nextReg > ra.highWaterMark:
    ra.highWaterMark = ra.nextReg

# Bytecode generation helpers
proc emitABC*(prog: var RegBytecodeProgram, op: RegOpCode, a, b, c: uint8,
              debug: RegDebugInfo = RegDebugInfo()) {.inline.} =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 0,
    b: b,
    c: c,
    debug: debug
  )

proc emitABx*(prog: var RegBytecodeProgram, op: RegOpCode, a: uint8, bx: uint16,
              debug: RegDebugInfo = RegDebugInfo()) {.inline.} =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 1,
    bx: bx,
    debug: debug
  )

proc emitAsBx*(prog: var RegBytecodeProgram, op: RegOpCode, a: uint8, sbx: int16,
               debug: RegDebugInfo = RegDebugInfo()) {.inline.} =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 2,
    sbx: sbx,
    debug: debug
  )
