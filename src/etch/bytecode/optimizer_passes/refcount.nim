# refcount.nim

import std/[tables, sets, strformat]
import ../../common/logging
import ../../core/vm_types


type
  RefCountOp = object
    pc: int
    op: OpCode
    reg: uint8
    isInc: bool  # true for IncRef, false for DecRef

  OptimizationContext = object
    lifetimes: Table[uint8, LifetimeRange]
    refOps: seq[RefCountOp]
    moveOps: Table[int, tuple[dest: uint8, src: uint8]]  # pc -> (dest, src)
    toRemove: HashSet[int]  # PCs of instructions to remove


proc belongsToTrackedLifetime(ctx: OptimizationContext, reg: uint8, incPc, decPc: int): bool =
  ## Returns true when the register is tied to a tracked lifetime range that spans
  ## both the IncRef and the potential DecRef. These refs correspond to user
  ## variables (hoisted refs, defer locals, etc.) and must never be removed.
  if not ctx.lifetimes.hasKey(reg):
    return false

  let lifetime = ctx.lifetimes[reg]
  return lifetime.startPC <= incPc and decPc <= lifetime.endPC


proc analyzeRefCountOps(instructions: seq[InstructionEntry]): OptimizationContext =
  result.toRemove = initHashSet[int]()
  result.moveOps = initTable[int, tuple[dest: uint8, src: uint8]]()
  result.refOps = @[]

  for pc, entry in instructions:
    let instr = entry.instr
    case instr.op
    of opIncRef:
      result.refOps.add(RefCountOp(
        pc: pc,
        op: instr.op,
        reg: instr.a,
        isInc: true
      ))
    of opDecRef:
      result.refOps.add(RefCountOp(
        pc: pc,
        op: instr.op,
        reg: instr.a,
        isInc: false
      ))
    of opMove:
      # opMove uses ABC format (opType 0)
      if instr.opType == ifmtABC:
        result.moveOps[pc] = (dest: instr.a, src: instr.b)
    else:
      discard


proc findRedundantPairs(ctx: var OptimizationContext, instructions: seq[InstructionEntry], verbose: bool, isSafeCall: proc(idx: int, op: OpCode): bool = nil) =
  # Pattern: IncRef followed by DecRef on same register
  # Pattern: DecRef followed by IncRef on same register (less common but possible)

  var i = 0
  while i < instructions.len - 1:
    let curr = instructions[i].instr

    # Look ahead for matching operations
    if curr.op == opIncRef:
      # Search for corresponding DecRef
      var j = i + 1
      var foundIntervening = false

      while j < instructions.len and j < i + 20:  # Look ahead window
        let next = instructions[j].instr

        # First, check if ANY instruction reads or writes the register
        # This is the conservative approach - assume any access is a use
        var usesReg = (next.a == curr.a)
        if next.opType == ifmtABC:
          usesReg = usesReg or (next.b == curr.a) or (next.c == curr.a)
        elif next.opType == ifmtABx:
          # For ABx format, only check if lower 8 bits match (some instructions pack data there)
          let bReg = uint8(next.bx and 0xFF)
          usesReg = usesReg or (bReg == curr.a)

        if usesReg:
          # Check if this is a safe use that doesn't require the reference
          var isSafe = false

          # Special handling for opArg: check if it's passed to a safe function
          if next.op == opArg and isSafeCall != nil and next.a == curr.a:
             # Scan forward to find the consuming call
             var stackDepth = 1 # We are at the opArg, so it pushes 1
             var k = j + 1
             while k < instructions.len and k < j + 50: # Limit lookahead
               let future = instructions[k].instr
               if future.op == opArg:
                 stackDepth.inc
               elif future.op == opCall or future.op == opCallBuiltin:
                 if future.opType == ifmtCall:
                    stackDepth -= future.numArgs.int
                    if stackDepth <= 0:
                       # This is the consumer!
                       if isSafeCall(future.funcIdx.int, future.op):
                          isSafe = true
                          logOptimizer(verbose, &"Found safe use at PC {j} (call to {future.funcIdx})")
                       break
                 else:
                    break

               k.inc

          if not isSafe:
            logOptimizer(verbose, &"Found intervening use at PC {j} op={next.op} reg={curr.a}")
            foundIntervening = true
            break

        # Found matching DecRef
        if next.op == opDecRef and next.a == curr.a:
          if not foundIntervening:
            let hasAliasMove = i > 0 and instructions[i - 1].instr.op == opMove and instructions[i - 1].instr.a == curr.a
            if hasAliasMove:
              logOptimizer(verbose, &"Keeping refcount pair for aliased move into R[{curr.a}]")
            elif ctx.belongsToTrackedLifetime(curr.a, i, j):
              let lifetime = ctx.lifetimes[curr.a]
              logOptimizer(verbose, &"Keeping refcount pair for tracked lifetime reg R[{curr.a}] ({lifetime.varName})")
            else:
              # Redundant pair - can eliminate both
              ctx.toRemove.incl(i)
              ctx.toRemove.incl(j)
          break

        inc j

    elif curr.op == opDecRef:
      # Check for DecRef + Move + IncRef pattern (common in assignments)
      if i + 2 < instructions.len:
        let move = instructions[i + 1].instr
        let inc = instructions[i + 2].instr

        if move.op == opMove and move.opType == ifmtABC and inc.op == opIncRef:
          # Check if DecRef and IncRef target same register (destination of move)
          if curr.a == move.a and inc.a == move.a:
            # This is: DecRef dest, Move dest src, IncRef dest
            # If src is at its last use, this can become just: Move dest src
            # For now, we keep the IncRef but eliminate the DecRef+IncRef if they cancel
            # We'll handle move semantics in a separate pass
            discard

    inc i


proc eliminateDeadDecRefs(ctx: var OptimizationContext, instructions: seq[InstructionEntry],
                          lifetimes: Table[uint8, LifetimeRange]) =
  # DecRef operations on registers that are immediately overwritten are redundant

  for i in 0..<instructions.len - 1:
    let curr = instructions[i].instr
    if curr.op != opDecRef:
      continue

    # Check if next instruction overwrites this register with a non-ref value
    discard instructions[i + 1]  # TODO: implement dead DecRef elimination

    # If the next instruction writes nil or a non-ref value to this register,
    # the DecRef is still needed to free the old value before overwriting
    # So we can't eliminate it in most cases

    # However, if the register is about to be freed (goes out of scope),
    # and there's a DecRef right before it, that's handled by normal scope exit


proc applyMoveSemantics(ctx: var OptimizationContext, instructions: seq[InstructionEntry],
                        lifetimes: Table[uint8, LifetimeRange]) =
  # Pattern: DecRef R[dest], Move R[dest] R[src], IncRef R[dest]
  # If R[src] is at its last use, optimize to: Move R[dest] R[src]
  # This transfers ownership instead of incrementing and decrementing

  for i in 0..<instructions.len - 2:
    if i in ctx.toRemove:
      continue

    let decr = instructions[i].instr
    let move = instructions[i + 1].instr
    let incr = instructions[i + 2].instr

    if decr.op == opDecRef and move.op == opMove and move.opType == ifmtABC and incr.op == opIncRef:
      # Check if this matches the pattern
      if decr.a == move.a and incr.a == move.a:
        let srcReg = move.b

        # Check if srcReg is at or near its last use
        if lifetimes.hasKey(srcReg):
          let lifetime = lifetimes[srcReg]

          # If this is close to the last use, we can transfer ownership
          # Allow a small window (10 instructions) to account for imprecision
          if i >= lifetime.lastUsePC - 10 and i <= lifetime.lastUsePC + 10:
            # Move semantics: eliminate DecRef and IncRef, keep just Move
            ctx.toRemove.incl(i)      # Remove DecRef
            ctx.toRemove.incl(i + 2)  # Remove IncRef
            # Keep the Move instruction


proc optimizeRefCounting*(instructions: seq[InstructionEntry], lifetimes: Table[uint8, LifetimeRange], verbose: bool = false, isSafeCall: proc(idx: int, op: OpCode): bool = nil): seq[InstructionEntry] =
  logOptimizer(verbose, "Starting ref count optimization pass")

  var ctx = analyzeRefCountOps(instructions)
  ctx.lifetimes = lifetimes

  logOptimizer(verbose, &"Analyzing {instructions.len} instructions, {ctx.refOps.len} ref ops")

  # Apply optimization passes
  findRedundantPairs(ctx, instructions, verbose, isSafeCall)
  eliminateDeadDecRefs(ctx, instructions, lifetimes)
  applyMoveSemantics(ctx, instructions, lifetimes)

  # Rebuild instruction sequence without removed instructions
  result = @[]
  for i, entry in instructions:
    if i notin ctx.toRemove:
      result.add(entry)

  # Report optimization results
  if ctx.toRemove.len > 0:
    logOptimizer(verbose, &"Eliminated {ctx.toRemove.len} redundant ref count operations")
  else:
    logOptimizer(verbose, "No ref count optimizations found")
