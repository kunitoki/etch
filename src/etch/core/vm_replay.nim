# vm_replay.nim

import ../common/constants
import ../capabilities/replay
import ./vm_types


# Enable replay recording on a VM
proc enableReplayRecording*(vm: VirtualMachine, snapshotInterval: int = DEFAULT_SNAPSHOT_INTERVAL) =
  let engine = newReplayEngine(vm, snapshotInterval)
  vm.replayEngine = cast[pointer](engine)
  GC_ref(engine)  # Must keep reference - engine stored as pointer in VM
  engine.startRecording()


# Stop replay recording (but keep engine alive for data extraction)
proc stopReplayRecording*(vm: VirtualMachine) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.stopRecording()


# Clean up replay engine (call after data has been saved/used)
proc cleanupReplayEngine*(vm: VirtualMachine) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    GC_unref(engine)  # Release the reference we took in enableReplayRecording/restoreReplayEngine
    vm.replayEngine = nil


# Seek to a specific statement index
proc seekToStatement*(vm: VirtualMachine, stmtIdx: int) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.seekTo(stmtIdx)


# Seek to a specific time (in seconds from start)
proc seekToTime*(vm: VirtualMachine, targetTime: float) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.seekToTime(targetTime)


# Get current replay progress (0.0 to 1.0)
proc getReplayProgress*(vm: VirtualMachine): float =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getProgress()
  return 0.0


# Get total duration of recorded execution
proc getReplayDuration*(vm: VirtualMachine): float =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getTotalDuration()
  return 0.0


# Get replay statistics
proc getReplayStats*(vm: VirtualMachine): tuple[snapshots: int, deltas: int, statements: int, duration: float] =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    return engine.getStats()
  return (0, 0, 0, 0.0)


# Print replay statistics
proc printReplayStats*(vm: VirtualMachine) =
  if vm.replayEngine != nil:
    let engine = cast[ReplayEngine](vm.replayEngine)
    engine.printStats()
