# noop_removal.nim
# Optimization pass to remove NoOp instructions and fix jump targets

import std/[strformat]
import ../../common/logging
import ../../core/vm_types


proc isSkipInstruction(op: OpCode): bool =
  op in {
    opLoadBool, opTest, opTestSet, opTestTag,
    opEq, opLt, opLe,
    opEqI, opLtI, opLeI,
    opEqInt, opLtInt, opLeInt,
    opEqFloat, opLtFloat, opLeFloat
  }


proc optimizeNoOpRemoval*(instructions: seq[InstructionEntry], verbose: bool): seq[InstructionEntry] =
  # Remove opNoOp instructions and fix jump targets
  var mapping = newSeq[int](instructions.len)
  var keptInstructions: seq[tuple[entry: InstructionEntry, oldIdx: int]] = @[]

  # First pass: build mapping and new instruction list
  var newIdx = 0
  for oldIdx, entry in instructions:
    # Don't remove NoOp if it's the target of a skip instruction (i.e. previous instruction is a skip)
    # This preserves the "skip next" semantics
    var keep = true
    if entry.instr.op == opNoOp:
      if oldIdx > 0 and isSkipInstruction(instructions[oldIdx-1].instr.op):
        keep = true
      else:
        keep = false

    if not keep:
      mapping[oldIdx] = -1 # Mark as removed
    else:
      mapping[oldIdx] = newIdx
      keptInstructions.add((entry, oldIdx))
      newIdx.inc

  # Fix mapping for removed instructions (point to next valid instruction)
  var nextValid = keptInstructions.len
  for oldIdx in countdown(instructions.len - 1, 0):
    if mapping[oldIdx] == -1:
      mapping[oldIdx] = nextValid
    else:
      nextValid = mapping[oldIdx]

  # Second pass: fix jump targets
  result = newSeqOfCap[InstructionEntry](keptInstructions.len)

  for i in 0..<keptInstructions.len:
    var (entry, oldIdx) = keptInstructions[i]
    var instr = entry.instr

    case instr.op
    of opJmp, opForLoop, opForPrep, opPushDefer, opIncTest, opLtJmp, opForIntLoop, opForIntPrep:
      let oldOffset = int(instr.sbx)
      let oldTarget = oldIdx + 1 + oldOffset
      if oldTarget >= 0 and oldTarget < instructions.len:
        let newTarget = mapping[oldTarget]
        # If newTarget is valid (not end of code)
        if newTarget < keptInstructions.len:
            let newOffset = newTarget - (i + 1)
            instr.sbx = int16(newOffset)
        else:
            # Jump to end of code
            let newOffset = newTarget - (i + 1)
            instr.sbx = int16(newOffset)

    of opCmpJmp, opCmpJmpInt, opCmpJmpFloat:
      let oldOffset = int16((instr.ax shr 16) and 0xFFFF)
      let oldTarget = oldIdx + 1 + int(oldOffset)
      if oldTarget >= 0 and oldTarget < instructions.len:
        let newTarget = mapping[oldTarget]
        let newOffset = newTarget - (i + 1)
        let low16 = instr.ax and 0xFFFF
        instr.ax = low16 or (uint32(uint16(newOffset)) shl 16)

    else:
      discard

    entry.instr = instr
    result.add(entry)

  logOptimizer(verbose, &"Removed {instructions.len - result.len} NoOps")
