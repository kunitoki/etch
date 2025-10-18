# regvm_serialize.nim
# Register VM bytecode serialization and deserialization

import std/[tables, streams, strutils]
import ../common/constants
import regvm, regvm_lifetime


type
  RegCompilerFlags* = object
    verbose*: bool
    debug*: bool
    optimizeLevel*: int

  RegDebugInfo* = object
    line*: int
    col*: int
    sourceFile*: string
    functionName*: string
    localVars*: seq[string]

  RegInstructionDebug* = object
    debug*: RegDebugInfo

  RegBytecodeFile* = object
    # File metadata
    sourceHash*: string
    compilerVersion*: string
    compilerFlags*: RegCompilerFlags
    sourceFile*: string

    # Program data
    entryPoint*: int
    constants*: seq[V]
    instructions*: seq[RegInstruction]
    instructionDebugInfo*: seq[RegDebugInfo]

    # Function metadata
    functions*: Table[string, FunctionInfo]

    # CFFI metadata
    cffiInfo*: Table[string, CFFIInfo]


# Forward declarations for internal helpers
proc serializeV(stream: Stream, val: V)
proc deserializeV(stream: Stream): V
proc serializeRegInstruction(stream: Stream, instr: RegInstruction)
proc deserializeRegInstruction(stream: Stream): RegInstruction


# Serialize a V value with full type preservation
proc serializeV(stream: Stream, val: V) =
  # Write the kind (VKind enum value)
  stream.write(uint8(val.kind))

  # Write type-specific data
  case val.kind:
  of vkInt:
    stream.write(val.ival)
  of vkFloat:
    stream.write(val.fval)
  of vkBool:
    stream.write(val.bval)
  of vkChar:
    stream.write(val.cval)
  of vkString:
    stream.write(uint32(val.sval.len))
    stream.write(val.sval)
  of vkArray:
    stream.write(uint32(val.aval.len))
    for item in val.aval:
      serializeV(stream, item)
  of vkTable:
    stream.write(uint32(val.tval.len))
    for key, value in val.tval:
      stream.write(uint32(key.len))
      stream.write(key)
      serializeV(stream, value)
  of vkSome, vkOk, vkErr:
    # Option/Result types with wrapped values
    serializeV(stream, val.wrapped[])
  of vkNil, vkNone:
    discard  # No additional data to serialize


# Deserialize a V value with full type restoration
proc deserializeV(stream: Stream): V =
  # Read the kind
  let kind = VKind(stream.readUint8())

  # Read type-specific data
  case kind:
  of vkInt:
    result = makeInt(stream.readInt64())
  of vkFloat:
    result = makeFloat(stream.readFloat64())
  of vkBool:
    result = makeBool(stream.readBool())
  of vkChar:
    result = makeChar(stream.readChar())
  of vkString:
    let len = stream.readUint32()
    result = makeString(stream.readStr(int(len)))
  of vkArray:
    let len = stream.readUint32()
    var arr = newSeq[V](len)
    for i in 0..<len:
      arr[i] = deserializeV(stream)
    result = makeArray(arr)
  of vkTable:
    let len = stream.readUint32()
    result = makeTable()
    for _ in 0..<len:
      let keyLen = stream.readUint32()
      let key = stream.readStr(int(keyLen))
      result.tval[key] = deserializeV(stream)
  of vkSome:
    result = makeSome(deserializeV(stream))
  of vkOk:
    result = makeOk(deserializeV(stream))
  of vkErr:
    result = makeErr(deserializeV(stream))
  of vkNil:
    result = makeNil()
  of vkNone:
    result = makeNone()


# Serialize a register VM instruction
proc serializeRegInstruction(stream: Stream, instr: RegInstruction) =
  stream.write(uint8(instr.op))
  stream.write(instr.a)
  stream.write(instr.opType)
  case instr.opType:
  of 0:  # ABC format
    stream.write(instr.b)
    stream.write(instr.c)
  of 1:  # ABx format
    stream.write(instr.bx)
  of 2:  # AsBx format
    stream.write(instr.sbx)
  of 3:  # Ax format
    stream.write(instr.ax)
  of 4:  # Function call format
    stream.write(instr.funcIdx)
    stream.write(instr.numArgs)
    stream.write(instr.numResults)
  else:
    discard

  # Serialize debug info
  stream.write(uint32(instr.debug.line))
  let sourceFileLen = uint32(instr.debug.sourceFile.len)
  stream.write(sourceFileLen)
  if sourceFileLen > 0:
    stream.write(instr.debug.sourceFile)


# Deserialize a register VM instruction
proc deserializeRegInstruction(stream: Stream): RegInstruction =
  let op = RegOpCode(stream.readUint8())
  let a = stream.readUint8()
  let opType = stream.readUint8()

  # Create the instruction with the correct variant from the start
  case opType:
  of 0:  # ABC format
    let b = stream.readUint8()
    let c = stream.readUint8()
    result = RegInstruction(op: op, a: a, opType: 0, b: b, c: c)
  of 1:  # ABx format
    let bx = stream.readUint16()
    result = RegInstruction(op: op, a: a, opType: 1, bx: bx)
  of 2:  # AsBx format
    let sbx = stream.readInt16()
    result = RegInstruction(op: op, a: a, opType: 2, sbx: sbx)
  of 3:  # Ax format
    let ax = stream.readUint32()
    result = RegInstruction(op: op, a: a, opType: 3, ax: ax)
  of 4:  # Function call format
    let funcIdx = stream.readUint16()
    let numArgs = stream.readUint8()
    let numResults = stream.readUint8()
    result = RegInstruction(op: op, a: a, opType: 4, funcIdx: funcIdx, numArgs: numArgs, numResults: numResults)
  else:
    # Default case - create as ABC format with zeros
    result = RegInstruction(op: op, a: a, opType: 0, b: 0, c: 0)

  # Deserialize debug info
  let line = stream.readUint32()
  let sourceFileLen = stream.readUint32()
  let sourceFile = if sourceFileLen > 0: stream.readStr(int(sourceFileLen)) else: ""
  result.debug.line = int(line)
  result.debug.sourceFile = sourceFile


# Serialize register VM bytecode to binary format
proc serializeToBinary*(prog: RegBytecodeProgram, sourceHash: string = "",
                        compilerVersion: string = "", sourceFile: string = "",
                        flags: RegCompilerFlags = RegCompilerFlags()): string =
  var stream = newStringStream()

  # Magic header: "ETCH" + VM type byte + version
  # This ensures compatibility with stack VM format but differentiation
  stream.write(BYTECODE_MAGIC)  # "ETCH"
  stream.write(uint8(vmRegister))  # VM type: register-based
  stream.write(uint32(BYTECODE_VERSION))

  # Source hash (32 bytes, padded with zeros if needed)
  var hashBytes = sourceHash
  if hashBytes.len < 32:
    hashBytes = hashBytes & repeat('\0', 32 - hashBytes.len)
  elif hashBytes.len > 32:
    hashBytes = hashBytes[0..<32]
  stream.write(hashBytes)

  # Compiler version hash (32 bytes, padded with zeros if needed)
  var compilerBytes = compilerVersion
  if compilerBytes.len < 32:
    compilerBytes = compilerBytes & repeat('\0', 32 - compilerBytes.len)
  elif compilerBytes.len > 32:
    compilerBytes = compilerBytes[0..<32]
  stream.write(compilerBytes)

  # Compiler flags
  var flagBits: uint8 = 0
  if flags.verbose:
    flagBits = flagBits or 1
  if flags.debug:
    flagBits = flagBits or 2
  flagBits = flagBits or uint8(flags.optimizeLevel shl 4)  # Store optimize level in upper 4 bits
  stream.write(flagBits)

  # Source file name
  var sourceFileLen = uint32(sourceFile.len)
  stream.write(sourceFileLen)
  if sourceFileLen > 0:
    stream.write(sourceFile)

  # Entry point
  stream.write(uint32(prog.entryPoint))

  # Constants pool
  var constCount = uint32(prog.constants.len)
  stream.write(constCount)
  for c in prog.constants:
    serializeV(stream, c)

  # Instructions
  var instrCount = uint32(prog.instructions.len)
  stream.write(instrCount)
  for instr in prog.instructions:
    serializeRegInstruction(stream, instr)

  # Functions table
  var funcCount = uint32(prog.functions.len)
  stream.write(funcCount)
  for name, info in prog.functions:
    var nameLen = uint32(name.len)
    stream.write(nameLen)
    stream.write(name)
    stream.write(uint32(info.startPos))
    stream.write(uint32(info.endPos))
    stream.write(uint32(info.numParams))
    stream.write(uint32(info.numLocals))

  # CFFI info
  var cffiCount = uint32(prog.cffiInfo.len)
  stream.write(cffiCount)
  for name, cffi in prog.cffiInfo:
    # Write function name
    var nameLen = uint32(name.len)
    stream.write(nameLen)
    stream.write(name)

    # Write CFFI metadata
    var libLen = uint32(cffi.library.len)
    stream.write(libLen)
    stream.write(cffi.library)

    var symLen = uint32(cffi.symbol.len)
    stream.write(symLen)
    stream.write(cffi.symbol)

    var baseLen = uint32(cffi.baseName.len)
    stream.write(baseLen)
    stream.write(cffi.baseName)

    # Parameter types
    var paramCount = uint32(cffi.paramTypes.len)
    stream.write(paramCount)
    for paramType in cffi.paramTypes:
      var typeLen = uint32(paramType.len)
      stream.write(typeLen)
      stream.write(paramType)

    # Return type
    var retLen = uint32(cffi.returnType.len)
    stream.write(retLen)
    stream.write(cffi.returnType)

  # Lifetime data (for debugger) - contains full scope/lifetime information
  var lifetimeCount = uint32(prog.lifetimeData.len)
  stream.write(lifetimeCount)
  for funcName, rawData in prog.lifetimeData:
    let lifetimeData = cast[ptr FunctionLifetimeData](rawData)

    # Write function name
    var funcNameLen = uint32(funcName.len)
    stream.write(funcNameLen)
    stream.write(funcName)

    # Write lifetime ranges
    var rangeCount = uint32(lifetimeData.ranges.len)
    stream.write(rangeCount)
    for r in lifetimeData.ranges:
      # Variable name
      var varNameLen = uint32(r.varName.len)
      stream.write(varNameLen)
      stream.write(r.varName)
      # Register and PCs
      stream.write(r.register)
      stream.write(int32(r.startPC))
      stream.write(int32(r.endPC))
      stream.write(int32(r.defPC))
      stream.write(int32(r.lastUsePC))
      stream.write(int32(r.scopeLevel))

    # Write pcToVariables map
    var pcMapCount = uint32(lifetimeData.pcToVariables.len)
    stream.write(pcMapCount)
    for pc, vars in lifetimeData.pcToVariables:
      stream.write(int32(pc))
      var varListCount = uint32(vars.len)
      stream.write(varListCount)
      for varName in vars:
        var varNameLen = uint32(varName.len)
        stream.write(varNameLen)
        stream.write(varName)

    # Write destructorPoints map
    var destructorCount = uint32(lifetimeData.destructorPoints.len)
    stream.write(destructorCount)
    for pc, vars in lifetimeData.destructorPoints:
      stream.write(int32(pc))
      var varListCount = uint32(vars.len)
      stream.write(varListCount)
      for varName in vars:
        var varNameLen = uint32(varName.len)
        stream.write(varNameLen)
        stream.write(varName)

  stream.setPosition(0)
  result = stream.readAll()
  stream.close()


# Deserialize register VM bytecode from binary format
proc deserializeFromBinary*(data: string): RegBytecodeProgram =
  var stream = newStringStream(data)

  # Check magic header
  let magic = stream.readStr(4)
  if magic != BYTECODE_MAGIC:
    raise newException(ValueError, "Invalid bytecode file: bad magic (expected ETCH, got " & magic & ")")

  # Check VM type
  let vmTypeValue = stream.readUint8()
  if vmTypeValue != uint8(vmRegister):
    raise newException(ValueError, "Unknown VM type: " & $vmTypeValue & " (expected " & $uint8(vmRegister) & " for register VM)")

  let version = stream.readUint32()
  if version != uint32(BYTECODE_VERSION):
    raise newException(ValueError, "Unsupported bytecode version: " & $version)

  # Skip source hash (32 bytes)
  discard stream.readStr(32)

  # Skip compiler version (32 bytes)
  discard stream.readStr(32)

  # Skip compiler flags
  discard stream.readUint8()

  # Skip source file
  let sourceFileLen = stream.readUint32()
  if sourceFileLen > 0:
    discard stream.readStr(int(sourceFileLen))

  # Read entry point
  result.entryPoint = int(stream.readUint32())

  # Read constants
  let constCount = stream.readUint32()
  result.constants = newSeq[V](constCount)
  for i in 0..<constCount:
    result.constants[i] = deserializeV(stream)

  # Read instructions
  let instrCount = stream.readUint32()
  result.instructions = newSeq[RegInstruction](instrCount)
  for i in 0..<instrCount:
    result.instructions[i] = deserializeRegInstruction(stream)

  # Read functions table
  let funcCount = stream.readUint32()
  result.functions = initTable[string, FunctionInfo]()
  for _ in 0..<funcCount:
    let nameLen = stream.readUint32()
    let name = stream.readStr(int(nameLen))
    var info: FunctionInfo
    info.name = name
    info.startPos = int(stream.readUint32())
    info.endPos = int(stream.readUint32())
    info.numParams = int(stream.readUint32())
    info.numLocals = int(stream.readUint32())
    result.functions[name] = info

  # Read CFFI info
  let cffiCount = stream.readUint32()
  result.cffiInfo = initTable[string, CFFIInfo]()
  for _ in 0..<cffiCount:
    # Read function name
    let nameLen = stream.readUint32()
    let name = stream.readStr(int(nameLen))

    # Read CFFI metadata
    var cffi: CFFIInfo

    let libLen = stream.readUint32()
    cffi.library = stream.readStr(int(libLen))

    let symLen = stream.readUint32()
    cffi.symbol = stream.readStr(int(symLen))

    let baseLen = stream.readUint32()
    cffi.baseName = stream.readStr(int(baseLen))

    # Parameter types
    let paramCount = stream.readUint32()
    cffi.paramTypes = newSeq[string](paramCount)
    for i in 0..<paramCount:
      let typeLen = stream.readUint32()
      cffi.paramTypes[i] = stream.readStr(int(typeLen))

    # Return type
    let retLen = stream.readUint32()
    cffi.returnType = stream.readStr(int(retLen))

    result.cffiInfo[name] = cffi

  # Read lifetime data (for debugger)
  let lifetimeCount = stream.readUint32()
  result.lifetimeData = initTable[string, pointer]()
  for _ in 0..<lifetimeCount:
    # Read function name
    let funcNameLen = stream.readUint32()
    let funcName = stream.readStr(int(funcNameLen))

    # Read lifetime ranges
    let rangeCount = stream.readUint32()
    var ranges: seq[LifetimeRange] = @[]
    for _ in 0..<rangeCount:
      # Variable name
      let varNameLen = stream.readUint32()
      let varName = stream.readStr(int(varNameLen))
      # Register and PCs
      let register = stream.readUint8()
      let startPC = int(stream.readInt32())
      let endPC = int(stream.readInt32())
      let defPC = int(stream.readInt32())
      let lastUsePC = int(stream.readInt32())
      let scopeLevel = int(stream.readInt32())

      ranges.add(LifetimeRange(
        varName: varName,
        register: register,
        startPC: startPC,
        endPC: endPC,
        defPC: defPC,
        lastUsePC: lastUsePC,
        scopeLevel: scopeLevel
      ))

    # Read pcToVariables map
    let pcMapCount = stream.readUint32()
    var pcToVariables = initTable[int, seq[string]]()
    for _ in 0..<pcMapCount:
      let pc = int(stream.readInt32())
      let varListCount = stream.readUint32()
      var vars: seq[string] = @[]
      for _ in 0..<varListCount:
        let varNameLen = stream.readUint32()
        let varName = stream.readStr(int(varNameLen))
        vars.add(varName)
      pcToVariables[pc] = vars

    # Read destructorPoints map
    let destructorCount = stream.readUint32()
    var destructorPoints = initTable[int, seq[string]]()
    for _ in 0..<destructorCount:
      let pc = int(stream.readInt32())
      let varListCount = stream.readUint32()
      var vars: seq[string] = @[]
      for _ in 0..<varListCount:
        let varNameLen = stream.readUint32()
        let varName = stream.readStr(int(varNameLen))
        vars.add(varName)
      destructorPoints[pc] = vars

    # Create FunctionLifetimeData and store on heap
    var heapData = new(FunctionLifetimeData)
    heapData[] = FunctionLifetimeData(
      functionName: funcName,
      ranges: ranges,
      pcToVariables: pcToVariables,
      destructorPoints: destructorPoints
    )
    result.lifetimeData[funcName] = cast[pointer](heapData)
    GC_ref(heapData)

  stream.close()


# Save register VM bytecode to file
proc saveRegBytecode*(prog: RegBytecodeProgram, filename: string,
                     sourceHash: string = "", compilerVersion: string = "",
                     sourceFile: string = "", flags: RegCompilerFlags = RegCompilerFlags()) =
  let binaryData = prog.serializeToBinary(sourceHash, compilerVersion, sourceFile, flags)
  writeFile(filename, binaryData)


# Load register VM bytecode from file
proc loadRegBytecode*(filename: string): RegBytecodeProgram =
  let binaryData = readFile(filename)
  deserializeFromBinary(binaryData)


# Debug string representation for opcodes
proc `$`*(op: RegOpCode): string =
  case op
  of ropMove: "MOVE"
  of ropLoadK: "LOADK"
  of ropLoadBool: "LOADBOOL"
  of ropLoadNil: "LOADNIL"
  of ropGetGlobal: "GETGLOBAL"
  of ropSetGlobal: "SETGLOBAL"
  of ropAdd: "ADD"
  of ropSub: "SUB"
  of ropMul: "MUL"
  of ropDiv: "DIV"
  of ropMod: "MOD"
  of ropPow: "POW"
  of ropAddI: "ADDI"
  of ropSubI: "SUBI"
  of ropMulI: "MULI"
  of ropUnm: "UNM"
  of ropEq: "EQ"
  of ropLt: "LT"
  of ropLe: "LE"
  of ropEqI: "EQI"
  of ropLtI: "LTI"
  of ropLeI: "LEI"
  of ropEqStore: "EQSTORE"
  of ropLtStore: "LTSTORE"
  of ropLeStore: "LESTORE"
  of ropNeStore: "NESTORE"
  of ropNot: "NOT"
  of ropAnd: "AND"
  of ropOr: "OR"
  of ropIn: "IN"
  of ropNotIn: "NOTIN"
  of ropCast: "CAST"
  of ropWrapSome: "WRAPSOME"
  of ropLoadNone: "LOADNONE"
  of ropWrapOk: "WRAPOK"
  of ropWrapErr: "WRAPERR"
  of ropTestTag: "TESTTAG"
  of ropUnwrapOption: "UNWRAPOPTION"
  of ropUnwrapResult: "UNWRAPRESULT"
  of ropNewArray: "NEWARRAY"
  of ropGetIndex: "GETINDEX"
  of ropSetIndex: "SETINDEX"
  of ropGetIndexI: "GETINDEXI"
  of ropSetIndexI: "SETINDEXI"
  of ropLen: "LEN"
  of ropSlice: "SLICE"
  of ropNewTable: "NEWTABLE"
  of ropGetField: "GETFIELD"
  of ropSetField: "SETFIELD"
  of ropJmp: "JMP"
  of ropTest: "TEST"
  of ropTestSet: "TESTSET"
  of ropCall: "CALL"
  of ropTailCall: "TAILCALL"
  of ropReturn: "RETURN"
  of ropForLoop: "FORLOOP"
  of ropForPrep: "FORPREP"
  of ropAddAdd: "ADDADD"
  of ropMulAdd: "MULADD"
  of ropCmpJmp: "CMPJMP"
  of ropIncTest: "INCTEST"
  of ropLoadAddStore: "LOADADDSTORE"
  of ropGetAddSet: "GETADDSET"