# types.nim
# Core type definitions for Etch VM
# Extracted from vm.nim and lifetime.nim to resolve circular dependencies

import std/[tables, sets, monotimes]
import ../common/[cffi]

type
  # ---------------------------------------------------------------------------
  # Value Types (V)
  # ---------------------------------------------------------------------------

  # Optimized V type using discriminated union to reduce memory footprint
  VKind* {.size: sizeof(uint8).} = enum
    vkNil, vkBool, vkChar, vkInt, vkFloat, vkEnum, # Scalars
    vkString, vkArray, vkTable,                    # Containers/Objects
    vkSome, vkNone, vkOk, vkErr,                   # Monads
    vkRef, vkWeak, vkClosure,                      # Heap-managed references and closures
    vkCoroutine, vkChannel, vkTypeDesc             # Coroutines and channels

  VBox* = ref V  # Boxed V for wrapped types (some/ok/error) to avoid recursion

  V* = object
    case kind*: VKind
    of vkNil, vkNone:
      discard
    of vkBool:
      bval*: bool
    of vkChar:
      cval*: char
    of vkInt:
      ival*: int64
    of vkFloat:
      fval*: float64
    of vkString:
      sval*: string
    of vkArray:
      aval*: ref seq[V]  # Use ref to avoid deep copy overhead
    of vkTable:
      tval*: Table[string, V]
    of vkSome, vkOk, vkErr:
      wrapped*: VBox
    of vkRef:
      refId*: int  # Heap object ID
    of vkClosure:
      closureId*: int  # Closure heap object ID
    of vkWeak:
      weakId*: int  # Weak reference ID
    of vkCoroutine:
      coroId*: int  # Coroutine ID
    of vkChannel:
      chanId*: int  # Channel ID
    of vkTypeDesc:
      typeDescName*: string  # Name of the type being described
    of vkEnum:
      enumTypeId*: int       # Type ID for the enum
      enumIntVal*: int64     # Integer value
      enumStringVal*: string # String value

  # ---------------------------------------------------------------------------
  # Heap Types
  # ---------------------------------------------------------------------------

  HeapObjectKind* {.size: sizeof(uint8).} = enum
    hokTable, hokArray, hokClosure, hokRef, hokScalar, hokWeak

  HeapObject* = ref object
    id*: int
    strongRefs*: int
    weakRefs*: int
    destructorFuncIdx*: int
    marked*: bool
    dirty*: bool
    beingDestroyed*: bool
    case kind*: HeapObjectKind
    of hokTable:
      fields*: Table[string, V]
      fieldRefs*: HashSet[int]
      fieldCache*: Table[string, V]
    of hokArray:
      elements*: seq[V]
      elementRefs*: HashSet[int]
    of hokClosure:
      funcIdx*: int
      captures*: seq[V]
      captureRefs*: HashSet[int]
    of hokRef:
      refValue*: V
      refTargetId*: int
    of hokScalar:
      value*: V
    of hokWeak:
      targetId*: int
      targetType*: string

  # Destructor callback type - called when an object with a destructor is freed
  DestructorCallback* = proc(vm: pointer, funcIdx: int, objId: int) {.closure.}

  # Statistics for adaptive cycle detection
  HeapStats* = object
    allocCount*: int
    freeCount*: int
    cyclesDetected*: int
    cycleCheckCount*: int
    totalGCTime*: int64                # Total time spent in GC (nanoseconds)
    avgAllocRate*: float               # Moving average of allocation rate
    lastCheckAllocs*: int              # Allocs at last cycle check

  # Global edge buffer for efficient edge tracking
  EdgeType* {.size: sizeof(uint8).} = enum
    etField, etElement, etCapture, etRef

  EdgeEntry* = object
    sourceId*: int32     # Parent object ID (4 bytes)
    targetId*: int32     # Child object ID (4 bytes)
    nextEdge*: int32     # Next edge index for this source (4 bytes) - Linked list
    fieldHash*: int16    # Hash of field name for debugging (2 bytes)
    edgeType*: EdgeType  # Field vs array element (1 byte)
    padding*: int8       # Padding to align to 16 bytes

  EdgeBuffer* = ref object
    edges*: seq[EdgeEntry]
    index*: seq[int32]   # Object ID -> First edge index (Head of linked list)
    dirtyEdges*: HashSet[int]
    totalEdges*: int
    maxEdges*: int

  # Time-sliced GC state for pause/resume capability
  CycleInfo* = object
    objectIds*: seq[int]
    objectKinds*: seq[HeapObjectKind]
    totalSize*: int

  GCState* = ref object
    inProgress*: bool                     # Is GC currently in progress?
    reachableFromDirty*: HashSet[int]     # Objects reachable from dirty set
    pendingObjects*: seq[int]             # Objects still to process
    tarjanIndex*: int                     # Current Tarjan index
    tarjanStack*: seq[int]                # Tarjan stack
    tarjanIndices*: seq[int]              # Object -> index mapping (O(1) access)
    tarjanLowlinks*: seq[int]             # Object -> lowlink mapping (O(1) access)
    tarjanOnStack*: HashSet[int]          # Objects currently on Tarjan stack
    cycles*: seq[CycleInfo]               # Detected cycles so far
    objectsProcessedThisSlice*: int       # Objects processed in current slice
    maxObjectsPerSlice*: int              # Max objects to process before yielding

  # Bump allocator for temporary frame-local objects (zero overhead)
  BumpAllocator* = ref object
    buffer*: seq[int]                  # Object IDs allocated this frame
    enabled*: bool                     # Is bump allocation enabled?
    maxPerFrame*: int                  # Max temp objects per frame (safety limit)

  # Heap definition (redefined here to include fields)
  Heap* = ref object
    objects*: seq[HeapObject]
    nextId*: int
    freeList*: seq[int]
    dirtyObjects*: HashSet[int]
    weakRefObjects*: HashSet[int] # Track active weak references for fast nullification
    cycleDetectionInterval*: int
    minCycleInterval*: int
    maxCycleInterval*: int
    operationCount*: int
    verbose*: bool
    vm*: pointer # VirtualMachine
    callDestructor*: proc(vm: pointer, funcIdx: int, objId: int) {.nimcall.}
    stats*: HeapStats
    enableVerification*: bool
    verificationInterval*: int
    lastVerificationOp*: int
    frameBudgetUs*: int
    frameStartTime*: MonoTime
    gcWorkThisFrame*: int
    dirtyCheckedThisFrame*: int
    edgeBuffer*: EdgeBuffer
    gcState*: GCState
    bumpAllocator*: BumpAllocator

  # ---------------------------------------------------------------------------
  # Instruction Types
  # ---------------------------------------------------------------------------

  # VM instruction formats
  InstructionFormat* {.size: sizeof(uint8).} = enum
    ifmtABC,    # 3 registers
    ifmtABx,    # register + 16-bit constant/offset
    ifmtAsBx,   # register + signed 16-bit offset
    ifmtAx,     # 26-bit constant for large jumps
    ifmtCall    # function call format

  # Register-based opcodes (3-address format like Lua)
  OpCode* {.size: sizeof(uint8).} = enum
    # Constants and moves
    opMove,          # R[A] = R[B]
    opLoadK,         # R[A] = K[Bx] (load constant)
    opLoadBool,      # R[A] = bool(B), if C skip next
    opLoadNil,       # R[A..B] = nil

    # Global access
    opGetGlobal,     # R[A] = Globals[K[Bx]]
    opSetGlobal,     # Globals[K[Bx]] = R[A]
    opInitGlobal,    # Globals[K[Bx]] = R[A] (only if not already set - for <global> initialization)

    # Arithmetic (R[A] = R[B] op R[C])
    opAdd, opSub, opMul, opDiv, opMod, opPow,
    opAddI,          # R[A] = R[B] + imm (immediate add for common case)
    opSubI,          # R[A] = R[B] - imm
    opMulI,          # R[A] = R[B] * imm
    opDivI,          # R[A] = R[B] / imm
    opModI,          # R[A] = R[B] % imm
    opAndI,          # R[A] = R[B] and imm (boolean immediate)
    opOrI,           # R[A] = R[B] or imm (boolean immediate)

    # Type-specialized arithmetic (no runtime type checks)
    opAddInt,        # R[A] = R[B] + R[C] (integers only)
    opSubInt,        # R[A] = R[B] - R[C] (integers only)
    opMulInt,        # R[A] = R[B] * R[C] (integers only)
    opDivInt,        # R[A] = R[B] / R[C] (integers only)
    opModInt,        # R[A] = R[B] mod R[C] (integers only)
    opAddFloat,      # R[A] = R[B] + R[C] (floats only)
    opSubFloat,      # R[A] = R[B] - R[C] (floats only)
    opMulFloat,      # R[A] = R[B] * R[C] (floats only)
    opDivFloat,      # R[A] = R[B] / R[C] (floats only)
    opModFloat,      # R[A] = R[B] mod R[C] (floats only)

    # Fused arithmetic
    opAddAdd,        # R[A] = R[A] + R[B] + R[C] (generic)
    opAddAddInt,     # R[A] = R[A] + R[B] + R[C] (integers only)
    opAddAddFloat,   # R[A] = R[A] + R[B] + R[C] (floats only)
    opMulAdd,        # R[A] = R[B] * R[C] + R[D] (multiply-add)
    opMulAddInt,     # R[A] = R[D] + (R[B] * R[C]) (integers only)
    opMulAddFloat,   # R[A] = R[B] * R[C] + R[D] (floats only)
    opSubSub,        # R[A] = R[B] - R[C] - R[D] (double subtract)
    opSubSubInt,     # R[A] = R[B] - R[C] - R[D] (integers only)
    opSubSubFloat,   # R[A] = R[B] - R[C] - R[D] (floats only)
    opMulSub,        # R[A] = R[B] * R[C] - R[D] (multiply-subtract)
    opMulSubInt,     # R[A] = R[B] * R[C] - R[D] (integers only)
    opMulSubFloat,   # R[A] = R[B] * R[C] - R[D] (floats only)
    opSubMul,        # R[A] = R[B] - R[C] * R[D] (subtract multiply)
    opSubMulInt,     # R[A] = R[B] - R[C] * R[D] (integers only)
    opSubMulFloat,   # R[A] = R[B] - R[C] * R[D] (floats only)
    opDivAdd,        # R[A] = R[B] / R[C] + R[D] (divide-add)
    opDivAddInt,     # R[A] = R[B] / R[C] + R[D] (integers only)
    opDivAddFloat,   # R[A] = R[B] / R[C] + R[D] (floats only)
    opAddSub,        # R[A] = R[B] + R[C] - R[D] (add-subtract)
    opAddSubInt,     # R[A] = R[B] + R[C] - R[D] (integers only)
    opAddSubFloat,   # R[A] = R[B] + R[C] - R[D] (floats only)
    opAddMul,        # R[A] = (R[B] + R[C]) * R[D] (add then multiply)
    opAddMulInt,     # R[A] = (R[B] + R[C]) * R[D] (integers only)
    opAddMulFloat,   # R[A] = (R[B] + R[C]) * R[D] (floats only)
    opSubDiv,        # R[A] = (R[B] - R[C]) / R[D] (subtract then divide)
    opSubDivInt,     # R[A] = (R[B] - R[C]) / R[D] (integers only)
    opSubDivFloat,   # R[A] = (R[B] - R[C]) / R[D] (floats only)

    # Unary arithmetic
    opUnm,           # R[A] = -R[B]

    # Comparisons (if (R[B] op R[C]) != A then skip)
    opEq, opLt, opLe,
    opEqI,           # R[B] == imm (immediate comparison)
    opLtI,           # R[B] < imm
    opLeI,           # R[B] <= imm
    opLtJmp,         # if R[B] < R[C] then pc += sBx

    # Type-specialized comparisons (no runtime type checks)
    opEqInt,         # if R[B] == R[C] (ints) != A then skip
    opLtInt,         # if R[B] < R[C] (ints) != A then skip
    opLeInt,         # if R[B] <= R[C] (ints) != A then skip
    opEqFloat,       # if R[B] == R[C] (floats) != A then skip
    opLtFloat,       # if R[B] < R[C] (floats) != A then skip
    opLeFloat,       # if R[B] <= R[C] (floats) != A then skip

    # Store comparison results (R[A] = R[B] op R[C])
    opEqStore, opNeStore, opLtStore, opLeStore,

    # Type-specialized store comparisons
    opEqStoreInt,    # R[A] = R[B] == R[C] (ints)
    opLtStoreInt,    # R[A] = R[B] < R[C] (ints)
    opLeStoreInt,    # R[A] = R[B] <= R[C] (ints)
    opEqStoreFloat,  # R[A] = R[B] == R[C] (floats)
    opLtStoreFloat,  # R[A] = R[B] < R[C] (floats)
    opLeStoreFloat,  # R[A] = R[B] <= R[C] (floats)

    # Logic
    opNot,           # R[A] = not R[B]
    opAnd,           # R[A] = R[B] and R[C]
    opOr,            # R[A] = R[B] or R[C]

    # Membership
    opIn,            # R[A] = R[B] in R[C] (check if element is in array/string)
    opNotIn,         # R[A] = R[B] not in R[C]

    # Type conversions
    opCast,          # R[A] = cast(R[B], type=C)

    # Option/Result wrapping
    opWrapSome,      # R[A] = some(R[B])
    opLoadNone,      # R[A] = none
    opWrapOk,        # R[A] = ok(R[B])
    opWrapErr,       # R[A] = error(R[B])
    opTestTag,       # Test if R[A] has tag B, if not skip next
    opUnwrapOption,  # R[A] = unwrap(Option R[B])
    opUnwrapResult,  # R[A] = unwrap(Result R[B])

    # Arrays/Tables
    opNewArray,      # R[A] = new array(size=B)
    opGetIndex,      # R[A] = R[B][R[C]]
    opSetIndex,      # R[A][R[B]] = R[C]
    opGetIndexI,     # R[A] = R[B][imm] (immediate index)
    opSetIndexI,     # R[A][imm] = R[C]

    # Type-specialized array indexing (no runtime type checks)
    opGetIndexInt,   # R[A] = R[B][R[C]] (returns vkInt, array of integers)
    opGetIndexFloat, # R[A] = R[B][R[C]] (returns vkFloat, array of floats)
    opGetIndexIInt,  # R[A] = R[B][imm] (returns vkInt, array of integers)
    opGetIndexIFloat,# R[A] = R[B][imm] (returns vkFloat, array of floats)

    # Type-specialized array set operations (no runtime type checks)
    opSetIndexInt,   # R[A][R[B]] = R[C] (array of integers)
    opSetIndexFloat, # R[A][R[B]] = R[C] (array of floats)
    opSetIndexIInt,  # R[A][imm] = R[C] (array of integers)
    opSetIndexIFloat,# R[A][imm] = R[C] (array of floats)

    opLen,           # R[A] = len(R[B])
    opSlice,         # R[A] = R[B][R[C]:R[D]] (slice operation)
    opConcatArray,   # R[A] = R[B] + R[C] (array concatenation)

    # Objects/Tables
    opNewTable,      # R[A] = new table
    opGetField,      # R[A] = R[B][K[C]] (field access with constant key)
    opSetField,      # R[B][K[C]] = R[A] (field set with constant key)
    opSetRef,        # heap[R[A]] = R[B] (update scalar ref value)

    # Reference counting
    opNewRef,        # R[A] = new heap object (allocate on heap, returns ref)
    opIncRef,        # Increment reference count of R[A]
    opDecRef,        # Decrement reference count of R[A], free if zero
    opNewWeak,       # R[A] = new weak reference to R[B]
    opWeakToStrong,  # R[A] = promote weak ref R[B] to strong (nil if freed)
    opCheckCycles,   # Check for reference cycles and report

    # Control flow
    opJmp,           # pc += sBx (unconditional jump)
    opTest,          # if not (R[A] == C) then skip
    opTestSet,       # if (R[B] == C) then R[A]=R[B] else skip
    opArg,           # Queue R[A] as next call argument
    opArgImm,        # Queue constant K[Bx] as next call argument
    opCall,          # Native Etch call via function table index
    opCallBuiltin,   # Builtin dispatch using builtin ID in funcIdx
    opCallHost,      # Host function call via function table index
    opCallFFI,       # CFFI function call via function table index
    opTailCall,      # tail call optimization
    opReturn,        # return R[A..A+B-2]
    opNoOp,          # No operation (used to maintain jump offsets)

    # Defer support
    opPushDefer,     # Push defer body PC (at pc + sBx) to defer stack
    opExecDefers,    # Execute all defers in reverse order
    opDeferEnd,      # Mark end of defer body (returns from defer execution)

    # Loops (optimized for common patterns)
    opForLoop,       # for loop increment and test
    opForPrep,       # for loop preparation
    opForIntLoop,    # specialized int for loop increment/test
    opForIntPrep,    # specialized int for loop preparation

    # Fused operations (aggressive fusion)
    opCmpJmp,        # Compare and jump in one instruction
    opCmpJmpInt,     # Compare and jump (integers)
    opCmpJmpFloat,   # Compare and jump (floats)
    opIncTest,       # Increment and test (common loop pattern)
    opLoadAddStore,  # Load, add, store pattern
    opLoadSubStore,  # Load, subtract, store pattern
    opLoadMulStore,  # Load, multiply, store pattern
    opLoadDivStore,  # Load, divide, store pattern
    opLoadModStore,  # Load, modulo, store pattern
    opGetAddSet,     # Array[i] += value pattern
    opGetSubSet,     # Array[i] -= value pattern
    opGetMulSet,     # Array[i] *= value pattern
    opGetDivSet,     # Array[i] /= value pattern
    opGetModSet,     # Array[i] %= value pattern

    # Coroutines
    opYield,         # Yield from coroutine: save state, return to caller
    opSpawn,         # R[A] = new coroutine from function at index B with C args
    opResume,        # Resume coroutine R[B], store result in R[A]

    # Channels
    opChannelNew,    # R[A] = new channel with capacity R[B]
    opChannelSend,   # Send R[B] to channel R[A] (may suspend)
    opChannelRecv,   # R[A] = receive from channel R[B] (may suspend)
    opChannelClose   # Close channel R[A]

  # Debug information for instructions
  DebugInfo* = object
    line*: int
    col*: int
    sourceFile*: string
    functionName*: string
    localVars*: seq[string]

  Instruction* {.packed.} = object
    op*: OpCode
    a*: uint8 # Destination register (8-bit = 256 registers)
    case opType*: InstructionFormat
    of ifmtABC:
      b*: uint8
      c*: uint8
    of ifmtABx:
      bx*: uint16
    of ifmtAsBx:
      sbx*: int16
    of ifmtAx:
      ax*: uint32
    of ifmtCall:
      funcIdx*: uint16    # Function index into functionTable
      numArgs*: uint8     # Number of arguments
      numResults*: uint8  # Number of results

  InstructionEntry* = object
    instr*: Instruction
    debug*: DebugInfo

  # ---------------------------------------------------------------------------
  # Lifetime Types (from lifetime.nim)
  # ---------------------------------------------------------------------------

  # Lifetime range for a variable - PC range where it's alive
  LifetimeRange* = object
    varName*: string
    register*: uint8
    startPC*: int      # PC where variable is first defined
    endPC*: int        # PC where variable goes out of scope
    defPC*: int        # PC where variable is actually assigned (may differ from startPC)
    lastUsePC*: int    # PC of last use (for optimization)
    scopeLevel*: int   # Nesting level for scopes

  # Scope information during compilation
  ScopeInfo* = object
    level*: int
    startPC*: int
    variables*: seq[string]  # Variables defined in this scope
    parentScope*: ref ScopeInfo

  # Function-specific lifetime data for embedding in bytecode
  FunctionLifetimeData* = object
    functionName*: string
    ranges*: seq[LifetimeRange]
    pcToVariables*: Table[int, seq[string]]
    destructorPoints*: Table[int, seq[string]]

  # Variable state at a specific PC (for debugger)
  VariableState* = object
    name*: string
    register*: uint8
    isDefined*: bool  # Has been assigned
    value*: pointer   # Optional cached value

  # ---------------------------------------------------------------------------
  # VM Types
  # ---------------------------------------------------------------------------

  RegisterFrame* = object
    regs*: seq[V]                    # Registers (dynamically sized based on function's maxRegister)
    pc*: int                         # Program counter
    base*: int                       # Base register for current function
    returnAddr*: int                 # Return address for function calls
    baseReg*: uint8                  # Result register in calling frame
    deferStack*: seq[int]            # Stack of defer body PC locations to execute on scope exit
    deferReturnPC*: int              # PC to return to after executing a defer body
    when not defined(deploy):
      funcName*: string              # Current function name (for debugging/profiling)

  # Register allocation helper
  RegisterAllocator* = object
    nextReg*: uint8
    maxRegs*: uint8
    highWaterMark*: uint8  # Track the highest register number ever allocated
    regMap*: Table[string, uint8]  # Variable name to register mapping

  # Function kind enum for unified function representation
  FunctionKind* {.size: sizeof(uint8).} = enum
    fkNative,    # Native Etch function
    fkCFFI,      # C FFI function
    fkHost,      # Host function (called via C API)
    fkBuiltin    # Builtin runtime function

  CffiCacheState* = enum
    ccsUnresolved, ccsMissing, ccsReady

  CffiCacheEntry* = object
    state*: CffiCacheState
    function*: CFFIFunction

  # Unified function info that can represent native, C FFI, and host functions
  FunctionInfo* = object
    name*: string
    baseName*: string         # Base name without mangling (e.g., "sin")
    paramTypes*: seq[string]
    returnType*: string
    case kind*: FunctionKind
    of fkNative:
      startPos*: int
      endPos*: int
      maxRegister*: int       # Maximum register number used in this function
    of fkCFFI:
      library*: string        # Normalized library name (e.g., "xyz", "c", "math")
      libraryPath*: string    # Actual resolved library file path (e.g., "whatever/libxyz.so")
      symbol*: string
    of fkHost:
      discard  # Host functions are handled via the hostFunctions table in the VM
    of fkBuiltin:
      builtinId*: uint16      # Encoded BuiltinFuncId for fast dispatch

  BytecodeProgram* = ref object
    instructions*: seq[Instruction]
    debugInfo*: seq[DebugInfo]
    constants*: seq[V]
    entryPoint*: int
    functions*: Table[string, FunctionInfo]  # Unified function table (name -> unified info)
    functionTable*: seq[string]  # Function index table (index -> name for direct calls)
    lifetimeData*: Table[string, pointer]  # Function -> Lifetime data (FunctionLifetimeData) for debugging/destructors
    varMaps*: Table[string, Table[string, uint8]]  # Function -> (variable name -> register) mapping for debugging
    typeDestructors*: Table[string, int]  # Type name -> destructor function index (-1 if none)
    cffiRegistry*: CFFIRegistry        # Shared CFFI registry used when compiling this program

  VirtualMachine* = ref object
    program*: BytecodeProgram             # The program being executed
    frames*: seq[RegisterFrame]           # Call stack of register frames
    framePool*: seq[RegisterFrame]        # Pool of reusable register frames
    currentFrame*: ptr RegisterFrame      # Pointer to current frame for fast access
    constants*: seq[V]                    # Constant pool
    globals*: Table[string, V]            # Global variables
    pendingCallArgs*: seq[V]              # Argument buffer populated by opArg/opArgImm
    argScratch*: seq[V]                   # Scratch buffer reused when materializing call args
    functionInfos*: seq[FunctionInfo]     # Cached function info by index
    functionInfoPresent*: seq[bool]       # Tracks which function indices had metadata
    cffiRegistry*: pointer                # C FFI registry for dynamic library functions (CFFIRegistry)
    cffiCache*: seq[CffiCacheEntry]       # Cached CFFI lookups by index
    hostFunctions*: pointer               # Host functions table from context (Table[string, HostFunctionInfo])
    hostFunctionCache*: pointer           # Optional Table[uint16, HostFunctionInfo] built lazily
    destructorStack*: seq[int]            # Stack of object IDs currently having their destructors executed (prevents per-object recursion)
    heap*: Heap                           # Heap for reference counting (vm_heap.Heap)
    activeCoroId*: int                    # Currently executing coroutine (-1 = main thread)
    coroutines*: seq[pointer]             # Coroutine storage (seq[Coroutine])
    coroRefCounts*: seq[int]              # Reference counts for coroutine values (mirrors coroutines seq)
    coroCleanupProc*: proc(vm: VirtualMachine, coro: pointer) {.closure, nimcall.} # Callback for coroutine cleanup with defer execution
    channels*: seq[pointer]               # Channel storage (seq[Channel])
    comptimeInjections*: Table[string, V] # Values injected during comptime execution
    context*: pointer                     # Back reference to EtchContext that created this VM
    outputCallback*: proc(output: string) {.closure.} # Callback for capturing program output in debug mode
    outputBuffer*: string                 # Shared output buffer for print statements (preserves chronological order across coroutines)
    outputCount*: int                     # Number of print statements in buffer
    rngState*: uint64                     # RNG state for cross-platform deterministic random
    verboseLogging*: bool                 # True when VM is executing with --verbose enabled
    # Capabilities: debugger
    debugger*: pointer                    # Optional debugger (nil for production)
    isDebugging*: bool                    # True when running in debug server mode
    # Capabilities: instruction profiler
    profiler*: pointer                    # Optional profiler (nil for production)
    isProfiling*: bool                    # True when profiling is enabled
    # Capabilities: perfetto tracer
    perfetto*: pointer                    # Optional Perfetto tracer (nil when not tracing)
    isPerfettoTracing*: bool              # True when Perfetto tracing is enabled
    # Capabilities: record/replay
    replayEngine*: pointer                # Optional replay engine (nil when not recording/replaying)
    isReplaying*: bool                    # True when in replay mode (read-only execution)


# Invalid register constant
const InvalidRegister* = uint8.high


# Helpers
template isHeapObject*(v: V): bool =
  v.kind == vkRef or v.kind == vkClosure


template heapObjectId*(v: V): int =
  (if v.kind == vkRef: v.refId
   elif v.kind == vkClosure: v.closureId
   else: 0)


proc `==`*(a, b: Instruction): bool =
  if a.op != b.op or a.a != b.a or a.opType != b.opType:
    return false
  case a.opType
  of ifmtABC:
    return a.b == b.b and a.c == b.c
  of ifmtABx:
    return a.bx == b.bx
  of ifmtAsBx:
    return a.sbx == b.sbx
  of ifmtAx:
    return a.ax == b.ax
  of ifmtCall:
    return a.funcIdx == b.funcIdx and a.numArgs == b.numArgs and a.numResults == b.numResults
