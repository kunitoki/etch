# serialize.nim
# Register VM bytecode serialization and deserialization

import std/[tables, streams, strutils, strformat, os]
import ../common/constants
import ../core/[vm, vm_types]


type
  CompilerFlags* = object
    verbose*: bool
    debug*: bool
    optimizeLevel*: int

  BytecodeHeader* = object
    valid*: bool
    version*: uint32
    sourceHash*: string
    compilerVersion*: string
    verbose*: bool
    debug*: bool
    optimizeLevel*: int

  BytecodeFile* = object
    # File metadata
    sourceHash*: string
    compilerVersion*: string
    compilerFlags*: CompilerFlags
    sourceFile*: string

    # Program data
    entryPoint*: int
    constants*: seq[V]
    instructions*: seq[Instruction]
    instructionDebugInfo*: seq[DebugInfo]

    # Unified function metadata
    functions*: Table[string, FunctionInfo]


# Forward declarations for internal helpers
proc serializeV(stream: Stream, val: V)
proc deserializeV(stream: Stream): V
proc serializeInstruction(stream: Stream, instr: Instruction)
proc deserializeInstruction(stream: Stream): Instruction
proc serializeDebugInfoEntry(stream: Stream, info: DebugInfo)
proc deserializeDebugInfoEntry(stream: Stream): DebugInfo


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
    stream.write(uint32(val.aval[].len))
    for item in val.aval[]:
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
  of vkRef:
    stream.write(int32(val.refId))
  of vkClosure:
    stream.write(int32(val.closureId))
  of vkWeak:
    stream.write(int32(val.weakId))
  of vkCoroutine:
    stream.write(int32(val.coroId))
  of vkChannel:
    stream.write(int32(val.chanId))
  of vkTypeDesc:
    stream.write(uint32(val.typeDescName.len))
    stream.write(val.typeDescName)
  of vkEnum:
    stream.write(int32(val.enumTypeId))
    stream.write(val.enumIntVal)
    stream.write(uint32(val.enumStringVal.len))
    stream.write(val.enumStringVal)
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
    result = makeError(deserializeV(stream))
  of vkRef:
    result = makeRef(stream.readInt32())
  of vkClosure:
    result = makeClosure(stream.readInt32())
  of vkWeak:
    result = makeWeak(stream.readInt32())
  of vkCoroutine:
    result = V(kind: vkCoroutine, coroId: stream.readInt32())
  of vkChannel:
    result = V(kind: vkChannel, chanId: stream.readInt32())
  of vkTypeDesc:
    let len = stream.readUint32()
    result = makeTypeDesc(stream.readStr(int(len)))
  of vkNil:
    result = makeNil()
  of vkNone:
    result = makeNone()
  of vkEnum:
    result = V(
      kind: vkEnum,
      enumTypeId: stream.readInt32(),
      enumIntVal: stream.readInt64(),
      enumStringVal: stream.readStr(int(stream.readUint32()))
    )


# Serialize a register VM instruction
proc serializeInstruction(stream: Stream, instr: Instruction) =
  stream.write(uint8(instr.op))
  stream.write(instr.a)
  stream.write(uint8(instr.opType))  # Write enum as uint8
  case instr.opType:
  of ifmtABC:  # ABC format
    stream.write(instr.b)
    stream.write(instr.c)
  of ifmtABx:  # ABx format
    stream.write(instr.bx)
  of ifmtAsBx:  # AsBx format
    stream.write(instr.sbx)
  of ifmtAx:  # Ax format
    stream.write(instr.ax)
  of ifmtCall:  # Function call format
    stream.write(instr.funcIdx)
    stream.write(instr.numArgs)
    stream.write(instr.numResults)


# Deserialize a register VM instruction
proc deserializeInstruction(stream: Stream): Instruction =
  let op = OpCode(stream.readUint8())
  let a = stream.readUint8()
  let opType = stream.readUint8()

  # Create the instruction with the correct variant from the start
  case opType:
  of 0:  # ABC format
    let b = stream.readUint8()
    let c = stream.readUint8()
    result = Instruction(op: op, a: a, opType: ifmtABC, b: b, c: c)
  of 1:  # ABx format
    let bx = stream.readUint16()
    result = Instruction(op: op, a: a, opType: ifmtABx, bx: bx)
  of 2:  # AsBx format
    let sbx = stream.readInt16()
    result = Instruction(op: op, a: a, opType: ifmtAsBx, sbx: sbx)
  of 3:  # Ax format
    let ax = stream.readUint32()
    result = Instruction(op: op, a: a, opType: ifmtAx, ax: ax)
  of 4:  # Function call format
    let funcIdx = stream.readUint16()
    let numArgs = stream.readUint8()
    let numResults = stream.readUint8()
    result = Instruction(op: op, a: a, opType: ifmtCall, funcIdx: funcIdx, numArgs: numArgs, numResults: numResults)
  else:
    # Default case - create as ABC format with zeros
    result = Instruction(op: op, a: a, opType: ifmtABC, b: 0, c: 0)


proc serializeDebugInfoEntry(stream: Stream, info: DebugInfo) =
  stream.write(int32(info.line))
  stream.write(int32(info.col))

  stream.write(uint32(info.sourceFile.len))
  if info.sourceFile.len > 0:
    stream.write(info.sourceFile)

  stream.write(uint32(info.functionName.len))
  if info.functionName.len > 0:
    stream.write(info.functionName)


proc deserializeDebugInfoEntry(stream: Stream): DebugInfo =
  ## Deserialize a debug info record regardless of deploy mode
  let line = int(stream.readInt32())
  let col = int(stream.readInt32())

  let sourceFileLen = stream.readUint32()
  var sourceFile = ""
  if sourceFileLen > 0:
    sourceFile = stream.readStr(int(sourceFileLen))

  let functionNameLen = stream.readUint32()
  var functionName = ""
  if functionNameLen > 0:
    functionName = stream.readStr(int(functionNameLen))

  result = DebugInfo(
    line: line,
    col: col,
    sourceFile: sourceFile,
    functionName: functionName,
    localVars: @[]
  )


# Serialize register VM bytecode to binary format
proc serializeToBinary*(prog: BytecodeProgram, sourceHash: string = "",
                        compilerVersion: string = "", sourceFile: string = "",
                        flags: CompilerFlags = CompilerFlags()): string =
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
    serializeInstruction(stream, instr)

  let debugCount = uint32(prog.instructions.len)
  if prog.debugInfo.len != prog.instructions.len:
    raise newException(ValueError, &"Debug info count mismatch: have {prog.debugInfo.len} entries for {prog.instructions.len} instructions")
  stream.write(debugCount)
  for info in prog.debugInfo:
    serializeDebugInfoEntry(stream, info)

  # Functions table (unified representation)
  var funcCount = uint32(prog.functions.len)
  stream.write(funcCount)
  for name, funcInfo in prog.functions:
    # Write function names
    stream.write(uint32(name.len))
    stream.write(name)
    stream.write(uint32(funcInfo.baseName.len))
    stream.write(funcInfo.baseName)

    # Write function kind
    stream.write(uint8(funcInfo.kind))

    # Parameter types
    stream.write(uint32(funcInfo.paramTypes.len))
    for paramType in funcInfo.paramTypes:
      stream.write(uint32(paramType.len))
      stream.write(paramType)

    # Return type
    stream.write(uint32(funcInfo.returnType.len))
    stream.write(funcInfo.returnType)

    case funcInfo.kind:
    of fkNative:
      # Native function fields
      stream.write(uint32(funcInfo.startPos))
      stream.write(uint32(funcInfo.endPos))
      stream.write(uint32(funcInfo.maxRegister))
    of fkCFFI:
      # CFFI function fields
      stream.write(uint32(funcInfo.library.len))
      stream.write(funcInfo.library)

      stream.write(uint32(funcInfo.libraryPath.len))
      stream.write(funcInfo.libraryPath)

      stream.write(uint32(funcInfo.symbol.len))
      stream.write(funcInfo.symbol)
    of fkHost:
      # Host function fields - no additional data to serialize
      # Host functions are provided by the host context at runtime
      discard
    of fkBuiltin:
      # Builtin metadata: just builtin id
      stream.write(uint16(funcInfo.builtinId))

  # Function table (index -> name mapping for direct calls)
  var funcTableCount = uint32(prog.functionTable.len)
  stream.write(funcTableCount)
  for funcName in prog.functionTable:
    var nameLen = uint32(funcName.len)
    stream.write(nameLen)
    stream.write(funcName)

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

  # Variable maps (for debugging - maps variable names to registers per function)
  var varMapCount = uint32(prog.varMaps.len)
  stream.write(varMapCount)
  for funcName, varMap in prog.varMaps:
    # Write function name
    var funcNameLen = uint32(funcName.len)
    stream.write(funcNameLen)
    stream.write(funcName)

    # Write variable map
    var mapSize = uint32(varMap.len)
    stream.write(mapSize)
    for varName, regNum in varMap:
      var varNameLen = uint32(varName.len)
      stream.write(varNameLen)
      stream.write(varName)
      stream.write(uint8(regNum))

  stream.setPosition(0)
  result = stream.readAll()
  stream.close()


# Deserialize register VM bytecode from binary format
proc deserializeFromBinary*(data: string): BytecodeProgram =
  result = new(BytecodeProgram)
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
  let instrCount = int(stream.readUint32())
  result.instructions = newSeq[Instruction](instrCount)
  for i in 0..<instrCount:
    result.instructions[i] = deserializeInstruction(stream)

  let debugCount = int(stream.readUint32())
  if debugCount != instrCount:
    raise newException(ValueError, &"Bytecode debug info mismatch: expected {instrCount} entries, got {debugCount}")
  result.debugInfo = newSeq[DebugInfo](debugCount)
  for i in 0..<debugCount:
    result.debugInfo[i] = deserializeDebugInfoEntry(stream)

  # Read functions table (unified representation)
  let funcCount = stream.readUint32()
  result.functions = initTable[string, FunctionInfo]()
  for _ in 0..<funcCount:
    let nameLen = stream.readUint32()
    let name = stream.readStr(int(nameLen))

    let baseLen = stream.readUint32()
    let baseName = stream.readStr(int(baseLen))

    # Read function kind
    let kind = stream.readUint8()

    # Parameter types
    let paramCount = stream.readUint32()
    var paramTypes = newSeq[string](paramCount)
    for i in 0..<paramCount:
      let typeLen = stream.readUint32()
      paramTypes[i] = stream.readStr(int(typeLen))

    # Return type
    let retLen = stream.readUint32()
    let returnType = stream.readStr(int(retLen))

    case FunctionKind(kind):
    of fkNative:
      # Native function
      result.functions[name] = FunctionInfo(
        name: name,
        baseName: baseName,
        kind: fkNative,
        paramTypes: paramTypes,
        returnType: returnType,
        startPos: int(stream.readUint32()),
        endPos: int(stream.readUint32()),
        maxRegister: int(stream.readUint32())
      )
    of fkCFFI:
      # CFFI function
      let libLen = stream.readUint32()
      let library = stream.readStr(int(libLen))

      let libPathLen = stream.readUint32()
      let libraryPath = stream.readStr(int(libPathLen))

      let symLen = stream.readUint32()
      let symbol = stream.readStr(int(symLen))

      result.functions[name] = FunctionInfo(
        name: name,
        baseName: baseName,
        kind: fkCFFI,
        paramTypes: paramTypes,
        returnType: returnType,
        library: library,
        libraryPath: libraryPath,
        symbol: symbol
      )
    of fkHost:
      # Host function - no additional data to deserialize
      result.functions[name] = FunctionInfo(
        name: name,
        baseName: baseName,
        kind: fkHost,
        paramTypes: paramTypes,
        returnType: returnType
      )
    of fkBuiltin:
      let builtinId = stream.readUint16()
      result.functions[name] = FunctionInfo(
        name: name,
        baseName: baseName,
        kind: fkBuiltin,
        paramTypes: paramTypes,
        returnType: returnType,
        builtinId: builtinId
      )

  # Read function table (index -> name mapping for direct calls)
  let funcTableCount = stream.readUint32()
  result.functionTable = newSeq[string](funcTableCount)
  for i in 0..<funcTableCount:
    let nameLen = stream.readUint32()
    result.functionTable[i] = stream.readStr(int(nameLen))

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

  # Read variable maps (for debugging)
  let varMapCount = stream.readUint32()
  result.varMaps = initTable[string, Table[string, uint8]]()
  for _ in 0..<varMapCount:
    # Read function name
    let funcNameLen = stream.readUint32()
    let funcName = stream.readStr(int(funcNameLen))

    # Read variable map
    let mapSize = stream.readUint32()
    var varMap = initTable[string, uint8]()
    for _ in 0..<mapSize:
      let varNameLen = stream.readUint32()
      let varName = stream.readStr(int(varNameLen))
      let regNum = stream.readUint8()
      varMap[varName] = regNum

    result.varMaps[funcName] = varMap

  stream.close()


# Save register VM bytecode to file
proc saveBytecode*(prog: BytecodeProgram, filename: string,
                     sourceHash: string = "", compilerVersion: string = "",
                     sourceFile: string = "", flags: CompilerFlags = CompilerFlags()) =
  let binaryData = prog.serializeToBinary(sourceHash, compilerVersion, sourceFile, flags)
  writeFile(filename, binaryData)


# Load register VM bytecode from file
proc loadBytecode*(filename: string): BytecodeProgram =
  let binaryData = readFile(filename)
  deserializeFromBinary(binaryData)


proc readBytecodeHeader*(filename: string): BytecodeHeader =
  ## Read just the header of a bytecode file for cache validation
  ## Returns valid=false if file doesn't exist or has invalid format
  result.valid = false

  if not fileExists(filename):
    return

  try:
    let data = readFile(filename)
    if data.len < 73:  # Minimum header size: 4 (magic) + 1 (vm type) + 4 (version) + 32 (source hash) + 32 (compiler version) + 1 (flags) = 74
      return

    var stream = newStringStream(data)

    # Check magic header
    let magic = stream.readStr(4)
    if magic != BYTECODE_MAGIC:
      return

    # Check VM type
    let vmTypeValue = stream.readUint8()
    if vmTypeValue != uint8(vmRegister):
      return

    # Read version
    result.version = stream.readUint32()

    # Read source hash (32 bytes, trim null padding)
    result.sourceHash = stream.readStr(32).strip(chars = {'\0'})

    # Read compiler version (32 bytes, trim null padding)
    result.compilerVersion = stream.readStr(32).strip(chars = {'\0'})

    # Read compiler flags
    let flagBits = stream.readUint8()
    result.verbose = (flagBits and 1) != 0
    result.debug = (flagBits and 2) != 0
    result.optimizeLevel = int(flagBits shr 4)

    result.valid = true
  except:
    result.valid = false


# Debug string representation for opcodes
proc `$`*(op: OpCode): string =
  case op
  of opMove: "MOVE"
  of opLoadK: "LOADK"
  of opLoadBool: "LOADBOOL"
  of opLoadNil: "LOADNIL"
  of opGetGlobal: "GETGLOBAL"
  of opSetGlobal: "SETGLOBAL"
  of opInitGlobal: "INITGLOBAL"
  of opAdd: "ADD"
  of opSub: "SUB"
  of opMul: "MUL"
  of opDiv: "DIV"
  of opMod: "MOD"
  of opPow: "POW"
  of opAddI: "ADDI"
  of opSubI: "SUBI"
  of opMulI: "MULI"
  of opDivI: "DIVI"
  of opModI: "MODI"
  of opAndI: "ANDI"
  of opOrI: "ORI"
  of opAddInt: "ADDINT"
  of opSubInt: "SUBINT"
  of opMulInt: "MULINT"
  of opDivInt: "DIVINT"
  of opModInt: "MODINT"
  of opAddFloat: "ADDFLOAT"
  of opSubFloat: "SUBFLOAT"
  of opMulFloat: "MULFLOAT"
  of opDivFloat: "DIVFLOAT"
  of opModFloat: "MODFLOAT"
  of opAddAdd: "ADDADD"
  of opAddAddInt: "ADDADDINT"
  of opAddAddFloat: "ADDADDFLOAT"
  of opMulAdd: "MULADD"
  of opMulAddInt: "MULADDINT"
  of opMulAddFloat: "MULADDFLOAT"
  of opSubSub: "SUBSUB"
  of opSubSubInt: "SUBSUBINT"
  of opSubSubFloat: "SUBSUBFLOAT"
  of opMulSub: "MULSUB"
  of opMulSubInt: "MULSUBINT"
  of opMulSubFloat: "MULSUBFLOAT"
  of opSubMul: "SUBMUL"
  of opSubMulInt: "SUBMULINT"
  of opSubMulFloat: "SUBMULFLOAT"
  of opDivAdd: "DIVADD"
  of opDivAddInt: "DIVADDINT"
  of opDivAddFloat: "DIVADDFLOAT"
  of opAddSub: "ADDSUB"
  of opAddSubInt: "ADDSUBINT"
  of opAddSubFloat: "ADDSUBFLOAT"
  of opAddMul: "ADDMUL"
  of opAddMulInt: "ADDMULINT"
  of opAddMulFloat: "ADDMULFLOAT"
  of opSubDiv: "SUBDIV"
  of opSubDivInt: "SUBDIVINT"
  of opSubDivFloat: "SUBDIVFLOAT"
  of opUnm: "UNM"
  of opEq: "EQ"
  of opLt: "LT"
  of opLe: "LE"
  of opLtJmp: "LTJMP"
  of opEqI: "EQI"
  of opLtI: "LTI"
  of opLeI: "LEI"
  of opEqInt: "EQINT"
  of opLtInt: "LTINT"
  of opLeInt: "LEINT"
  of opEqFloat: "EQFLOAT"
  of opLtFloat: "LTFLOAT"
  of opLeFloat: "LEFLOAT"
  of opEqStore: "EQSTORE"
  of opLtStore: "LTSTORE"
  of opLeStore: "LESTORE"
  of opNeStore: "NESTORE"
  of opEqStoreInt: "EQSTOREINT"
  of opLtStoreInt: "LTSTOREINT"
  of opLeStoreInt: "LESTOREINT"
  of opEqStoreFloat: "EQSTOREFLOAT"
  of opLtStoreFloat: "LTSTOREFLOAT"
  of opLeStoreFloat: "LESTOREFLOAT"
  of opNot: "NOT"
  of opAnd: "AND"
  of opOr: "OR"
  of opIn: "IN"
  of opNotIn: "NOTIN"
  of opCast: "CAST"
  of opArg: "ARG"
  of opArgImm: "ARGIMM"
  of opWrapSome: "WRAPSOME"
  of opLoadNone: "LOADNONE"
  of opWrapOk: "WRAPOK"
  of opWrapErr: "WRAPERR"
  of opTestTag: "TESTTAG"
  of opUnwrapOption: "UNWRAPOPTION"
  of opUnwrapResult: "UNWRAPRESULT"
  of opNewArray: "NEWARRAY"
  of opGetIndex: "GETINDEX"
  of opSetIndex: "SETINDEX"
  of opGetIndexI: "GETINDEXI"
  of opSetIndexI: "SETINDEXI"
  of opGetIndexInt: "GETINDEXINT"
  of opGetIndexFloat: "GETINDEXFLOAT"
  of opGetIndexIInt: "GETINDEXIINT"
  of opGetIndexIFloat: "GETINDEXIFLOAT"
  of opSetIndexInt: "SETINDEXINT"
  of opSetIndexFloat: "SETINDEXFLOAT"
  of opSetIndexIInt: "SETINDEXIINT"
  of opSetIndexIFloat: "SETINDEXIFLOAT"
  of opLen: "LEN"
  of opSlice: "SLICE"
  of opConcatArray: "CONCATARRAY"
  of opNewTable: "NEWTABLE"
  of opGetField: "GETFIELD"
  of opSetField: "SETFIELD"
  of opSetRef: "SETREF"
  of opNewRef: "NEWREF"
  of opIncRef: "INCREF"
  of opDecRef: "DECREF"
  of opNewWeak: "NEWWEAK"
  of opWeakToStrong: "WEAKTOSTRONG"
  of opCheckCycles: "CHECKCYCLES"
  of opJmp: "JMP"
  of opTest: "TEST"
  of opTestSet: "TESTSET"
  of opCall: "CALL"
  of opCallBuiltin: "CALLBUILTIN"
  of opCallHost: "CALLHOST"
  of opCallFFI: "CALLFFI"
  of opTailCall: "TAILCALL"
  of opReturn: "RETURN"
  of opNoOp: "NOOP"
  of opPushDefer: "PUSHDEFER"
  of opExecDefers: "EXECDEFERS"
  of opDeferEnd: "DEFEREND"
  of opForLoop: "FORLOOP"
  of opForPrep: "FORPREP"
  of opForIntLoop: "FORINTLOOP"
  of opForIntPrep: "FORINTPREP"
  of opCmpJmp: "CMPJMP"
  of opCmpJmpInt: "CMPJMPINT"
  of opCmpJmpFloat: "CMPJMPFLOAT"
  of opIncTest: "INCTEST"
  of opLoadAddStore: "LOADADDSTORE"
  of opLoadSubStore: "LOADSUBSTORE"
  of opLoadMulStore: "LOADMULSTORE"
  of opLoadDivStore: "LOADDIVSTORE"
  of opLoadModStore: "LOADMODSTORE"
  of opGetAddSet: "GETADDSET"
  of opGetSubSet: "GETSUBSET"
  of opGetMulSet: "GETMULSET"
  of opGetDivSet: "GETDIVSET"
  of opGetModSet: "GETMODSET"
  of opYield: "YIELD"
  of opSpawn: "SPAWN"
  of opResume: "RESUME"
  of opChannelNew: "CHANNELNEW"
  of opChannelSend: "CHANNELSEND"
  of opChannelRecv: "CHANNELRECV"
  of opChannelClose: "CHANNELCLOSE"
