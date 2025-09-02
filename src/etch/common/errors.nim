# errors.nim
# Centralized error handling and formatting for the Etch language implementation

import std/[strformat, strutils]
import types


# Etch-specific exception types
type
  EtchError* = object of CatchableError
    pos*: Pos

  ParseError* = object of EtchError
  TypecheckError* = object of EtchError
  ProveError* = object of EtchError
  CompileError* = object of EtchError
  RuntimeError* = object of EtchError


# Format an error message with position and context
# Lazily loads source lines from disk if not already cached.
# This centralizes error formatting and avoids loading source files unless an error occurs.
proc formatError*(pos: Pos, msg: string, sourceLines: seq[string]): string =
  let filename = if pos.filename.len > 0: pos.filename else: "<unknown>"

  # If we don't have reliable location information, fall back to plain message.
  let hasFilename = filename.len > 0 and filename != "<unknown>"
  let hasCoords = pos.line > 0 and pos.col > 0
  if not (hasFilename and hasCoords):
    return msg & "\n"

  result = &"{filename}:{pos.line}:{pos.col}: error: {msg}\n"

  # Get source lines for this specific file from cache, or lazily load from disk
  var finalSourceLines: seq[string] = @[]
  if filename == "<unknown>" and sourceLines.len > 0:
    finalSourceLines = sourceLines
  elif filename != "<unknown>" and filename.len > 0:
    # Lazy loading: try to load from disk on demand (only when error occurs)
    try:
      finalSourceLines = readFile(filename).splitLines()
    except:
      discard

  if finalSourceLines.len > 0 and pos.line > 0 and pos.line <= finalSourceLines.len:
    let lineIdx = pos.line - 1
    let line = finalSourceLines[lineIdx]

    # Show context: line before (if exists)
    if lineIdx > 0:
      result.add &"  {pos.line - 1} | {finalSourceLines[lineIdx - 1]}\n"

    # Show the error line
    result.add &"  {pos.line} | {line}\n"

    # Show the caret pointing to the error column
    let prefixLen = 2 + len($pos.line) + 3 # "  " + line number + " | "
    let caretPos = max(0, pos.col - 1)     # convert to 0-based for spacing calculation
    let totalSpaces = prefixLen + caretPos
    let caret = " ".repeat(totalSpaces) & "^"
    result.add &"{caret}\n"

    # Show context: line after (if exists)
    if lineIdx + 1 < finalSourceLines.len:
      result.add &"  {pos.line + 1} | {finalSourceLines[lineIdx + 1]}\n"


# Helper procs for creating formatted exceptions
proc newParseError*(pos: Pos, msg: string): ref ParseError =
  result = newException(ParseError, msg)
  result.pos = pos


proc newTypecheckError*(pos: Pos, msg: string): ref TypecheckError =
  result = newException(TypecheckError, msg)
  result.pos = pos


proc newProveError*(pos: Pos, msg: string): ref ProveError =
  result = newException(ProveError, msg)
  result.pos = pos


proc newCompileError*(pos: Pos, msg: string): ref CompileError =
  result = newException(CompileError, msg)
  result.pos = pos


proc newRuntimeError*(pos: Pos, msg: string): ref RuntimeError =
  result = newException(RuntimeError, msg)
  result.pos = pos


# For errors without position information
proc newEtchError*(msg: string): ref EtchError =
  newException(EtchError, msg)
