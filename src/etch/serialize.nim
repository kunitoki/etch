# serialize.nim
# Bytecode serialization and deserialization for Etch programs

import std/[tables, streams, strutils]
import ast

type
  GlobalValue* = object
    kind*: TypeKind
    ival*: int64
    fval*: float64
    bval*: bool
    sval*: string

  CompilerFlags* = object
    includeDebugInfo*: bool

  DebugInfo* = object
    line*: int
    col*: int
    sourceFile*: string
    functionName*: string
    localVars*: seq[string]

  OpCode* = enum
    opLoadInt, opLoadFloat, opLoadString, opLoadBool, opLoadNil
    opLoadVar, opStoreVar
    opAdd, opSub, opMul, opDiv, opMod
    opEq, opNe, opLt, opLe, opGt, opGe
    opAnd, opOr, opNot, opNeg
    opCall, opReturn
    opJump, opJumpIfFalse
    opNewRef, opDeref
    opPop, opDup
    opMakeArray, opArrayGet, opArraySlice, opArrayLen
    opCast

  Instruction* = object
    op*: OpCode
    arg*: int64
    sarg*: string
    debug*: DebugInfo

  FunctionDebugInfo* = object
    name*: string
    startLine*: int
    endLine*: int
    parameterNames*: seq[string]
    localVarNames*: seq[string]

  BytecodeProgram* = object
    instructions*: seq[Instruction]
    constants*: seq[string]
    functions*: Table[string, int]
    sourceHash*: string
    globals*: seq[string]
    globalValues*: Table[string, GlobalValue]
    sourceFile*: string
    functionDebugInfo*: Table[string, FunctionDebugInfo]
    lineToInstructionMap*: Table[int, seq[int]]
    compilerFlags*: CompilerFlags

proc serializeToBinary*(prog: BytecodeProgram): string =
  ## Serialize bytecode program to binary format for storage
  var stream = newStringStream()

  # Magic header: "ETCH" + version byte
  stream.write("ETCH")
  stream.write(uint8(3))  # Version 3 (added global values)

  # Source hash (32 bytes, padded with zeros if needed)
  var hashBytes = prog.sourceHash
  if hashBytes.len < 32:
    hashBytes = hashBytes & repeat('\0', 32 - hashBytes.len)
  elif hashBytes.len > 32:
    hashBytes = hashBytes[0..<32]
  stream.write(hashBytes)

  # Compiler flags
  stream.write(uint8(if prog.compilerFlags.includeDebugInfo: 1 else: 0))

  # Source file name
  let sourceFileBytes = prog.sourceFile
  var sourceFileLen = uint32(sourceFileBytes.len)
  stream.write(sourceFileLen)
  if sourceFileLen > 0:
    stream.write(sourceFileBytes)

  # Constants pool
  var constCount = uint32(prog.constants.len)
  stream.write(constCount)
  for c in prog.constants:
    var cLen = uint32(c.len)
    stream.write(cLen)
    stream.write(c)

  # Global variables
  var globalCount = uint32(prog.globals.len)
  stream.write(globalCount)
  for g in prog.globals:
    var gLen = uint32(g.len)
    stream.write(gLen)
    stream.write(g)

  # Global variable values
  var globalValueCount = uint32(prog.globalValues.len)
  stream.write(globalValueCount)
  for name, value in prog.globalValues:
    var nameLen = uint32(name.len)
    stream.write(nameLen)
    stream.write(name)
    # Serialize value
    stream.write(uint8(ord(value.kind)))
    case value.kind
    of tkInt:
      stream.write(value.ival)
    of tkFloat:
      stream.write(value.fval)
    of tkBool:
      stream.write(uint8(if value.bval: 1 else: 0))
    of tkString:
      var sLen = uint32(value.sval.len)
      stream.write(sLen)
      stream.write(value.sval)
    else:
      discard # Other types not supported yet

  # Functions table
  var funcCount = uint32(prog.functions.len)
  stream.write(funcCount)
  for name, offset in prog.functions:
    var nameLen = uint32(name.len)
    stream.write(nameLen)
    stream.write(name)
    stream.write(uint32(offset))

  # Instructions
  var instrCount = uint32(prog.instructions.len)
  stream.write(instrCount)
  for instr in prog.instructions:
    stream.write(uint8(ord(instr.op)))
    stream.write(instr.arg)
    var sargLen = uint32(instr.sarg.len)
    stream.write(sargLen)
    if sargLen > 0:
      stream.write(instr.sarg)

    # Debug info (simplified - only line/col if present)
    var hasDebug = uint8(if instr.debug.line > 0: 1 else: 0)
    stream.write(hasDebug)
    if hasDebug == 1:
      stream.write(uint32(instr.debug.line))
      stream.write(uint32(instr.debug.col))

  stream.setPosition(0)
  result = stream.readAll()
  stream.close()

proc deserializeFromBinary*(data: string): BytecodeProgram =
  ## Deserialize bytecode program from binary format
  var stream = newStringStream(data)

  # Check magic header
  let magic = stream.readStr(4)
  if magic != "ETCH":
    raise newException(ValueError, "Invalid bytecode file: bad magic")

  let version = stream.readUint8()
  if version != 1 and version != 2:
    raise newException(ValueError, "Unsupported bytecode version: " & $version)

  result = BytecodeProgram(
    instructions: @[],
    constants: @[],
    functions: initTable[string, int](),
    globals: @[],
    functionDebugInfo: initTable[string, FunctionDebugInfo](),
    lineToInstructionMap: initTable[int, seq[int]](),
    compilerFlags: CompilerFlags()  # Will be set below
  )

  # Read source hash
  result.sourceHash = stream.readStr(32).strip(chars = {'\0'})

  # Read compiler flags (only in version 2+)
  if version >= 2:
    let includeDebugFlag = stream.readUint8()
    result.compilerFlags = CompilerFlags(includeDebugInfo: includeDebugFlag != 0)
  else:
    result.compilerFlags = CompilerFlags(includeDebugInfo: false)

  # Read source file
  let sourceFileLen = stream.readUint32()
  result.sourceFile = if sourceFileLen > 0: stream.readStr(int(sourceFileLen)) else: ""

  # Read constants
  let constCount = stream.readUint32()
  for i in 0..<constCount:
    let cLen = stream.readUint32()
    result.constants.add(stream.readStr(int(cLen)))

  # Read globals
  let globalCount = stream.readUint32()
  for i in 0..<globalCount:
    let gLen = stream.readUint32()
    result.globals.add(stream.readStr(int(gLen)))

  # Read global values (only in version 3+)
  if version >= 3:
    let globalValueCount = stream.readUint32()
    for i in 0..<globalValueCount:
      let nameLen = stream.readUint32()
      let name = stream.readStr(int(nameLen))
      let valueKind = TypeKind(stream.readUint8())
      var value = GlobalValue(kind: valueKind)
      case valueKind
      of tkInt:
        value.ival = stream.readInt64()
      of tkFloat:
        value.fval = stream.readFloat64()
      of tkBool:
        value.bval = stream.readUint8() != 0
      of tkString:
        let sLen = stream.readUint32()
        value.sval = stream.readStr(int(sLen))
      else:
        discard # Other types not supported yet
      result.globalValues[name] = value

  # Read functions
  let funcCount = stream.readUint32()
  for i in 0..<funcCount:
    let nameLen = stream.readUint32()
    let name = stream.readStr(int(nameLen))
    let offset = stream.readUint32()
    result.functions[name] = int(offset)

  # Read instructions
  let instrCount = stream.readUint32()
  for i in 0..<instrCount:
    let op = OpCode(stream.readUint8())
    let arg = stream.readInt64()
    let sargLen = stream.readUint32()
    let sarg = if sargLen > 0: stream.readStr(int(sargLen)) else: ""

    var debug = DebugInfo()
    let hasDebug = stream.readUint8()
    if hasDebug == 1:
      debug.line = int(stream.readUint32())
      debug.col = int(stream.readUint32())

    result.instructions.add(Instruction(
      op: op,
      arg: arg,
      sarg: sarg,
      debug: debug
    ))

  stream.close()

proc saveBytecode*(prog: BytecodeProgram, filename: string) =
  ## Save bytecode program to .etcx file
  let binaryData = prog.serializeToBinary()
  writeFile(filename, binaryData)

proc loadBytecode*(filename: string): BytecodeProgram =
  ## Load bytecode program from .etcx file
  let binaryData = readFile(filename)
  deserializeFromBinary(binaryData)