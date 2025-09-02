proc compileIfStatement(c: var Compiler, s: Statement) =
  if c.verbose:
    logCompiler(c.verbose, "Compiling if statement")
    logCompiler(c.verbose, &"   Then body len = {s.thenBody.len}")
    logCompiler(c.verbose, &"   Else body len = {s.elseBody.len}")
    if s.elseBody.len > 0:
      logCompiler(c.verbose, &"   First else body statement: {s.elseBody[0].kind}")
      if s.elseBody[0].kind == skIf:
        logCompiler(c.verbose, "   Detected elif chain")
  var jmpPos: int

  # Special handling for comparison conditions
  if s.cond.kind == ekBin and s.cond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
    let leftReg = c.compileExpression(s.cond.lhs)
    let rightReg = c.compileExpression(s.cond.rhs)
    let debugInfo = c.makeDebugInfo(s.pos)

    # Use fused opCmpJmp
    # We jump if condition is FALSE (inverted logic)
    var cmpType: int = case s.cond.bop:
      of boEq: 1 # Ne
      of boNe: 0 # Eq
      of boLt: 5 # Ge
      of boLe: 4 # Gt
      of boGt: 3 # Le
      of boGe: 2 # Lt
      else: -1

    # Check types for specialization
    let leftTyp = s.cond.lhs.typ
    let rightTyp = s.cond.rhs.typ
    let useIntOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkInt and rightTyp.kind == tkInt
    let useFloatOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkFloat and rightTyp.kind == tkFloat
    let opcode = if useIntOps: opCmpJmpInt elif useFloatOps: opCmpJmpFloat else: opCmpJmp

    # Emit opCmpJmp
    # A = cmpType
    # Ax = [Offset:16][C:8][B:8]
    # We don't know offset yet, set to 0
    let encoded = (uint32(rightReg) shl 8) or uint32(leftReg)
    c.prog.emitAx(opcode, uint8(cmpType), encoded, debugInfo)
    jmpPos = c.prog.instructions.len - 1

    c.allocator.freeReg(leftReg)
    c.allocator.freeReg(rightReg)
  else:
    # General expression condition
    let condReg = c.compileExpression(s.cond)
    c.prog.emitABC(opTest, condReg, 0, 0, c.makeDebugInfo(s.pos))
    jmpPos = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(s.pos))  # Placeholder jump
    c.allocator.freeReg(condReg)

  # Then branch
  for stmt in s.thenBody:
    c.compileStatement(stmt)

  # We need to jump over elif/else blocks after executing then branch
  var jumpToEndPositions: seq[int] = @[]
  if s.elifChain.len > 0 or s.elseBody.len > 0:
    let jumpPos = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(s.pos))  # Jump to end after then branch
    jumpToEndPositions.add(jumpPos)

  # Patch first condition's false jump to here (start of elif chain or else)
  let offset = int16(c.prog.instructions.len - jmpPos - 1)
  if c.prog.instructions[jmpPos].op in {opCmpJmp, opCmpJmpInt, opCmpJmpFloat}:
    let currentAx = c.prog.instructions[jmpPos].ax
    c.prog.instructions[jmpPos].ax = (currentAx and 0xFFFF) or (uint32(offset) shl 16)
  else:
    c.prog.instructions[jmpPos].sbx = offset

  # Compile elif chain
  for elifClause in s.elifChain:
    logCompiler(c.verbose, "Compiling elif clause")

    # Compile elif condition
    var elifJmpPos: int
    if elifClause.cond.kind == ekBin and elifClause.cond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
      let leftReg = c.compileExpression(elifClause.cond.lhs)
      let rightReg = c.compileExpression(elifClause.cond.rhs)
      let debugInfo = c.makeDebugInfo(elifClause.cond.pos)

      # Use fused opCmpJmp
      var cmpType: int = case elifClause.cond.bop:
        of boEq: 1 # Ne
        of boNe: 0 # Eq
        of boLt: 5 # Ge
        of boLe: 4 # Gt
        of boGt: 3 # Le
        of boGe: 2 # Lt
        else: -1

      # Check types for specialization
      let leftTyp = elifClause.cond.lhs.typ
      let rightTyp = elifClause.cond.rhs.typ
      let useIntOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkInt and rightTyp.kind == tkInt
      let useFloatOps = leftTyp != nil and rightTyp != nil and leftTyp.kind == tkFloat and rightTyp.kind == tkFloat
      let opcode = if useIntOps: opCmpJmpInt elif useFloatOps: opCmpJmpFloat else: opCmpJmp

      let encoded = (uint32(rightReg) shl 8) or uint32(leftReg)
      c.prog.emitAx(opcode, uint8(cmpType), encoded, debugInfo)
      elifJmpPos = c.prog.instructions.len - 1

      c.allocator.freeReg(leftReg)
      c.allocator.freeReg(rightReg)
    else:
      # General expression condition
      let condReg = c.compileExpression(elifClause.cond)
      c.prog.emitABC(opTest, condReg, 0, 0, c.makeDebugInfo(elifClause.cond.pos))
      c.allocator.freeReg(condReg)

      # Jump to next elif/else if condition is false
      elifJmpPos = c.prog.instructions.len
      c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(elifClause.cond.pos))

    # Compile elif body
    for stmt in elifClause.body:
      c.compileStatement(stmt)

    # Jump to end after elif body
    let jumpPos = c.prog.instructions.len
    c.prog.emitAsBx(opJmp, 0, 0, c.makeDebugInfo(elifClause.cond.pos))
    jumpToEndPositions.add(jumpPos)

    # Patch elif condition jump to here (next elif or else)
    let offset = int16(c.prog.instructions.len - elifJmpPos - 1)
    if c.prog.instructions[elifJmpPos].op in {opCmpJmp, opCmpJmpInt, opCmpJmpFloat}:
      let currentAx = c.prog.instructions[elifJmpPos].ax
      c.prog.instructions[elifJmpPos].ax = (currentAx and 0xFFFF) or (uint32(offset) shl 16)
    else:
      c.prog.instructions[elifJmpPos].sbx = offset

  # Compile else branch if present
  if s.elseBody.len > 0:
    logCompiler(c.verbose, &"Compiling else branch with {s.elseBody.len} statements")
    for stmt in s.elseBody:
      logCompiler(c.verbose, &"  Else body statement: {stmt.kind}")
      c.compileStatement(stmt)

  # Patch all jumps to end
  for jumpPos in jumpToEndPositions:
    c.prog.instructions[jumpPos].sbx =
      int16(c.prog.instructions.len - jumpPos - 1)
