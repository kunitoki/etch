# regvm_exec.nim
# Execution engine for register-based VM with aggressive optimizations

import std/[tables, math, strutils]
import regvm

# C rand for consistency
proc c_rand(): cint {.importc: "rand", header: "<stdlib.h>".}
proc c_srand(seed: cuint) {.importc: "srand", header: "<stdlib.h>".}

# Create new VM instance
proc newRegisterVM*(prog: RegBytecodeProgram): RegisterVM =
  result = RegisterVM(
    frames: @[RegisterFrame()],
    program: prog,
    constants: prog.constants,
    globals: initTable[string, V]()
  )
  result.currentFrame = addr result.frames[0]

# Fast register access macros
template getReg(vm: RegisterVM, idx: uint8): V =
  vm.currentFrame.regs[idx]

template setReg(vm: RegisterVM, idx: uint8, val: V) =
  vm.currentFrame.regs[idx] = val

template getConst(vm: RegisterVM, idx: uint16): V =
  vm.constants[idx]

# Optimized arithmetic operations with type specialization
proc doAdd(a, b: V): V {.inline.} =
  if isInt(a) and isInt(b):
    makeInt(getInt(a) + getInt(b))
  elif isFloat(a) and isFloat(b):
    makeFloat(getFloat(a) + getFloat(b))
  elif getTag(a) == TAG_STRING and getTag(b) == TAG_STRING:
    # String concatenation
    var result: V
    result.data = TAG_STRING shl 48
    result.sval = a.sval & b.sval
    result
  elif getTag(a) == TAG_ARRAY and getTag(b) == TAG_ARRAY:
    # Array concatenation
    var result: V
    result.data = TAG_ARRAY shl 48
    result.aval = a.aval & b.aval
    result
  else:
    makeNil()  # Type error

proc doSub(a, b: V): V {.inline.} =
  if isInt(a) and isInt(b):
    makeInt(getInt(a) - getInt(b))
  elif isFloat(a) and isFloat(b):
    makeFloat(getFloat(a) - getFloat(b))
  else:
    makeNil()

proc doMul(a, b: V): V {.inline.} =
  if isInt(a) and isInt(b):
    makeInt(getInt(a) * getInt(b))
  elif isFloat(a) and isFloat(b):
    makeFloat(getFloat(a) * getFloat(b))
  else:
    makeNil()

proc doDiv(a, b: V): V {.inline.} =
  if isInt(a) and isInt(b):
    makeInt(getInt(a) div getInt(b))
  elif isFloat(a) and isFloat(b):
    makeFloat(getFloat(a) / getFloat(b))
  else:
    makeNil()

proc doMod(a, b: V): V {.inline.} =
  if isInt(a) and isInt(b):
    makeInt(getInt(a) mod getInt(b))
  else:
    makeNil()

proc doLt(a, b: V): bool {.inline.} =
  if isInt(a) and isInt(b):
    getInt(a) < getInt(b)
  elif isFloat(a) and isFloat(b):
    getFloat(a) < getFloat(b)
  elif getTag(a) == TAG_CHAR and getTag(b) == TAG_CHAR:
    getChar(a) < getChar(b)
  elif getTag(a) == TAG_STRING and getTag(b) == TAG_STRING:
    a.sval < b.sval
  else:
    false

proc doLe(a, b: V): bool {.inline.} =
  if isInt(a) and isInt(b):
    getInt(a) <= getInt(b)
  elif isFloat(a) and isFloat(b):
    getFloat(a) <= getFloat(b)
  elif getTag(a) == TAG_CHAR and getTag(b) == TAG_CHAR:
    getChar(a) <= getChar(b)
  elif getTag(a) == TAG_STRING and getTag(b) == TAG_STRING:
    a.sval <= b.sval
  else:
    false

proc doEq(a, b: V): bool {.inline.} =
  if isInt(a) and isInt(b):
    getInt(a) == getInt(b)
  elif isFloat(a) and isFloat(b):
    getFloat(a) == getFloat(b)
  elif getTag(a) == TAG_BOOL and getTag(b) == TAG_BOOL:
    a.data == b.data
  elif getTag(a) == TAG_CHAR and getTag(b) == TAG_CHAR:
    getChar(a) == getChar(b)
  elif getTag(a) == TAG_STRING and getTag(b) == TAG_STRING:
    a.sval == b.sval
  elif getTag(a) == TAG_NIL and getTag(b) == TAG_NIL:
    true
  else:
    false

# Main execution loop - highly optimized with computed goto if available
proc execute*(vm: RegisterVM, verbose: bool = false): int =
  var pc = vm.program.entryPoint
  let instructions = vm.program.instructions
  let maxInstr = instructions.len

  # Output buffer for print statements - significantly improves performance
  var outputBuffer: string = ""
  var outputCount = 0
  const BUFFER_SIZE = 8192  # Flush every 8KB or 100 lines

  template flushOutput() =
    if outputBuffer.len > 0:
      stdout.write(outputBuffer)
      outputBuffer.setLen(0)
      outputCount = 0

  # Main dispatch loop - unrolled for common instructions
  while pc < maxInstr:
    let instr = instructions[pc]

    when defined(debugRegVM):
      echo "[", pc, "] ", instr.op, " a=", instr.a,
           (if instr.opType == 0: " b=" & $instr.b & " c=" & $instr.c
            elif instr.opType == 1: " bx=" & $instr.bx
            elif instr.opType == 2: " sbx=" & $instr.sbx
            else: " ax=" & $instr.ax)

    if verbose and pc >= 4:  # Only log main function instructions
      echo "[REGVM] PC=", pc, " op=", instr.op

    inc pc

    # Use computed goto table for maximum performance
    # (Nim doesn't support computed goto, so we use case)
    case instr.op:

    # --- Move and Load Instructions ---
    of ropMove:
      setReg(vm, instr.a, getReg(vm, instr.b))

    of ropLoadK:
      # Handle both ABx (constant pool) and AsBx (immediate) formats
      if instr.opType == 1:  # ABx format - load from constant pool
        if verbose:
          echo "[REGVM] ropLoadK: loading const[", instr.bx, "] to reg ", instr.a
        setReg(vm, instr.a, getConst(vm, instr.bx))
      elif instr.opType == 2:  # AsBx format - immediate integer
        if verbose:
          echo "[REGVM] ropLoadK: loading immediate ", instr.sbx, " to reg ", instr.a
        setReg(vm, instr.a, makeInt(int64(instr.sbx)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropLoadBool:
      setReg(vm, instr.a, makeBool(instr.b != 0))
      if instr.c != 0:
        inc pc  # Skip next instruction

    of ropLoadNil:
      if verbose:
        echo "[REGVM] ropLoadNil: setting reg", instr.a, "..", instr.b, " to nil"
      for i in instr.a..instr.b:
        setReg(vm, i, makeNil())

    # --- Global Access ---
    of ropGetGlobal:
      if instr.opType == 1 and int(instr.bx) < vm.constants.len:
        let name = vm.constants[instr.bx].sval
        if vm.globals.hasKey(name):
          setReg(vm, instr.a, vm.globals[name])
        else:
          setReg(vm, instr.a, makeNil())
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetGlobal:
      if instr.opType == 1 and int(instr.bx) < vm.constants.len:
        let name = vm.constants[instr.bx].sval
        vm.globals[name] = getReg(vm, instr.a)

    # --- Arithmetic Operations ---
    of ropAdd:
      setReg(vm, instr.a, doAdd(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropSub:
      setReg(vm, instr.a, doSub(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropMul:
      setReg(vm, instr.a, doMul(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropDiv:
      setReg(vm, instr.a, doDiv(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropMod:
      setReg(vm, instr.a, doMod(getReg(vm, instr.b), getReg(vm, instr.c)))

    of ropPow:
      let base = getReg(vm, instr.b)
      let exp = getReg(vm, instr.c)
      if isFloat(base) and isFloat(exp):
        setReg(vm, instr.a, makeFloat(pow(getFloat(base), getFloat(exp))))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Immediate Arithmetic (Optimized) ---
    of ropAddI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) + imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSubI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) - imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropMulI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        setReg(vm, instr.a, makeInt(getInt(reg) * imm))
      else:
        setReg(vm, instr.a, makeNil())

    of ropUnm:
      let val = getReg(vm, instr.b)
      if isInt(val):
        setReg(vm, instr.a, makeInt(-getInt(val)))
      elif isFloat(val):
        setReg(vm, instr.a, makeFloat(-getFloat(val)))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Comparisons ---
    of ropEq:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let isEqual = doEq(b, c)
      let skipIfNot = instr.a != 0
      if verbose:
        echo "[REGVM] ropEq: reg", instr.b, "=", b.data.toHex, " reg", instr.c, "=", c.data.toHex,
             " equal=", isEqual, " skipIfNot=", skipIfNot, " willSkip=", (isEqual != skipIfNot)
      if isEqual != skipIfNot:
        inc pc  # Skip next instruction

    of ropLt:
      if doLt(getReg(vm, instr.b), getReg(vm, instr.c)) != (instr.a != 0):
        inc pc

    of ropLe:
      if doLe(getReg(vm, instr.b), getReg(vm, instr.c)) != (instr.a != 0):
        inc pc

    # --- Immediate Comparisons (Optimized) ---
    of ropEqI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) == imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    of ropLtI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) < imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    of ropLeI:
      let reg = getReg(vm, uint8(instr.bx and 0xFF))
      let imm = int64(int8(instr.bx shr 8))
      if isInt(reg):
        if (getInt(reg) <= imm) != (instr.a != 0):
          inc pc
      else:
        inc pc

    # --- Store comparison results in registers ---
    of ropEqStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      setReg(vm, instr.a, makeBool(doEq(b, c)))

    of ropNeStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      setReg(vm, instr.a, makeBool(not doEq(b, c)))

    of ropLtStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let result = makeBool(doLt(b, c))
      if verbose:
        echo "[REGVM] ropLtStore: reg", instr.a, " = reg", instr.b, "(", $b, ") < reg", instr.c, "(", $c, ") = ", $result
      setReg(vm, instr.a, result)

    of ropLeStore:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      let result = makeBool(doLe(b, c))
      if verbose:
        echo "[REGVM] ropLeStore: reg", instr.a, " = reg", instr.b, "(", $b, ") <= reg", instr.c, "(", $c, ") = ", $result
      setReg(vm, instr.a, result)

    # --- Logical Operations ---
    of ropNot:
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeBool(getTag(val) == TAG_NIL or
                                    (getTag(val) == TAG_BOOL and (val.data and 1) == 0)))

    of ropAnd:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      if verbose:
        echo "[REGVM] ropAnd: reg", instr.b, " tag=", getTag(b), " data=", b.data,
             " AND reg", instr.c, " tag=", getTag(c), " data=", c.data
      # Both values should be booleans - perform logical AND
      if getTag(b) == TAG_BOOL and getTag(c) == TAG_BOOL:
        let bVal = (b.data and 1) != 0
        let cVal = (c.data and 1) != 0
        setReg(vm, instr.a, makeBool(bVal and cVal))
        if verbose:
          echo "[REGVM] ropAnd: ", bVal, " AND ", cVal, " = ", bVal and cVal
      else:
        # Fallback to old behavior for non-boolean values
        if getTag(b) == TAG_NIL or (getTag(b) == TAG_BOOL and (b.data and 1) == 0):
          setReg(vm, instr.a, b)
        else:
          setReg(vm, instr.a, c)

    of ropOr:
      let b = getReg(vm, instr.b)
      let c = getReg(vm, instr.c)
      if getTag(b) != TAG_NIL and not (getTag(b) == TAG_BOOL and (b.data and 1) == 0):
        setReg(vm, instr.a, b)
      else:
        setReg(vm, instr.a, c)

    # --- Type conversions ---
    of ropCast:
      let val = getReg(vm, instr.b)
      let castType = instr.c
      var result: V

      case castType:
      of 1:  # To int
        if isInt(val):
          result = val
        elif isFloat(val):
          result = makeInt(int64(getFloat(val)))
        elif isString(val):
          # Try to parse string to int
          try:
            result = makeInt(int64(parseInt(val.sval)))
          except:
            result = makeNil()
        else:
          result = makeNil()

      of 2:  # To float
        if isFloat(val):
          result = val
        elif isInt(val):
          result = makeFloat(float64(getInt(val)))
        elif isString(val):
          # Try to parse string to float
          try:
            result = makeFloat(parseFloat(val.sval))
          except:
            result = makeNil()
        else:
          result = makeNil()

      of 3:  # To string
        if isInt(val):
          result = makeString($getInt(val))
        elif isFloat(val):
          result = makeString($getFloat(val))
        elif isString(val):
          result = val
        elif isBool(val):
          result = makeString(if getBool(val): "true" else: "false")
        elif isNil(val):
          result = makeString("nil")
        else:
          result = makeString("")

      else:
        result = makeNil()

      setReg(vm, instr.a, result)

    # --- Option/Result handling ---
    of ropWrapSome:
      # Wrap value as Some
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeSome(val))

    of ropLoadNone:
      # Load None value
      setReg(vm, instr.a, makeNone())

    of ropWrapOk:
      # Wrap value as Ok
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeOk(val))

    of ropWrapErr:
      # Wrap value as Err
      let val = getReg(vm, instr.b)
      setReg(vm, instr.a, makeErr(val))

    of ropTestTag:
      # Test if register has specific tag
      # Skip next instruction if tags MATCH (for match expressions)
      let val = getReg(vm, instr.a)
      let expectedTag = instr.b.uint64
      let actualTag = getTag(val)
      if verbose:
        echo "[REGVM] ropTestTag: reg=", instr.a, " expected=", expectedTag, " actual=", actualTag, " match=", actualTag == expectedTag
      if actualTag == expectedTag:
        if verbose:
          echo "[REGVM] ropTestTag: tags match, skipping next instruction (PC ", pc, " -> ", pc + 1, ")"
        inc pc  # Skip next instruction if tags match

    of ropUnwrapOption:
      # Unwrap Option value
      let val = getReg(vm, instr.b)
      if isSome(val):
        let unwrapped = unwrapOption(val)
        setReg(vm, instr.a, unwrapped)
        if verbose:
          echo "[REGVM] ropUnwrapOption: unwrapped Some value to reg ", instr.a, " value: ",
            if isInt(unwrapped): $getInt(unwrapped)
            elif isFloat(unwrapped): $getFloat(unwrapped)
            elif isString(unwrapped): unwrapped.sval
            else: "unknown"
      else:
        setReg(vm, instr.a, makeNil())
        if verbose:
          echo "[REGVM] ropUnwrapOption: value was None, set nil in reg ", instr.a

    of ropUnwrapResult:
      # Unwrap Result value
      let val = getReg(vm, instr.b)
      if isOk(val) or isErr(val):
        setReg(vm, instr.a, unwrapResult(val))
      else:
        setReg(vm, instr.a, makeNil())

    # --- Arrays ---
    of ropNewArray:
      var arr = V(data: TAG_ARRAY shl 48)
      arr.aval = newSeqOfCap[V](instr.bx)  # ABx format: use bx not b
      setReg(vm, instr.a, arr)

    of ropGetIndex:
      let arr = getReg(vm, instr.b)
      let idx = getReg(vm, instr.c)
      if getTag(arr) == TAG_ARRAY and isInt(idx):
        let i = getInt(idx)
        if i >= 0 and i < arr.aval.len:
          setReg(vm, instr.a, arr.aval[i])
        else:
          setReg(vm, instr.a, makeNil())
      elif getTag(arr) == TAG_STRING and isInt(idx):
        # String indexing - return single character as char
        let i = getInt(idx)
        if i >= 0 and i < arr.sval.len:
          setReg(vm, instr.a, makeChar(arr.sval[i]))
        else:
          setReg(vm, instr.a, makeNil())
      else:
        setReg(vm, instr.a, makeNil())

    of ropSlice:
      # R[A] = R[B][R[C]:R[D]] where B is array/string, C is start, D is end
      # Since we only have 3 operands in ABC format, we need to handle this specially
      # We'll use a trick: D comes from the next register after C
      let arr = getReg(vm, instr.b)
      let startVal = getReg(vm, instr.c)
      let endVal = getReg(vm, instr.c + 1)  # End index is in the next register

      # Convert indices to integers, handling defaults
      let startIdx = if isInt(startVal): getInt(startVal) else: 0

      if getTag(arr) == TAG_STRING:
        let endIdx = if isInt(endVal):
          let val = getInt(endVal)
          if val < 0: arr.sval.len else: int(val)  # -1 means "until end"
        else: arr.sval.len
        let actualStart = max(0, min(int(startIdx), arr.sval.len))
        let actualEnd = max(actualStart, min(int(endIdx), arr.sval.len))

        if actualStart >= actualEnd:
          var result: V
          result.data = TAG_STRING shl 48
          result.sval = ""
          setReg(vm, instr.a, result)
        else:
          var result: V
          result.data = TAG_STRING shl 48
          result.sval = arr.sval[actualStart..<actualEnd]
          setReg(vm, instr.a, result)
      elif getTag(arr) == TAG_ARRAY:
        let endIdx = if isInt(endVal):
          let val = getInt(endVal)
          if val < 0: arr.aval.len else: int(val)  # -1 means "until end"
        else: arr.aval.len
        let actualStart = max(0, min(int(startIdx), arr.aval.len))
        let actualEnd = max(actualStart, min(int(endIdx), arr.aval.len))

        if actualStart >= actualEnd:
          var result: V
          result.data = TAG_ARRAY shl 48
          result.aval = @[]
          setReg(vm, instr.a, result)
        else:
          var result: V
          result.data = TAG_ARRAY shl 48
          result.aval = arr.aval[actualStart..<actualEnd]
          setReg(vm, instr.a, result)
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndex:
      var arr = getReg(vm, instr.a)
      let idx = getReg(vm, instr.b)
      let val = getReg(vm, instr.c)
      if getTag(arr) == TAG_ARRAY and isInt(idx):
        let i = getInt(idx)
        if i >= 0:
          if i >= arr.aval.len:
            arr.aval.setLen(i + 1)
          arr.aval[i] = val
          setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropGetIndexI:
      let arr = getReg(vm, uint8(instr.bx and 0xFF))
      let idx = int(instr.bx shr 8)
      if getTag(arr) == TAG_ARRAY and idx < arr.aval.len:
        setReg(vm, instr.a, arr.aval[idx])
      elif getTag(arr) == TAG_STRING and idx < arr.sval.len:
        setReg(vm, instr.a, makeChar(arr.sval[idx]))
      else:
        setReg(vm, instr.a, makeNil())

    of ropSetIndexI:
      var arr = getReg(vm, instr.a)
      let idx = int(instr.bx and 0xFF)
      let val = getReg(vm, uint8(instr.bx shr 8))
      if getTag(arr) == TAG_ARRAY:
        if idx >= arr.aval.len:
          arr.aval.setLen(idx + 1)
        arr.aval[idx] = val
        setReg(vm, instr.a, arr)  # Important: write back the updated array

    of ropLen:
      let val = getReg(vm, instr.b)
      if verbose:
        echo "[REGVM] ropLen: getting length of reg", instr.b, " tag=", getTag(val),
             " (", if getTag(val) == TAG_ARRAY: "Array"
                   elif getTag(val) == TAG_STRING: "String"
                   else: "Other", ")"
      if getTag(val) == TAG_ARRAY:
        let lenVal = makeInt(int64(val.aval.len))
        if verbose:
          echo "[REGVM] ropLen: array length = ", val.aval.len, " -> reg", instr.a
        setReg(vm, instr.a, lenVal)
      elif getTag(val) == TAG_STRING:
        let lenVal = makeInt(int64(val.sval.len))
        if verbose:
          echo "[REGVM] ropLen: string length = ", val.sval.len, " -> reg", instr.a
        setReg(vm, instr.a, lenVal)
      else:
        if verbose:
          echo "[REGVM] ropLen: not array/string, setting 0 -> reg", instr.a
        setReg(vm, instr.a, makeInt(0))

    # --- Objects/Tables ---
    of ropNewTable:
      # Create a new empty table
      setReg(vm, instr.a, makeTable())
      if verbose:
        echo "[REGVM] ropNewTable: created new table in reg ", instr.a

    of ropGetField:
      # Get field from table: R[A] = R[B][K[C]]
      let table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        if table.tval.hasKey(fieldName):
          setReg(vm, instr.a, table.tval[fieldName])
        else:
          setReg(vm, instr.a, makeNil())
          if verbose:
            echo "[REGVM] ropGetField: field '", fieldName, "' not found in table"
      else:
        setReg(vm, instr.a, makeNil())
        if verbose:
          echo "[REGVM] ropGetField: ERROR - reg ", instr.b, " is not a table"

    of ropSetField:
      # Set field in table: R[B][K[C]] = R[A]
      var table = getReg(vm, instr.b)
      if isTable(table):
        let fieldName = vm.constants[instr.c].sval
        let value = getReg(vm, instr.a)
        table.tval[fieldName] = value
        setReg(vm, instr.b, table)
        if verbose:
          echo "[REGVM] ropSetField: set field '", fieldName, "' in table"
      else:
        if verbose:
          echo "[REGVM] ropSetField: ERROR - reg ", instr.b, " is not a table"

    # --- Control Flow ---
    of ropJmp:
      pc += int(instr.sbx)

    of ropTest:
      let val = getReg(vm, instr.a)
      let isTrue = getTag(val) != TAG_NIL and
                    not (getTag(val) == TAG_BOOL and (val.data and 1) == 0)
      if verbose:
        echo "[REGVM] ropTest: reg", instr.a, " val=", $val, " isTrue=", isTrue, " expected=", instr.c != 0, " skip=", isTrue != (instr.c != 0)
      if isTrue != (instr.c != 0):
        inc pc

    of ropTestSet:
      let val = getReg(vm, instr.b)
      let isTrue = getTag(val) != TAG_NIL and
                    not (getTag(val) == TAG_BOOL and (val.data and 1) == 0)
      if isTrue == (instr.c != 0):
        setReg(vm, instr.a, val)
      else:
        inc pc

    # --- Loops (Optimized) ---
    of ropForLoop:
      # Increment loop variable and test
      let idx = getReg(vm, instr.a)
      let limit = getReg(vm, instr.a + 1)
      let step = getReg(vm, instr.a + 2)

      # Debug output
      when defined(debugRegVM):
        echo "ForLoop: idx=", (if isInt(idx): $getInt(idx) else: "nil/non-int"),
             " limit=", (if isInt(limit): $getInt(limit) else: "nil/non-int"),
             " step=", (if isInt(step): $getInt(step) else: "nil/non-int"),
             " sbx=", instr.sbx
        echo "  -> reg[", instr.a, "] type tag = ", getTag(idx)
        echo "  -> reg[", instr.a+1, "] type tag = ", getTag(limit)
        echo "  -> reg[", instr.a+2, "] type tag = ", getTag(step)

      if isInt(idx) and isInt(limit) and isInt(step):
        let newIdx = getInt(idx) + getInt(step)
        setReg(vm, instr.a, makeInt(newIdx))

        if getInt(step) > 0:
          if newIdx < getInt(limit):  # Changed from <= to < for exclusive end
            pc += int(instr.sbx)  # Continue loop
        else:
          if newIdx > getInt(limit):  # Changed from >= to > for backward loops
            pc += int(instr.sbx)  # Continue loop

    of ropForPrep:
      # Prepare for loop - adjust initial value and check if loop should run
      let idx = getReg(vm, instr.a)
      let limit = getReg(vm, instr.a + 1)
      let step = getReg(vm, instr.a + 2)

      # Debug output
      when defined(debugRegVM):
        echo "ForPrep: idx=", (if isInt(idx): $getInt(idx) else: "?"),
             " limit=", (if isInt(limit): $getInt(limit) else: "?"),
             " step=", (if isInt(step): $getInt(step) else: "?"),
             " sbx=", instr.sbx

      if isInt(idx) and isInt(limit) and isInt(step):
        # Check if loop should run at all based on initial values
        let stepVal = getInt(step)
        let idxVal = getInt(idx)
        let limitVal = getInt(limit)

        when defined(debugRegVM):
          echo "  -> Initial idx=", idxVal, " limit=", limitVal, " step=", stepVal

        if stepVal > 0:
          if idxVal >= limitVal:
            # Skip loop entirely (e.g., for i in 5..<5)
            pc += int(instr.sbx)
        else:
          if idxVal <= limitVal:
            # Skip loop entirely (backward loop)
            pc += int(instr.sbx)
        # Otherwise continue to loop body

    # --- Function Calls ---
    of ropCall:
      let funcReg = instr.a
      let numArgs = instr.b
      let numResults = instr.c

      # Get function name from the register
      let funcNameVal = getReg(vm, funcReg)
      if verbose:
        echo "[REGVM] ropCall: funcReg=", funcReg, " numArgs=", numArgs
        if getTag(funcNameVal) == TAG_STRING:
          echo "[REGVM] ropCall: funcName='", funcNameVal.sval, "'"
        else:
          echo "[REGVM] ropCall: ERROR - funcReg doesn't contain a string!"
      if getTag(funcNameVal) != TAG_STRING:
        # Not a valid function name
        setReg(vm, funcReg, makeNil())
        continue

      let funcName = funcNameVal.sval

      # Check for C FFI functions first
      if vm.program.cffiInfo.hasKey(funcName):
        let cffiInfo = vm.program.cffiInfo[funcName]
        if verbose:
          echo "[REGVM] Calling C FFI function: ", funcName, " (", cffiInfo.baseName, ")"

        # Handle specific C FFI functions
        # This is a simplified implementation - a full implementation would use dlopen/dlsym
        case cffiInfo.baseName:
        of "sin":
          if numArgs == 1:
            let val = getReg(vm, funcReg + 1)
            if isFloat(val):
              setReg(vm, funcReg, makeFloat(sin(getFloat(val))))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        of "cos":
          if numArgs == 1:
            let val = getReg(vm, funcReg + 1)
            if isFloat(val):
              setReg(vm, funcReg, makeFloat(cos(getFloat(val))))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        of "sqrt":
          if numArgs == 1:
            let val = getReg(vm, funcReg + 1)
            if isFloat(val):
              setReg(vm, funcReg, makeFloat(sqrt(getFloat(val))))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        of "pow":
          if numArgs == 2:
            let base = getReg(vm, funcReg + 1)
            let exp = getReg(vm, funcReg + 2)
            if isFloat(base) and isFloat(exp):
              setReg(vm, funcReg, makeFloat(pow(getFloat(base), getFloat(exp))))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        of "c_add":
          if numArgs == 2:
            let a = getReg(vm, funcReg + 1)
            let b = getReg(vm, funcReg + 2)
            if isInt(a) and isInt(b):
              setReg(vm, funcReg, makeInt(getInt(a) + getInt(b)))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        of "c_multiply":
          if numArgs == 2:
            let a = getReg(vm, funcReg + 1)
            let b = getReg(vm, funcReg + 2)
            if isInt(a) and isInt(b):
              setReg(vm, funcReg, makeInt(getInt(a) * getInt(b)))
            else:
              setReg(vm, funcReg, makeNil())
          else:
            setReg(vm, funcReg, makeNil())

        else:
          if verbose:
            echo "[REGVM] Unimplemented C FFI function: ", cffiInfo.baseName
          setReg(vm, funcReg, makeNil())

        continue

      # Check for user-defined functions
      elif vm.program.functions.hasKey(funcName):
        let funcInfo = vm.program.functions[funcName]

        if verbose:
          echo "[REGVM] Calling user function ", funcName, " at ", funcInfo.startPos, " with ", numArgs, " args, result reg=", funcReg

        # Create new frame for the function
        var newFrame = RegisterFrame()
        newFrame.returnAddr = pc + 1  # Save position AFTER this call instruction
        newFrame.baseReg = funcReg     # Save result register

        # Copy arguments to new frame's registers starting at R0
        for i in 0'u8..<numArgs:
          let argVal = getReg(vm, funcReg + 1'u8 + i)
          newFrame.regs[i] = argVal
          if verbose:
            echo "[REGVM] Copying arg ", i, " from reg ", funcReg + 1'u8 + i, " to new frame reg ", i,
                 " tag=", getTag(argVal),
                 if getTag(argVal) == TAG_ARRAY: " (Array len=" & $argVal.aval.len & ")"
                 elif getTag(argVal) == TAG_INT: " (Int=" & $getInt(argVal) & ")"
                 else: ""

        # Push frame
        vm.frames.add(newFrame)
        vm.currentFrame = addr vm.frames[^1]

        # Jump to function
        pc = funcInfo.startPos
        continue

      # Handle builtin functions inline for performance
      # For builtin and C FFI functions, we need to handle both the mangled
      # names (with type info) and base names for compatibility
      case funcName:
      of "seed":
        if numArgs == 1:
          let seedVal = getReg(vm, funcReg + 1)
          if isInt(seedVal):
            c_srand(cuint(getInt(seedVal)))
          setReg(vm, funcReg, makeNil())

      of "rand":
        if numArgs == 1:
          # Single argument: rand(max) means rand from 0 to max
          let maxVal = getReg(vm, funcReg + 1)
          if isInt(maxVal):
            let maxInt = getInt(maxVal)
            if maxInt > 0:
              let randVal = c_rand() mod cint(maxInt)
              setReg(vm, funcReg, makeInt(int64(randVal)))
            else:
              setReg(vm, funcReg, makeInt(0))
        elif numArgs == 2:
          # Arguments: rand(max, min) in Etch becomes rand(arg1=max, arg2=min)
          let maxVal = getReg(vm, funcReg + 1)  # First argument is max
          let minVal = getReg(vm, funcReg + 2)  # Second argument is min
          if isInt(minVal) and isInt(maxVal):
            let minInt = getInt(minVal)
            let maxInt = getInt(maxVal)
            let range = maxInt - minInt
            if range > 0:
              let randVal = (c_rand() mod cint(range)) + cint(minInt)
              setReg(vm, funcReg, makeInt(int64(randVal)))
            else:
              setReg(vm, funcReg, makeInt(minInt))

      of "print":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Build the string to print
          let output = if isInt(val):
            $getInt(val)
          elif isFloat(val):
            $getFloat(val)
          elif isChar(val):
            $getChar(val)
          elif getTag(val) == TAG_BOOL:
            if (val.data and 1) != 0: "true" else: "false"
          elif getTag(val) == TAG_STRING:
            val.sval
          elif getTag(val) == TAG_ARRAY:
            # Print array elements (for debugging)
            $val.aval
          else:
            "nil"

          # Add to output buffer for batched I/O
          outputBuffer.add(output)
          outputBuffer.add('\n')
          outputCount.inc

          # Flush if buffer is getting large or we have many lines
          if outputBuffer.len >= BUFFER_SIZE or outputCount >= 100:
            flushOutput()

          setReg(vm, funcReg, makeNil())

      of "toString":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          var result: V
          result.data = TAG_STRING shl 48
          if isInt(val):
            result.sval = $getInt(val)
          elif isFloat(val):
            result.sval = $getFloat(val)
          elif isChar(val):
            result.sval = $getChar(val)
          elif getTag(val) == TAG_BOOL:
            result.sval = if (val.data and 1) != 0: "true" else: "false"
          elif getTag(val) == TAG_STRING:
            result.sval = val.sval
          else:
            result.sval = "nil"
          setReg(vm, funcReg, result)

      # Mock C functions for testing
      of "c_add":
        if numArgs == 2:
          let a = getReg(vm, funcReg + 1)
          let b = getReg(vm, funcReg + 2)
          if isInt(a) and isInt(b):
            setReg(vm, funcReg, makeInt(getInt(a) + getInt(b)))
          else:
            setReg(vm, funcReg, makeNil())

      of "c_multiply":
        if numArgs == 2:
          let a = getReg(vm, funcReg + 1)
          let b = getReg(vm, funcReg + 2)
          if isInt(a) and isInt(b):
            setReg(vm, funcReg, makeInt(getInt(a) * getInt(b)))
          else:
            setReg(vm, funcReg, makeNil())

      # Reference operations
      of "new":
        if numArgs == 1:
          # For now, just pass through the value (references are not truly implemented)
          # In a real implementation, this would allocate heap memory
          let val = getReg(vm, funcReg + 1)
          setReg(vm, funcReg, val)
        else:
          setReg(vm, funcReg, makeNil())

      of "deref":
        if numArgs == 1:
          # For now, just pass through the value (references are not truly implemented)
          # In a real implementation, this would dereference the pointer
          let val = getReg(vm, funcReg + 1)
          setReg(vm, funcReg, val)
        else:
          setReg(vm, funcReg, makeNil())

      # File I/O operations
      of "readFile":
        if numArgs == 1:
          let pathVal = getReg(vm, funcReg + 1)
          if isString(pathVal):
            try:
              let content = readFile(pathVal.sval)
              setReg(vm, funcReg, makeString(content))
            except:
              setReg(vm, funcReg, makeString(""))
          else:
            setReg(vm, funcReg, makeString(""))
        else:
          setReg(vm, funcReg, makeString(""))

      # Parsing functions
      of "parseInt":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            try:
              let intVal = parseInt(strVal.sval)
              # Return Some(intVal)
              setReg(vm, funcReg, makeSome(makeInt(int64(intVal))))
            except:
              # Return None
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      of "parseFloat":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            try:
              let floatVal = parseFloat(strVal.sval)
              # Return Some(floatVal)
              setReg(vm, funcReg, makeSome(makeFloat(floatVal)))
            except:
              # Return None
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      of "parseBool":
        if numArgs == 1:
          let strVal = getReg(vm, funcReg + 1)
          if isString(strVal):
            if strVal.sval == "true":
              setReg(vm, funcReg, makeSome(makeBool(true)))
            elif strVal.sval == "false":
              setReg(vm, funcReg, makeSome(makeBool(false)))
            else:
              setReg(vm, funcReg, makeNone())
          else:
            setReg(vm, funcReg, makeNone())
        else:
          setReg(vm, funcReg, makeNone())

      # Option/Result type checking
      of "isSome":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Some tag
          setReg(vm, funcReg, makeBool(isSome(val)))
        else:
          setReg(vm, funcReg, makeBool(false))

      of "isNone":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the None tag
          setReg(vm, funcReg, makeBool(isNone(val)))
        else:
          setReg(vm, funcReg, makeBool(true))

      of "isOk":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Ok tag
          setReg(vm, funcReg, makeBool(isOk(val)))
        else:
          setReg(vm, funcReg, makeBool(false))

      of "isErr":
        if numArgs == 1:
          let val = getReg(vm, funcReg + 1)
          # Check if the value has the Err tag
          setReg(vm, funcReg, makeBool(isErr(val)))
        else:
          setReg(vm, funcReg, makeBool(true))

      else:
        # Check if it's an unimplemented builtin that just returns the function name
        # (This is a placeholder for unimplemented builtins)
        if verbose:
          echo "[REGVM] Unknown function: ", funcName, " - returning function name as string"
        var result: V
        result.data = TAG_STRING shl 48
        result.sval = funcName
        setReg(vm, funcReg, result)

    of ropReturn:
      # Return from function
      let numResults = instr.a
      let firstResultReg = instr.b

      if verbose:
        echo "[REGVM] ropReturn: numResults=", numResults, " firstResultReg=", firstResultReg, " frames.len=", vm.frames.len

      # Check if we're returning from main (only 1 frame)
      if vm.frames.len <= 1:
        # Flush output buffer before exiting
        flushOutput()
        stdout.flushFile()
        return 0

      # Get return value (if any)
      var returnValue = makeNil()
      if numResults > 0:
        returnValue = getReg(vm, firstResultReg)

      # Pop frame
      let returnAddr = vm.currentFrame.returnAddr
      let resultReg = vm.currentFrame.baseReg
      discard vm.frames.pop()

      # Restore previous frame
      if vm.frames.len > 0:
        vm.currentFrame = addr vm.frames[^1]
        # Store return value in the result register (only if function returns a value)
        if numResults > 0:
          setReg(vm, resultReg, returnValue)
        # Continue execution after the call
        # Note: pc will be incremented at the start of the loop, so we need to decrement by 1
        pc = returnAddr - 1
        continue
      else:
        # No more frames, exit
        return 0

    # --- Fused Instructions (Aggressive Optimization) ---
    of ropAddAdd:
      # R[A] = R[B] + R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) + getInt(c) + getInt(d)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropMulAdd:
      # R[A] = R[B] * R[C] + R[D]
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let d = getReg(vm, uint8((instr.ax shr 16) and 0xFF))

      if isInt(b) and isInt(c) and isInt(d):
        setReg(vm, instr.a, makeInt(getInt(b) * getInt(c) + getInt(d)))
      else:
        setReg(vm, instr.a, makeNil())

    of ropCmpJmp:
      # Combined compare and jump
      let b = getReg(vm, uint8(instr.ax and 0xFF))
      let c = getReg(vm, uint8((instr.ax shr 8) and 0xFF))
      let jmpOffset = int16((instr.ax shr 16) and 0xFFFF)

      if doLt(b, c):
        pc += int(jmpOffset)

    of ropIncTest:
      # Increment and test (common loop pattern)
      var val = getReg(vm, instr.a)
      if isInt(val):
        let newVal = getInt(val) + 1
        setReg(vm, instr.a, makeInt(newVal))
        if newVal < int64(instr.bx):
          pc += int(instr.sbx)

    else:
      # Unimplemented instructions
      discard

  # Flush any remaining buffered output
  flushOutput()
  # Ensure all output is written to terminal
  stdout.flushFile()
  return 0

# Run a register-based program
proc runRegProgram*(prog: RegBytecodeProgram, verbose: bool = false): int =
  let vm = newRegisterVM(prog)
  return vm.execute(verbose)