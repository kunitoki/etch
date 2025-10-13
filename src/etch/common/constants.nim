# constants.nim
# Program-wide constants for the Etch language implementation

# VM types
type
  VMType* = enum
    vmStack = 1    # Stack-based VM
    vmRegister = 2 # Register-based VM

# Module names for logging
const
  MODULE_COMPILER* = "COMPILER"
  MODULE_BYTECODE* = "BYTECODE"
  MODULE_PROVER* = "PROVER"
  MODULE_VM* = "VM"
  MODULE_TYPECHECKER* = "TYPECHECKER"
  MODULE_PARSER* = "PARSER"
  MODULE_LEXER* = "LEXER"
  MODULE_AST* = "AST"
  MODULE_DEBUG* = "DEBUG"

# Program metadata
const
  PROGRAM_NAME* = "Etch"
  PROGRAM_VERSION* = "0.1.0"
  BYTECODE_CACHE_DIR* = "__etch__"
  BYTECODE_FILE_EXTENSION* = ".etcx"

# Global names
const
  MAIN_FUNCTION_NAME* = "main"
  GLOBAL_INIT_FUNC_NAME* = "__global_init__"

# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 19  # Added debug info serialization for instructions

# AST version for union type support
const
  AST_VERSION* = 2

# Runtime constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1000

# VM Optimization constants
const
  # Fast variable slots - number of local variables cached per frame
  VM_FAST_SLOTS_COUNT* = 8
