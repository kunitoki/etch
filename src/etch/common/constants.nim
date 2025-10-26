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


# Function utils
const
  FUNCTION_NAME_SEPARATOR_STRING* = "__"
  FUNCTION_RETURN_SEPARATOR_STRING* = "_"


# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 25  # Added varMaps for variable name display in debugging


# Symbolic execution constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1_000


# Replay constants
const
  REPLAY_VERSION* = 1  # Version of replay format
  DEFAULT_SNAPSHOT_INTERVAL* = 1_000  # Take snapshot every N instructions
