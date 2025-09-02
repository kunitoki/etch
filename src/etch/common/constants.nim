# constants.nim
# Program-wide constants for the Etch language implementation

import std/[os, algorithm, hashes]

# VM types
type
  VMType* = enum
    vmRegister = 1 # Register-based VM

# Module names for logging
const
  MODULE_COMPILER* = "COMPILER"
  MODULE_PROVER* = "PROVER"
  MODULE_OPTIMIZER* = "OPTIMIZER"
  MODULE_VM* = "VM"
  MODULE_HEAP* = "HEAP"
  MODULE_CLI* = "CLI"
  MODULE_TYPECHECKER* = "TYPECHECK"

# Program metadata
const
  PROGRAM_NAME* = "Etch"
  PROGRAM_VERSION* = "0.2.0"
  SOURCE_FILE_EXTENSION* = ".etch"
  BYTECODE_CACHE_DIR* = "__etch__"
  BYTECODE_FILE_EXTENSION* = ".etcx"

# Global names
const
  MAIN_FUNCTION_NAME* = "main"
  GLOBAL_INIT_FUNCTION_NAME* = "<global>"

# Function utils
const
  FUNCTION_NAME_SEPARATOR_STRING* = "::"     # Separates function name from signature: funcName::signature
  FUNCTION_RETURN_SEPARATOR_STRING* = ":"    # Separates parameters from return type: params:returnType

# Bytecode serialization constants
const
  BYTECODE_MAGIC* = "ETCH"
  BYTECODE_VERSION* = 43

# VirtualMachine constants
const
  MAX_REGISTERS* = 255  # Maximum number of registers per function frame (must fit in uint8)
  MAX_CONSTANTS* = 65536  # Maximum constants per function (16-bit index)

# Symbolic execution constants
const
  MAX_LOOP_ITERATIONS* = 1_000_000
  MAX_RECURSION_DEPTH* = 1_000

# Replay constants
const
  REPLAY_VERSION* = 1  # Version of replay format
  DEFAULT_SNAPSHOT_INTERVAL* = 1_000  # Take snapshot every N instructions

## Computes a deterministic combined hash from the contents
## of all regular files under `folder` (recursively).
proc folderHash*(folder: string): Hash {.compileTime.} =
  var files: seq[string] = @[]

  # Collect files recursively
  for path in walkDirRec(folder):
    if fileExists(path):
      files.add(path)

  # Deterministic order
  files.sort(system.cmp)

  # Mix per-file content hashes into a single hash
  var combined: Hash = 0
  for f in files:
    let h = hash(readFile(f))
    combined = combined !& h
  result = !$combined  # finalize

# Choose the folder you want to scan (relative to project root)
const
  COMPILER_SOURCE_FOLDER* = currentSourcePath().parentDir.parentDir
  COMPILER_BUILD_HASH* = folderHash(COMPILER_SOURCE_FOLDER)
