# logging.nim
# Centralized logging utilities for the Etch language implementation

import ../interpreter/serialize
import constants

proc verboseLog*(flags: CompilerFlags, module: string, msg: string) =
  if flags.verbose:
    echo "[", module, "] ", msg

template logVerbose*(flags: CompilerFlags, module: string, msg: string) =
  verboseLog(flags, module, msg)

# Convenience templates for each module
template logCompiler*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_COMPILER, msg)

template logBytecode*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_BYTECODE, msg)

template logProver*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_PROVER, msg)

template logVM*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_VM, msg)

template logTypechecker*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_TYPECHECKER, msg)

template logParser*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_PARSER, msg)

template logLexer*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_LEXER, msg)

template logAST*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_AST, msg)

template logDebug*(flags: CompilerFlags, msg: string) =
  verboseLog(flags, MODULE_DEBUG, msg)
