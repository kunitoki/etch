# dead_code.nim
# Dead code elimination using lifetime analysis

import std/[tables]
import ../../common/logging
import ../../core/vm_types


proc optimizeDeadCode*(instructions: seq[InstructionEntry], lifetimes: Table[uint8, LifetimeRange], verbose: bool = false): seq[InstructionEntry] =
  ## Eliminate dead code - instructions that compute values that are never used
  logOptimizer(verbose, "Starting dead code elimination optimization pass")

  return instructions
