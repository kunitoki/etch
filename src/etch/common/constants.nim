# constants.nim
# Program-wide constants for the Etch language implementation


# VM types
type
  VMType* = enum
    vmRegister = 1 # Register-based VM


# Module names for logging
const
  MODULE_COMPILER* = "COMPILER"
  MODULE_PROVER* = "PROVER"
  MODULE_VM* = "VM"


# Program metadata
const
  PROGRAM_NAME* = "Etch"
  PROGRAM_VERSION* = "0.1.0"
  BYTECODE_CACHE_DIR* = "__etch__"
  BYTECODE_FILE_EXTENSION* = ".etcx"


# Global names
const
  MAIN_FUNCTION_NAME* = "main"
  GLOBAL_INIT_FUNCTION_NAME* = "<global>"


# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 23


# Symbolic execution constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1000
