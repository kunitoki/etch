# cli_debug.nim
# Debug command implementation

import ../../../common/errors
import ../../../capabilities/debugserver
import ../../compiler
import ../options


proc debugCommand*(options: CliOptions): int =
  if options.modeArg == "":
    stderr.writeLine("Error: --debug-server requires a file argument")
    return 1

  validateFile(options.modeArg)
  let compilerOpts = makeCompilerOptions(options.modeArg, runVirtualMachine = false, options)

  try:
    let (prog, sourceHash, evaluatedGlobals, moduleRegistry, cffiRegistry) = parseAndTypecheck(compilerOpts)
    let regBytecode = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, options.modeArg, compilerOpts, moduleRegistry, cffiRegistry)
    runDebugServer(regBytecode, options.modeArg)
  except EtchError as e:
    sendCompilationError(formatError(e.pos, e.msg, @[]))
    return 1
  except Exception as e:
    sendCompilationError(e.msg)
    return 1

  return 0
