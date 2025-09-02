# dumper.nim
# Enhanced bytecode dumping utilities for Register VM programs

import std/[strutils, strformat, tables, sequtils, algorithm]
import ../core/[vm, vm_types]


proc alignRight*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = repeat(fillChar, padding) & s


proc alignLeft*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = s & repeat(fillChar, padding)


proc formatInstruction*(instr: Instruction): string =
  case instr.opType
  of ifmtABC:  # ABC format
    case instr.op
    of opMove:
      result = &"R[{instr.a}] = R[{instr.b}]"
    of opAdd:
      result = &"R[{instr.a}] = R[{instr.b}] + R[{instr.c}]"
    of opSub:
      result = &"R[{instr.a}] = R[{instr.b}] - R[{instr.c}]"
    of opMul:
      result = &"R[{instr.a}] = R[{instr.b}] * R[{instr.c}]"
    of opDiv:
      result = &"R[{instr.a}] = R[{instr.b}] / R[{instr.c}]"
    of opMod:
      result = &"R[{instr.a}] = R[{instr.b}] % R[{instr.c}]"
    of opAddInt:
      result = &"R[{instr.a}] = R[{instr.b}] +_int R[{instr.c}]"
    of opSubInt:
      result = &"R[{instr.a}] = R[{instr.b}] -_int R[{instr.c}]"
    of opMulInt:
      result = &"R[{instr.a}] = R[{instr.b}] *_int R[{instr.c}]"
    of opDivInt:
      result = &"R[{instr.a}] = R[{instr.b}] /_int R[{instr.c}]"
    of opModInt:
      result = &"R[{instr.a}] = R[{instr.b}] %_int R[{instr.c}]"
    of opAddFloat:
      result = &"R[{instr.a}] = R[{instr.b}] +_float R[{instr.c}]"
    of opSubFloat:
      result = &"R[{instr.a}] = R[{instr.b}] -_float R[{instr.c}]"
    of opMulFloat:
      result = &"R[{instr.a}] = R[{instr.b}] *_float R[{instr.c}]"
    of opDivFloat:
      result = &"R[{instr.a}] = R[{instr.b}] /_float R[{instr.c}]"
    of opModFloat:
      result = &"R[{instr.a}] = R[{instr.b}] %_float R[{instr.c}]"
    of opPow:
      result = &"R[{instr.a}] = R[{instr.b}] ** R[{instr.c}]"
    of opUnm:
      result = &"R[{instr.a}] = -R[{instr.b}]"
    of opEq:
      result = &"if (R[{instr.b}] == R[{instr.c}]) != {instr.a} then skip"
    of opLt:
      result = &"if (R[{instr.b}] < R[{instr.c}]) != {instr.a} then skip"
    of opLe:
      result = &"if (R[{instr.b}] <= R[{instr.c}]) != {instr.a} then skip"
    of opLtJmp:
      if instr.opType == ifmtAx:
        let b = uint8((instr.ax shr 16) and 0xFF)
        let c = uint8((instr.ax shr 24) and 0xFF)
        let off = int16(instr.ax and 0xFFFF)
        result = &"if R[{b}] < R[{c}] then jump {off} (branched=" & $(instr.a != 0) & ")"
      else:
        result = &"if R[{instr.b}] < R[{instr.c}] then jump {instr.sbx}"
    of opEqStore:
      result = &"R[{instr.a}] = (R[{instr.b}] == R[{instr.c}])"
    of opLtStore:
      result = &"R[{instr.a}] = (R[{instr.b}] < R[{instr.c}])"
    of opLeStore:
      result = &"R[{instr.a}] = (R[{instr.b}] <= R[{instr.c}])"
    of opNeStore:
      result = &"R[{instr.a}] = (R[{instr.b}] != R[{instr.c}])"
    of opNot:
      result = &"R[{instr.a}] = not R[{instr.b}]"
    of opAnd:
      result = &"R[{instr.a}] = R[{instr.b}] and R[{instr.c}]"
    of opOr:
      result = &"R[{instr.a}] = R[{instr.b}] or R[{instr.c}]"
    of opIn:
      result = &"R[{instr.a}] = R[{instr.b}] in R[{instr.c}]"
    of opNotIn:
      result = &"R[{instr.a}] = R[{instr.b}] not in R[{instr.c}]"
    of opGetIndex:
      result = &"R[{instr.a}] = R[{instr.b}][R[{instr.c}]]"
    of opSetIndex:
      result = &"R[{instr.a}][R[{instr.b}]] = R[{instr.c}]"
    of opGetField:
      result = &"R[{instr.a}] = R[{instr.b}].field[{instr.c}]"
    of opSetField:
      result = &"R[{instr.b}].field[{instr.c}] = R[{instr.a}]"
    of opSetRef:
      result = &"*R[{instr.a}] = R[{instr.b}]"
    of opTest:
      result = &"if R[{instr.a}] != {instr.c} then skip"
    of opTestSet:
      result = &"if R[{instr.b}] == {instr.c} then R[{instr.a}]=R[{instr.b}] else skip"
    of opReturn:
      if instr.a == 0:
        result = &"return nil"
      elif instr.a == 1:
        result = &"return R[{instr.b}]"
      else:
        result = &"return R[{instr.b}..{instr.b + instr.a - 1}]"
    of opLoadBool:
      result = &"R[{instr.a}] = {instr.b != 0}; if {instr.c} skip next"
    of opLoadNil:
      result = &"R[{instr.a}..{instr.b}] = nil"
    of opNewArray:
      result = &"R[{instr.a}] = new array[{instr.b}]"
    of opNewTable:
      result = &"R[{instr.a}] = new table"
    of opLen:
      result = &"R[{instr.a}] = len(R[{instr.b}])"
    of opSlice:
      result = &"R[{instr.a}] = R[{instr.b}][R[{instr.c}]:end]"
    of opWrapSome:
      result = &"R[{instr.a}] = some(R[{instr.b}])"
    of opLoadNone:
      result = &"R[{instr.a}] = none"
    of opWrapOk:
      result = &"R[{instr.a}] = ok(R[{instr.b}])"
    of opWrapErr:
      result = &"R[{instr.a}] = error(R[{instr.b}])"
    of opTestTag:
      result = &"if R[{instr.a}] not tagged {instr.b} then skip"
    of opUnwrapOption:
      result = &"R[{instr.a}] = unwrap(Option R[{instr.b}])"
    of opUnwrapResult:
      result = &"R[{instr.a}] = unwrap(Result R[{instr.b}])"
    of opCast:
      result = &"R[{instr.a}] = cast(R[{instr.b}], type={instr.c})"
    of opForPrep:
      result = &"for prep R[{instr.a}]"
    of opForIntPrep:
      result = &"for prep int R[{instr.a}]"
    of opForIntLoop:
      result = &"for loop int R[{instr.a}]"
    of opForLoop:
      result = &"for loop R[{instr.a}]"
    of opArg:
      result = &"arg += R[{instr.a}]"
    of opIncTest:
      result = &"R[{instr.a}]++; test R[{instr.b}] < R[{instr.c}]"
    of opLoadAddStore:
      result = &"R[{instr.a}].field[K[{instr.c}]] += R[{instr.b}]"
    of opLoadSubStore:
      result = &"R[{instr.a}].field[K[{instr.c}]] -= R[{instr.b}]"
    of opLoadMulStore:
      result = &"R[{instr.a}].field[K[{instr.c}]] *= R[{instr.b}]"
    of opLoadDivStore:
      result = &"R[{instr.a}].field[K[{instr.c}]] /= R[{instr.b}]"
    of opLoadModStore:
      result = &"R[{instr.a}].field[K[{instr.c}]] %= R[{instr.b}]"
    of opGetAddSet:
      result = &"R[{instr.a}][R[{instr.b}]] += R[{instr.c}]"
    of opGetSubSet:
      result = &"R[{instr.a}][R[{instr.b}]] -= R[{instr.c}]"
    of opGetMulSet:
      result = &"R[{instr.a}][R[{instr.b}]] *= R[{instr.c}]"
    of opGetDivSet:
      result = &"R[{instr.a}][R[{instr.b}]] /= R[{instr.c}]"
    of opGetModSet:
      result = &"R[{instr.a}][R[{instr.b}]] %= R[{instr.c}]"
    else:
      result = &"{instr.op} A={instr.a} B={instr.b} C={instr.c}"

  of ifmtABx:  # ABx format
    case instr.op
    of opLoadK:
      result = &"R[{instr.a}] = K[{instr.bx}]"
    of opGetGlobal:
      result = &"R[{instr.a}] = G[K[{instr.bx}]]"
    of opSetGlobal:
      result = &"G[K[{instr.bx}]] = R[{instr.a}]"
    of opJmp:
      let offset = cast[int16](instr.bx)
      let sign = if offset >= 0: "+" else: ""
      result = &"jump {sign}{offset}"
    of opAddI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] + {imm}"
    of opSubI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] - {imm}"
    of opMulI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] * {imm}"
    of opDivI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] / {imm}"
    of opModI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] % {imm}"
    of opAndI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] and {imm}"
    of opOrI:
      let reg = uint8(instr.bx and 0xFF)
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = int(if imm8 < 128: int(imm8) else: int(imm8) - 256)
      result = &"R[{instr.a}] = R[{reg}] or {imm}"
    of opEqI:
      result = &"if R[{instr.a}] == {instr.bx} then skip"
    of opLtI:
      result = &"if R[{instr.a}] < {instr.bx} then skip"
    of opLeI:
      result = &"if R[{instr.a}] <= {instr.bx} then skip"
    of opGetIndexI:
      result = &"R[{instr.a}] = R[{instr.a}][{instr.bx}]"
    of opSetIndexI:
      result = &"R[{instr.a}][{instr.bx}] = R[{instr.a}]"
    of opArgImm:
      result = &"arg += K[{instr.bx}]"
    else:
      result = &"{instr.op} A={instr.a} Bx={instr.bx}"

  of ifmtAx:  # Ax format (fused registers)
    case instr.op
    of opAddAdd:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulAdd:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulAddInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulAddFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubSub:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubSubInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubSubFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulSub:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulSubInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opMulSubFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] * R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubMul:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubMulInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubMulFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}] * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opDivAdd:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] / R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opDivAddInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] / R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opDivAddFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] / R[{uint8((instr.ax shr 8) and 0xFF)}] + R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddSub:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddSubInt:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddSubFloat:
      result = &"R[{instr.a}] = R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}] - R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddMul:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}]) * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddMulInt:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}]) * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opAddMulFloat:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] + R[{uint8((instr.ax shr 8) and 0xFF)}]) * R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubDiv:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}]) / R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubDivInt:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}]) / R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opSubDivFloat:
      result = &"R[{instr.a}] = (R[{uint8(instr.ax and 0xFF)}] - R[{uint8((instr.ax shr 8) and 0xFF)}]) / R[{uint8((instr.ax shr 16) and 0xFF)}]"
    of opCmpJmp:
      let b = uint8(instr.ax and 0xFF)
      let c = uint8((instr.ax shr 8) and 0xFF)
      let off = int16((instr.ax shr 16) and 0xFFFF)
      let cmpStr = case instr.a
        of 0: "=="
        of 1: "!="
        of 2: "<"
        of 3: "<="
        of 4: ">"
        of 5: ">="
        else: "?"
      result = &"if R[{b}] {cmpStr} R[{c}] then jump {off}"
    else:
      result = &"{instr.op} A={instr.a} Ax={instr.ax}"

  of ifmtAsBx:  # AsBx format
    case instr.op
    of opLoadK:
      # opLoadK with AsBx uses immediate value (no biasing)
      result = &"R[{instr.a}] = {instr.sbx}"
    of opJmp:
      # Jump instructions need offset calculation
      let sbx = instr.sbx
      let sign = if sbx >= 0: "+" else: ""
      result = &"jump {sign}{sbx}"
    of opForPrep:
      result = &"for prep R[{instr.a}] sBx={instr.sbx}"
    of opForLoop:
      result = &"for loop R[{instr.a}] sBx={instr.sbx}"
    else:
      result = &"{instr.op} A={instr.a} sBx={instr.sbx}"

  of ifmtCall:
    case instr.op
    of opCall:
      result = &"R[{instr.a}] = call F[{instr.funcIdx}]({instr.numArgs} args, {instr.numResults} results)"
    of opCallBuiltin:
      result = &"R[{instr.a}] = call_builtin#{instr.funcIdx}({instr.numArgs} args)"
    of opCallHost:
      result = &"R[{instr.a}] = call_host F[{instr.funcIdx}]({instr.numArgs} args)"
    of opCallFFI:
      result = &"R[{instr.a}] = call_ffi F[{instr.funcIdx}]({instr.numArgs} args)"
    else:
      result = &"{instr.op} A={instr.a} funcIdx={instr.funcIdx} args={instr.numArgs} results={instr.numResults}"


proc dumpConstants*(prog: BytecodeProgram) =
  echo ""
  echo "=== CONSTANTS TABLE ==="
  if prog.constants.len == 0:
    echo "  (no constants)"
  else:
    for i, constant in prog.constants:
      let valueStr = case constant.kind
        of vkNil:
          "nil"
        of vkBool:
          if constant.bval: "true" else: "false"
        of vkChar:
          &"'{constant.cval}'"
        of vkInt:
          &"{constant.ival}"
        of vkFloat:
          &"{constant.fval}"
        of vkString:
          &"\"{constant.sval}\""
        of vkRef:
          "ref(...)"
        of vkClosure:
          "closure(...)"
        of vkWeak:
          "weak(...)"
        of vkSome:
          "some(...)"
        of vkNone:
          "none"
        of vkOk:
          "ok(...)"
        of vkErr:
          "error(...)"
        of vkArray:
          &"[array:{constant.aval[].len}]"
        of vkTable:
          &"{{table:{constant.tval.len}}}"
        of vkCoroutine:
          &"<coroutine#{constant.coroId}>"
        of vkChannel:
          &"<channel#{constant.chanId}>"
        of vkTypeDesc:
          &"typedesc({constant.typeDescName})"
        of vkEnum:
          &"enum({constant.enumTypeId}, {constant.enumIntVal}, \"{constant.enumStringVal}\")"
      echo &"  K[{i:3}] = {valueStr}"


proc dumpGlobals*(prog: BytecodeProgram) =
  echo ""
  echo "=== GLOBAL VARIABLES ==="
  # Global tracking not implemented in BytecodeProgram yet
  echo "  (global tracking not available)"


proc dumpFunctions*(prog: BytecodeProgram) =
  echo ""
  echo "=== FUNCTIONS TABLE ==="
  if prog.functionTable.len == 0:
    echo "  (no functions)"
  else:
    # Calculate width for index alignment (like R[  4])
    for i, funcName in prog.functionTable:
      let displayName = if prog.functions.hasKey(funcName):
        let info = prog.functions[funcName]
        if info.baseName != "" and info.baseName != funcName:
          &"{funcName} ({info.baseName})"
        else:
          funcName
      else:
        funcName

      echo &"  F[{i:3}] = {displayName}"

      if prog.functions.hasKey(funcName):
        let info = prog.functions[funcName]
        case info.kind
        of fkNative:
          echo &"    @ PC {info.startPos}..{info.endPos}, {info.paramTypes.len} params, returns: {info.returnType}, maxReg: {info.maxRegister}"
        of fkCFFI:
          echo &"    FFI from {info.library} (symbol: {info.symbol}), {info.paramTypes.len} params, returns: {info.returnType}"
        of fkHost:
          echo &"    Host function, {info.paramTypes.len} params, returns: {info.returnType}"
        of fkBuiltin:
          echo &"    Builtin id {info.builtinId}, {info.paramTypes.len} params, returns: {info.returnType}"


proc dumpInstructionsSummary*(prog: BytecodeProgram) =
  echo ""
  echo "=== INSTRUCTIONS SUMMARY ==="
  var opCounts = initTable[OpCode, int]()

  for instr in prog.instructions:
    if opCounts.hasKey(instr.op):
      opCounts[instr.op] += 1
    else:
      opCounts[instr.op] = 1

  var sortedOps: seq[tuple[op: OpCode, count: int]] = @[]
  for op, count in opCounts:
    sortedOps.add((op, count))
  sortedOps.sort(proc(a, b: tuple[op: OpCode, count: int]): int = cmp(b.count, a.count))

  for (op, count) in sortedOps:
    echo &"  {($op).alignLeft(20)} {count:4} times"


proc formatInstructionLine(instr: Instruction, index: int, prog: BytecodeProgram): string =
  ## Format a single instruction line with index, opcode, and decoded instruction
  let indexStr = ($index).alignRight(4)
  let opStr = ($instr.op).alignLeft(16)
  let decoded = formatInstruction(instr)

  # Add constant value if it's a LoadK instruction
  var extra = ""
  if instr.op == opLoadK and instr.opType == ifmtABx and instr.bx < prog.constants.len.uint16:
    let constant = prog.constants[instr.bx]
    extra = case constant.kind
      of vkString: &"  ; \"{constant.sval}\""
      of vkInt: &"  ; {constant.ival}"
      of vkFloat: &"  ; {constant.fval}"
      of vkBool: (if constant.bval: "  ; true" else: "  ; false")
      of vkChar: &"  ; '{constant.cval}'"
      of vkNil: "  ; nil"
      else: ""

  result = &"{indexStr}: {opStr} {decoded}{extra}"


proc calculateMaxLineWidth(instructions: seq[Instruction], startIdx, endIdx: int, prog: BytecodeProgram): int =
  ## Calculate the maximum width of instruction lines for alignment
  result = 0
  for i in startIdx..<endIdx:
    let line = formatInstructionLine(instructions[i], i, prog)
    if line.len > result:
      result = line.len


proc addSourceComment(baseLine: string, instr: Instruction, pc: int,
                      sourceLines: seq[string], maxLineWidth: int,
                      shownLines: var Table[int, bool], prog: BytecodeProgram): string =
  ## Add aligned source code comment to an instruction line
  result = baseLine
  let debug = prog.getDebugInfo(pc)
  if debug.line > 0 and debug.line <= sourceLines.len:
    let lineContent = sourceLines[debug.line - 1].strip()
    if lineContent != "":
      let padding = max(1, maxLineWidth - baseLine.len + 1)
      let padStr = repeat(' ', padding)
      if shownLines.hasKey(debug.line) and shownLines[debug.line]:
        result = &"{baseLine}{padStr}|"
      else:
        shownLines[debug.line] = true
        result = &"{baseLine}{padStr}{lineContent}"


proc dumpInstructionBlock(header: string, instructions: seq[Instruction], startIdx, endIdx: int,
                          prog: BytecodeProgram, sourceLines: seq[string]) =
  ## Dump a block of instructions with proper formatting and source line comments
  if startIdx >= endIdx:
    return

  echo ""
  echo header

  # Calculate maximum line width for alignment
  let maxLineWidth = calculateMaxLineWidth(instructions, startIdx, endIdx, prog)

  # Track which source lines have been shown to avoid repetition
  var shownLines = initTable[int, bool]()

  # Print instructions with aligned comments
  for i in startIdx..<endIdx:
    let instr = instructions[i]
    let baseLine = formatInstructionLine(instr, i, prog)
    let finalLine = addSourceComment(baseLine, instr, i, sourceLines, maxLineWidth, shownLines, prog)
    echo finalLine


proc dumpInstructionsByFunctions*(prog: BytecodeProgram, sourceFile: string = "", maxInstructions: int = -1) =
  echo ""
  echo "=== BYTECODE INSTRUCTIONS BY FUNCTION ==="

  # Read source file lines if debug information is available
  var sourceLines: seq[string] = @[]
  if sourceFile != "":
    try:
      sourceLines = sourceFile.readFile().splitLines()
    except:
      sourceLines = @[]  # If file can't be read, proceed without source lines

  # Create a list of native functions only (those with actual bytecode), sorted by their address
  type FuncEntry = tuple[name: string, info: FunctionInfo]
  var funcList: seq[FuncEntry] = @[]
  for name, info in prog.functions:
    if info.kind == fkNative:  # Only include native functions with actual bytecode
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

    # Determine the end address for this function
    let nextFuncAddress = if funcIdx + 1 < funcList.len:
      funcList[funcIdx + 1].info.startPos
    else:
      totalInstructions

    # Print instructions for this function
    let funcStart = max(info.startPos, currentIdx)
    let funcEnd = min(nextFuncAddress, limit)

    if funcStart < funcEnd:
      let header = &"--- Function: {funcName} (starts at {info.startPos}, {info.paramTypes.len} params, {info.maxRegister} max regs) ---"
      dumpInstructionBlock(header, prog.instructions, funcStart, funcEnd, prog, sourceLines)

    currentIdx = funcEnd

  # Handle any remaining instructions that don't belong to a function
  if currentIdx < limit:
    dumpInstructionBlock("--- Instructions outside functions ---", prog.instructions, currentIdx, limit, prog, sourceLines)

  if maxInstructions > 0 and totalInstructions > maxInstructions:
    echo &"... ({totalInstructions - maxInstructions} more instructions)"


proc dumpControlFlow*(prog: BytecodeProgram) =
  echo ""
  echo "=== CONTROL FLOW ANALYSIS ==="

  var jumpTargets = initTable[int, seq[int]]()

  for i, instr in prog.instructions:
    case instr.op
    of opJmp:
      var target: int
      case instr.opType
      of ifmtABx:  # ABx format
        target = i + cast[int16](instr.bx) + 1
      of ifmtAsBx:  # AsBx format
        target = i + cast[int16](instr.sbx) - 32767 + 1
      else:
        continue
      if target >= 0 and target < prog.instructions.len:
        if not jumpTargets.hasKey(target):
          jumpTargets[target] = @[]
        jumpTargets[target].add(i)
    of opTest, opTestSet:
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
      let sources = jumpTargets[target].join(", ")
      echo &"  Instruction {target:3} <- from {sources}"


proc dumpRegisterUsage*(prog: BytecodeProgram) =
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
    of ifmtABC:  # ABC format
      if instr.op notin {opLoadBool, opLoadNil, opNewArray, opNewTable, opLoadNone}:
        # Most ABC instructions read from B and/or C
        let srcB = instr.b.int
        let srcC = instr.c.int

        if not registerReads.hasKey(srcB):
          registerReads[srcB] = 0
        registerReads[srcB] += 1
        maxRegister = max(maxRegister, srcB)

        if instr.op in {opAdd, opSub, opMul, opDiv, opMod, opPow,
                        opEq, opLt, opLe, opAnd, opOr, opIn, opNotIn,
                        opGetIndex, opSetIndex}:
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


proc dumpBytecodeProgram*(prog: BytecodeProgram,
                          sourceFile: string = "",
                          showConstants: bool = true,
                          showGlobals: bool = true,
                          showFunctions: bool = true,
                          showSummary: bool = true,
                          showDetailed: bool = true,
                          showControlFlow: bool = true,
                          showRegisterUsage: bool = true,
                          maxInstructions: int = -1) =
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
    dumpInstructionsByFunctions(prog, sourceFile, maxInstructions)
