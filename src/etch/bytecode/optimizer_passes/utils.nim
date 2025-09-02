# utils.nim

import std/sets
import ../../core/vm_types


proc getJumpTargets*(instructions: seq[InstructionEntry]): HashSet[int] =
  result = initHashSet[int]()
  for i, entry in instructions:
    let instr = entry.instr
    case instr.op
    of opJmp, opForLoop, opForPrep, opPushDefer, opIncTest, opLtJmp:
      # sBx is offset
      let offset = instr.sbx
      let target = i + 1 + offset
      if target >= 0 and target < instructions.len:
        result.incl(target)
    of opForIntLoop, opForIntPrep:
      let offset = instr.sbx
      let target = i + 1 + offset
      if target >= 0 and target < instructions.len:
        result.incl(target)
    of opCmpJmp, opCmpJmpInt, opCmpJmpFloat:
      # Packed offset in ax
      let offset = int16((instr.ax shr 16) and 0xFFFF)
      let target = i + 1 + int(offset)
      if target >= 0 and target < instructions.len:
        result.incl(target)
    else:
      discard
