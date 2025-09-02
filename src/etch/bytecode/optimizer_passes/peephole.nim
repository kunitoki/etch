# peephole.nim
# Advanced peephole optimization pass
# Performs local optimizations on instruction windows

import std/[strformat, sets, tables]
import ../../common/logging
import ../../core/vm_types
import ./utils


proc hasYieldInstructions(instructions: seq[InstructionEntry]): bool =
  ## Check if the function contains any yield instructions
  for entry in instructions:
    if entry.instr.op == opYield:
      return true
  return false


proc optimizePeephole*(instructions: seq[InstructionEntry],
                       lifetimes: Table[uint8, LifetimeRange],
                       verbose: bool = false): seq[InstructionEntry] =
  ## Perform peephole optimizations on bytecode
  logOptimizer(verbose, "Starting peephole optimization pass")

  let jumpTargets = getJumpTargets(instructions)
  let hasYields = hasYieldInstructions(instructions)
  var res = instructions
  var optimizedCount = 0
  var i = 0

  if hasYields:
    logOptimizer(verbose, "Function has yields - using conservative optimizations")

  while i < res.len - 1:
    let curr = res[i].instr
    let next = if i + 1 < res.len: res[i+1].instr else: Instruction(op: opNoOp)

    # Skip if next instruction is a jump target
    if (i + 1) in jumpTargets:
      i.inc
      continue

    # Pattern 1: LoadK + Move -> LoadK (eliminate redundant move)
    # LoadK R[A], K[Bx]
    # Move R[B], R[A]
    # -> LoadK R[B], K[Bx]
    # Safe if: no yields OR source register lifetime ends at move instruction
    if curr.op == opLoadK and next.op == opMove and
       curr.opType == ifmtABx and next.opType == ifmtABC:
      if next.b == curr.a:
        # Check if optimization is safe
        var isSafe = not hasYields
        if hasYields and lifetimes.hasKey(curr.a):
          let lifetime = lifetimes[curr.a]
          # Safe if register's lifetime ends at or before the move instruction
          isSafe = lifetime.lastUsePC <= i + 1

        if isSafe:
          var optimized = curr
          optimized.a = next.a
          res[i].instr = optimized
          res[i+1].instr = Instruction(op: opNoOp)
          optimizedCount.inc
          logOptimizer(verbose, &"Eliminated LoadK+Move at {i}-{i+1}")
          i += 2
          continue

    # Pattern 2: Move R[A], R[B]; Move R[C], R[A] -> Move R[C], R[B]
    # (chain move elimination)
    # But skip if the result would be a self-move (R[C] = R[B] where C == B)
    if curr.op == opMove and next.op == opMove and
       curr.opType == ifmtABC and next.opType == ifmtABC:
      if next.b == curr.a:
        # Check if optimization would create a self-move
        if next.a != curr.b:  # Only optimize if destination != final source
          var optimized = next
          optimized.b = curr.b
          res[i].instr = optimized
          res[i+1].instr = Instruction(op: opNoOp)
          optimizedCount.inc
          logOptimizer(verbose, &"Simplified move chain at {i}-{i+1}")
          i += 2
          continue

    # Pattern 3: Add R[A], R[B], R[C]; Move R[D], R[A] -> Add R[D], R[B], R[C]
    # (forward result directly to destination)
    # Safe if: no yields OR source register lifetime ends at move instruction
    let isArithmetic = curr.op in {
      opAdd, opSub, opMul, opDiv, opMod,
      opAddInt, opSubInt, opMulInt, opDivInt, opModInt,
      opAddFloat, opSubFloat, opMulFloat, opDivFloat, opModFloat,
      opPow
    }
    if isArithmetic and next.op == opMove and
       curr.opType == ifmtABC and next.opType == ifmtABC:
      if next.b == curr.a:
        # Check if optimization is safe
        var isSafe = not hasYields
        if hasYields and lifetimes.hasKey(curr.a):
          let lifetime = lifetimes[curr.a]
          # Safe if register's lifetime ends at or before the move instruction
          isSafe = lifetime.lastUsePC <= i + 1

        if isSafe:
          var optimized = curr
          optimized.a = next.a
          res[i].instr = optimized
          res[i+1].instr = Instruction(op: opNoOp)
          optimizedCount.inc
          logOptimizer(verbose, &"Forwarded arithmetic result at {i}-{i+1}")
          i += 2
          continue

    # Pattern 4: Load immediate 0/1 optimizations
    # LoadK R[A], 0; Add R[B], R[A], R[C] -> Move R[B], R[C]
    # LoadK R[A], 0; Add R[B], R[C], R[A] -> Move R[B], R[C]
    if curr.op == opLoadK and curr.opType == ifmtABx and i + 1 < res.len:
      # Check if loading 0 or 1
      # Note: We can't check constant values here without the constants table
      # So we'll handle this in a separate pass that has access to constants
      discard

    # Pattern 5: Redundant comparison elimination
    # Eq R[A], R[B], R[C]
    # Eq R[A], R[B], R[C]  (same comparison)
    # -> first one only
    if curr.op in {opEq, opLt, opLe, opEqInt, opLtInt, opLeInt, opEqFloat, opLtFloat, opLeFloat} and
       next.op == curr.op and curr.opType == ifmtABC and next.opType == ifmtABC:
      if curr.a == next.a and curr.b == next.b and curr.c == next.c:
        res[i+1].instr = Instruction(op: opNoOp)
        optimizedCount.inc
        logOptimizer(verbose, &"Eliminated redundant comparison at {i+1}")
        i += 2
        continue

    i.inc

  if optimizedCount > 0:
    logOptimizer(verbose, &"Performed {optimizedCount} peephole optimizations")

  return res
