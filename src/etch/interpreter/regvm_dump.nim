# regvm_dump.nim
# Enhanced bytecode dumping utilities for Register VM programs

import std/[strutils, strformat, tables, sequtils, algorithm]
import regvm

proc alignRight*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = repeat(fillChar, padding) & s

proc alignLeft*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = s & repeat(fillChar, padding)

proc formatInstruction*(instr: RegInstruction): string =
  case instr.opType
  of 0:  # ABC format
    case instr.op
    of ropMove:
      result = &"R[{instr.a}] = R[{instr.b}]"
    of ropAdd:
      result = &"R[{instr.a}] = R[{instr.b}] + R[{instr.c}]"
    of ropSub:
      result = &"R[{instr.a}] = R[{instr.b}] - R[{instr.c}]"
    of ropMul:
      result = &"R[{instr.a}] = R[{instr.b}] * R[{instr.c}]"
    of ropDiv:
      result = &"R[{instr.a}] = R[{instr.b}] / R[{instr.c}]"
    of ropMod:
      result = &"R[{instr.a}] = R[{instr.b}] % R[{instr.c}]"
    of ropPow:
      result = &"R[{instr.a}] = R[{instr.b}] ** R[{instr.c}]"
    of ropUnm:
      result = &"R[{instr.a}] = -R[{instr.b}]"
    of ropEq:
      result = &"if (R[{instr.b}] == R[{instr.c}]) != {instr.a} then skip"
    of ropLt:
      result = &"if (R[{instr.b}] < R[{instr.c}]) != {instr.a} then skip"
    of ropLe:
      result = &"if (R[{instr.b}] <= R[{instr.c}]) != {instr.a} then skip"
    of ropEqStore:
      result = &"R[{instr.a}] = (R[{instr.b}] == R[{instr.c}])"
    of ropLtStore:
      result = &"R[{instr.a}] = (R[{instr.b}] < R[{instr.c}])"
    of ropLeStore:
      result = &"R[{instr.a}] = (R[{instr.b}] <= R[{instr.c}])"
    of ropNeStore:
      result = &"R[{instr.a}] = (R[{instr.b}] != R[{instr.c}])"
    of ropNot:
      result = &"R[{instr.a}] = not R[{instr.b}]"
    of ropAnd:
      result = &"R[{instr.a}] = R[{instr.b}] and R[{instr.c}]"
    of ropOr:
      result = &"R[{instr.a}] = R[{instr.b}] or R[{instr.c}]"
    of ropIn:
      result = &"R[{instr.a}] = R[{instr.b}] in R[{instr.c}]"
    of ropNotIn:
      result = &"R[{instr.a}] = R[{instr.b}] not in R[{instr.c}]"
    of ropGetIndex:
      result = &"R[{instr.a}] = R[{instr.b}][R[{instr.c}]]"
    of ropSetIndex:
      result = &"R[{instr.a}][R[{instr.b}]] = R[{instr.c}]"
    of ropGetField:
      result = &"R[{instr.a}] = R[{instr.b}].field[{instr.c}]"
    of ropSetField:
      result = &"R[{instr.b}].field[{instr.c}] = R[{instr.a}]"
    of ropTest:
      result = &"if R[{instr.a}] != {instr.c} then skip"
    of ropTestSet:
      result = &"if R[{instr.b}] == {instr.c} then R[{instr.a}]=R[{instr.b}] else skip"
    of ropCall:
      result = &"R[{instr.a}] = call functionTable[{instr.funcIdx}]({instr.numArgs} args, {instr.numResults} results)"
    of ropReturn:
      result = &"return R[{instr.a}..{instr.a + instr.b - 2}]"
    of ropLoadBool:
      result = &"R[{instr.a}] = {instr.b != 0}; if {instr.c} skip next"
    of ropLoadNil:
      result = &"R[{instr.a}..{instr.b}] = nil"
    of ropNewArray:
      result = &"R[{instr.a}] = new array[{instr.b}]"
    of ropNewTable:
      result = &"R[{instr.a}] = new table"
    of ropLen:
      result = &"R[{instr.a}] = len(R[{instr.b}])"
    of ropSlice:
      result = &"R[{instr.a}] = R[{instr.b}][R[{instr.c}]:end]"
    of ropWrapSome:
      result = &"R[{instr.a}] = Some(R[{instr.b}])"
    of ropLoadNone:
      result = &"R[{instr.a}] = None"
    of ropWrapOk:
      result = &"R[{instr.a}] = Ok(R[{instr.b}])"
    of ropWrapErr:
      result = &"R[{instr.a}] = Err(R[{instr.b}])"
    of ropTestTag:
      result = &"if R[{instr.a}] not tagged {instr.b} then skip"
    of ropUnwrapOption:
      result = &"R[{instr.a}] = unwrap(Option R[{instr.b}])"
    of ropUnwrapResult:
      result = &"R[{instr.a}] = unwrap(Result R[{instr.b}])"
    of ropCast:
      result = &"R[{instr.a}] = cast(R[{instr.b}], type={instr.c})"
    of ropForPrep:
      result = &"for prep R[{instr.a}]"
    of ropForLoop:
      result = &"for loop R[{instr.a}]"
    of ropIncTest:
      result = &"R[{instr.a}]++; test R[{instr.b}] < R[{instr.c}]"
    else:
      result = &"{instr.op} A={instr.a} B={instr.b} C={instr.c}"

  of 1:  # ABx format
    case instr.op
    of ropLoadK:
      result = &"R[{instr.a}] = K[{instr.bx}]"
    of ropGetGlobal:
      result = &"R[{instr.a}] = Global[K[{instr.bx}]]"
    of ropSetGlobal:
      result = &"Global[K[{instr.bx}]] = R[{instr.a}]"
    of ropJmp:
      let offset = cast[int16](instr.bx)
      let sign = if offset >= 0: "+" else: ""
      result = &"jump {sign}{offset}"
    of ropAddI:
      result = &"R[{instr.a}] = R[{instr.a}] + {instr.bx}"
    of ropSubI:
      result = &"R[{instr.a}] = R[{instr.a}] - {instr.bx}"
    of ropMulI:
      result = &"R[{instr.a}] = R[{instr.a}] * {instr.bx}"
    of ropEqI:
      result = &"if R[{instr.a}] == {instr.bx} then skip"
    of ropLtI:
      result = &"if R[{instr.a}] < {instr.bx} then skip"
    of ropLeI:
      result = &"if R[{instr.a}] <= {instr.bx} then skip"
    of ropGetIndexI:
      result = &"R[{instr.a}] = R[{instr.a}][{instr.bx}]"
    of ropSetIndexI:
      result = &"R[{instr.a}][{instr.bx}] = R[{instr.a}]"
    else:
      result = &"{instr.op} A={instr.a} Bx={instr.bx}"

  of 2:  # AsBx format
    let sbx = cast[int16](instr.sbx) - 32767
    let sign = if sbx >= 0: "+" else: ""
    case instr.op
    of ropJmp:
      result = &"jump {sign}{sbx}"
    of ropCmpJmp:
      result = &"cmp-jump {sign}{sbx}"
    else:
      result = &"{instr.op} A={instr.a} sBx={sbx}"

  else:
    result = &"{instr.op} (unknown format)"

proc dumpConstants*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== CONSTANTS TABLE ==="
  if prog.constants.len == 0:
    echo "  (no constants)"
  else:
    for i, constant in prog.constants:
      let valueStr = case constant.kind
        of vkInt:
          &"{constant.ival}"
        of vkFloat:
          &"{constant.fval}"
        of vkBool:
          if constant.bval: "true" else: "false"
        of vkString:
          &"\"{constant.sval}\""
        of vkNil:
          "nil"
        of vkChar:
          &"'{constant.cval}'"
        of vkSome:
          "Some(...)"
        of vkNone:
          "None"
        of vkOk:
          "Ok(...)"
        of vkErr:
          "Err(...)"
        of vkArray:
          &"[array:{constant.aval.len}]"
        of vkTable:
          &"{{table:{constant.tval.len}}}"
      echo &"  K[{i:3}] = {valueStr}"

proc dumpGlobals*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== GLOBAL VARIABLES ==="
  # Global tracking not implemented in RegBytecodeProgram yet
  echo "  (global tracking not available)"

proc dumpFunctions*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== FUNCTIONS TABLE ==="
  if prog.functions.len == 0:
    echo "  (no functions)"
  else:
    type FuncEntry = tuple[name: string, info: FunctionInfo]
    var funcList: seq[FuncEntry] = @[]
    for name, info in prog.functions:
      funcList.add((name, info))
    funcList.sort(proc(a, b: FuncEntry): int = cmp(a.info.startPos, b.info.startPos))

    for i, funcTuple in funcList:
      let (name, info) = funcTuple
      echo &"  [{i:3}] {name} @ instruction {info.startPos}"
      echo &"       Params: {info.numParams}, Locals: {info.numLocals}"

proc dumpInstructionsSummary*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== INSTRUCTIONS SUMMARY ==="
  var opCounts = initTable[RegOpCode, int]()

  for instr in prog.instructions:
    if opCounts.hasKey(instr.op):
      opCounts[instr.op] += 1
    else:
      opCounts[instr.op] = 1

  var sortedOps: seq[tuple[op: RegOpCode, count: int]] = @[]
  for op, count in opCounts:
    sortedOps.add((op, count))
  sortedOps.sort(proc(a, b: tuple[op: RegOpCode, count: int]): int = cmp(b.count, a.count))

  for (op, count) in sortedOps:
    echo &"  {($op).alignLeft(20)} {count:4} times"

proc dumpInstructionsByFunctions*(prog: RegBytecodeProgram, maxInstructions: int = -1) =
  echo ""
  echo "=== BYTECODE INSTRUCTIONS BY FUNCTION ==="

  # Create a list of functions sorted by their address
  type FuncEntry = tuple[name: string, info: FunctionInfo]
  var funcList: seq[FuncEntry] = @[]
  for name, info in prog.functions:
    funcList.add((name, info))
  funcList.sort(proc(a, b: FuncEntry): int = cmp(a.info.startPos, b.info.startPos))

  let totalInstructions = prog.instructions.len
  let limit = if maxInstructions > 0: min(maxInstructions, totalInstructions) else: totalInstructions

  var currentIdx = 0
  for funcIdx, funcEntry in funcList:
    let (funcName, info) = funcEntry

    # Skip if we've reached the instruction limit
    if currentIdx >= limit:
      break

    # Print function header
    echo ""
    echo &"--- Function: {funcName} (starts at {info.startPos}, {info.numParams} params, {info.numLocals} locals) ---"

    # Determine the end address for this function
    let nextFuncAddress = if funcIdx + 1 < funcList.len:
      funcList[funcIdx + 1].info.startPos
    else:
      totalInstructions

    # Print instructions for this function
    let funcStart = max(info.startPos, currentIdx)
    let funcEnd = min(nextFuncAddress, limit)

    if funcStart < funcEnd:
      for i in funcStart..<funcEnd:
        let instr = prog.instructions[i]
        let indexStr = ($i).alignRight(4)
        let opStr = ($instr.op).alignLeft(16)
        let decoded = formatInstruction(instr)

        # Add constant value if it's a LoadK instruction
        var extra = ""
        if instr.op == ropLoadK and instr.bx < prog.constants.len.uint16:
          let constant = prog.constants[instr.bx]
          extra = case constant.kind
            of vkString: &"  ; \"{constant.sval}\""
            of vkInt: &"  ; {constant.ival}"
            of vkFloat: &"  ; {constant.fval}"
            of vkBool: (if constant.bval: "  ; true" else: "  ; false")
            of vkChar: &"  ; '{constant.cval}'"
            of vkNil: "  ; nil"
            else: ""

        echo &"{indexStr}: {opStr} {decoded}{extra}"

    currentIdx = funcEnd

  # Handle any remaining instructions that don't belong to a function
  if currentIdx < limit:
    echo ""
    echo "--- Instructions outside functions ---"
    for i in currentIdx..<limit:
      let instr = prog.instructions[i]
      let indexStr = ($i).alignRight(4)
      let opStr = ($instr.op).alignLeft(16)
      let decoded = formatInstruction(instr)
      echo &"{indexStr}: {opStr} {decoded}"

  if maxInstructions > 0 and totalInstructions > maxInstructions:
    echo &"... ({totalInstructions - maxInstructions} more instructions)"

proc dumpControlFlow*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== CONTROL FLOW ANALYSIS ==="

  var jumpTargets = initTable[int, seq[int]]()

  for i, instr in prog.instructions:
    case instr.op
    of ropJmp:
      var target: int
      case instr.opType
      of 1:  # ABx format
        target = i + cast[int16](instr.bx) + 1
      of 2:  # AsBx format
        target = i + cast[int16](instr.sbx) - 32767 + 1
      else:
        continue
      if target >= 0 and target < prog.instructions.len:
        if not jumpTargets.hasKey(target):
          jumpTargets[target] = @[]
        jumpTargets[target].add(i)
    of ropTest, ropTestSet:
      # These conditionally skip the next instruction
      let target = i + 2
      if target < prog.instructions.len:
        if not jumpTargets.hasKey(target):
          jumpTargets[target] = @[]
        jumpTargets[target].add(i)
    else:
      discard

  if jumpTargets.len == 0:
    echo "  (no jumps detected)"
  else:
    var targets = toSeq(jumpTargets.keys)
    targets.sort()
    for target in targets:
      let sources = jumpTargets[target]
      echo &"  Instruction {target:3} <- from {sources.join(\", \")}"

proc dumpRegisterUsage*(prog: RegBytecodeProgram) =
  echo ""
  echo "=== REGISTER USAGE ANALYSIS ==="

  var maxRegister = 0
  var registerReads = initTable[int, int]()
  var registerWrites = initTable[int, int]()

  for instr in prog.instructions:
    # Track writes (destination register A)
    let destReg = instr.a.int
    if not registerWrites.hasKey(destReg):
      registerWrites[destReg] = 0
    registerWrites[destReg] += 1
    maxRegister = max(maxRegister, destReg)

    # Track reads based on instruction format
    case instr.opType
    of 0:  # ABC format
      if instr.op notin {ropLoadBool, ropLoadNil, ropNewArray, ropNewTable, ropLoadNone}:
        # Most ABC instructions read from B and/or C
        let srcB = instr.b.int
        let srcC = instr.c.int

        if not registerReads.hasKey(srcB):
          registerReads[srcB] = 0
        registerReads[srcB] += 1
        maxRegister = max(maxRegister, srcB)

        if instr.op in {ropAdd, ropSub, ropMul, ropDiv, ropMod, ropPow,
                        ropEq, ropLt, ropLe, ropAnd, ropOr, ropIn, ropNotIn,
                        ropGetIndex, ropSetIndex}:
          if not registerReads.hasKey(srcC):
            registerReads[srcC] = 0
          registerReads[srcC] += 1
          maxRegister = max(maxRegister, srcC)
    else:
      discard

  echo &"  Maximum register used: R[{maxRegister}]"
  echo &"  Total unique registers: {registerWrites.len}"
  echo ""
  echo "  Most written registers:"
  var writeList: seq[tuple[reg: int, count: int]] = @[]
  for reg, count in registerWrites:
    writeList.add((reg, count))
  writeList.sort(proc(a, b: tuple[reg: int, count: int]): int = cmp(b.count, a.count))
  for i in 0..<min(10, writeList.len):
    echo &"    R[{writeList[i].reg:3}]: {writeList[i].count:4} writes"

proc dumpBytecodeProgram*(prog: RegBytecodeProgram, sourceFile: string = "",
                         showConstants: bool = true, showGlobals: bool = true,
                         showFunctions: bool = true, showSummary: bool = true,
                         showDetailed: bool = true, showControlFlow: bool = true,
                         showRegisterUsage: bool = true, maxInstructions: int = -1) =
  let fileName = if sourceFile.len > 0: sourceFile else: "register_vm_bytecode"
  echo &"=== REGISTER VM BYTECODE DUMP FOR: {fileName} ==="
  echo &"Instructions: {prog.instructions.len}"
  echo &"Constants: {prog.constants.len}"
  echo &"Functions: {prog.functions.len}"

  if showConstants:
    dumpConstants(prog)

  if showGlobals:
    dumpGlobals(prog)

  if showFunctions:
    dumpFunctions(prog)

  if showSummary:
    dumpInstructionsSummary(prog)

  if showControlFlow:
    dumpControlFlow(prog)

  if showRegisterUsage:
    dumpRegisterUsage(prog)

  if showDetailed:
    dumpInstructionsByFunctions(prog, maxInstructions)