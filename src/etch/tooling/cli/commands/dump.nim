# cli_dump.nim
# Dump command implementation

import ../options
import ../../../capabilities/dumper
import ./gen # For compileToBytecode


proc dumpCommand*(options: CliOptions): int =
  if options.modeArg == "":
    stderr.writeLine("Error: --dump requires a file argument")
    return 1

  validateFile(options.modeArg)

  let bytecodeProgram = compileToBytecode(options)
  dumpBytecodeProgram(bytecodeProgram, options.modeArg)
  return 0
