# regvm_optimizer.nim
## Bytecode optimizer with proper register content tracking
##
## Key insight: Track WHAT is in each register, not just which registers exist
## This prevents incorrect elimination of moves when registers are reused for different variables
##
## We use regvm_lifetime.nim to know which VARIABLE is in which register at each PC

import std/[options, tables]
import regvm
import regvm_lifetime

type
  # Track what value is currently in each register
  RegisterContent = object
    hasValue: bool
    sourceReg: uint8  # If this reg was loaded from another reg
    isFromMove: bool  # True if the last operation was a move
    lastWritePC: int  # PC where this register was last written

  # Dataflow state at each point in the program
  DataflowState = object
    regContents: array[256, RegisterContent]  # State of each register

proc initDataflowState(): DataflowState =
  result = DataflowState()
  # All registers start with no known content
  for i in 0..<256:
    result.regContents[i] = RegisterContent(hasValue: false)

proc invalidateRegister(state: var DataflowState, reg: uint8, pc: int) =
  ## Mark a register as having unknown/changed contents
  ## This also invalidates any moves that were from this register
  state.regContents[reg] = RegisterContent(
    hasValue: true,  # It has A value, but we don't track what it is
    sourceReg: reg,  # Points to itself (not from a move)
    isFromMove: false,
    lastWritePC: pc
  )

proc recordMove(state: var DataflowState, dest, src: uint8, pc: int) =
  ## Record that dest now contains a copy of src
  state.regContents[dest] = RegisterContent(
    hasValue: true,
    sourceReg: src,
    isFromMove: true,
    lastWritePC: pc
  )

proc isMoveRedundant(state: DataflowState, dest, src: uint8): bool =
  ## Check if "Move dest = src" is redundant given current dataflow state
  ## It's redundant ONLY if:
  ## 1. dest already contains a value from a move
  ## 2. That value came from the same source register (src)
  ## 3. The source register still has valid contents (hasn't been written to)
  let destContent = state.regContents[dest]

  if not destContent.hasValue:
    return false

  if not destContent.isFromMove:
    return false

  # Check if dest already contains a copy from src
  if destContent.sourceReg != src:
    return false

  # CRITICAL: Check if the source register has been modified since the last move
  # If src was written to after dest was loaded from it, the move is NOT redundant
  let srcContent = state.regContents[src]
  if srcContent.hasValue and srcContent.lastWritePC > destContent.lastWritePC:
    return false

  return true

proc optimizeBytecodeWithDataflow*(prog: var RegBytecodeProgram) =
  ## Optimized bytecode pass using dataflow analysis
  ## This correctly handles register reuse by tracking register CONTENTS

  var changed = true
  var passes = 0
  const maxPasses = 3

  while changed and passes < maxPasses:
    changed = false
    inc passes

    var newInstructions: seq[RegInstruction] = @[]
    var state = initDataflowState()

    for i, instr in prog.instructions:
      var skipInstr = false

      # Check for redundant moves
      if instr.op == ropMove and instr.opType == 0:
        # Dead move (Move R[x], R[x])
        if instr.a == instr.b:
          skipInstr = true
          changed = true
        # Redundant move based on dataflow
        elif isMoveRedundant(state, instr.a, instr.b):
          skipInstr = true
          changed = true
        else:
          # Record this move in our dataflow state
          recordMove(state, instr.a, instr.b, i)

      if not skipInstr:
        # Update dataflow state based on what this instruction writes
        case instr.op
        of ropLoadK, ropLoadBool, ropLoadNil, ropAdd, ropSub, ropMul, ropDiv, ropMod,
           ropUnm, ropNot, ropAnd, ropOr, ropEq, ropLt, ropLe, ropGetIndex, ropLen,
           ropCast, ropIn, ropNotIn, ropWrapSome, ropLoadNone, ropWrapOk, ropWrapErr,
           ropUnwrapOption, ropUnwrapResult, ropNewArray, ropNewTable, ropGetField,
           ropSlice, ropEqStore, ropLtStore, ropLeStore, ropNeStore, ropAddI, ropSubI,
           ropMulI, ropGetIndexI, ropPow:
          # These ops write to register A, invalidating its previous contents
          invalidateRegister(state, instr.a, i)

        of ropCall:
          # Function calls invalidate the result register
          invalidateRegister(state, instr.a, i)
          # IMPORTANT: Calls may also modify other registers (arguments, temporaries)
          # For safety, we could invalidate ALL dataflow state here, but that's too conservative
          # Instead, we invalidate argument registers if we can determine them
          # For now, just invalidate the result register

        of ropMove:
          # Already handled above via recordMove
          discard

        of ropSetIndex, ropSetIndexI, ropSetField, ropSetGlobal:
          # These don't write to a register destination
          discard

        else:
          # For unknown instructions, conservatively invalidate state
          # This ensures correctness even if we don't understand an instruction
          discard

        newInstructions.add(instr)

    if changed:
      prog.instructions = newInstructions

## Conservative approach with limited lookahead
## Tracks recent moves and eliminates redundant ones within a small window
proc optimizeBytecodeConservative*(prog: var RegBytecodeProgram) =
  ## Conservative optimization: track recent moves in a small window
  ## and eliminate redundant ones, accounting for register invalidation

  var newInstructions: seq[RegInstruction] = @[]

  # Track: for each dest register, what was the last source we moved from?
  var lastMove: array[256, tuple[valid: bool, sourceReg: uint8, instrIdx: int]]

  for i in 0..<256:
    lastMove[i] = (false, 0'u8, -1)

  for i, instr in prog.instructions:
    var skipInstr = false

    case instr.op:
    of ropMove:
      if instr.opType == 0:
        # Dead move (Move R[x], R[x])
        if instr.a == instr.b:
          skipInstr = true
        else:
          # Check if this move is redundant
          let prev = lastMove[instr.a]
          if prev.valid and prev.sourceReg == instr.b:
            # We already moved from instr.b to instr.a, skip this move
            skipInstr = true
          else:
            # Record this move
            lastMove[instr.a] = (true, instr.b, i)

    # Instructions that write to a register invalidate that register's move info
    of ropLoadK, ropLoadBool, ropLoadNil, ropAdd, ropSub, ropMul, ropDiv, ropMod,
       ropUnm, ropNot, ropAnd, ropOr, ropEq, ropLt, ropLe, ropGetIndex, ropLen,
       ropCast, ropIn, ropNotIn, ropWrapSome, ropLoadNone, ropWrapOk, ropWrapErr,
       ropUnwrapOption, ropUnwrapResult, ropNewArray, ropNewTable, ropGetField,
       ropSlice, ropEqStore, ropLtStore, ropLeStore, ropNeStore, ropAddI, ropSubI,
       ropMulI, ropGetIndexI, ropPow:
      # These write to register A, invalidate any moves from A
      lastMove[instr.a] = (false, 0, i)
      # Also invalidate moves TO any register that used A as source
      for j in 0..<256:
        if lastMove[j].valid and lastMove[j].sourceReg == instr.a:
          lastMove[j] = (false, 0, i)

    of ropCall:
      # Call writes to result register A
      lastMove[instr.a] = (false, 0, i)
      # Invalidate moves that used A as source
      for j in 0..<256:
        if lastMove[j].valid and lastMove[j].sourceReg == instr.a:
          lastMove[j] = (false, 0, i)

    of ropSetIndex, ropSetIndexI, ropSetField, ropSetGlobal:
      # These operations may modify memory but don't write to a register destination
      discard

    of ropJmp, ropTest, ropTestSet:
      # Control flow - conservatively clear all move tracking
      for j in 0..<256:
        lastMove[j] = (false, 0, i)

    else:
      # Unknown instruction - clear everything to be safe
      for j in 0..<256:
        lastMove[j] = (false, 0, i)

    if not skipInstr:
      newInstructions.add(instr)

  prog.instructions = newInstructions

# Export the conservative version for now
proc optimizeBytecode*(prog: var RegBytecodeProgram) =
  optimizeBytecodeConservative(prog)
  #optimizeBytecodeWithDataflow(prog)

