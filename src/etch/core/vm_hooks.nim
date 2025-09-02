# vm_hooks.nim

import std/[times, tables, options]
import ../common/[constants, logging]
import ../capabilities/[profiler, debugger, replay]
import ./[vm, vm_types]

when defined(perfetto):
  import ../capabilities/perfetto

  proc beginPerfettoEvent*(vm: VirtualMachine, category: string, name: string, id: uint64 = 0) =
    if vm.isPerfettoTracing and vm.perfetto != nil:
      let tracer = cast[PerfettoTracer](vm.perfetto)
      tracer.beginEvent(category, name, id)

  proc endPerfettoEvent*(vm: VirtualMachine, category: string, name: string, id: uint64 = 0) =
    if vm.isPerfettoTracing and vm.perfetto != nil:
      let tracer = cast[PerfettoTracer](vm.perfetto)
      tracer.endEvent(category, name, id)

  proc flushPerfetto*(vm: VirtualMachine) =
    if vm.isPerfettoTracing and vm.perfetto != nil:
      let tracer = cast[PerfettoTracer](vm.perfetto)
      tracer.flush()


type
  InstructionHookResult* = tuple[
    returnValue: Option[int],
    shouldTakeSnapshot: bool,
    statementToSnapshot: int
  ]

proc onCreateVirtualMachineWithDebugger*(vm: VirtualMachine, debugger: RegEtchDebugger) =
  vm.debugger = cast[pointer](debugger)
  vm.isDebugging = true
  if debugger != nil:
    debugger.attachToVM(cast[pointer](vm))


proc onCreateVirtualMachineWithProfiler*(vm: VirtualMachine) =
  let profiler = newProfiler()
  GC_ref(profiler)  # Keep profiler alive - prevent GC from collecting it
  vm.profiler = cast[pointer](profiler)
  vm.isProfiling = true


proc onCreateVirtualMachineWithPerfetto*(vm: VirtualMachine, outputFile: string) =
  when defined(perfetto):
    let tracer = newPerfettoTracer("etch", outputFile)
    if tracer.startTracing():
      GC_ref(tracer)  # Keep tracer alive
      vm.perfetto = cast[pointer](tracer)
      vm.isPerfettoTracing = true


proc onExecuteBegin*(vm: VirtualMachine, pc: int, verbose: bool): string =
  ## Hook called at the beginning of VM execution
  var currentFuncName = ""

  if not vm.isDebugging:
    if vm.profiler != nil:
      let profilerRef = cast[VirtualMachineProfiler](vm.profiler)
      # Find which function contains the entry point
      for funcName, funcInfo in vm.program.functions:
        if funcInfo.kind == fkNative and pc >= funcInfo.startPos and pc <= funcInfo.endPos:
          profilerRef.enterFunction(funcName)
          currentFuncName = funcName
          break

    when defined(perfetto):
      if vm.isPerfettoTracing:
        # Find which function contains the entry point
        for funcName, funcInfo in vm.program.functions:
          if funcInfo.kind == fkNative and pc >= funcInfo.startPos and pc <= funcInfo.endPos:
            vm.beginPerfettoEvent("function", funcName)
            currentFuncName = funcName
            break

  return currentFuncName


proc onExecuteEnd*(vm: VirtualMachine, currentFuncName: string, verbose: bool) =
  ## Hook called at the end of VM execution
  if vm.isProfiling and vm.profiler != nil:
    let profiler = cast[VirtualMachineProfiler](vm.profiler)
    # Capture execution end time before report generation
    profiler.executionEndTime = getTime()
    let report = profiler.generateReport(addr vm.heap.stats)
    echo report
    GC_unref(profiler)  # Release the reference we acquired with GC_ref()

  when defined(perfetto):
    if vm.isPerfettoTracing:
      vm.endPerfettoEvent("function", currentFuncName)
      vm.flushPerfetto()


proc onInstructionBegin*(vm: VirtualMachine, instr: Instruction, pc: int, verbose: bool): InstructionHookResult =
  ## Hook called at the beginning of each instruction execution
  # Replay engine hook - statement-level snapshots (BEFORE instruction)
  var shouldTakeSnapshot = false
  var statementToSnapshot = 0
  let debug = vm.program.getDebugInfo(pc)

  let replayEngineRef = cast[ReplayEngine](vm.replayEngine)
  if replayEngineRef != nil and replayEngineRef.isRecording:
    # Detect statement changes (new source line)
    if debug.line > 0 and (debug.line != replayEngineRef.lastSourceLine or debug.sourceFile != replayEngineRef.lastSourceFile):
      replayEngineRef.currentStatement += 1
      replayEngineRef.lastSourceLine = debug.line
      replayEngineRef.lastSourceFile = debug.sourceFile
      # Mark that we should take a snapshot AFTER this instruction executes
      if replayEngineRef.currentStatement mod replayEngineRef.snapshotInterval == 0:
        shouldTakeSnapshot = true
        statementToSnapshot = replayEngineRef.currentStatement

  # Profiler hook - before instruction
  let profilerRef = cast[VirtualMachineProfiler](vm.profiler)
  if profilerRef != nil:
    profilerRef.recordInstructionStart(instr.op, debug.sourceFile, debug.line, debug.functionName)

  # Debugger hook - before instruction
  let debuggerRef = cast[RegEtchDebugger](vm.debugger)
  if debuggerRef != nil:
    let res = debuggerRef.debuggerStepVM(pc, debug)
    if res.isSome:
      flushOutput(vm)
      return (res, shouldTakeSnapshot, statementToSnapshot)

  if verbose:
    logVM(verbose, "[" & $pc & "] " & $instr.op & " a=" & $instr.a &
          (if instr.opType == ifmtABC: " b=" & $instr.b & " c=" & $instr.c
          elif instr.opType == ifmtABx: " bx=" & $instr.bx
          elif instr.opType == ifmtAsBx: " sbx=" & $instr.sbx
          elif instr.opType == ifmtAx: " ax=" & $instr.ax
          elif instr.opType == ifmtCall: " funcIdx=" & $instr.funcIdx & " numArgs=" & $instr.numArgs
          else: ""))
    logVM(verbose, "PC=" & $pc & " op=" & $instr.op)

  return (none(int), shouldTakeSnapshot, statementToSnapshot)


proc onInstructionEnd*(vm: VirtualMachine, instr: Instruction, shouldTakeSnapshot: bool, statementToSnapshot: int, verbose: bool) =
  ## Hook called at the beginning of each instruction execution
  # Profiler hook - after instruction
  let profilerRef = cast[VirtualMachineProfiler](vm.profiler)
  if profilerRef != nil:
    profilerRef.recordInstructionEnd(instr.op)

  # Replay engine hook - take snapshot AFTER instruction (if needed)
  let replayEngineRef = cast[ReplayEngine](vm.replayEngine)
  if shouldTakeSnapshot and replayEngineRef != nil:
    replayEngineRef.takeSnapshot(statementToSnapshot)


proc onInvokeClosureInstructionBegin*(vm: VirtualMachine, funcInfo: FunctionInfo, verbose: bool) =
  if vm.debugger != nil:
    let debugger = cast[RegEtchDebugger](vm.debugger)
    let funcDebug = vm.program.getDebugInfo(funcInfo.startPos)
    let targetFile = if funcDebug.sourceFile.len > 0:
      funcDebug.sourceFile
    else:
      MAIN_FUNCTION_NAME
    let targetLine = if funcDebug.line > 0:
      funcDebug.line
    else:
      1
    debugger.pushStackFrame(funcInfo.baseName, targetFile, targetLine, false)

  if vm.profiler != nil:
    let profiler = cast[VirtualMachineProfiler](vm.profiler)
    profiler.enterFunction(funcInfo.baseName)


proc onInvokeClosureInstructionEnd*(vm: VirtualMachine, newFrame: RegisterFrame, pc: int, verbose: bool) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      engine.recordDelta(ExecutionDelta(
        instructionIndex: pc,
        kind: dkFramePush,
        pushedFrame: newFrame
      ))


proc onInvokeNativeInstructionBegin*(vm: VirtualMachine, funcInfo: FunctionInfo, verbose: bool) =
  if vm.debugger != nil:
    let debugger = cast[RegEtchDebugger](vm.debugger)
    let funcDebug = vm.program.getDebugInfo(funcInfo.startPos)
    let targetFile = if funcDebug.sourceFile.len > 0:
      funcDebug.sourceFile
    else:
      MAIN_FUNCTION_NAME
    let targetLine = if funcDebug.line > 0:
      funcDebug.line
    else:
      1

    if funcInfo.baseName == MAIN_FUNCTION_NAME and debugger.stackFrames.len > 0 and
      debugger.stackFrames[^1].functionName == GLOBAL_INIT_FUNCTION_NAME:
      debugger.popStackFrame()

    debugger.pushStackFrame(funcInfo.baseName, targetFile, targetLine, false)

  if vm.profiler != nil:
    let profiler = cast[VirtualMachineProfiler](vm.profiler)
    profiler.enterFunction(funcInfo.baseName)

  when defined(perfetto):
    if vm.isPerfettoTracing:
      vm.beginPerfettoEvent("function", funcInfo.baseName)


proc onInvokeNativeInstructionEnd*(vm: VirtualMachine, newFrame: RegisterFrame, pc: int, verbose: bool) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      engine.recordDelta(ExecutionDelta(
        instructionIndex: pc,
        kind: dkFramePush,
        pushedFrame: newFrame
      ))


proc onReturnInstructionBegin*(vm: VirtualMachine, verbose: bool) =
  if vm.debugger != nil:
    let debugger = cast[RegEtchDebugger](vm.debugger)
    debugger.popStackFrame()

  # Profiler hook - exit function
  if vm.profiler != nil:
    let profiler = cast[VirtualMachineProfiler](vm.profiler)
    profiler.exitFunction()

  when defined(perfetto):
    if vm.isPerfettoTracing:
      vm.endPerfettoEvent("function", vm.currentFunctionName())


proc onReturnInstructionEnd*(vm: VirtualMachine, poppedFrame: RegisterFrame, pc: int, verbose: bool) =
  # Replay engine hook - record frame pop
  var recording = false

  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      recording = true
      engine.recordDelta(ExecutionDelta(
        instructionIndex: pc,
        kind: dkFramePop,
        poppedFrame: poppedFrame
      ))

  # Return to pool if not recording (to avoid corrupting history)
  if not recording:
    vm.framePool.add(poppedFrame)


proc onUpdateRNGState*(vm: VirtualMachine, oldState: uint64, newState: uint64) =
  # Replay engine hook - record RNG state change
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    if engine.isRecording:
      engine.recordDelta(ExecutionDelta(
        instructionIndex: vm.currentFrame.pc,
        kind: dkRNGChange,
        oldRNG: oldState,
        newRNG: newState
      ))
