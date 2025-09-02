# cli_main.nim
# Main CLI entry point and command dispatch

import std/[os, strformat]
import ./[options]
import ./commands/[gen, run, test, bench, debug, dump, replay]
import ../../core/[vm_execution, vm_types, vm_replay]
import ../../capabilities/[replay]
import ../../common/[constants, logging]



proc handleRecording*(options: CliOptions): int =
  if options.recordFile != "":
    if options.files.len != 1:
      stderr.writeLine("Error: --record requires exactly one source file")
      return 1

    let sourceFile = options.files[0]
    validateFile(sourceFile)
    let replayFile = options.recordFile & ".replay"

    logCLI(options.verbose, &"Recording execution of: {sourceFile}")
    logCLI(options.verbose, &"Output will be saved to: {replayFile}\n")

    # Compile and run the program with recording enabled
    let bytecodeProgram = compileToBytecode(options)
    let vm = newVirtualMachine(bytecodeProgram)
    vm.enableReplayRecording(snapshotInterval = 1)

    let exitCode = vm.execute(verbose = options.verbose)
    vm.stopReplayRecording()

    # Save replay data to file
    if vm.replayEngine != nil:
      let engine = cast[ReplayEngine](vm.replayEngine)
      try:
        engine.saveToFile(replayFile, sourceFile)
        if options.verbose:
          let stats = engine.getStats()
          logCLI(options.verbose, &"\nSaved {stats.statements} statements ({stats.snapshots} snapshots) to {replayFile}")
      except Exception as e:
        stderr.writeLine(&"Error saving replay: {e.msg}")
        vm.cleanupReplayEngine()
        return 1

    # Clean up replay engine after saving
    vm.cleanupReplayEngine()

    return exitCode

  return 0  # No recording requested


proc dispatchCommand*(options: CliOptions): int =
  # Handle recording first
  if options.recordFile != "":
    return handleRecording(options)

  # Handle --record without --run
  if options.recordFile != "" and options.command == cmdRun and options.runBackend == "":
    stderr.writeLine("Error: --record requires --run to execute the program")
    return 1

  # Dispatch to appropriate command
  case options.command
  of cmdGen:
    return genCommand(options)
  of cmdRun:
    return runCommand(options)
  of cmdTest:
    return testCommand(options)
  of cmdTestC:
    return testCommand(options)  # Same as test, backend handled in options
  of cmdPerf:
    return benchCommand(options)
  of cmdDebug:
    return debugCommand(options)
  of cmdDump:
    return dumpCommand(options)
  of cmdReplay:
    return replayCommand(options)

proc main*() =
  if paramCount() < 1: usage()

  let options = parseCliArguments()

  # Handle special cases that don't need file validation
  if options.command in [cmdTest, cmdPerf]:
    quit dispatchCommand(options)

  # Validate we have the right number of files
  if options.files.len == 0:
    if options.command in [cmdRun, cmdDump, cmdDebug, cmdReplay, cmdGen]:
      usage()
    else:
      # Commands that don't require files
      quit dispatchCommand(options)

  if options.files.len > 1 and options.command != cmdTest and options.command != cmdTestC:
    stderr.writeLine("Error: Multiple files provided but command only accepts one")
    usage()

  # Validate files/directories exist
  for file in options.files:
    if options.command in [cmdTest, cmdTestC, cmdPerf]:
      # For test and perf commands, accept either files or directories
      if not fileExists(file) and not dirExists(file):
        stderr.writeLine(&"Error: cannot open: {file}")
        quit 1
    else:
      # For other commands, only accept files
      if not fileExists(file):
        stderr.writeLine(&"Error: cannot open: {file}")
        quit 1

  # Dispatch to command
  let exitCode = dispatchCommand(options)
  quit exitCode
