# loops_v2.nim
# Proper loop optimization implementation with:
# 1. Global removal/insertion table
# 2. Data-flow analysis for loop-carried dependencies
# 3. Single-pass optimization

import std/[tables, sets, strformat, algorithm, options]
import ../../common/logging
import ../../core/vm_types


type
  LoopKind = enum
    lkGeneric
    lkNumericFor

  LoopRegion = object
    ## Represents a loop with all its metadata
    kind: LoopKind
    startPC: int              # First instruction in loop body
    endPC: int                # Back-edge instruction PC
    prepPC: int               # ForPrep instruction PC (-1 if none)
    baseReg: uint8            # Base register for for-loops
    depth: int                # Nesting depth (0 = outermost)
    parent: int               # Index of parent loop (-1 if top-level)

  RegisterDef = object
    ## Tracks where a register is defined
    pc: int
    loopDepth: int           # At what loop depth this def occurs

  RegisterUse = object
    ## Tracks where a register is used
    pc: int
    loopDepth: int

  DataFlowInfo = object
    ## Complete data-flow information for optimization
    defs: Table[uint8, seq[RegisterDef]]        # reg -> all definitions
    uses: Table[uint8, seq[RegisterUse]]        # reg -> all uses
    liveIn: Table[int, HashSet[uint8]]          # loop startPC -> registers live on entry
    liveOut: Table[int, HashSet[uint8]]         # loop endPC -> registers live on exit
    loopInvariant: Table[int, HashSet[int]]     # loop startPC -> set of invariant instruction PCs
    loopCarried: Table[int, Table[uint8, bool]] # loop startPC -> reg -> is loop-carried

  GlobalOptimizationPlan = object
    ## Global plan for all optimizations before any modifications
    removals: HashSet[int]                      # PCs to remove
    insertions: Table[int, seq[InstructionEntry]]  # PC -> instructions to insert before it
    replacements: Table[int, Instruction]       # PC -> replacement instruction


proc findMatchingForPrep(instructions: seq[InstructionEntry], loopPc: int, baseReg: uint8): int =
  ## Find the matching ForPrep instruction for a ForLoop back edge
  for idx in countdown(loopPc - 1, 0):
    let candidate = instructions[idx].instr
    if (candidate.op == opForPrep or candidate.op == opForIntPrep) and candidate.a == baseReg:
      return idx
  return -1


proc detectAllLoops(instructions: seq[InstructionEntry]): seq[LoopRegion] =
  ## Detect all loops in a single pass and compute nesting relationships
  result = @[]

  # First pass: detect all loops
  for pc, entry in instructions:
    let instr = entry.instr
    case instr.op
    of opForLoop, opForIntLoop:
      if instr.opType == ifmtAsBx:
        let loopStart = pc + 1 + int(instr.sbx)
        if loopStart >= 0 and loopStart < instructions.len and loopStart <= pc:
          let prepPc = findMatchingForPrep(instructions, pc, instr.a)
          result.add(LoopRegion(
            kind: lkNumericFor,
            startPC: loopStart,
            endPC: pc,
            prepPC: (if prepPc >= 0: prepPc else: -1),
            baseReg: instr.a,
            depth: 0,
            parent: -1
          ))

    of opJmp:
      if instr.opType == ifmtAsBx:
        let target = pc + 1 + int(instr.sbx)
        if target >= 0 and target < instructions.len and target < pc:
          result.add(LoopRegion(
            kind: lkGeneric,
            startPC: target,
            endPC: pc,
            prepPC: -1,
            baseReg: 0,
            depth: 0,
            parent: -1
          ))
    else:
      discard

  # Second pass: compute nesting relationships
  # Sort by start PC (outer loops first), then by end PC descending (longer loops first)
  result.sort(proc(a, b: LoopRegion): int =
    let startCmp = cmp(a.startPC, b.startPC)
    if startCmp != 0:
      return startCmp
    return cmp(b.endPC, a.endPC)  # Descending for end PC
  )

  # Compute depth and parent relationships
  for i in 0 ..< result.len:
    for j in 0 ..< i:
      # Check if loop i is nested inside loop j
      if result[i].startPC > result[j].startPC and result[i].endPC <= result[j].endPC:
        if result[i].parent == -1 or result[j].startPC > result[result[i].parent].startPC:
          result[i].parent = j
          result[i].depth = result[j].depth + 1


proc writesRegister(instr: Instruction): Option[uint8] =
  ## Returns the register written by this instruction, if any
  case instr.op
  of opJmp, opTest, opReturn, opNoOp:
    return none(uint8)
  of opForPrep, opForIntPrep, opForLoop, opForIntLoop:
    # These write to multiple registers (a, a+1, a+2)
    return some(instr.a)
  else:
    return some(instr.a)


proc readsRegisters(instr: Instruction): seq[uint8] =
  ## Returns all registers read by this instruction
  result = @[]
  case instr.opType
  of ifmtABC:
    result.add(instr.b)
    if instr.c < 128:  # Not a constant
      result.add(instr.c)
  of ifmtABx:
    if instr.op in {opMove, opLoadK}:
      discard  # These don't read from registers
    else:
      # Most ABx instructions use the lower byte of bx as a register
      result.add(uint8(instr.bx and 0xFF))
  of ifmtAsBx:
    if instr.op in {opJmp}:
      discard  # Jump doesn't read registers
    elif instr.op in {opForLoop, opForIntLoop}:
      # ForLoop reads from a, a+1, a+2
      result.add(instr.a)
      result.add(instr.a + 1)
      result.add(instr.a + 2)
  of ifmtCall:
    # Function calls read all argument registers
    # For now, conservatively assume it reads many registers
    discard
  of ifmtAx:
    discard


proc buildDataFlowInfo(instructions: seq[InstructionEntry], loops: seq[LoopRegion]): DataFlowInfo =
  ## Build complete data-flow information for all loops
  result.defs = initTable[uint8, seq[RegisterDef]]()
  result.uses = initTable[uint8, seq[RegisterUse]]()
  result.liveIn = initTable[int, HashSet[uint8]]()
  result.liveOut = initTable[int, HashSet[uint8]]()
  result.loopInvariant = initTable[int, HashSet[int]]()
  result.loopCarried = initTable[int, Table[uint8, bool]]()

  # Build a map of PC -> loop depth
  var pcToDepth = initTable[int, int]()
  for loop in loops:
    for pc in loop.startPC .. loop.endPC:
      let currentDepth = pcToDepth.getOrDefault(pc, -1)
      pcToDepth[pc] = max(currentDepth, loop.depth)

  # Collect all defs and uses
  for pc, entry in instructions:
    let instr = entry.instr
    let depth = pcToDepth.getOrDefault(pc, 0)

    # Track definitions
    let writtenReg = writesRegister(instr)
    if writtenReg.isSome:
      let reg = writtenReg.get
      if not result.defs.hasKey(reg):
        result.defs[reg] = @[]
      result.defs[reg].add(RegisterDef(pc: pc, loopDepth: depth))

    # Track uses
    for reg in readsRegisters(instr):
      if not result.uses.hasKey(reg):
        result.uses[reg] = @[]
      result.uses[reg].add(RegisterUse(pc: pc, loopDepth: depth))

  # Analyze each loop
  for loop in loops:
    var invariantPCs = initHashSet[int]()
    var loopCarriedRegs = initTable[uint8, bool]()

    # Find loop-invariant instructions
    for pc in loop.startPC .. loop.endPC:
      let instr = instructions[pc].instr
      var isInvariant = true

      # Check if all inputs are invariant
      for reg in readsRegisters(instr):
        if result.defs.hasKey(reg):
          for def in result.defs[reg]:
            if def.pc >= loop.startPC and def.pc <= loop.endPC and def.pc != pc:
              isInvariant = false
              break

      if isInvariant:
        invariantPCs.incl(pc)

    result.loopInvariant[loop.startPC] = invariantPCs

    # Find loop-carried dependencies
    for reg in 0'u8 .. 255'u8:
      if not result.defs.hasKey(reg):
        continue

      var hasDefInLoop = false
      var hasUseAfterDef = false

      for def in result.defs[reg]:
        if def.pc >= loop.startPC and def.pc <= loop.endPC:
          hasDefInLoop = true
          # Check if there's a use of this register later in the loop
          if result.uses.hasKey(reg):
            for use in result.uses[reg]:
              if use.pc >= loop.startPC and use.pc <= loop.endPC and use.pc > def.pc:
                hasUseAfterDef = true
                break

      loopCarriedRegs[reg] = hasDefInLoop and hasUseAfterDef

    result.loopCarried[loop.startPC] = loopCarriedRegs


proc canHoistInstruction(pc: int, instr: Instruction, loop: LoopRegion,
                          dataFlow: DataFlowInfo): bool =
  ## Determine if an instruction can be safely hoisted out of the loop

  # Check if instruction is loop-invariant
  if not dataFlow.loopInvariant.hasKey(loop.startPC):
    return false
  if pc notin dataFlow.loopInvariant[loop.startPC]:
    return false

  # Don't hoist loop control instructions
  case instr.op
  of opForPrep, opForIntPrep, opForLoop, opForIntLoop:
    return false
  of opJmp, opTest, opTestSet, opTestTag, opCmpJmp, opCmpJmpInt, opCmpJmpFloat:
    return false
  else:
    discard

  # Don't hoist instructions with side effects
  case instr.op
  of opCall, opCallBuiltin, opCallHost, opCallFFI, opReturn:
    return false
  of opSetGlobal, opSetField, opSetIndex, opSetRef:
    return false
  else:
    discard

  # Check that the result register is not loop-carried
  let writtenReg = writesRegister(instr)
  if writtenReg.isSome:
    let reg = writtenReg.get
    if dataFlow.loopCarried.hasKey(loop.startPC):
      let carried = dataFlow.loopCarried[loop.startPC]
      if carried.hasKey(reg) and carried[reg]:
        return false

  return true


proc planLoopOptimizations(instructions: seq[InstructionEntry],
                           loops: seq[LoopRegion],
                           dataFlow: DataFlowInfo,
                           verbose: bool): GlobalOptimizationPlan =
  ## Create a global optimization plan for all loops at once
  result.removals = initHashSet[int]()
  result.insertions = initTable[int, seq[InstructionEntry]]()
  result.replacements = initTable[int, Instruction]()

  # Process loops from innermost to outermost
  var sortedLoops = loops
  sortedLoops.sort(proc(a, b: LoopRegion): int = cmp(b.depth, a.depth))

  for loop in sortedLoops:
    # Find instructions to hoist
    var toHoist: seq[tuple[pc: int, entry: InstructionEntry]] = @[]

    for pc in loop.startPC .. loop.endPC:
      if pc in result.removals:
        continue  # Already being removed

      let entry = instructions[pc]
      if canHoistInstruction(pc, entry.instr, loop, dataFlow):
        # Check if this register's value is actually used after the loop
        let writtenReg = writesRegister(entry.instr)
        if writtenReg.isSome:
          let reg = writtenReg.get
          var usedAfterLoop = false

          if dataFlow.uses.hasKey(reg):
            for use in dataFlow.uses[reg]:
              if use.pc > loop.endPC:
                usedAfterLoop = true
                break

          if usedAfterLoop or entry.instr.op == opLoadK:
            toHoist.add((pc, entry))

    if toHoist.len > 0:
      # Determine where to insert hoisted instructions
      let insertionPoint = if loop.prepPC >= 0: loop.prepPC else: loop.startPC

      if not result.insertions.hasKey(insertionPoint):
        result.insertions[insertionPoint] = @[]

      for (pc, entry) in toHoist:
        result.insertions[insertionPoint].add(entry)
        result.removals.incl(pc)
        logOptimizer(verbose, &"Planning to hoist instruction at PC {pc} to PC {insertionPoint}")


proc applyOptimizationPlan(instructions: seq[InstructionEntry],
                            plan: GlobalOptimizationPlan,
                            verbose: bool = false): seq[InstructionEntry] =
  ## Apply the global optimization plan to create the optimized instruction sequence
  result = @[]

  # Build PC mapping: old PC -> new PC
  var pcMapping = initTable[int, int]()
  var newPC = 0

  for pc, entry in instructions:
    # Account for insertions before this PC
    if plan.insertions.hasKey(pc):
      newPC += plan.insertions[pc].len

    # Skip removed instructions
    if pc in plan.removals:
      pcMapping[pc] = -1  # Mark as removed
      continue

    pcMapping[pc] = newPC
    newPC += 1

  if verbose:
    logOptimizer(true, "PC Mapping:")
    for oldPC, newPC in pcMapping:
      logOptimizer(true, &"  {oldPC} -> {newPC}")

  # Now build the result with adjusted jump offsets
  for pc, entry in instructions:
    # Insert hoisted instructions before this PC if needed
    if plan.insertions.hasKey(pc):
      for hoistedEntry in plan.insertions[pc]:
        result.add(hoistedEntry)

    # Skip removed instructions
    if pc in plan.removals:
      continue

    var newEntry = entry

    # Apply replacement if exists
    if plan.replacements.hasKey(pc):
      newEntry.instr = plan.replacements[pc]

    # Adjust jump offsets for jump instructions
    if newEntry.instr.opType == ifmtAsBx:
      let instr = newEntry.instr
      if instr.op in {opJmp, opForLoop, opForIntLoop, opForPrep, opForIntPrep}:
        # Calculate the old target PC
        let oldTargetPC = pc + 1 + int(instr.sbx)

        # Find the new target PC
        if pcMapping.hasKey(oldTargetPC):
          let newTargetPC = pcMapping[oldTargetPC]
          if newTargetPC >= 0:  # Target wasn't removed
            let currentNewPC = pcMapping[pc]
            let newOffset = newTargetPC - currentNewPC - 1
            var adjustedInstr = instr
            adjustedInstr.sbx = int16(newOffset)
            newEntry.instr = adjustedInstr

    result.add(newEntry)


proc optimizeLoops*(instructions: seq[InstructionEntry],
                    lifetimes: Table[uint8, LifetimeRange],
                    verbose: bool = false): seq[InstructionEntry] =
  ## Main entry point for properly designed loop optimization
  logOptimizer(verbose, "Starting loop optimization")

  discard lifetimes  # Not used yet, but keep for future

  # Step 1: Detect all loops and their nesting relationships
  let loops = detectAllLoops(instructions)
  if loops.len == 0:
    logOptimizer(verbose, "No loops found")
    return instructions

  logOptimizer(verbose, &"Detected {loops.len} loops")
  for i, loop in loops:
    logOptimizer(verbose, &"  Loop {i}: PC {loop.startPC}..{loop.endPC}, depth={loop.depth}, parent={loop.parent}")

  # Step 2: Build complete data-flow information
  let dataFlow = buildDataFlowInfo(instructions, loops)

  # Step 3: Create global optimization plan
  let plan = planLoopOptimizations(instructions, loops, dataFlow, verbose)

  if plan.removals.len == 0 and plan.insertions.len == 0:
    logOptimizer(verbose, "No optimizations planned")
    return instructions

  logOptimizer(verbose, &"Planned {plan.removals.len} removals, {plan.insertions.len} insertion points")

  # Step 4: Apply the plan in a single pass
  result = applyOptimizationPlan(instructions, plan, verbose)

  # Step 5: Convert generic ForPrep/ForLoop to integer-specialized variants
  for idx in 0 ..< result.len:
    var entry = result[idx]
    var instr = entry.instr
    if instr.op == opForPrep:
      instr.op = opForIntPrep
      entry.instr = instr
      result[idx] = entry
    elif instr.op == opForLoop:
      instr.op = opForIntLoop
      entry.instr = instr
      result[idx] = entry

  logOptimizer(verbose, &"Loop optimization complete: {instructions.len} -> {result.len} instructions")
