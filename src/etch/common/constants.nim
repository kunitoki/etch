# constants.nim
# Program-wide constants for the Etch language implementation

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
  GLOBAL_FINI_FUNC_NAME* = "__global_fini__"

# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 13

# Runtime constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000

# VM Optimization constants
const
  # Fast variable slots - number of local variables cached per frame
  VM_FAST_SLOTS_COUNT* = 8

# Bytecode Optimization constants
const
  # Enable bytecode optimization passes only in release builds
  ENABLE_BYTECODE_OPTIMIZATION* = defined(release)
