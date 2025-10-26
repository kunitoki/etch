# regvm_replay.nim
# Replay engine for register-based VM - enables "video scrubbing" through program execution
# This allows seeking to any point in execution history with near-instant performance

import std/[tables, times, streams]
import regvm, ../common/constants


type
  # Lightweight state snapshot taken at intervals
  VMSnapshot* = object
    instructionIndex*: int
    timestamp*: float

    # Full VM state at this point
    frames*: seq[RegisterFrame]
    globals*: Table[string, V]
    rngState*: uint64

    # Debug metadata
    sourceFile*: string
    sourceLine*: int

  # Tracks changes between snapshots
  DeltaKind* = enum
    dkRegWrite      # Register value changed
    dkGlobalWrite   # Global variable changed
    dkFramePush     # Function call (new frame)
    dkFramePop      # Function return (pop frame)
    dkRNGChange     # RNG state changed (for determinism)
    dkPCJump        # Program counter jumped

  ExecutionDelta* = object
    instructionIndex*: int
    case kind*: DeltaKind
    of dkRegWrite:
      frameIdx*: int
      regIdx*: uint8
      oldVal*: V
      newVal*: V
    of dkGlobalWrite:
      globalName*: string
      oldGlobal*: V
      newGlobal*: V
    of dkFramePush:
      pushedFrame*: RegisterFrame
    of dkFramePop:
      poppedFrame*: RegisterFrame
    of dkRNGChange:
      oldRNG*: uint64
      newRNG*: uint64
    of dkPCJump:
      oldPC*: int
      newPC*: int

  ReplayEngine* = ref object
    # Snapshot storage - sparse checkpoints for fast seeking
    snapshots*: seq[VMSnapshot]
    snapshotInterval*: int  # Take snapshot every N statements

    # Delta storage - every state change
    deltas*: seq[ExecutionDelta]
    deltaIndex*: Table[int, seq[int]]  # statementIdx -> delta indices

    # Recording/playback state
    isRecording*: bool
    isReplaying*: bool
    currentStatement*: int    # Current statement execution count
    totalStatements*: int     # Total statements executed
    lastSourceLine*: int      # Last source line we saw (for detecting statement changes)
    lastSourceFile*: string   # Last source file we saw

    # Statistics
    totalSnapshots*: int
    totalDeltas*: int
    recordingStartTime*: float

    # Reference to VM and program
    vm*: RegisterVM
    program*: RegBytecodeProgram


# Create new replay engine
proc newReplayEngine*(vm: RegisterVM, snapshotInterval: int = DEFAULT_SNAPSHOT_INTERVAL): ReplayEngine =
  result = ReplayEngine(
    snapshots: @[],
    snapshotInterval: snapshotInterval,
    deltas: @[],
    deltaIndex: initTable[int, seq[int]](),
    isRecording: false,
    isReplaying: false,
    currentStatement: 0,
    totalStatements: 0,
    lastSourceLine: -1,
    lastSourceFile: "",
    totalSnapshots: 0,
    totalDeltas: 0,
    recordingStartTime: 0.0,
    vm: vm,
    program: vm.program
  )


# Deep copy a RegisterFrame (needed for snapshots)
proc copyRegisterFrame(frame: RegisterFrame): RegisterFrame =
  result = RegisterFrame(
    regs: frame.regs,
    pc: frame.pc,
    base: frame.base,
    returnAddr: frame.returnAddr,
    baseReg: frame.baseReg,
    deferStack: frame.deferStack,
    deferReturnPC: frame.deferReturnPC
  )


# Take full snapshot of VM state
proc takeSnapshot*(engine: ReplayEngine, instrIdx: int) =
  if not engine.isRecording:
    return

  let vm = engine.vm

  # Get debug info if available
  var sourceFile = ""
  var sourceLine = 0
  if instrIdx >= 0 and instrIdx < vm.program.instructions.len:
    let instr = vm.program.instructions[instrIdx]
    sourceFile = instr.debug.sourceFile
    sourceLine = instr.debug.line

  # Deep copy frames
  var framesCopy: seq[RegisterFrame] = @[]
  for frame in vm.frames:
    framesCopy.add(copyRegisterFrame(frame))

  var snapshot = VMSnapshot(
    instructionIndex: instrIdx,
    timestamp: epochTime(),
    frames: framesCopy,
    globals: vm.globals,  # Tables are ref types, but V values are copied
    rngState: vm.rngState,
    sourceFile: sourceFile,
    sourceLine: sourceLine
  )

  engine.snapshots.add(snapshot)
  engine.totalSnapshots += 1


# Record a delta (state change)
proc recordDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  if not engine.isRecording:
    return

  let idx = engine.deltas.len
  engine.deltas.add(delta)
  engine.totalDeltas += 1

  # Index by instruction for fast lookup
  if not engine.deltaIndex.hasKey(delta.instructionIndex):
    engine.deltaIndex[delta.instructionIndex] = @[]
  engine.deltaIndex[delta.instructionIndex].add(idx)


# Restore VM to a specific snapshot
proc restoreSnapshot*(engine: ReplayEngine, snapshot: VMSnapshot) =
  let vm = engine.vm

  # Restore full state - deep copy frames
  vm.frames = @[]
  for frame in snapshot.frames:
    vm.frames.add(copyRegisterFrame(frame))

  vm.globals = snapshot.globals
  vm.rngState = snapshot.rngState

  if vm.frames.len > 0:
    vm.currentFrame = addr vm.frames[^1]
    # Don't overwrite PC - the frame already has the correct PC from the snapshot

  engine.currentStatement = snapshot.instructionIndex


# Apply a delta forward (move forward in time)
proc applyDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  let vm = engine.vm

  case delta.kind
  of dkRegWrite:
    if delta.frameIdx < vm.frames.len:
      vm.frames[delta.frameIdx].regs[delta.regIdx] = delta.newVal
  of dkGlobalWrite:
    vm.globals[delta.globalName] = delta.newGlobal
  of dkFramePush:
    vm.frames.add(copyRegisterFrame(delta.pushedFrame))
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkFramePop:
    if vm.frames.len > 0:
      discard vm.frames.pop()
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkRNGChange:
    vm.rngState = delta.newRNG
  of dkPCJump:
    if vm.frames.len > 0:
      vm.currentFrame.pc = delta.newPC


# Unapply a delta (move backward in time)
proc unapplyDelta*(engine: ReplayEngine, delta: ExecutionDelta) =
  let vm = engine.vm

  case delta.kind
  of dkRegWrite:
    if delta.frameIdx < vm.frames.len:
      vm.frames[delta.frameIdx].regs[delta.regIdx] = delta.oldVal
  of dkGlobalWrite:
    vm.globals[delta.globalName] = delta.oldGlobal
  of dkFramePush:
    if vm.frames.len > 0:
      discard vm.frames.pop()
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkFramePop:
    vm.frames.add(copyRegisterFrame(delta.poppedFrame))
    if vm.frames.len > 0:
      vm.currentFrame = addr vm.frames[^1]
  of dkRNGChange:
    vm.rngState = delta.oldRNG
  of dkPCJump:
    if vm.frames.len > 0:
      vm.currentFrame.pc = delta.oldPC


# Seek to a specific statement (the scrubbing API!)
proc seekTo*(engine: ReplayEngine, targetStmt: int) =
  if engine.snapshots.len == 0:
    return

  # Clamp target to valid range
  let target = max(0, min(targetStmt, engine.totalStatements))

  # Find nearest snapshot BEFORE or AT target
  var nearestSnapshot: VMSnapshot
  var snapshotIdx = -1

  for i in countdown(engine.snapshots.high, 0):
    if engine.snapshots[i].instructionIndex <= target:
      nearestSnapshot = engine.snapshots[i]
      snapshotIdx = i
      break

  if snapshotIdx < 0:
    # Use first snapshot
    nearestSnapshot = engine.snapshots[0]

  # Restore to snapshot
  engine.restoreSnapshot(nearestSnapshot)

  # Apply deltas forward to reach target
  for i in nearestSnapshot.instructionIndex ..< target:
    if engine.deltaIndex.hasKey(i):
      for deltaIdx in engine.deltaIndex[i]:
        engine.applyDelta(engine.deltas[deltaIdx])

  engine.currentStatement = target


# Start recording execution
proc startRecording*(engine: ReplayEngine) =
  engine.isRecording = true
  engine.isReplaying = false
  engine.snapshots = @[]
  engine.deltas = @[]
  engine.deltaIndex = initTable[int, seq[int]]()
  engine.currentStatement = -1  # Will be incremented to 0 on first statement
  engine.lastSourceLine = -1
  engine.lastSourceFile = ""
  engine.totalSnapshots = 0
  engine.totalDeltas = 0
  engine.recordingStartTime = epochTime()


# Stop recording
proc stopRecording*(engine: ReplayEngine) =
  engine.isRecording = false
  engine.totalStatements = engine.currentStatement + 1  # +1 because we started at -1


# Truncate recording from current point and restart (for timeline branching)
proc truncateAndRestart*(engine: ReplayEngine) =
  ## Truncate the recording from the current statement forward
  ## This is used when the user modifies state during debugging
  ## and wants to create a new timeline from that point

  if not engine.isRecording and not engine.isReplaying:
    # Not recording or replaying, nothing to truncate
    return

  let currentStmt = engine.currentStatement

  # Remove all snapshots after current statement
  var newSnapshots: seq[VMSnapshot] = @[]
  for snapshot in engine.snapshots:
    if snapshot.instructionIndex <= currentStmt:
      newSnapshots.add(snapshot)

  engine.snapshots = newSnapshots

  # Clear delta data after current point
  var newDeltas: seq[ExecutionDelta] = @[]
  for delta in engine.deltas:
    if delta.instructionIndex <= currentStmt:
      newDeltas.add(delta)

  engine.deltas = newDeltas

  # Rebuild delta index
  engine.deltaIndex = initTable[int, seq[int]]()
  for i, delta in engine.deltas:
    if not engine.deltaIndex.hasKey(delta.instructionIndex):
      engine.deltaIndex[delta.instructionIndex] = @[]
    engine.deltaIndex[delta.instructionIndex].add(i)

  # Reset counters
  engine.totalSnapshots = engine.snapshots.len
  engine.totalDeltas = engine.deltas.len

  # Restart recording from current point
  engine.isRecording = true
  engine.isReplaying = false

  # Sync the VM's replay flag
  engine.vm.isReplaying = false

  # Take a snapshot at current state (this becomes the new branch point)
  engine.takeSnapshot(currentStmt)


# Start replaying (sets flag to prevent further recording)
proc startReplaying*(engine: ReplayEngine) =
  engine.isReplaying = true
  engine.isRecording = false


# Get current replay progress (0.0 to 1.0)
proc getProgress*(engine: ReplayEngine): float =
  if engine.totalStatements == 0:
    return 0.0
  return engine.currentStatement.float / engine.totalStatements.float


# Get total duration of recorded execution
proc getTotalDuration*(engine: ReplayEngine): float =
  if engine.snapshots.len < 2:
    return 0.0
  return engine.snapshots[^1].timestamp - engine.snapshots[0].timestamp


# Seek to a specific time (in seconds from start)
proc seekToTime*(engine: ReplayEngine, targetTime: float) =
  if engine.snapshots.len == 0:
    return

  let startTime = engine.snapshots[0].timestamp
  let targetTimestamp = startTime + targetTime

  # Find instruction closest to target time
  var bestIdx = 0
  var bestDiff = abs(engine.snapshots[0].timestamp - targetTimestamp)

  for i in 1 ..< engine.snapshots.len:
    let diff = abs(engine.snapshots[i].timestamp - targetTimestamp)
    if diff < bestDiff:
      bestDiff = diff
      bestIdx = i

  # Seek to that instruction
  engine.seekTo(engine.snapshots[bestIdx].instructionIndex)


# Get statistics about the replay session
proc getStats*(engine: ReplayEngine): tuple[snapshots: int, deltas: int,
                                            statements: int, duration: float] =
  return (
    snapshots: engine.totalSnapshots,
    deltas: engine.totalDeltas,
    statements: engine.totalStatements,
    duration: engine.getTotalDuration()
  )


# Print replay statistics (for debugging)
proc printStats*(engine: ReplayEngine) =
  let stats = engine.getStats()
  echo "Replay Statistics:"
  echo "  Total statements executed: ", stats.statements
  echo "  Total snapshots: ", stats.snapshots
  echo "  Total deltas: ", stats.deltas
  echo "  Duration: ", stats.duration, " seconds"
  echo "  Snapshot interval: ", engine.snapshotInterval, " statements"
  if stats.statements > 0:
    echo "  Memory per statement: ~",
         (stats.deltas * 50 + stats.snapshots * 1024) div stats.statements, " bytes"


# Save replay data to file
proc saveToFile*(engine: ReplayEngine, filename: string, sourceFile: string) =
  var stream = newFileStream(filename, fmWrite)
  if stream == nil:
    raise newException(IOError, "Failed to create replay file: " & filename)

  try:
    # Write header
    stream.write("ETCH_REPLAY")
    stream.write(uint32(1))  # Version

    # Write source file path
    stream.write(int32(sourceFile.len))
    if sourceFile.len > 0:
      stream.write(sourceFile)

    # Write metadata
    stream.write(uint32(engine.totalStatements))
    stream.write(int32(engine.snapshotInterval))
    stream.write(float64(engine.getTotalDuration()))

    # Write snapshots count
    stream.write(uint32(engine.snapshots.len))

    # Write each snapshot
    for snapshot in engine.snapshots:
      stream.write(int32(snapshot.instructionIndex))
      stream.write(float64(snapshot.timestamp))
      stream.write(int32(snapshot.sourceFile.len))
      if snapshot.sourceFile.len > 0:
        stream.write(snapshot.sourceFile)
      stream.write(int32(snapshot.sourceLine))

      # Write frames
      stream.write(uint32(snapshot.frames.len))
      for frame in snapshot.frames:
        stream.write(int32(frame.pc))
        stream.write(int32(frame.base))
        stream.write(int32(frame.returnAddr))
        stream.write(uint8(frame.baseReg))

        # Write registers
        for i in 0..<MAX_REGISTERS:
          # Simplified V serialization - just write kind and basic values
          let val = frame.regs[i]
          stream.write(uint8(val.kind))
          case val.kind
          of vkInt: stream.write(val.ival)
          of vkFloat: stream.write(val.fval)
          of vkBool: stream.write(val.bval)
          of vkChar: stream.write(val.cval)
          of vkString:
            stream.write(uint32(val.sval.len))
            if val.sval.len > 0:
              stream.write(val.sval)
          else:
            discard  # Skip complex types for now

      # Write globals
      stream.write(uint32(snapshot.globals.len))
      for key, val in snapshot.globals:
        stream.write(uint32(key.len))
        stream.write(key)
        # Simplified V serialization
        stream.write(uint8(val.kind))
        case val.kind
        of vkInt: stream.write(val.ival)
        of vkFloat: stream.write(val.fval)
        of vkBool: stream.write(val.bval)
        of vkChar: stream.write(val.cval)
        of vkString:
          stream.write(uint32(val.sval.len))
          if val.sval.len > 0:
            stream.write(val.sval)
        else:
          discard

      stream.write(uint64(snapshot.rngState))

  finally:
    stream.close()


# Load replay data from file
proc loadFromFile*(filename: string): tuple[sourceFile: string, totalStatements: int,
                                             snapshotInterval: int, duration: float,
                                             snapshots: seq[VMSnapshot]] =
  var stream = newFileStream(filename, fmRead)
  if stream == nil:
    raise newException(IOError, "Failed to open replay file: " & filename)

  try:
    # Read and verify header
    var header = ""
    header.setLen(11)
    discard stream.readData(addr header[0], 11)
    if header != "ETCH_REPLAY":
      raise newException(ValueError, "Invalid replay file format")

    let version = stream.readUint32()
    if version != 1:
      raise newException(ValueError, "Unsupported replay file version: " & $version)

    # Read source file path
    let sourceFileLen = stream.readInt32()
    var sourceFile = ""
    if sourceFileLen > 0:
      sourceFile.setLen(sourceFileLen)
      discard stream.readData(addr sourceFile[0], sourceFileLen)

    # Read metadata
    let totalStatements = int(stream.readUint32())
    let snapshotInterval = stream.readInt32()
    let duration = stream.readFloat64()

    # Read snapshots
    let snapshotCount = int(stream.readUint32())
    var snapshots: seq[VMSnapshot] = @[]

    for _ in 0..<snapshotCount:
      let instrIdx = stream.readInt32()
      let timestamp = stream.readFloat64()

      let sourceFileLen = stream.readInt32()
      var sourceFile = ""
      if sourceFileLen > 0:
        sourceFile.setLen(sourceFileLen)
        discard stream.readData(addr sourceFile[0], sourceFileLen)

      let sourceLine = stream.readInt32()

      # Read frames
      let frameCount = int(stream.readUint32())
      var frames: seq[RegisterFrame] = @[]

      for _ in 0..<frameCount:
        let pc = stream.readInt32()
        let base = stream.readInt32()
        let returnAddr = stream.readInt32()
        let baseReg = stream.readUint8()

        var frame = RegisterFrame(
          pc: pc,
          base: base,
          returnAddr: returnAddr,
          baseReg: baseReg,
          deferStack: @[],
          deferReturnPC: -1
        )

        # Read registers
        for i in 0..<MAX_REGISTERS:
          let kind = VKind(stream.readUint8())
          case kind
          of vkInt:
            frame.regs[i] = makeInt(stream.readInt64())
          of vkFloat:
            frame.regs[i] = makeFloat(stream.readFloat64())
          of vkBool:
            frame.regs[i] = makeBool(stream.readBool())
          of vkChar:
            frame.regs[i] = makeChar(stream.readChar())
          of vkString:
            let slen = int(stream.readUint32())
            if slen > 0:
              var str = ""
              str.setLen(slen)
              discard stream.readData(addr str[0], slen)
              frame.regs[i] = makeString(str)
            else:
              frame.regs[i] = makeString("")
          else:
            frame.regs[i] = makeNil()

        frames.add(frame)

      # Read globals
      let globalCount = int(stream.readUint32())
      var globals = initTable[string, V]()

      for _ in 0..<globalCount:
        let keyLen = int(stream.readUint32())
        var key = ""
        key.setLen(keyLen)
        discard stream.readData(addr key[0], keyLen)

        let kind = VKind(stream.readUint8())
        case kind
        of vkInt:
          globals[key] = makeInt(stream.readInt64())
        of vkFloat:
          globals[key] = makeFloat(stream.readFloat64())
        of vkBool:
          globals[key] = makeBool(stream.readBool())
        of vkChar:
          globals[key] = makeChar(stream.readChar())
        of vkString:
          let slen = int(stream.readUint32())
          if slen > 0:
            var str = ""
            str.setLen(slen)
            discard stream.readData(addr str[0], slen)
            globals[key] = makeString(str)
          else:
            globals[key] = makeString("")
        else:
          globals[key] = makeNil()

      let rngState = stream.readUint64()

      snapshots.add(VMSnapshot(
        instructionIndex: instrIdx,
        timestamp: timestamp,
        frames: frames,
        globals: globals,
        rngState: rngState,
        sourceFile: sourceFile,
        sourceLine: sourceLine
      ))

    return (sourceFile, totalStatements, snapshotInterval, duration, snapshots)

  finally:
    stream.close()


# Restore replay engine from loaded data
proc restoreReplayEngine*(vm: RegisterVM, totalStatements: int, snapshotInterval: int,
                          snapshots: seq[VMSnapshot]): ReplayEngine =
  result = ReplayEngine(
    snapshots: snapshots,
    snapshotInterval: snapshotInterval,
    deltas: @[],
    deltaIndex: initTable[int, seq[int]](),
    isRecording: false,
    isReplaying: true,
    currentStatement: 0,
    totalStatements: totalStatements,
    lastSourceLine: -1,
    lastSourceFile: "",
    totalSnapshots: snapshots.len,
    totalDeltas: 0,
    recordingStartTime: 0.0,
    vm: vm,
    program: vm.program
  )
