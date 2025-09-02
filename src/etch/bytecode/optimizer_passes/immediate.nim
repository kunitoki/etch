# immediate.nim
# Convert operations with small constants to immediate forms
# opAdd R[A], R[B], K[small_const] -> opAddI R[A], R[B], imm

import std/[strformat]
import ../../common/logging
import ../../core/vm_types


proc fitsIn8BitSigned(val: int64): bool {.inline.} =
  val >= -128 and val <= 127


proc optimizeImmediate*(instructions: seq[InstructionEntry], constants: seq[V], verbose: bool = false): seq[InstructionEntry] =
  ## Convert operations with small constants to immediate forms
  logOptimizer(verbose, "Starting immediate conversion optimization pass")

  var res = instructions
  var convertedCount = 0

  # Early exit if no constants
  if constants.len == 0:
    logOptimizer(verbose, "No constants to optimize")
    return res

  for i in 0 ..< res.len:
    var instr = res[i].instr

    # Pattern: LoadK + Arithmetic -> Arithmetic with immediate
    # Look for: Op R[A], R[B], R[C] where R[C] was just loaded from a small constant
    if i > 0 and instr.opType == ifmtABC:
      let prev = res[i-1].instr

      # Check if previous instruction loaded a constant into the operand register
      if prev.op == opLoadK and prev.opType == ifmtABx:
        let constReg = prev.a
        let constIdx = prev.bx

        # Check if this instruction uses that constant register
        var usesConst = false
        var constIsC = false

        if instr.c == constReg:
          usesConst = true
          constIsC = true

        if usesConst and int(constIdx) < constants.len:
          let constVal = constants[constIdx]

          # Only convert if constant is a small integer
          if constVal.kind == vkInt and fitsIn8BitSigned(constVal.ival):
            let immVal = constVal.ival

            # Check which operations can be converted
            var newOp = opNoOp
            case instr.op
            of opAdd, opAddInt:
              newOp = opAddI
            of opSub, opSubInt:
              newOp = opSubI
            of opMul, opMulInt:
              newOp = opMulI
            of opDiv, opDivInt:
              newOp = opDivI
            of opMod, opModInt:
              newOp = opModI
            of opAnd:
              newOp = opAndI
            of opOr:
              newOp = opOrI
            # Comparison operations - only if constant is second operand
            of opEq, opEqInt:
              if constIsC:
                newOp = opEqI
            of opLt, opLtInt:
              if constIsC:
                newOp = opLtI
            of opLe, opLeInt:
              if constIsC:
                newOp = opLeI
            else:
              discard

            if newOp != opNoOp:
              # Convert to immediate form
              # ifmtABx: A=dest, Bx=[reg:8][imm:8]
              # The non-constant operand becomes the register operand
              let reg = if constIsC: instr.b else: instr.c
              let imm8 = if immVal < 0: uint8(256 + int(immVal)) else: uint8(immVal)

              var converted = instr
              converted.op = newOp
              converted.opType = ifmtABx
              converted.bx = uint16(reg) or (uint16(imm8) shl 8)

              res[i].instr = converted
              # Mark the LoadK as NoOp since we no longer need it
              res[i-1].instr = Instruction(op: opNoOp)
              convertedCount.inc
              logOptimizer(verbose, &"Converted {instr.op} to {newOp} with immediate {immVal} at {i}")

  if convertedCount > 0:
    logOptimizer(verbose, &"Converted {convertedCount} operations to immediate forms")

  return res
