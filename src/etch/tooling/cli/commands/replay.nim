# cli_replay.nim
# Replay command implementation

import std/[os, strutils, strformat]
import ../options
import ../../../core/[vm, vm_execution, vm_types, vm_replay]
import ../../../capabilities/[replay]

import ./gen # For compileToBytecode


proc replayCommand*(options: CliOptions): int =
  if options.modeArg == "":
    stderr.writeLine("Error: --replay requires a file argument")
    return 1

  let replayFile = if options.modeArg.endsWith(".replay"): options.modeArg else: options.modeArg & ".replay"

  if not fileExists(replayFile):
    echo &"Error: Replay file not found: {replayFile}"
    return 1

  echo &"Loading replay from: {replayFile}"

  # Load replay data (includes source file path)
  let replayData = loadFromFile(replayFile)
  let sourceFile = replayData.sourceFile

  if not fileExists(sourceFile):
    echo &"Error: Source file not found: {sourceFile}"
    echo &"Note: The replay was recorded from '{sourceFile}' which is no longer available"
    return 1

  echo &"Source file: {sourceFile}"
  echo &"Loaded {replayData.totalStatements} statements ({replayData.snapshots.len} snapshots)"
  echo ""

  # Compile source to get bytecode
  let optionsWithSource = CliOptions(
    verbose: options.verbose,
    debug: options.debug,
    profile: options.profile,
    force: options.force,
    gcCycleInterval: options.gcCycleInterval,
    command: cmdGen,
    files: @[sourceFile],  # Set source file for compilation
    backend: "vm",         # Use VM backend for compilation
    modeArg: "",
    runBackend: "",
    recordFile: "",
    stepArg: ""
  )
  let bytecodeProgram = compileToBytecode(optionsWithSource)
  let vm = newVirtualMachine(bytecodeProgram)

  # Restore replay engine from loaded data
  let engine = restoreReplayEngine(vm, replayData.totalStatements, replayData.snapshotInterval, replayData.snapshots)
  vm.replayEngine = cast[pointer](engine)
  GC_ref(engine)

  # Parse step argument
  if options.stepArg == "":
    echo "Error: --replay requires --step argument"
    echo "Example: --step S,10,20,E  (S=start, E=end)"
    return 1

  var steps: seq[int] = @[]
  for part in options.stepArg.split(','):
    let trimmed = part.strip()
    if trimmed == "S" or trimmed == "s":
      steps.add(0)  # Start
    elif trimmed == "E" or trimmed == "e":
      steps.add(replayData.totalStatements - 1)  # End
    else:
      try:
        let stmt = parseInt(trimmed)
        if stmt < 0 or stmt >= replayData.totalStatements:
          echo &"Warning: Statement {stmt} out of range (0..{replayData.totalStatements - 1})"
        else:
          steps.add(stmt)
      except ValueError:
        echo &"Error: Invalid step value: {trimmed}"
        return 1

  if steps.len == 0:
    echo "Error: No valid steps provided"
    return 1

  echo ""
  echo &"==== Stepping through {steps.len} statements ===="
  echo ""

  # Step through each statement
  for i, stmt in steps:
    echo &"[{i + 1}/{steps.len}] Seeking to statement {stmt} / {replayData.totalStatements - 1}..."
    vm.seekToStatement(stmt)
    vm.printVirtualMachineState()
    echo ""

  echo "==== Replay Complete ===="

  # Clean up replay engine before exiting
  vm.cleanupReplayEngine()

  return 0
