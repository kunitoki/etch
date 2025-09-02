# move_fusion.nim
# Peephole fusion to collapse AddInt+Move into a single instruction

import std/[strformat]
import ../../common/logging
import ../../core/vm_types


proc instructionReadsRegistry(instr: Instruction, reg: uint8): bool =
  ## Helper for instructions with multiple register sources (value/container/index)
  if instr.a == reg or instr.b == reg:
    return true
  if instr.op != opSetIndexI and instr.c == reg:
    return true
  return false


proc usesRegister(instr: Instruction, reg: uint8): bool =
  ## Check if `instr` reads from `reg`
  case instr.op
  of opMove, opUnm, opNot, opCast, opLen, opSlice,
     opIncRef, opDecRef, opWeakToStrong, opWrapSome,
     opWrapOk, opWrapErr, opUnwrapOption, opUnwrapResult:
    if instr.opType == ifmtABC:
      return instr.b == reg
  of opAdd, opSub, opMul, opDiv, opMod, opPow, opAnd, opOr,
     opEq, opLt, opLe, opNeStore, opGetIndex, opGetField:
    if instr.opType == ifmtABC:
      return instr.b == reg or instr.c == reg
  of opAddI, opSubI, opMulI, opDivI, opModI, opEqI, opLtI, opLeI, opGetIndexI:
    if instr.opType == ifmtABC:
      return instr.b == reg
  of opSetIndex, opSetIndexI, opSetField, opSetRef:
    if instr.opType == ifmtABC:
      return instructionReadsRegistry(instr, reg)
  of opCall:
    if instr.opType == ifmtCall:
      for i in 1'u8 .. instr.numArgs:
        if instr.a + i == reg:
          return true
  of opTest, opTestSet, opTestTag, opIncTest:
    if instr.opType == ifmtABC:
      if instr.a == reg:
        return true
      if instr.op == opTestSet and instr.b == reg:
        return true
  of opCmpJmp:
    if instr.opType == ifmtABC:
      return instr.a == reg or instr.b == reg
  of opReturn:
    if instr.opType == ifmtABC and instr.a != 0:
      return instr.a == reg
  else:
    return false
  return false


proc registerUsedAfter(instructions: seq[InstructionEntry], start: int, reg: uint8): bool =
  for j in start..<instructions.len:
    if usesRegister(instructions[j].instr, reg):
      return true
  return false


proc isMutableAccumulatorOp(instr: Instruction): bool =
  case instr.op
  of opAdd, opSub, opMul, opDiv, opMod,
     opAddInt, opSubInt, opMulInt, opDivInt, opModInt,
     opAddFloat, opSubFloat, opMulFloat, opDivFloat, opModFloat:
    return instr.opType == ifmtABC
  else:
    return false


proc usesJumpOffset(op: OpCode): bool {.inline.} =
  ## Determine if the opcode interprets sBx as a control-flow offset
  op in {opJmp, opForLoop, opForPrep, opPushDefer, opCmpJmp, opIncTest, opLtJmp}


proc optimizeMoveFusion*(instructions: seq[InstructionEntry], verbose: bool = false): seq[InstructionEntry] =
  logOptimizer(verbose, "Starting move fusion optimization pass")

  var res: seq[InstructionEntry] = @[]
  var oldToNew = newSeq[int](instructions.len)
  for idx in 0 ..< oldToNew.len: oldToNew[idx] = -1

  var i = 0
  while i < instructions.len:
    let entry = instructions[i]
    let instr = entry.instr

    if i + 1 < instructions.len:
      let nextEntry = instructions[i + 1]
      let next = nextEntry.instr
      if next.op == opMove and instr.opType == ifmtABC and next.opType == ifmtABC:
        if next.b == instr.a and next.a == instr.b and isMutableAccumulatorOp(instr):
          if not registerUsedAfter(instructions, i + 2, instr.a):
            var fused = instr
            fused.a = instr.b
            oldToNew[i] = res.len
            res.add(InstructionEntry(instr: fused, debug: entry.debug))
            logOptimizer(verbose, &"Fused {instr.op} + Move into single accumulator at PCs {i},{i+1} -> R[{fused.a}]")
            i += 2
            continue
    oldToNew[i] = res.len
    res.add(entry)
    inc i

  # Fix jump offsets to account for removed instructions
  if res.len != instructions.len:
    for newIdx, entry in res:
      let instr = entry.instr
      if instr.opType == ifmtAsBx and usesJumpOffset(instr.op):
        # Find originating old PC for this instruction
        var oldPc = -1
        for j, mapped in oldToNew:
          if mapped == newIdx:
            oldPc = j
            break
        if oldPc >= 0:
          var targetOld = oldPc + 1 + int(instructions[oldPc].instr.sbx)
          # Advance target to next surviving instruction if it was removed
          if targetOld >= 0 and targetOld < oldToNew.len and oldToNew[targetOld] == -1:
            var forward = targetOld
            while forward < oldToNew.len and oldToNew[forward] == -1:
              inc forward
            if forward < oldToNew.len:
              targetOld = forward
            else:
              var backward = targetOld
              while backward >= 0 and oldToNew[backward] == -1:
                dec backward
              if backward >= 0:
                targetOld = backward

          if targetOld >= 0 and targetOld < oldToNew.len and oldToNew[targetOld] != -1:
            let targetNew = oldToNew[targetOld]
            var patched = instr
            patched.sbx = int16(targetNew - (newIdx + 1))
            var newEntry = entry
            newEntry.instr = patched
            res[newIdx] = newEntry

  logOptimizer(verbose, &"Move fusion reduced instruction count to {res.len}")
  return res
