# vm_execution.nim
# Execution engine for register-based VM with aggressive optimizations

import std/[tables, times, sets, options]
import ../common/[constants, logging, types]
import ../capabilities/debugger
import ./exec_instructions/[move_load, arithmetic, globals, comparison, control_flow, typeconv, option_result, arrays, objects, refcounting, defers, fused, function, coroutines, returns]
import ./[vm, vm_heap, vm_coroutine, vm_types, vm_hooks]




# Forward declarations (defined later in this file)
proc invokeDestructor*(vm: VirtualMachine, funcIdx: int, objId: int)
proc cleanupCoroutineWithDefers*(vm: VirtualMachine, coro: Coroutine)


## Fetch current instruction and prefetch the next one on compilers that support it.
template prepareInstruction*(instructions: seq[Instruction], pc: int, maxInstr: int): Instruction =
  when defined(gcc) or defined(clang):
    let nextPc = pc + 1
    if nextPc < maxInstr:
      builtinPrefetch(cast[pointer](addr instructions[nextPc]))
  instructions[pc]


# Helper to create initial frame with dynamically sized register array
proc createInitialFrame(prog: BytecodeProgram): RegisterFrame =
  result = RegisterFrame()
  result.pc = -1  # Initialize to -1 so execute() uses entryPoint on first run

  # Allocate registers based on <global> function's maxRegister
  # Plus extra registers for function calls during global initialization
  if prog.functions.hasKey(GLOBAL_INIT_FUNCTION_NAME):
    let globalFunc = prog.functions[GLOBAL_INIT_FUNCTION_NAME]
    # Ensure we have at least 5 registers: 1 for the function itself + 4 for common function call arguments
    let numRegs = max(5, globalFunc.maxRegister + 1)
    result.regs = newSeq[V](numRegs)
    for i in 0..<numRegs:
      result.regs[i] = V(kind: vkNil)
  else:
    # Default to MAX_REGISTERS if no global function (shouldn't normally happen)
    result.regs = newSeq[V](MAX_REGISTERS)
    for i in 0..<MAX_REGISTERS:
      result.regs[i] = V(kind: vkNil)


# Create new VM instance
proc newVirtualMachine*(prog: BytecodeProgram): VirtualMachine =
  let initialFrame = createInitialFrame(prog)

  var heap = newHeap(verbose = false, cycleInterval = 1000)
  var cffiRegistry = if prog.cffiRegistry != nil: cast[pointer](addr prog.cffiRegistry[]) else: nil

  result = VirtualMachine(
    frames: @[initialFrame],                     # Initialize with initial frame
    framePool: @[],                              # Initialize empty frame pool
    program: prog,                               # Program bytecode
    constants: prog.constants,                   # Constant pool
    globals: initTable[string, V](),             # Global variable table
    cffiRegistry: cffiRegistry,                  # CFFI function registry
    rngState: 1'u64,                             # Initialize RNG with default seed
    heap: heap,                                  # Heap will be initialized below
    argScratch: @[],                             # Scratch space for function call arguments
    pendingCallArgs: @[],                        # Initialize pending call arguments
    functionInfos: @[],                          # Function info cache
    functionInfoPresent: @[],                    # Function info caches
    cffiCache: @[],                              # Initialize empty CFFI cache
    destructorStack: @[],                        # No destructors running initially
    coroutines: @[],                             # Initialize empty coroutine array
    coroRefCounts: @[],                          # Initialize empty coroutine refcount array
    activeCoroId: -1,                            # No active coroutine initially
    channels: @[],                               # Initialize empty channel array
    comptimeInjections: initTable[string, V](),  # Initialize comptime injections table
    outputBuffer: "",                            # Initialize empty output buffer
    outputCount: 0                               # Initialize output count
  )

  result.currentFrame = addr result.frames[0]
  result.rebuildFunctionCaches()

  # Set up coroutine cleanup callback
  result.coroCleanupProc = proc(vm: VirtualMachine, coro: pointer) =
    cleanupCoroutineWithDefers(vm, cast[Coroutine](coro))

  # Initialize heap for reference counting
  result.heap = heap
  # Set VM reference in heap for destructor calls
  heap.vm = cast[pointer](result)
  # Set destructor callback so heap can invoke destructors
  heap.callDestructor = proc(vmPtr: pointer, funcIdx: int, objId: int) =
    let vm = cast[VirtualMachine](vmPtr)
    invokeDestructor(vm, funcIdx, objId)


proc newVirtualMachineWithDebugger*(prog: BytecodeProgram, debugger: RegEtchDebugger): VirtualMachine =
  result = newVirtualMachine(prog)
  onCreateVirtualMachineWithDebugger(result, debugger)


proc newVirtualMachineWithProfiler*(prog: BytecodeProgram): VirtualMachine =
  result = newVirtualMachine(prog)
  onCreateVirtualMachineWithProfiler(result)


proc newVirtualMachineWithPerfetto*(prog: BytecodeProgram, outputFile: string = ""): VirtualMachine =
  result = newVirtualMachine(prog)
  onCreateVirtualMachineWithPerfetto(result, outputFile)


template dispatchInstruction(vm: VirtualMachine, instr: Instruction, pcVar: var int, verboseFlag: bool) =
  # Use computed goto for maximum performance
  case instr.op:
  # --- No operation - used to maintain jump offsets when optimizations skip instructions ---
  of opNoOp: logVM(verboseFlag, "opNoOp")

  # --- Move and Load Instructions ---
  of opMove: execMove(vm, instr, verboseFlag)
  of opLoadK: execLoadK(vm, instr, verboseFlag)
  of opLoadBool: execLoadBool(vm, instr, pcVar)
  of opLoadNil: execLoadNil(vm, instr, verboseFlag)

  # --- Global Access ---
  of opInitGlobal: execInitGlobal(vm, instr, pcVar)
  of opGetGlobal: execGetGlobal(vm, instr)
  of opSetGlobal: execSetGlobal(vm, instr, pcVar)

  # --- Arithmetic Operations ---
  of opAdd: execAdd(vm, instr)
  of opSub: execSub(vm, instr)
  of opMul: execMul(vm, instr)
  of opDiv: execDiv(vm, instr)
  of opMod: execMod(vm, instr)

  # Type-specialized integer arithmetic (no type checks, direct operations)
  of opAddInt: execAddInt(vm, instr)
  of opSubInt: execSubInt(vm, instr)
  of opMulInt: execMulInt(vm, instr)
  of opDivInt: execDivInt(vm, instr)
  of opModInt: execModInt(vm, instr)

  # Type-specialized float arithmetic (no type checks, direct operations)
  of opAddFloat: execAddFloat(vm, instr)
  of opSubFloat: execSubFloat(vm, instr)
  of opMulFloat: execMulFloat(vm, instr)
  of opDivFloat: execDivFloat(vm, instr)
  of opModFloat: execModFloat(vm, instr)

  # Fused arithmetic
  of opAddAdd: execAddAdd(vm, instr)
  of opAddAddInt: execAddAddInt(vm, instr)
  of opAddAddFloat: execAddAddFloat(vm, instr)
  of opMulAddInt: execMulAddInt(vm, instr)
  of opMulAddFloat: execMulAddFloat(vm, instr)

  of opMulAdd: execMulAdd(vm, instr)
  of opSubSubInt: execSubSubInt(vm, instr)
  of opSubSubFloat: execSubSubFloat(vm, instr)
  of opSubSub: execSubSub(vm, instr)
  of opMulSubInt: execMulSubInt(vm, instr)
  of opMulSubFloat: execMulSubFloat(vm, instr)
  of opMulSub: execMulSub(vm, instr)
  of opSubMulInt: execSubMulInt(vm, instr)
  of opSubMulFloat: execSubMulFloat(vm, instr)
  of opSubMul: execSubMul(vm, instr)
  of opDivAddInt: execDivAddInt(vm, instr)
  of opDivAddFloat: execDivAddFloat(vm, instr)
  of opDivAdd: execDivAdd(vm, instr)
  of opAddSubInt: execAddSubInt(vm, instr)
  of opAddSubFloat: execAddSubFloat(vm, instr)
  of opAddSub: execAddSub(vm, instr)
  of opAddMulInt: execAddMulInt(vm, instr)
  of opAddMulFloat: execAddMulFloat(vm, instr)
  of opAddMul: execAddMul(vm, instr)
  of opSubDivInt: execSubDivInt(vm, instr)
  of opSubDivFloat: execSubDivFloat(vm, instr)
  of opSubDiv: execSubDiv(vm, instr)

  of opPow: execPow(vm, instr)

  # Immediate Arithmetic (Optimized)
  of opAddI: execAddI(vm, instr)
  of opSubI: execSubI(vm, instr)
  of opMulI: execMulI(vm, instr)
  of opDivI: execDivI(vm, instr)
  of opModI: execModI(vm, instr)
  of opAndI: execAndI(vm, instr)
  of opOrI: execOrI(vm, instr)
  of opUnm: execUnm(vm, instr)

  # --- Comparisons ---
  of opEq: execEq(vm, instr, pcVar, verboseFlag)
  of opLt: execLt(vm, instr, pcVar, verboseFlag)
  of opLe: execLe(vm, instr, pcVar, verboseFlag)
  of opLtJmp: execLtJmp(vm, instr, pcVar)

  # --- Type-specialized Comparisons ---
  of opEqInt: execEqInt(vm, instr, pcVar)
  of opLtInt: execLtInt(vm, instr, pcVar)
  of opLeInt: execLeInt(vm, instr, pcVar)
  of opEqFloat: execEqFloat(vm, instr, pcVar)
  of opLtFloat: execLtFloat(vm, instr, pcVar)
  of opLeFloat: execLeFloat(vm, instr, pcVar)

  # --- Immediate Comparisons (Optimized) ---
  of opEqI: execEqI(vm, instr, pcVar)
  of opLtI: execLtI(vm, instr, pcVar)
  of opLeI: execLeI(vm, instr, pcVar)

  # --- Store comparison results in registers ---
  of opEqStore: execEqStore(vm, instr)
  of opNeStore: execNeStore(vm, instr)
  of opLtStore: execLtStore(vm, instr, verboseFlag)
  of opLeStore: execLeStore(vm, instr, verboseFlag)

  # --- Type-specialized Store Comparisons ---
  of opEqStoreInt: execEqStoreInt(vm, instr)
  of opLtStoreInt: execLtStoreInt(vm, instr)
  of opLeStoreInt: execLeStoreInt(vm, instr)
  of opEqStoreFloat: execEqStoreFloat(vm, instr)
  of opLtStoreFloat: execLtStoreFloat(vm, instr)
  of opLeStoreFloat: execLeStoreFloat(vm, instr)

  # --- Logical Operations ---
  of opNot: execNot(vm, instr)
  of opAnd: execAnd(vm, instr, verboseFlag)
  of opOr: execOr(vm, instr)

  # --- Membership operators ---
  of opIn: execIn(vm, instr)
  of opNotIn: execNotIn(vm, instr)

  # --- Type conversions ---
  of opCast: execCast(vm, instr)

  # --- Option/Result handling ---
  of opWrapSome: execWrapSome(vm, instr)
  of opLoadNone: execLoadNone(vm, instr)
  of opWrapOk: execWrapOk(vm, instr)
  of opWrapErr: execWrapError(vm, instr)
  of opTestTag: execTestTag(vm, instr, pcVar, verboseFlag)
  of opUnwrapOption: execUnwrapOption(vm, instr, verboseFlag)
  of opUnwrapResult: execUnwrapResult(vm, instr)

  # --- Arrays ---
  of opNewArray: execNewArray(vm, instr, verboseFlag)
  of opGetIndex: execGetIndex(vm, instr, verboseFlag)
  of opSetIndex: execSetIndex(vm, instr, verboseFlag)
  of opGetIndexI: execGetIndexI(vm, instr, verboseFlag)
  of opSetIndexI: execSetIndexI(vm, instr, verboseFlag)
  of opGetIndexInt: execGetIndexInt(vm, instr, verboseFlag)
  of opGetIndexFloat: execGetIndexFloat(vm, instr, verboseFlag)
  of opGetIndexIInt: execGetIndexIInt(vm, instr, verboseFlag)
  of opGetIndexIFloat: execGetIndexIFloat(vm, instr, verboseFlag)
  of opSetIndexInt: execSetIndexInt(vm, instr, verboseFlag)
  of opSetIndexFloat: execSetIndexFloat(vm, instr, verboseFlag)
  of opSetIndexIInt: execSetIndexIInt(vm, instr, verboseFlag)
  of opSetIndexIFloat: execSetIndexIFloat(vm, instr, verboseFlag)
  of opLen: execLen(vm, instr, verboseFlag)
  of opSlice: execSlice(vm, instr)
  of opConcatArray: execConcatArray(vm, instr, verboseFlag)

  # --- Objects/Tables ---
  of opNewTable: execNewTable(vm, instr, verboseFlag)
  of opGetField: execGetField(vm, instr, verboseFlag)
  of opSetField: execSetField(vm, instr, verboseFlag)

  # --- Reference Counting ---
  of opNewRef: execNewRef(vm, instr, verboseFlag)
  of opSetRef: execSetRef(vm, instr, verboseFlag)
  of opIncRef: execIncRef(vm, instr, verboseFlag)
  of opDecRef: execDecRef(vm, instr, verboseFlag)
  of opNewWeak: execNewWeak(vm, instr, verboseFlag)
  of opWeakToStrong: execWeakToStrong(vm, instr, verboseFlag)
  of opCheckCycles: execCheckCycles(vm, verboseFlag)

  # --- Control Flow ---
  of opJmp: execJmp(vm, instr, pcVar)
  of opTest: execTest(vm, instr, pcVar, verboseFlag)
  of opTestSet: execTestSet(vm, instr, pcVar)

  # --- Loops (Optimized) ---
  of opForIntLoop: execForIntLoop(vm, instr, pcVar, verboseFlag)
  of opForIntPrep: execForIntPrep(vm, instr, pcVar, verboseFlag)
  of opForLoop: execForLoop(vm, instr, pcVar, verboseFlag)
  of opForPrep: execForPrep(vm, instr, pcVar, verboseFlag)

  # --- Function Calls ---
  of opArg: execArg(vm, instr, verboseFlag)
  of opArgImm: execArgImm(vm, instr, verboseFlag)
  of opCall: execCallEtch(vm, instr, pcVar, verboseFlag)
  of opCallBuiltin: execCallBuiltin(vm, instr, pcVar, verboseFlag)
  of opCallHost: execCallHost(vm, instr, pcVar, verboseFlag)
  of opCallFFI: execCallFFI(vm, instr, pcVar, verboseFlag)
  of opReturn:
    if not execReturn(vm, instr, pcVar, verboseFlag):
      break # Execution has ended

  # --- Defer Instructions ---
  of opPushDefer: execPushDefer(vm, instr, pcVar, verboseFlag)
  of opExecDefers: execExecDefers(vm, pcVar, verboseFlag)
  of opDeferEnd: execDeferEnd(vm, pcVar, verboseFlag)

  # --- Fused Instructions (Aggressive Optimization) ---
  of opLoadAddStore: execLoadAddStore(vm, instr, verboseFlag)
  of opLoadSubStore: execLoadSubStore(vm, instr, verboseFlag)
  of opLoadMulStore: execLoadMulStore(vm, instr, verboseFlag)
  of opLoadDivStore: execLoadDivStore(vm, instr, verboseFlag)
  of opLoadModStore: execLoadModStore(vm, instr, verboseFlag)
  of opGetAddSet: execGetAddSet(vm, instr, verboseFlag)
  of opGetSubSet: execGetSubSet(vm, instr, verboseFlag)
  of opGetMulSet: execGetMulSet(vm, instr, verboseFlag)
  of opGetDivSet: execGetDivSet(vm, instr, verboseFlag)
  of opGetModSet: execGetModSet(vm, instr, verboseFlag)

  # --- Jump Compare/Inc ---
  of opCmpJmp: execCmpJmp(vm, instr, pcVar)
  of opCmpJmpInt: execCmpJmpInt(vm, instr, pcVar)
  of opCmpJmpFloat: execCmpJmpFloat(vm, instr, pcVar)
  of opIncTest: execIncTest(vm, instr, pcVar)

  # --- Coroutines ---
  of opYield:
    if handleYield(vm, instr):
      break # Exit execution loop

  of opSpawn: handleSpawn(vm, instr, verboseFlag)
  of opResume: handleResume(vm, instr, execute, verboseFlag)

  # --- Channels ---
  of opChannelNew: handleChannelNew(vm, instr)
  of opChannelSend: handleChannelSend(vm, instr)
  of opChannelRecv: handleChannelRecv(vm, instr)
  of opChannelClose: handleChannelClose(vm, instr)

  # --- Everything else ---
  of opTailCall:
    break


# Main execution loop - highly optimized with case statements
proc execute*(vm: VirtualMachine, verbose: bool = false): int =
  # When debugging or in destructor or executing coroutine, resume from where we left off; otherwise start from entry point
  # For destructors, we set currentFrame.pc before calling execute(), so we need to use it
  # For coroutines, we need to use the coroutine's PC, not the entry point
  # Also respect explicitly set PC (e.g., from C API function calls)
  var pc = if vm.currentFrame.pc >= 0 and (vm.isDebugging or vm.destructorStack.len > 0 or vm.activeCoroId >= 0 or vm.currentFrame.pc != vm.program.entryPoint):
    vm.currentFrame.pc
  else:
    vm.program.entryPoint

  let instructions = vm.program.instructions
  let maxInstr = instructions.len
  vm.currentFrame.pc = pc  # Initialize PC in frame

  vm.verboseLogging = vm.verboseLogging or verbose
  vm.heap.verbose = vm.verboseLogging
  var currentFuncName: string = ""

  let hasHooks = vm.verboseLogging or
    (vm.isDebugging and vm.debugger != nil) or
    (vm.isReplaying and vm.replayEngine != nil) or
    (vm.isReplaying and vm.profiler != nil) or
    vm.isPerfettoTracing

  # Track entry function (typically "main") for profiling and tracing
  when not defined(deploy):
    currentFuncName = onExecuteBegin(vm, pc, verbose)

  # Main dispatch loop - unrolled for common instructions
  if not hasHooks:
    while pc < maxInstr:
      {.computedgoto.}
      let instr = prepareInstruction(instructions, pc, maxInstr)
      vm.currentFrame.pc = pc
      inc pc
      dispatchInstruction(vm, instr, pc, false)

  else:
    while pc < maxInstr:
      let instr = prepareInstruction(instructions, pc, maxInstr)
      vm.currentFrame.pc = pc

      when not defined(deploy):
        let (returnValue, shouldTakeSnapshot, statementToSnapshot) = onInstructionBegin(vm, instr, pc, verbose)
        if returnValue.isSome:
          return returnValue.get()

      inc pc
      dispatchInstruction(vm, instr, pc, verbose)

      when not defined(deploy):
        onInstructionEnd(vm, instr, shouldTakeSnapshot, statementToSnapshot, verbose)

  # Flush any remaining buffered output
  if vm.frames.len <= 1:
    flushOutput(vm)

    when not defined(deploy):
      onExecuteEnd(vm, currentFuncName, verbose)

    # Run final cycle detection before exit
    runFinalCycleDetection(vm)

  return 0


# Run a register-based program
proc runProgram*(prog: BytecodeProgram, verbose: bool = false): (int, Table[string, V]) =
  let vm = newVirtualMachine(prog)

  let exitCode = vm.execute(verbose)

  return (exitCode, vm.comptimeInjections)


# Run a register-based program with profiling
proc runProgramWithProfiler*(prog: BytecodeProgram, verbose: bool = false): (int, Table[string, V]) =
  let vm = newVirtualMachineWithProfiler(prog)

  let exitCode = vm.execute(verbose)

  return (exitCode, vm.comptimeInjections)


# Run a register-based program with Perfetto tracing
proc runProgramWithPerfetto*(prog: BytecodeProgram, outputFile: string = "", verbose: bool = false): (int, Table[string, V]) =
  let vm = newVirtualMachineWithPerfetto(prog, outputFile)

  let exitCode = vm.execute(verbose)

  when defined(perfetto):
    let tracer = cast[PerfettoTracer](vm.perfetto)
    if tracer != nil:
      tracer.stopTracing()
      GC_unref(tracer)

  return (exitCode, vm.comptimeInjections)


# Invoke a destructor function for an object being freed
# This is called from heap deallocation (vm_heap.nim)
proc invokeDestructor*(vm: VirtualMachine, funcIdx: int, objId: int) =
  ## Invoke a destructor function with the given object ID as argument
  ## Called from freeObject when an object with a destructor is being deallocated

  # Validate function index
  if funcIdx < 0 or funcIdx >= vm.functionInfos.len:
    return

  # Prevent recursive destructor calls on the SAME object (but allow nested destructors for different objects)
  if objId in vm.destructorStack:
    return

  let funcInfo = vm.functionInfos[funcIdx]
  if not vm.functionInfoPresent[funcIdx]:
    return

  let funcName = funcInfo.name

  # Mark that we're in THIS object's destructor
  vm.destructorStack.add(objId)

  # Create temporary frame for destructor execution
  let numRegs = max(1, funcInfo.maxRegister + 1)
  var destructorFrame = RegisterFrame()
  destructorFrame.regs = newSeq[V](numRegs)
  destructorFrame.returnAddr = -1  # Special marker: destructor call
  destructorFrame.baseReg = 0
  destructorFrame.deferStack = @[]
  destructorFrame.deferReturnPC = -1
  when not defined(deploy):
    destructorFrame.funcName = funcName

  # Initialize all registers to nil
  for i in 0..<numRegs:
    destructorFrame.regs[i] = V(kind: vkNil)

  # Set the object ref as the first argument (register 0)
  destructorFrame.regs[0] = makeRef(objId)

  # Set PC to destructor start
  destructorFrame.pc = funcInfo.startPos

  # Save current execution state
  # IMPORTANT: Save the frame INDEX, not the pointer, since we'll be replacing vm.frames
  let savedFrameIdx = vm.frames.len - 1
  let savedFrames = vm.frames

  # Create isolated execution context for destructor
  vm.frames = @[destructorFrame]
  vm.currentFrame = addr vm.frames[0]

  # Execute the destructor by calling execute() on the isolated context
  # This reuses all the opcode handling from the main VM loop
  try:
    discard execute(vm, verbose = false)
  except CatchableError as e:
    # TODO: Log error to VM's error handling system
    echo "[HEAP] Error in destructor ", funcName, ": ", e.msg
  except Exception as e:
    # TODO: Log error to VM's error handling system
    echo "[HEAP] Fatal error in destructor ", funcName, ": ", e.msg
  finally:
    # Remove this object from the destructor stack
    vm.destructorStack.delete(vm.destructorStack.len - 1)
    # Restore execution state
    vm.frames = savedFrames
    if savedFrameIdx >= 0 and savedFrameIdx < vm.frames.len:
      vm.currentFrame = addr vm.frames[savedFrameIdx]


proc cleanupCoroutineWithDefers*(vm: VirtualMachine, coro: Coroutine) =
  ## Execute deferred cleanup blocks and clean up coroutine resources
  ## This is the main entry point for coroutine cleanup, called from opDecRef

  let verbose = vm.verboseLogging
  if coro == nil:
    logVM(verbose, "cleanupCoroutineWithDefers: received nil coroutine reference")
    return

  logVM(verbose, "cleanupCoroutineWithDefers: coroId=" & $coro.id &
        " state=" & $coro.state & " savedPC=" & $coro.savedFrame.pc &
        " resumePC=" & $coro.resumePC & " defers=" & $coro.savedFrame.deferStack.len)

  if coro.state == csDead:
    logVM(verbose, "cleanupCoroutineWithDefers: coroId=" & $coro.id & " already dead, skipping")
    return  # Already cleaned up

  # Mark as dead FIRST to prevent re-entrant cleanup or resume
  coro.state = csDead
  logVM(verbose, "cleanupCoroutineWithDefers: marked coroId=" & $coro.id & " as csDead")

  # Execute defers if any are registered in the coroutine's frame
  # We do this BEFORE cleaning up refs, while the frame is still intact
  if coro.savedFrame.deferStack.len > 0:
    # Save current VM state
    # Save frame INDEX instead of pointer, since pointer becomes invalid after seq assignment
    let savedFrameIndex = vm.frames.len - 1  # Index of current frame
    let savedActiveCoroId = vm.activeCoroId
    let savedDestructorStack = vm.destructorStack
    var savedFrames = vm.frames

    # Mark that we're in a destructor-like context to prevent re-entrant cleanup
    # Use a special sentinel value (-1) to indicate "in defer cleanup"
    vm.destructorStack = @[-1]

    # Restore coroutine's frame temporarily to execute defers
    vm.frames = @[coro.savedFrame]
    vm.currentFrame = addr vm.frames[0]
    vm.activeCoroId = -1  # Not in an active coroutine context
    logVM(verbose, "cleanupCoroutineWithDefers: executing " & $vm.currentFrame.deferStack.len &
      " defer(s) for coroId=" & $coro.id & " stack=" & $coro.savedFrame.deferStack)

    # Set up defer execution - simulate what happens at function exit
    # We set a fake return PC that we'll use to detect when defers are done
    let fakeReturnPC = vm.program.instructions.len  # Beyond end of program
    vm.currentFrame.deferReturnPC = fakeReturnPC

    # Start executing from the first defer
    # NOTE: The defer PC points to opDeferEnd, but we need to execute from the defer body start
    # The defer body is always 1 instruction before opDeferEnd
    var pc = vm.currentFrame.deferStack[vm.currentFrame.deferStack.len - 1] - 1
    vm.currentFrame.deferStack.setLen(vm.currentFrame.deferStack.len - 1)
    vm.currentFrame.pc = pc
    logVM(verbose, "cleanupCoroutineWithDefers: starting defer execution at PC=" & $pc & " fakeReturnPC=" & $fakeReturnPC)

    # Execute instructions until we return to the fake PC (all defers done)
    let maxInstr = vm.program.instructions.len
    var iterLimit = 10000  # Safety limit to prevent infinite loops
    while pc < maxInstr and pc != fakeReturnPC and iterLimit > 0:
      iterLimit -= 1

      let instrPC = pc
      let instr = vm.program.instructions[pc]
      vm.currentFrame.pc = instrPC

      inc pc
      logVM(verbose, "cleanupCoroutineWithDefers: executing defer instr PC=" & $instrPC & " op=" & $instr.op)

      # Execute the instruction - use the same dispatch as the main loop
      # but skip coroutine operations and returns (handled specially)
      case instr.op:
      # Skip coroutine operations during cleanup
      of opYield, opResume, opSpawn:
        logVM(verbose, "cleanupCoroutineWithDefers: skipping coroutine op " & $instr.op & " at PC=" & $instrPC)
        continue

      # Handle defer control flow
      of opDeferEnd:
        execDeferEnd(vm, pc, false)
        logVM(verbose, "cleanupCoroutineWithDefers: finished defer body, next PC=" & $pc)

      # Handle returns from defer bodies
      of opReturn:
        # Check if we're in a nested function call (frames.len > 1)
        if vm.frames.len > 1:
          # Pop the function frame and return to caller
          let returnAddr = vm.currentFrame.returnAddr
          vm.frames.setLen(vm.frames.len - 1)
          vm.currentFrame = addr vm.frames[^1]
          pc = returnAddr - 1
          logVM(verbose, "cleanupCoroutineWithDefers: returning from nested frame to PC=" & $pc)
        elif vm.currentFrame.deferStack.len > 0:
          # Returning from defer body, more defers to execute
          let nextDeferPC = vm.currentFrame.deferStack[vm.currentFrame.deferStack.len - 1]
          vm.currentFrame.deferStack.setLen(vm.currentFrame.deferStack.len - 1)
          pc = nextDeferPC
          logVM(verbose, "cleanupCoroutineWithDefers: continuing with next defer at PC=" & $pc)
        else:
          # No more defers, return to fake PC to exit loop
          pc = vm.currentFrame.deferReturnPC
          logVM(verbose, "cleanupCoroutineWithDefers: all defer bodies finished, jumping to fakeReturnPC")

      # Execute all other instructions normally
      of opMove: execMove(vm, instr, false)
      of opLoadK: execLoadK(vm, instr, false)
      of opLoadBool: execLoadBool(vm, instr, pc)
      of opLoadNil: execLoadNil(vm, instr, false)
      of opGetGlobal: execGetGlobal(vm, instr)
      of opSetGlobal: execSetGlobal(vm, instr, pc)
      of opAdd: execAdd(vm, instr)
      of opSub: execSub(vm, instr)
      of opMul: execMul(vm, instr)
      of opDiv: execDiv(vm, instr)
      of opMod: execMod(vm, instr)
      of opPow: execPow(vm, instr)
      of opUnm: execUnm(vm, instr)
      of opAddI: execAddI(vm, instr)
      of opSubI: execSubI(vm, instr)
      of opMulI: execMulI(vm, instr)
      of opEq: execEq(vm, instr, pc, false)
      of opLt: execLt(vm, instr, pc, verbose)
      of opLe: execLe(vm, instr, pc, verbose)
      of opNot: execNot(vm, instr)
      of opAnd: execAnd(vm, instr, false)
      of opOr: execOr(vm, instr)
      of opIncRef: execIncRef(vm, instr, false)
      of opDecRef: execDecRef(vm, instr, false)
      of opArg: execArg(vm, instr, false)
      of opArgImm: execArgImm(vm, instr, false)
      of opCall: execCallEtch(vm, instr, pc, false)
      of opCallBuiltin: execCallBuiltin(vm, instr, pc, false)
      of opCallHost: execCallHost(vm, instr, pc, false)
      of opCallFFI: execCallFFI(vm, instr, pc, false)
      # For all other instructions (jumps, arrays, etc.), handle them normally
      # We need to be comprehensive here to support arbitrary defer bodies
      else:
        logVM(verbose, "cleanupCoroutineWithDefers: skipping unsupported op " & $instr.op & " during cleanup")
        # Skip other complex instructions during cleanup
        discard

    # Restore VM state
    vm.frames = savedFrames
    # Recalculate frame pointer from saved index (pointer would be invalid after seq assignment)
    if savedFrameIndex >= 0 and savedFrameIndex < vm.frames.len:
      vm.currentFrame = addr vm.frames[savedFrameIndex]
    vm.activeCoroId = savedActiveCoroId
    vm.destructorStack = savedDestructorStack
    logVM(verbose, "cleanupCoroutineWithDefers: completed defer execution for coroId=" & $coro.id)
  else:
    logVM(verbose, "cleanupCoroutineWithDefers: no defers registered for coroId=" & $coro.id)

  # Decrement refcounts for all values in the coroutine's saved registers
  logVM(verbose, "cleanupCoroutineWithDefers: releasing register refs for coroId=" & $coro.id & " regs=" & $coro.savedFrame.regs.len)
  for i, val in coro.savedFrame.regs:
    if val.isHeapObject:
      let obj = vm.heap.getObject(val.heapObjectId)
      if obj != nil:
        vm.heap.decRef(val.heapObjectId)
      elif verbose:
        logVM(verbose, "cleanupCoroutineWithDefers: skipping decRef for freed object #" & $val.heapObjectId)
    # Always clear the register so future cleanup passes see vkNil and skip it
    coro.savedFrame.regs[i] = V(kind: vkNil)

  # Release GC reference (already marked as dead above)
  GC_unref(coro)
  logVM(verbose, "cleanupCoroutineWithDefers: finished cleanup for coroId=" & $coro.id)


# Frame Budget API Implementation

proc beginFrameImpl*(vm: VirtualMachine, budgetUs: int64) =
  ## Implementation of beginFrame - starts a new frame with GC budget
  vm.heap.beginHeapFrame(budgetUs)


proc needsGCFrameImpl*(vm: VirtualMachine): bool =
  ## Implementation of needsGCFrame - checks if GC needs more time
  return vm.heap.dirtyObjects.len > 1000


proc getGCFrameStatsImpl*(vm: VirtualMachine): tuple[usedUs: int64, budgetUs: int64, dirtyCount: int] =
  ## Implementation of getGCFrameStats - returns frame GC statistics
  return vm.heap.getFrameGCStats()


proc setHeapVerbose*(vm: VirtualMachine, verbose: bool) =
  ## Set heap verbose mode for GC debugging
  vm.heap.verbose = verbose


proc setHeapCycleInterval*(vm: VirtualMachine, interval: int) =
  ## Set GC cycle detection interval (operations between cycle checks)
  vm.heap.cycleDetectionInterval = interval
  vm.heap.minCycleInterval = max(100, interval div 10)
  vm.heap.maxCycleInterval = interval * 10
