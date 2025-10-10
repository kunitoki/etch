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

    # Type conversions
    ropCast,          # R[A] = cast(R[B], type=C)

    # Option/Result wrapping
    ropWrapSome,      # R[A] = Some(R[B])
    ropLoadNone,      # R[A] = None
    ropWrapOk,        # R[A] = Ok(R[B])
    ropWrapErr,       # R[A] = Err(R[B])
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
    ropCall,          # R[A..A+C-2] = R[A](R[A+1..A+B-1])
    ropTailCall,      # tail call optimization
    ropReturn,        # return R[A..A+B-2]

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
    else:
      discard
    debug*: RegDebugInfo  # Debug information for this instruction

  RegisterFrame* = object
    regs*: array[256, V]  # Register file (actual size 256, indexed 0-255)
    pc*: int                         # Program counter
    base*: int                       # Base register for current function
    returnAddr*: int                 # Return address for function calls
    baseReg*: uint8                  # Result register in calling frame

  RegisterVM* = ref object
    frames*: seq[RegisterFrame]     # Call stack of register frames
    currentFrame*: ptr RegisterFrame
    constants*: seq[V]               # Constant pool
    globals*: Table[string, V]      # Global variables
    program*: RegBytecodeProgram    # The program being executed
    debugger*: pointer               # Optional debugger (nil for production)
    isDebugging*: bool               # True when running in debug server mode
    cffiRegistry*: pointer           # C FFI registry for dynamic library functions

  FunctionInfo* = object
    name*: string
    startPos*: int
    endPos*: int
    numParams*: int
    numLocals*: int

  CFFIInfo* = object
    library*: string
    symbol*: string
    baseName*: string  # Base name without mangling (e.g., "sin")
    paramTypes*: seq[string]
    returnType*: string

  RegBytecodeProgram* = object
    instructions*: seq[RegInstruction]
    constants*: seq[V]
    entryPoint*: int
    functions*: Table[string, FunctionInfo]  # Function table
    cffiInfo*: Table[string, CFFIInfo]  # C FFI function metadata
    variableMap*: Table[string, Table[string, uint8]]  # Function -> Variable name -> Register mapping
    lifetimeData*: Table[string, pointer]  # Function -> Lifetime data (FunctionLifetimeData) for debugging/destructors

  # Reuse V type from main VM but with optimizations
  V* = object
    # Type tag and immediate data (tag in upper 16 bits)
    data*: uint64
    # Numeric storage - either int or float value
    ival*: int64    # Store full int64 value (also used for bool, char)
    fval*: float64  # Store full float value
    # Secondary storage for complex types (only used when needed)
    sval*: string
    aval*: seq[V]
    tval*: Table[string, V]

# Type tags for NaN-boxing (upper 16 bits of data field)
const
  TAG_INT*    = 0x0000'u64
  TAG_FLOAT*  = 0x0001'u64
  TAG_BOOL*   = 0x0002'u64
  TAG_NIL*    = 0x0003'u64
  TAG_STRING* = 0x0004'u64
  TAG_ARRAY*  = 0x0005'u64
  TAG_TABLE*  = 0x0006'u64
  TAG_CHAR*   = 0x0007'u64
  TAG_SOME*   = 0x0008'u64  # Option[T].Some
  TAG_NONE*   = 0x0009'u64  # Option[T].None
  TAG_OK*     = 0x000A'u64  # Result[T].Ok
  TAG_ERR*    = 0x000B'u64  # Result[T].Err

# Fast value constructors using NaN-boxing
proc makeInt*(val: int64): V {.inline.} =
  # Store full 64-bit integer value
  result.data = TAG_INT shl 48
  result.ival = val

proc makeFloat*(val: float64): V {.inline.} =
  # For floats, we need to store the full 64 bits somewhere
  # We'll use a secondary field for this
  result.data = TAG_FLOAT shl 48 or (cast[uint64](val) and 0xFFFF)  # Store lower 16 bits in data
  # Store full float value - we need a new field for this
  result.fval = val

proc makeBool*(val: bool): V {.inline.} =
  V(data: uint64(val) or (TAG_BOOL shl 48))

proc makeNil*(): V {.inline.} =
  V(data: TAG_NIL shl 48)

proc makeChar*(val: char): V {.inline.} =
  V(data: uint64(val.ord) or (TAG_CHAR shl 48))

proc makeString*(val: string): V {.inline.} =
  result.data = TAG_STRING shl 48
  result.sval = val

proc makeSome*(val: V): V {.inline.} =
  # Create an Option.Some value wrapping the given value
  result = val  # Copy the wrapped value (including all fields)
  # Store the original tag in bits 32-47 and set TAG_SOME as the main tag
  let originalTag = (val.data shr 48) and 0xFFFF
  result.data = (TAG_SOME shl 48) or (originalTag shl 32) or (val.data and 0xFFFFFFFF'u64)

proc makeNone*(): V {.inline.} =
  # Create an Option.None value
  result.data = TAG_NONE shl 48

proc makeOk*(val: V): V {.inline.} =
  # Create a Result.Ok value wrapping the given value
  result = val  # Copy the wrapped value (including all fields)
  # Store the original tag in bits 32-47 and set TAG_OK as the main tag
  let originalTag = (val.data shr 48) and 0xFFFF
  result.data = (TAG_OK shl 48) or (originalTag shl 32) or (val.data and 0xFFFFFFFF'u64)

proc makeErr*(val: V): V {.inline.} =
  # Create a Result.Err value wrapping the error
  result = val  # Copy the error value (usually string) - including all fields
  # Store the original tag in bits 32-47 and set TAG_ERR as the main tag
  let originalTag = (val.data shr 48) and 0xFFFF
  result.data = (TAG_ERR shl 48) or (originalTag shl 32) or (val.data and 0xFFFFFFFF'u64)

proc makeArray*(vals: seq[V]): V {.inline.} =
  result.data = TAG_ARRAY shl 48
  result.aval = vals

proc makeTable*(): V {.inline.} =
  result.data = TAG_TABLE shl 48
  result.tval = initTable[string, V]()

proc getTag*(v: V): uint64 {.inline.} =
  v.data shr 48

proc isInt*(v: V): bool {.inline.} =
  getTag(v) == TAG_INT

proc isFloat*(v: V): bool {.inline.} =
  getTag(v) == TAG_FLOAT

proc isChar*(v: V): bool {.inline.} =
  getTag(v) == TAG_CHAR

proc getChar*(v: V): char {.inline.} =
  char(v.data and 0xFF)

proc getInt*(v: V): int64 {.inline.} =
  # Return full 64-bit integer value
  v.ival

proc getFloat*(v: V): float64 {.inline.} =
  v.fval

proc isString*(v: V): bool {.inline.} =
  getTag(v) == TAG_STRING

proc isBool*(v: V): bool {.inline.} =
  getTag(v) == TAG_BOOL

proc getBool*(v: V): bool {.inline.} =
  (v.data and 0xFF) != 0

proc isNil*(v: V): bool {.inline.} =
  getTag(v) == TAG_NIL

proc isSome*(v: V): bool {.inline.} =
  getTag(v) == TAG_SOME

proc isNone*(v: V): bool {.inline.} =
  getTag(v) == TAG_NONE

proc isOk*(v: V): bool {.inline.} =
  getTag(v) == TAG_OK

proc isErr*(v: V): bool {.inline.} =
  getTag(v) == TAG_ERR

proc isArray*(v: V): bool {.inline.} =
  getTag(v) == TAG_ARRAY

proc isTable*(v: V): bool {.inline.} =
  getTag(v) == TAG_TABLE

proc unwrapOption*(v: V): V {.inline.} =
  # Unwrap a Some value to get the inner value
  if isSome(v):
    # The wrapped value is stored in the lower bits with its own tag
    # We need to extract the complete wrapped value, preserving its tag
    result = v
    # The tag of the wrapped value is stored in bits 32-47
    let wrappedTag = (v.data shr 32) and 0xFFFF
    # Clear the Some tag and shift the wrapped tag to the correct position
    result.data = (wrappedTag shl 48) or (v.data and 0xFFFFFFFF'u64)
  else:
    result = makeNil()

proc unwrapResult*(v: V): V {.inline.} =
  # Unwrap an Ok or Err value to get the inner value
  if isOk(v) or isErr(v):
    result = v
    # The tag of the wrapped value is stored in bits 32-47
    let wrappedTag = (v.data shr 32) and 0xFFFF
    # Clear the Ok/Err tag and shift the wrapped tag to the correct position
    result.data = (wrappedTag shl 48) or (v.data and 0xFFFFFFFF'u64)
  else:
    result = makeNil()

# Register allocation helper
type
  RegAllocator* = object
    nextReg*: uint8
    maxRegs*: uint8
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

# Bytecode generation helpers
proc emitABC*(prog: var RegBytecodeProgram, op: RegOpCode, a, b, c: uint8,
              debug: RegDebugInfo = RegDebugInfo()) =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 0,
    b: b,
    c: c,
    debug: debug
  )

proc emitABx*(prog: var RegBytecodeProgram, op: RegOpCode, a: uint8, bx: uint16,
              debug: RegDebugInfo = RegDebugInfo()) =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 1,
    bx: bx,
    debug: debug
  )
  when defined(debugRegCompiler):
    echo "[EMIT] ", prog.instructions.len - 1, ": ", op, " a=", a, " bx=", bx

proc emitAsBx*(prog: var RegBytecodeProgram, op: RegOpCode, a: uint8, sbx: int16,
               debug: RegDebugInfo = RegDebugInfo()) =
  prog.instructions.add RegInstruction(
    op: op,
    a: a,
    opType: 2,
    sbx: sbx,
    debug: debug
  )
