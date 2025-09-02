# profiler.nim

import std/[tables, times, algorithm, strutils, strformat, sequtils, os]
import ../core/vm_types
import ../bytecode/frontend/ast


type
  SourceLocation* = object
    file*: string
    line*: int
    functionName*: string

  SourceLocationProfile* = object
    location*: SourceLocation
    opcode*: OpCode
    count*: uint64
    totalTime*: Duration

  InstructionProfile* = object
    opcode*: OpCode
    count*: uint64
    totalTime*: Duration

  FunctionProfile* = object
    name*: string
    callCount*: uint64
    totalTime*: Duration
    selfTime*: Duration
    instructionCount*: uint64
    childCalls*: Table[string, uint64]

  ProfilerFrame* = object
    functionName*: string
    startTime*: Time
    startInstructionCount*: uint64
    instructionCount*: uint64

  VirtualMachineProfiler* = ref object
    enabled*: bool
    startTime*: Time
    executionEndTime*: Time
    totalInstructions*: uint64
    instructionProfiles*: Table[OpCode, InstructionProfile]
    sourceLocationProfiles*: seq[SourceLocationProfile]
    functionProfiles*: Table[string, FunctionProfile]
    frameStack*: seq[ProfilerFrame]
    lastInstructionTime*: Time
    lastSourceLocation*: SourceLocation
    sampleInterval*: int


proc newProfiler*(): VirtualMachineProfiler =
  result = VirtualMachineProfiler(
    enabled: true,
    startTime: getTime(),
    executionEndTime: getTime(),
    totalInstructions: 0,
    instructionProfiles: initTable[OpCode, InstructionProfile](),
    sourceLocationProfiles: @[],
    functionProfiles: initTable[string, FunctionProfile](),
    frameStack: @[],
    lastInstructionTime: getTime(),
    lastSourceLocation: SourceLocation(file: "", line: 0, functionName: ""),
    sampleInterval: 1
  )


proc recordInstructionStart*(profiler: VirtualMachineProfiler, opcode: OpCode, sourceFile: string = "", line: int = 0, functionName: string = "") {.inline.} =
  if not profiler.enabled:
    return

  profiler.lastInstructionTime = getTime()
  profiler.lastSourceLocation = SourceLocation(file: sourceFile, line: line, functionName: functionName)
  profiler.totalInstructions += 1
  if profiler.frameStack.len > 0:
    profiler.frameStack[^1].instructionCount += 1


proc recordInstructionEnd*(profiler: VirtualMachineProfiler, opcode: OpCode) {.inline.} =
  if not profiler.enabled:
    return

  let endTime = getTime()
  let duration = endTime - profiler.lastInstructionTime

  if not profiler.instructionProfiles.hasKey(opcode):
    profiler.instructionProfiles[opcode] = InstructionProfile(
      opcode: opcode,
      count: 0,
      totalTime: initDuration()
    )

  profiler.instructionProfiles[opcode].count += 1
  profiler.instructionProfiles[opcode].totalTime += duration

  if profiler.lastSourceLocation.line > 0:
    var found = false
    for locProfile in profiler.sourceLocationProfiles.mitems:
      if locProfile.location.file == profiler.lastSourceLocation.file and
         locProfile.location.line == profiler.lastSourceLocation.line and
         locProfile.opcode == opcode:
        locProfile.count += 1
        locProfile.totalTime += duration
        found = true
        break

    if not found:
      profiler.sourceLocationProfiles.add(SourceLocationProfile(
        location: profiler.lastSourceLocation,
        opcode: opcode,
        count: 1,
        totalTime: duration
      ))


proc enterFunction*(profiler: VirtualMachineProfiler, functionName: string) =
  if not profiler.enabled:
    return

  let frame = ProfilerFrame(
    functionName: functionName,
    startTime: getTime(),
    startInstructionCount: profiler.totalInstructions,
    instructionCount: 0
  )
  profiler.frameStack.add(frame)

  if not profiler.functionProfiles.hasKey(functionName):
    profiler.functionProfiles[functionName] = FunctionProfile(
      name: functionName,
      callCount: 0,
      totalTime: initDuration(),
      selfTime: initDuration(),
      instructionCount: 0,
      childCalls: initTable[string, uint64]()
    )

  profiler.functionProfiles[functionName].callCount += 1


proc exitFunction*(profiler: VirtualMachineProfiler) =
  if not profiler.enabled or profiler.frameStack.len == 0:
    return

  let frame = profiler.frameStack.pop()
  let endTime = getTime()
  let totalDuration = endTime - frame.startTime

  if profiler.functionProfiles.hasKey(frame.functionName):
    profiler.functionProfiles[frame.functionName].totalTime += totalDuration
    profiler.functionProfiles[frame.functionName].instructionCount += frame.instructionCount

  if profiler.frameStack.len > 0:
    let parentFrame = profiler.frameStack[^1]
    if profiler.functionProfiles.hasKey(parentFrame.functionName):
      if not profiler.functionProfiles[parentFrame.functionName].childCalls.hasKey(frame.functionName):
        profiler.functionProfiles[parentFrame.functionName].childCalls[frame.functionName] = 0
      profiler.functionProfiles[parentFrame.functionName].childCalls[frame.functionName] += 1


proc reset*(profiler: VirtualMachineProfiler) =
  profiler.startTime = getTime()
  profiler.totalInstructions = 0
  profiler.instructionProfiles.clear()
  profiler.sourceLocationProfiles.setLen(0)
  profiler.functionProfiles.clear()
  profiler.frameStack.setLen(0)
  profiler.lastInstructionTime = getTime()
  profiler.lastSourceLocation = SourceLocation(file: "", line: 0, functionName: "")


proc computeSelfTimes*(profiler: VirtualMachineProfiler) =
  for funcName, profile in profiler.functionProfiles.mpairs:
    profile.selfTime = profile.totalTime
    for childName, childCount in profile.childCalls:
      if profiler.functionProfiles.hasKey(childName):
        let childProfile = profiler.functionProfiles[childName]
        let avgChildTime = if childProfile.callCount > 0:
          childProfile.totalTime div childProfile.callCount.int
        else:
          initDuration()
        profile.selfTime -= avgChildTime * childCount.int


proc formatDuration(d: Duration): string =
  let nanoseconds = d.inNanoseconds
  if nanoseconds < 1000:
    return &"{nanoseconds}ns"
  elif nanoseconds < 1_000_000:
    let microseconds = nanoseconds div 1000
    return &"{microseconds}.{(nanoseconds mod 1000 div 100)}us"
  elif nanoseconds < 1_000_000_000:
    let microseconds = nanoseconds div 1000
    return &"{(microseconds div 1000)}.{(microseconds mod 1000 div 100)}ms"
  else:
    let microseconds = nanoseconds div 1000
    return &"{(microseconds div 1_000_000)}.{(microseconds mod 1_000_000 div 100_000)}s"


proc formatPercentage(part, total: int64): string =
  if total == 0:
    return "0.00%"
  let percentage = (part.float / total.float) * 100.0
  return &"{percentage.formatFloat(ffDecimal, 2)}%"


proc getSourceLine(filePath: string, lineNum: int): string =
  try:
    if not fileExists(filePath):
      return ""
    let lines = readFile(filePath).split('\n')
    if lineNum > 0 and lineNum <= lines.len:
      var line = lines[lineNum - 1].strip()
      let commentPos = line.find("//")
      if commentPos >= 0:
        line = line[0..<commentPos].strip()
      return line
  except:
    discard
  return ""


proc generateReport*(profiler: VirtualMachineProfiler, heapStats: ptr HeapStats = nil): string =
  profiler.computeSelfTimes()

  let totalTime = profiler.executionEndTime - profiler.startTime
  result = "\n"
  result &= "╔═══════════════════════════════════════════════════════════════════════════════╗\n"
  result &= "║                            VM PROFILER REPORT                                 ║\n"
  result &= "╚═══════════════════════════════════════════════════════════════════════════════╝\n\n"

  result &= &"Total Execution Time: {formatDuration(totalTime)}\n"
  if heapStats != nil:
    let gcTime = initDuration(nanoseconds = heapStats.totalGCTime)
    result &= &"Total GC Time:        {formatDuration(gcTime)}\n"
    result &= &"GC Cycles:            {heapStats.cycleCheckCount}\n"
  result &= &"Total Instructions:   {profiler.totalInstructions}\n"
  if totalTime.inNanoseconds > 0:
    let ips = (profiler.totalInstructions.float / totalTime.inNanoseconds.float) * 1_000_000_000.0
    result &= &"Instructions/Second:  {ips.formatFloat(ffDecimal, 1)}\n"
  result &= "\n"

  result &= "┌────────────────────────────────────────────────────────────────────────────┐\n"
  result &= "│                        TOP FUNCTIONS BY TOTAL TIME                         │\n"
  result &= "├───────────────────────────┬───────┬────────────┬────────────┬──────────────┤\n"
  result &= "│ Function                  │ Calls │ Total Time │ Self Time  │ Instructions │\n"
  result &= "├───────────────────────────┼───────┼────────────┼────────────┼──────────────┤\n"

  var funcProfiles = toSeq(profiler.functionProfiles.values)
  funcProfiles.sort(proc(a, b: FunctionProfile): int =
    cmp(b.totalTime.inNanoseconds, a.totalTime.inNanoseconds)
  )

  for i, profile in funcProfiles:
    if i >= 20:
      break
    let demangled = demangleFunctionSignature(profile.name)
    let funcName = if demangled.len > 25: &"{demangled[0..21]}..." else: demangled

    result &= &"│ {funcName.alignLeft(25)} │ "
    result &= &"{($profile.callCount).align(5)} │ "
    result &= &"{formatDuration(profile.totalTime).align(10)} │ "
    result &= &"{formatDuration(profile.selfTime).align(10)} │ "
    result &= &"{($profile.instructionCount).align(12)} │\n"

  result &= "└───────────────────────────┴───────┴────────────┴────────────┴──────────────┘\n\n"

  result &= "┌─────────────────────────────────────────────────────────────────────────────┐\n"
  result &= "│                      TOP INSTRUCTIONS BY FREQUENCY                          │\n"
  result &= "├─────────────────────────────────┬──────────────┬───────────┬────────────────┤\n"
  result &= "│ Opcode                          │ Count        │ Percent   │ Avg Time       │\n"
  result &= "├─────────────────────────────────┼──────────────┼───────────┼────────────────┤\n"

  var instrProfiles = toSeq(profiler.instructionProfiles.values)
  instrProfiles.sort(proc(a, b: InstructionProfile): int = cmp(b.count, a.count))

  for i, profile in instrProfiles:
    if i >= 20:
      break

    let opName = ($profile.opcode).alignLeft(31)
    let count = ($profile.count).align(12)
    let pct = formatPercentage(profile.count.int64, profiler.totalInstructions.int64).align(9)
    let avgTime = if profile.count > 0:
      formatDuration(profile.totalTime div profile.count.int)
    else:
      "0us"

    result &= &"│ {opName} │ {count} │ {pct} │ "
    result &= &"{avgTime.align(14)} │\n"

  result &= "└─────────────────────────────────┴──────────────┴───────────┴────────────────┘\n\n"

  if profiler.sourceLocationProfiles.len > 0:
    type AggregatedLocation = object
      file: string
      line: int
      totalCount: uint64
      totalTime: Duration
      instructions: Table[OpCode, tuple[count: uint64, time: Duration]]

    var aggregated = initTable[string, AggregatedLocation]()

    for locProfile in profiler.sourceLocationProfiles:
      let key = &"{locProfile.location.file}:{locProfile.location.line}"

      if not aggregated.hasKey(key):
        aggregated[key] = AggregatedLocation(
          file: locProfile.location.file,
          line: locProfile.location.line,
          totalCount: 0,
          totalTime: initDuration(),
          instructions: initTable[OpCode, tuple[count: uint64, time: Duration]]()
        )

      aggregated[key].totalCount += locProfile.count
      aggregated[key].totalTime += locProfile.totalTime

      if not aggregated[key].instructions.hasKey(locProfile.opcode):
        aggregated[key].instructions[locProfile.opcode] = (count: 0'u64, time: initDuration())

      var entry = aggregated[key].instructions[locProfile.opcode]
      entry.count += locProfile.count
      entry.time += locProfile.totalTime
      aggregated[key].instructions[locProfile.opcode] = entry

    var sortedAggregated = toSeq(aggregated.values)
    sortedAggregated.sort(proc(a, b: AggregatedLocation): int = cmp(b.totalTime.inNanoseconds, a.totalTime.inNanoseconds))

    result &= "┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\n"
    result &= "│                                         TOP SOURCE LOCATIONS BY TIME                                                 │\n"
    result &= "├──────────────────────────────────────────────────────┬──────────────────────────┬──────────┬────────────┬────────────┤\n"
    result &= "│ Source                                               │ Location                 │ Count    │ Time       │ Avg Time   │\n"
    result &= "├──────────────────────────────────────────────────────┼──────────────────────────┼──────────┼────────────┼────────────┤\n"

    for i, aggLoc in sortedAggregated:
      if i >= 30:
        break

      var locStr = aggLoc.file
      if locStr.len > 0:
        let parts = locStr.split("/")
        if parts.len > 0:
          locStr = parts[^1]
      locStr &= &":{aggLoc.line}"

      if locStr.len > 24:
        locStr = &"{locStr[0..20]}..."

      var sourceLine = getSourceLine(aggLoc.file, aggLoc.line)
      if sourceLine.len > 52:
        sourceLine = &"{sourceLine[0..48]}..."
      if sourceLine.len == 0:
        sourceLine = ""

      result &= &"│ {sourceLine.alignLeft(52)} │ "
      result &= &"{locStr.alignLeft(24)} │ "
      result &= &"{($aggLoc.totalCount).align(8)} │ "
      result &= &"{formatDuration(aggLoc.totalTime).align(10)} │ "
      let avgTime = if aggLoc.totalCount > 0:
        formatDuration(aggLoc.totalTime div aggLoc.totalCount.int)
      else:
        "0us"
      result &= &"{avgTime.align(10)} │\n"

    result &= "└──────────────────────────────────────────────────────┴──────────────────────────┴──────────┴────────────┴────────────┘\n\n"

    result &= "┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\n"
    result &= "│                                      INSTRUCTION BREAKDOWN BY SOURCE LOCATION                                        │\n"
    result &= "├──────────────────────────────────────────────────────┬──────────────────────────┬───────────────┬──────────┬─────────┤\n"
    result &= "│ Source                                               │ Location                 │ Instruction   │ Count    │ Time    │\n"
    result &= "├──────────────────────────────────────────────────────┼──────────────────────────┼───────────────┼──────────┼─────────┤\n"

    for i, aggLoc in sortedAggregated:
      if i >= 20:
        break

      var locStr = aggLoc.file
      if locStr.len > 0:
        let parts = locStr.split("/")
        if parts.len > 0:
          locStr = parts[^1]
      locStr &= &":{aggLoc.line}"

      if locStr.len > 24:
        locStr = &"{locStr[0..20]}..."

      var sourceLine = getSourceLine(aggLoc.file, aggLoc.line)
      if sourceLine.len > 52:
        sourceLine = &"{sourceLine[0..48]}..."
      if sourceLine.len == 0:
        sourceLine = ""

      var instrList: seq[tuple[op: OpCode, count: uint64, time: Duration]] = @[]
      for op, data in aggLoc.instructions:
        instrList.add((op: op, count: data.count, time: data.time))

      instrList.sort(proc(a, b: tuple[op: OpCode, count: uint64, time: Duration]): int =
        cmp(b.time.inNanoseconds, a.time.inNanoseconds)
      )

      let emptyString = ""
      for j, instr in instrList:
        if j == 0:
          result &= &"│ {sourceLine.alignLeft(52)} │ {locStr.alignLeft(24)} │ "
        else:
          result &= &"│ {emptyString.alignLeft(52)} │ {emptyString.alignLeft(24)} │ "

        result &= &"{($instr.op).alignLeft(13)} │ "
        result &= &"{($instr.count).align(8)} │ "
        result &= &"{formatDuration(instr.time).align(7)} │\n"

    result &= "└──────────────────────────────────────────────────────┴──────────────────────────┴───────────────┴──────────┴─────────┘\n"

  return result
