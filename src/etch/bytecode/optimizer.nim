# optimizer.nim
# Main entry point for bytecode optimization
# Coordinates multiple optimization passes

import tables
import ../core/vm_types
import ./optimizer_passes/[refcount, constant_folding, dead_code, loops, move_fusion, coalescing, fusion, noop_removal, peephole, immediate]
import ../common/builtins


type
  OptimizerConfig* = object
    level*: int                    # 0=debug (no opts), 1=release (all opts)
    verbose*: bool                 # Enable optimization logging

    enableRefCount*: bool          # Enable reference counting optimizations
    enableLoopOptimization*: bool  # Enable loop optimizations
    enableMoveFusion*: bool        # Fuse add/move patterns into accumulators
    enableInstructionFusion*: bool # Fuse arithmetic instructions

    enableCoalescing*: bool        # Coalesce registers to remove moves
    enableConstFolding*: bool      # Enable constant folding
    enableNoOpRemoval*: bool       # Remove NoOp instructions
    enableDeadCode*: bool          # Enable dead code elimination
    enablePeephole*: bool          # Enable peephole optimizations
    enableImmediate*: bool         # Convert small constants to immediate forms


proc newOptimizerConfig*(level: int = 1, verbose: bool = false): OptimizerConfig =
  result.level = level
  result.verbose = verbose

  # Enable passes based on optimization level
  result.enableRefCount = level >= 1           # ✓ Working - optimizes refcount ops
  result.enableLoopOptimization = level >= 1   # ✓ Working - optimizes loops
  result.enableMoveFusion = level >= 1         # ✓ Working - Fuse AddInt+Move into single op
  result.enableInstructionFusion = level >= 1  # ✓ Working - Fuse arithmetic instructions
  result.enableNoOpRemoval = level >= 1        # ✓ Working - But keep an eye on the jump targets
  result.enableConstFolding = level >= 1       # ✓ Working - Folds constant expressions
  result.enablePeephole = level >= 1           # ✓ Working - Now coroutine-safe with lifetime analysis
  result.enableImmediate = level >= 1          # ✓ Working - Convert small constants to immediate forms

  # Temporarily disabled passes
  result.enableCoalescing = false              # TODO: Fix - Coalesce registers
  result.enableDeadCode = false                # DISABLED - Incorrectly removes loop counter updates (breaks loops)


proc optimizeFunction*(entries: seq[InstructionEntry],
                       lifetimes: Table[uint8, LifetimeRange],
                       constants: var seq[V],
                       prog: BytecodeProgram,
                       config: OptimizerConfig): seq[InstructionEntry] =
  ## Apply all enabled optimization passes to a function's bytecode
  result = entries

  if config.level == 0:
    return result  # No optimizations

  # Each pass may enable further optimizations in subsequent passes

  # Pass 1: Constant folding (identifies and folds constant operations)
  if config.enableConstFolding:
    result = optimizeConstantFolding(result, constants, config.verbose)

  # Pass 1.1: Convert small constants to immediate forms
  if config.enableImmediate:
    result = optimizeImmediate(result, constants, config.verbose)

  # Pass 1.25: Peephole optimizations (local patterns)
  if config.enablePeephole:
    result = optimizePeephole(result, lifetimes, config.verbose)

  # Pass 1.5: Move fusion (collapse Add/Move sequences)
  if config.enableMoveFusion:
    result = optimizeMoveFusion(result, config.verbose)

  # Pass 1.6: Register Coalescing
  if config.enableCoalescing:
    result = optimizeRegisterCoalescing(result, lifetimes, config.verbose)

  # Pass 2: Reference counting optimizations
  if config.enableRefCount:
    let isSafeCall = proc(idx: int, op: OpCode): bool =
       if op == opCallBuiltin:
          # idx is builtinId
          if idx >= 0 and idx <= ord(BuiltinFuncId.high):
             let id = BuiltinFuncId(idx)
             return id in {bfPrint, bfDeref, bfNew, bfIsSome, bfIsNone, bfIsOk, bfIsErr}
       elif op == opCall:
          # idx is function table index
          if idx >= 0 and idx < prog.functionTable.len:
             let name = prog.functionTable[idx]

             # Check if name is a known builtin directly
             if isBuiltin(name):
                let id = getBuiltinId(name)
                return id in {bfPrint, bfDeref, bfNew, bfIsSome, bfIsNone, bfIsOk, bfIsErr}

             if prog.functions.hasKey(name):
                let info = prog.functions[name]
                if info.kind == fkBuiltin:
                   let id = BuiltinFuncId(info.builtinId)
                   return id in {bfPrint, bfDeref, bfNew, bfIsSome, bfIsNone, bfIsOk, bfIsErr}
       return false

    result = optimizeRefCounting(result, lifetimes, config.verbose, isSafeCall)

  # Pass 3: Dead code elimination (removes unused computations)
  if config.enableDeadCode:
    result = optimizeDeadCode(result, lifetimes, config.verbose)

  # Pass 4: Instruction fusion (AddAdd, MulAdd, etc.)
  if config.enableInstructionFusion:
    result = optimizeInstructionFusion(result, config.verbose)

  # Pass 5: Loop optimizations
  if config.enableLoopOptimization:
    result = optimizeLoops(result, lifetimes, config.verbose)

  # Pass 6: NoOp removal (removes opNoOp instructions)
  if config.enableNoOpRemoval:
    result = optimizeNoOpRemoval(result, config.verbose)

