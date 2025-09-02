# fusion.nim
# Instruction fusion optimization pass

import std/[sets, strformat, tables]
import ../../common/logging
import ../../core/vm_types
import ./utils


proc isSkipInstruction(op: OpCode): bool =
  op in {
    opLoadBool, opTest, opTestSet, opTestTag,
    opEq, opLt, opLe,
    opEqI, opLtI, opLeI,
    opEqInt, opLtInt, opLeInt,
    opEqFloat, opLtFloat, opLeFloat
  }


proc optimizeInstructionFusion*(instructions: seq[InstructionEntry], verbose: bool = false): seq[InstructionEntry] =
  logOptimizer(verbose, "Starting instruction fusion optimization pass")

  let jumpTargets = getJumpTargets(instructions)
  var res = instructions # Copy instructions
  var fusedCount = 0

  var i = 0
  while i < res.len - 1:
    let curr = res[i].instr
    let next = res[i+1].instr

    # Check if next instruction is a jump target
    if (i + 1) in jumpTargets:
      i.inc
      continue

    # Check if current instruction is skipped by previous instruction
    if i > 0 and isSkipInstruction(res[i-1].instr.op):
      i.inc
      continue

    # Pattern 1: Add + Add -> AddAdd (Generic, Int, Float)
    # R[A] = R[A] + R[B]
    # R[A] = R[A] + R[C]
    # -> R[A] = R[A] + R[B] + R[C]

    let isAdd = curr.op in {opAdd, opAddInt, opAddFloat}
    let isNextAdd = next.op == curr.op

    if isAdd and isNextAdd and curr.opType == ifmtABC and next.opType == ifmtABC:
      # Check accumulation pattern
      var currDest = curr.a
      var currSrc = 0'u8
      var isCurrAccum = false

      if curr.b == currDest:
        currSrc = curr.c
        isCurrAccum = true
      elif curr.c == currDest:
        currSrc = curr.b
        isCurrAccum = true

      if isCurrAccum:
        var nextDest = next.a
        var nextSrc = 0'u8
        var isNextAccum = false

        if nextDest == currDest:
          if next.b == nextDest:
            nextSrc = next.c
            isNextAccum = true
          elif next.c == nextDest:
            nextSrc = next.b
            isNextAccum = true

        if isNextAccum:
          var fusedOp = opNoOp
          case curr.op
          of opAdd: fusedOp = opAddAdd
          of opAddInt: fusedOp = opAddAddInt
          of opAddFloat: fusedOp = opAddAddFloat
          else: discard

          if fusedOp != opNoOp:
            var fusedInstr = curr
            fusedInstr.op = fusedOp
            fusedInstr.a = currDest
            fusedInstr.b = currSrc
            fusedInstr.c = nextSrc

            res[i].instr = fusedInstr
            res[i+1].instr = Instruction(op: opNoOp)
            fusedCount.inc
            logOptimizer(verbose, &"Fused {curr.op} at {i} and {i+1} into {fusedOp}")
            i.inc
            continue

    # Helper for 3-register ops
    template fuse3Reg(op1, op2, fusedOpCode, commutative2) =
      if curr.op == op1 and next.op == op2 and curr.opType == ifmtABC and next.opType == ifmtABC:
        let t = curr.a
        let a = next.a

        # Check if T is used in Op2
        var d = 0'u8
        var match = false

        if commutative2:
          if next.b == t:
            d = next.c
            match = true
          elif next.c == t:
            d = next.b
            match = true
        else:
          # Non-commutative: T must be first operand (next.b)
          if next.b == t:
            d = next.c
            match = true

        if match:
          var fusedInstr = Instruction(
            op: fusedOpCode,
            opType: ifmtAx,
            a: a,
            # Pack: B=curr.b, C=curr.c, D=d
            ax: uint32(curr.b) or (uint32(curr.c) shl 8) or (uint32(d) shl 16)
          )
          res[i].instr = fusedInstr
          res[i+1].instr = Instruction(op: opNoOp)
          fusedCount.inc
          logOptimizer(verbose, "Fused " & $op1 & "+" & $op2 & " at " & $i & " and " & $(i+1) & " into " & $fusedOpCode)
          i.inc
          continue

    # Helper for SubMul (Special case: T is 2nd operand)
    template fuseSubMul(mulOp: OpCode, subOp: OpCode, fusedOp: OpCode) =
      if curr.op == mulOp and next.op == subOp and curr.opType == ifmtABC and next.opType == ifmtABC:
        let t = curr.a
        let a = next.a

        # Sub: A = B - T (T is next.c)
        if next.c == t:
          let b = next.b
          # Fused: A=a, B=b, C=curr.b, D=curr.c
          var fusedInstr = Instruction(
            op: fusedOp,
            opType: ifmtAx,
            a: a,
            ax: uint32(b) or (uint32(curr.b) shl 8) or (uint32(curr.c) shl 16)
          )
          res[i].instr = fusedInstr
          res[i+1].instr = Instruction(op: opNoOp)
          fusedCount.inc
          logOptimizer(verbose, "Fused " & $mulOp & "+" & $subOp &
            " at " & $i & " and " & $(i+1) & " into " & $fusedOp)
          i.inc
          continue

    # Apply patterns

    # Group 1: Commutative 2nd Op
    fuse3Reg(opMul, opAdd, opMulAdd, true)
    fuse3Reg(opDiv, opAdd, opDivAdd, true)
    fuse3Reg(opAdd, opMul, opAddMul, true)
    fuse3Reg(opMulInt, opAddInt, opMulAddInt, true)
    fuse3Reg(opDivInt, opAddInt, opDivAddInt, true)
    fuse3Reg(opAddInt, opMulInt, opAddMulInt, true)
    fuse3Reg(opMulFloat, opAddFloat, opMulAddFloat, true)
    fuse3Reg(opDivFloat, opAddFloat, opDivAddFloat, true)
    fuse3Reg(opAddFloat, opMulFloat, opAddMulFloat, true)

    # Group 2: Non-commutative 2nd Op (T is 1st operand)
    fuse3Reg(opSub, opSub, opSubSub, false)
    fuse3Reg(opMul, opSub, opMulSub, false)
    fuse3Reg(opAdd, opSub, opAddSub, false)
    fuse3Reg(opSub, opDiv, opSubDiv, false)
    fuse3Reg(opSubInt, opSubInt, opSubSubInt, false)
    fuse3Reg(opMulInt, opSubInt, opMulSubInt, false)
    fuse3Reg(opAddInt, opSubInt, opAddSubInt, false)
    fuse3Reg(opSubInt, opDivInt, opSubDivInt, false)
    fuse3Reg(opSubFloat, opSubFloat, opSubSubFloat, false)
    fuse3Reg(opMulFloat, opSubFloat, opMulSubFloat, false)
    fuse3Reg(opAddFloat, opSubFloat, opAddSubFloat, false)
    fuse3Reg(opSubFloat, opDivFloat, opSubDivFloat, false)

    # Group 3: Special cases
    fuseSubMul(opMul, opSub, opSubMul)
    fuseSubMul(opMulInt, opSubInt, opSubMulInt)
    fuseSubMul(opMulFloat, opSubFloat, opSubMulFloat)

    i.inc

  if fusedCount > 0:
    logOptimizer(verbose, &"Fused {fusedCount} instruction pairs")

  return res
