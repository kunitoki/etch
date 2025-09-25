import strformat, strutils
import types

# Etch-specific exception types
type
  EtchError* = object of CatchableError
    pos*: Pos

  ParseError* = object of EtchError
  TypecheckError* = object of EtchError
  ProverError* = object of EtchError
  RuntimeError* = object of EtchError

# Global state for error formatting
var currentFilename* = "<unknown>"
var sourceLines*: seq[string] = @[]

proc loadSourceLines*(filename: string) =
  currentFilename = filename
  try:
    sourceLines = readFile(filename).splitLines()
  except:
    sourceLines = @[]

proc formatError*(pos: Pos, msg: string): string =
  let filename = if pos.filename.len > 0: pos.filename else: currentFilename
  result = &"{filename}:{pos.line}:{pos.col}: error: {msg}\n"

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
    let caretPos = max(0, pos.col - 1)  # convert to 0-based for spacing calculation
    let totalSpaces = prefixLen + caretPos
    let caret = " ".repeat(totalSpaces) & "^"
    result.add &"{caret}\n"

    # Show context: line after (if exists)
    if lineIdx + 1 < sourceLines.len:
      result.add &"  {pos.line + 1} | {sourceLines[lineIdx + 1]}\n"

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

proc newRuntimeError*(pos: Pos, msg: string): ref RuntimeError =
  result = newException(RuntimeError, formatError(pos, msg))
  result.pos = pos

# For errors without position information
proc newEtchError*(msg: string): ref EtchError =
  newException(EtchError, msg)
