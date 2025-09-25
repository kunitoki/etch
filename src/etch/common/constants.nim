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

# Runtime constants
const
  DEFAULT_HEAP_SIZE* = 1024
  MAX_RECURSION_DEPTH* = 1000
  MAX_LOOP_ITERATIONS* = 1_000_000
