# errors.nim
# Centralized error handling and formatting for the Etch language implementation

import std/[strformat, strutils, tables]
import types


# Etch-specific exception types
type
  EtchError* = object of CatchableError
    pos*: Pos

  ParseError* = object of EtchError
  TypecheckError* = object of EtchError
  ProverError* = object of EtchError
  CompilerError* = object of EtchError
  RuntimeError* = object of EtchError


# Global state for error formatting - cache source lines by filename
var currentFilename = "<unknown>"
var sourceLinesCache: Table[string, seq[string]] = initTable[string, seq[string]]()


# Format an error message with position and context
# Lazily loads source lines from disk if not already cached.
# This centralizes error formatting and avoids loading source files unless an error occurs.
proc formatError(pos: Pos, msg: string): string =
  let filename = if pos.filename.len > 0: pos.filename else: currentFilename
  result = &"{filename}:{pos.line}:{pos.col}: error: {msg}\n"

  # Get source lines for this specific file from cache, or lazily load from disk
  var sourceLines: seq[string] = @[]
  if filename in sourceLinesCache:
    sourceLines = sourceLinesCache[filename]
  elif filename != "<unknown>" and filename.len > 0:
    # Lazy loading: try to load from disk on demand (only when error occurs)
    try:
      sourceLines = readFile(filename).splitLines()
      sourceLinesCache[filename] = sourceLines
    except:
      discard

  if sourceLines.len > 0 and pos.line > 0 and pos.line <= sourceLines.len:
    let lineIdx = pos.line - 1
    let line = sourceLines[lineIdx]

    # Show context: line before (if exists)
    if lineIdx > 0:
      result.add &"  {pos.line - 1} | {sourceLines[lineIdx - 1]}\n"

    # Show the error line
    result.add &"  {pos.line} | {line}\n"

    # Show the caret pointing to the error column
    let prefixLen = 2 + len($pos.line) + 3 # "  " + line number + " | "
    let caretPos = max(0, pos.col - 1)     # convert to 0-based for spacing calculation
    let totalSpaces = prefixLen + caretPos
    let caret = " ".repeat(totalSpaces) & "^"
    result.add &"{caret}\n"

    # Show context: line after (if exists)
    if lineIdx + 1 < sourceLines.len:
      result.add &"  {pos.line + 1} | {sourceLines[lineIdx + 1]}\n"


# Load source lines from a string for error context
# Only call this for in-memory source code that isn't on disk.
# For file-based compilation, formatError() will lazily load from disk on demand.
proc loadSourceLinesFromString*(src: string, filename: string = "<unknown>") =
  currentFilename = filename
  if filename notin sourceLinesCache:
    sourceLinesCache[filename] = src.splitLines()


# Helper procs for creating formatted exceptions
proc newParseError*(pos: Pos, msg: string): ref ParseError =
  result = newException(ParseError, formatError(pos, msg))
  result.pos = pos

proc newTypecheckError*(pos: Pos, msg: string): ref TypecheckError =
  result = newException(TypecheckError, formatError(pos, msg))
  result.pos = pos

proc newProverError*(pos: Pos, msg: string): ref ProverError =
  result = newException(ProverError, formatError(pos, msg))
  result.pos = pos

proc newCompilerError*(pos: Pos, msg: string): ref CompilerError =
  result = newException(CompilerError, formatError(pos, msg))
  result.pos = pos

proc newRuntimeError*(pos: Pos, msg: string): ref RuntimeError =
  result = newException(RuntimeError, formatError(pos, msg))
  result.pos = pos


# For errors without position information
proc newEtchError*(msg: string): ref EtchError =
  newException(EtchError, msg)
