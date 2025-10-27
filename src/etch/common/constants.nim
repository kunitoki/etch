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
# Using :: and : as separators for readability (resembles C++/Rust namespace syntax):
# - :: and : are NOT valid identifier characters in Etch (identifiers are [a-zA-Z_][a-zA-Z0-9_]*)
# - : is only used for type annotations, not in function names
# - This prevents conflicts with user functions like "my__method" which would break with "__" separator
# - Makes mangled names readable: my__method::Is:i
const
  FUNCTION_NAME_SEPARATOR_STRING* = "::"     # Separates function name from signature: funcName::signature
  FUNCTION_RETURN_SEPARATOR_STRING* = ":"    # Separates parameters from return type: params:returnType


# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 27  # Added ropInitGlobal for C API global override support


# Symbolic execution constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1_000


# Replay constants
const
  REPLAY_VERSION* = 1  # Version of replay format
  DEFAULT_SNAPSHOT_INTERVAL* = 1_000  # Take snapshot every N instructions
