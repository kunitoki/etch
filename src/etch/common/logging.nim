# logging.nim
# Centralized logging utilities for the Etch language implementation

import types
import constants


# Verbose logging function
template verboseLog*(verbose: bool, module: string, msg: untyped) =
  if verbose:
    echo "[", module, "] ", $msg


# Convenience templates for each module
template logCompiler*(flags: CompilerFlags, msg: untyped) =
  verboseLog(flags.verbose, MODULE_COMPILER, msg)

template logProver*(flags: CompilerFlags, msg: untyped) =
  verboseLog(flags.verbose, MODULE_PROVER, msg)

template logVM*(flags: CompilerFlags, msg: untyped) =
  verboseLog(flags.verbose, MODULE_VM, msg)
