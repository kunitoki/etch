# regcompiler.nim
# Register-based bytecode compiler with aggressive optimizations

import std/[tables, options, strutils]
import ../frontend/ast
import ../common/types
import regvm
import regvm_lifetime


type
  RegCompiler* = object
    prog*: RegBytecodeProgram
    allocator*: RegAllocator
    constMap*: Table[string, uint16]  # Constant string to index map
    loopStack*: seq[LoopInfo]
    optimizeLevel*: int               # 0=none, 1=basic, 2=aggressive
    verbose*: bool                    # Enable debug output
    debug*: bool                      # Include debug info in bytecode
    funInstances*: Table[string, FunDecl]  # Function declarations for default params
    lifetimeTracker*: LifetimeTracker  # Track variable lifetimes for debugging and destructors

  LoopInfo = object
    startLabel*: int
    continueLabel*: int
    breakJumps*: seq[int]     # Positions of break jumps to patch
    loopVar*: uint8           # Register holding loop variable

# Helper to add constants
proc addConst*(c: var RegCompiler, val: regvm.V): uint16 =
  # Check if constant already exists (constant folding)
  for i, existing in c.prog.constants:
    let existingTag = regvm.getTag(existing)
    let valTag = regvm.getTag(val)

    if existingTag == valTag:
      case valTag:
      of regvm.TAG_STRING:
        if existing.sval == val.sval:
          return uint16(i)
      of regvm.TAG_FLOAT:
        if existing.fval == val.fval:
          return uint16(i)
      of regvm.TAG_INT:
        if existing.ival == val.ival:
          return uint16(i)
      of regvm.TAG_BOOL, regvm.TAG_NIL, regvm.TAG_CHAR:
        if existing.data == val.data:
          return uint16(i)
      else:
        discard

  c.prog.constants.add(val)
  return uint16(c.prog.constants.len - 1)

proc addStringConst*(c: var RegCompiler, s: string): uint16 =
  if c.constMap.hasKey(s):
    if c.verbose:
      echo "[REGCOMPILER] String '", s, "' already in const pool at index ", c.constMap[s]
    return c.constMap[s]

  var v: regvm.V
  v.data = TAG_STRING shl 48
  v.sval = s
  result = c.addConst(v)
  c.constMap[s] = result
  if c.verbose:
    echo "[REGCOMPILER] Added string '", s, "' to const pool at index ", result

# Forward declarations
proc compileExpr*(c: var RegCompiler, e: Expr): uint8
proc compileStmt*(c: var RegCompiler, s: Stmt)
proc compileBinOp(c: var RegCompiler, op: BinOp, dest, left, right: uint8, debug: RegDebugInfo = RegDebugInfo())
proc compileCall(c: var RegCompiler, e: Expr): uint8
proc optimizeBytecode*(prog: var RegBytecodeProgram)

proc makeDebugInfo(c: RegCompiler, pos: Pos): RegDebugInfo =
  ## Create debug info from AST position (only if debug mode enabled)
  if c.debug:
    result = RegDebugInfo(
      line: pos.line,
      col: pos.col,
      sourceFile: pos.filename
    )
  else:
    result = RegDebugInfo()  # Empty debug info in release mode
  when defined(debugRegCompiler):
    echo "[DEBUG] makeDebugInfo: line=", pos.line, " col=", pos.col, " file=", pos.filename

# Pattern matching for instruction fusion
proc tryFuseArithmetic(c: var RegCompiler, e: Expr): bool =
  ## Try to generate fused arithmetic instructions
  if e.kind != ekBin:
    return false

  # Pattern: (a + b) + c -> AddAdd
  if e.bop == boAdd and e.lhs.kind == ekBin and e.lhs.bop == boAdd:
    let destReg = c.allocator.allocReg()
    var aReg, bReg, cReg: uint8

    # Compile subexpressions to registers
    aReg = c.compileExpr(e.lhs.lhs)
    bReg = c.compileExpr(e.lhs.rhs)
    cReg = c.compileExpr(e.rhs)

    c.prog.instructions.add RegInstruction(
      op: ropAddAdd,
      a: destReg,
      opType: 3,  # Special format for 4 operands
      ax: uint32(aReg) or (uint32(bReg) shl 8) or (uint32(cReg) shl 16)
    )
    return true

  # Pattern: a * b + c -> MulAdd
  if e.bop == boAdd and e.lhs.kind == ekBin and e.lhs.bop == boMul:
    let destReg = c.allocator.allocReg()
    let aReg = c.compileExpr(e.lhs.lhs)
    let bReg = c.compileExpr(e.lhs.rhs)
    let cReg = c.compileExpr(e.rhs)

    c.prog.instructions.add RegInstruction(
      op: ropMulAdd,
      a: destReg,
      opType: 3,
      ax: uint32(aReg) or (uint32(bReg) shl 8) or (uint32(cReg) shl 16)
    )
    return true

  return false

proc compileExpr*(c: var RegCompiler, e: Expr): uint8 =
  ## Compile expression to register, return register number

  # Try instruction fusion first (if optimization enabled)
  if c.optimizeLevel >= 2 and c.tryFuseArithmetic(e):
    return c.allocator.nextReg - 1  # Fusion already allocated result

  case e.kind:
  of ekInt:
    result = c.allocator.allocReg()
    if c.verbose:
      echo "[REGCOMPILER] Compiling integer ", e.ival, " to reg ", result
    if e.ival >= -32768 and e.ival <= 32767:
      # Small integer - can use immediate encoding
      c.prog.emitAsBx(ropLoadK, result, int16(e.ival), c.makeDebugInfo(e.pos))
    else:
      # Large integer - need constant pool
      let constIdx = c.addConst(regvm.makeInt(e.ival))
      c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))

  of ekFloat:
    result = c.allocator.allocReg()
    let constIdx = c.addConst(regvm.makeFloat(e.fval))
    c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))

  of ekString:
    result = c.allocator.allocReg()
    if c.verbose:
      echo "[REGCOMPILER] Compiling string expression: '", e.sval, "'"
    let constIdx = c.addStringConst(e.sval)
    c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))
    if c.verbose:
      echo "[REGCOMPILER]   Loaded to register ", result, " from const[", constIdx, "]"

  of ekBool:
    result = c.allocator.allocReg()
    c.prog.emitABC(ropLoadBool, result, if e.bval: 1 else: 0, 0, c.makeDebugInfo(e.pos))

  of ekNil:
    result = c.allocator.allocReg()
    c.prog.emitABC(ropLoadNil, result, result, 0, c.makeDebugInfo(e.pos))  # Load nil to single register

  of ekCast:
    # Compile the expression to cast
    let exprReg = c.compileExpr(e.castExpr)
    result = c.allocator.allocReg()

    # Determine cast type code
    let castTypeCode = case e.castType.kind:
      of tkInt: 1
      of tkFloat: 2
      of tkString: 3
      else: 0

    # Emit cast instruction (using ropCast - we'll need to implement this)
    c.prog.emitABC(ropCast, result, exprReg, uint8(castTypeCode), c.makeDebugInfo(e.pos))
    c.allocator.freeReg(exprReg)

  of ekChar:
    result = c.allocator.allocReg()
    # Create a character constant
    let constIdx = c.addConst(regvm.makeChar(e.cval))
    c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))

  of ekVar:
    # Track variable use for lifetime analysis
    let currentPC = c.prog.instructions.len
    c.lifetimeTracker.useVariable(e.vname, currentPC)

    # Check if variable already in register
    if c.allocator.regMap.hasKey(e.vname):
      if c.verbose:
        echo "[REGCOMPILER] Variable '", e.vname, "' found in register ", c.allocator.regMap[e.vname]
      return c.allocator.regMap[e.vname]
    else:
      # Load from global
      if c.verbose:
        echo "[REGCOMPILER] Variable '", e.vname, "' not in regMap, loading from global"
      result = c.allocator.allocReg(e.vname)
      let nameIdx = c.addStringConst(e.vname)
      c.prog.emitABx(ropGetGlobal, result, nameIdx, c.makeDebugInfo(e.pos))

  of ekBin:
    let leftReg = c.compileExpr(e.lhs)
    let rightReg = c.compileExpr(e.rhs)
    result = c.allocator.allocReg()
    if c.verbose:
      echo "[REGCOMPILER] Binary op: leftReg=", leftReg, " rightReg=", rightReg, " resultReg=", result

    # Check for immediate optimizations
    if c.optimizeLevel >= 1 and e.rhs.kind == ekInt and
       e.rhs.ival >= -128 and e.rhs.ival <= 127:
      # Can use immediate version
      case e.bop:
      of boAdd:
        c.prog.emitABx(ropAddI, result, uint16(leftReg) or (uint16(e.rhs.ival) shl 8), c.makeDebugInfo(e.pos))
      of boSub:
        c.prog.emitABx(ropSubI, result, uint16(leftReg) or (uint16(e.rhs.ival) shl 8), c.makeDebugInfo(e.pos))
      of boMul:
        c.prog.emitABx(ropMulI, result, uint16(leftReg) or (uint16(e.rhs.ival) shl 8), c.makeDebugInfo(e.pos))
      else:
        # Fall back to regular instruction
        c.compileBinOp(e.bop, result, leftReg, rightReg, c.makeDebugInfo(e.pos))
    else:
      c.compileBinOp(e.bop, result, leftReg, rightReg, c.makeDebugInfo(e.pos))

    # Free temporary registers if they're not named variables
    if e.lhs.kind != ekVar:
      c.allocator.freeReg(leftReg)
    if e.rhs.kind != ekVar:
      c.allocator.freeReg(rightReg)

  of ekUn:
    let operandReg = c.compileExpr(e.ue)
    result = c.allocator.allocReg()

    let debug = c.makeDebugInfo(e.pos)
    case e.uop:
    of uoNeg:
      c.prog.emitABC(ropUnm, result, operandReg, 0, debug)
    of uoNot:
      c.prog.emitABC(ropNot, result, operandReg, 0, debug)

  of ekCall:
    result = c.compileCall(e)

  of ekArray:
    result = c.allocator.allocReg()
    if c.verbose:
      echo "[REGCOMPILER] Array expression allocated reg ", result
    c.prog.emitABx(ropNewArray, result, uint16(e.elements.len), c.makeDebugInfo(e.pos))

    # Set array elements
    for i, elem in e.elements:
      let elemReg = c.compileExpr(elem)
      # For now, always use the general SetIndex instruction
      # TODO: Optimize with immediate index using different encoding
      let idxReg = c.allocator.allocReg()
      let constIdx = c.addConst(regvm.makeInt(int64(i)))
      c.prog.emitABx(ropLoadK, idxReg, constIdx, c.makeDebugInfo(e.pos))
      c.prog.emitABC(ropSetIndex, result, idxReg, elemReg, c.makeDebugInfo(e.pos))
      c.allocator.freeReg(idxReg)
      c.allocator.freeReg(elemReg)

  of ekIndex:
    let arrReg = c.compileExpr(e.arrayExpr)
    result = c.allocator.allocReg()

    # Optimize for constant integer indices
    if c.optimizeLevel >= 1 and e.indexExpr.kind == ekInt and
       e.indexExpr.ival >= 0 and e.indexExpr.ival < 256:
      c.prog.emitABx(ropGetIndexI, result,
                      uint16(arrReg) or (uint16(e.indexExpr.ival) shl 8), c.makeDebugInfo(e.pos))
    else:
      let idxReg = c.compileExpr(e.indexExpr)
      c.prog.emitABC(ropGetIndex, result, arrReg, idxReg, c.makeDebugInfo(e.pos))

  of ekSlice:
    # Handle array/string slicing: arr[start:end]
    if c.verbose:
      echo "[REGCOMPILER] Compiling slice expression"

    let arrReg = c.compileExpr(e.sliceExpr)

    # Handle optional start index
    let startReg = if e.startExpr.isSome():
      c.compileExpr(e.startExpr.get())
    else:
      # No start index specified, use 0
      let reg = c.allocator.allocReg()
      c.prog.emitAsBx(ropLoadK, reg, 0)
      reg

    # The ropSlice instruction expects the end index in the register right after start
    # So we need to ensure proper register allocation
    let endReg = c.allocator.allocReg()

    # Compile the end expression into the allocated register
    if e.endExpr.isSome():
      let tempEndReg = c.compileExpr(e.endExpr.get())
      if tempEndReg != endReg:
        # Move to the expected position if necessary
        c.prog.emitABC(ropMove, endReg, tempEndReg, 0)
        c.allocator.freeReg(tempEndReg)
    else:
      # No end index specified, use -1 to indicate "until end"
      c.prog.emitAsBx(ropLoadK, endReg, -1)

    result = c.allocator.allocReg()
    # ropSlice expects: R[A] = R[B][R[C]:R[C+1]]
    c.prog.emitABC(ropSlice, result, arrReg, startReg, c.makeDebugInfo(e.pos))

    # Clean up registers
    c.allocator.freeReg(endReg)
    c.allocator.freeReg(startReg)
    c.allocator.freeReg(arrReg)

  of ekArrayLen:
    # Handle array/string length: #arr
    let arrReg = c.compileExpr(e.lenExpr)
    result = c.allocator.allocReg()
    c.prog.emitABC(ropLen, result, arrReg, 0, c.makeDebugInfo(e.pos))
    c.allocator.freeReg(arrReg)

  of ekNewRef:
    # Handle new(value) for creating references
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekNewRef expression"
    # Compile the init expression
    let initReg = c.compileExpr(e.init)

    # Allocate result register
    result = c.allocator.allocReg()

    # Load "new" function name
    let nameIdx = c.addStringConst("new")
    c.prog.emitABx(ropLoadK, result, nameIdx)

    # Set up argument in next register
    if initReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, initReg, 0)
      c.allocator.freeReg(initReg)

    # Call new function
    c.prog.emitABC(ropCall, result, 1, 1)  # 1 arg, 1 result

  of ekDeref:
    # Handle deref(ref) for dereferencing
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekDeref expression"
    # Compile the ref expression
    let refReg = c.compileExpr(e.refExpr)

    # Allocate result register
    result = c.allocator.allocReg()

    # Load "deref" function name
    let nameIdx = c.addStringConst("deref")
    c.prog.emitABx(ropLoadK, result, nameIdx)

    # Set up argument in next register
    if refReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, refReg, 0)
      c.allocator.freeReg(refReg)

    # Call deref function
    c.prog.emitABC(ropCall, result, 1, 1)  # 1 arg, 1 result

  of ekNew:
    # Handle new for heap allocation (similar to ekNewRef)
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekNew expression"
    # If there's an init expression, compile it
    if e.initExpr.isSome:
      let initReg = c.compileExpr(e.initExpr.get)

      # Allocate result register
      result = c.allocator.allocReg()

      # Load "new" function name
      let nameIdx = c.addStringConst("new")
      c.prog.emitABx(ropLoadK, result, nameIdx)

      # Set up argument in next register
      if initReg != result + 1:
        c.prog.emitABC(ropMove, result + 1, initReg, 0)
        c.allocator.freeReg(initReg)

      # Call new function
      c.prog.emitABC(ropCall, result, 1, 1)  # 1 arg, 1 result
    else:
      # No init expression - just return nil for now
      result = c.allocator.allocReg()
      c.prog.emitABC(ropLoadNil, result, result, 0)

  of ekOptionSome:
    # Handle some(value) for option types
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekOptionSome expression"
    # Compile the inner value first
    let innerReg = c.compileExpr(e.someExpr)
    result = c.allocator.allocReg()
    # Wrap it as Some
    c.prog.emitABC(ropWrapSome, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekOptionNone:
    # Handle none for option types
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekOptionNone expression"
    result = c.allocator.allocReg()
    # Create a None value
    c.prog.emitABC(ropLoadNone, result, 0, 0, c.makeDebugInfo(e.pos))

  of ekResultOk:
    # Handle ok(value) for result types
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekResultOk expression"
    # Compile the inner value first
    let innerReg = c.compileExpr(e.okExpr)
    result = c.allocator.allocReg()
    # Wrap it as Ok
    c.prog.emitABC(ropWrapOk, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekResultErr:
    # Handle error(msg) for result types
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekResultErr expression"
    # Compile the error message first
    let innerReg = c.compileExpr(e.errExpr)
    result = c.allocator.allocReg()
    # Wrap it as Err
    c.prog.emitABC(ropWrapErr, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekMatch:
    # Handle match expressions properly
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekMatch expression"

    # Compile the expression to match against
    let matchReg = c.compileExpr(e.matchExpr)
    result = c.allocator.allocReg()

    var jumpToEndPositions: seq[int] = @[]

    # Compile each case
    for i, matchCase in e.cases:
      if c.verbose:
        echo "[REGCOMPILER]   Compiling match case ", i, " pattern: ", matchCase.pattern.kind

      # Pattern matching - simplified version
      var shouldJumpToNext = -1

      case matchCase.pattern.kind:
      of pkSome:
        # Check if it's a Some value
        # ropTestTag: skips next if tags MATCH
        # So if tag is Some, skip the jump and execute case body
        # If tag is not Some, execute jump to next case
        c.prog.emitABC(ropTestTag, matchReg, TAG_SOME.uint8, 0, c.makeDebugInfo(e.pos))  # Test if tag is Some
        if c.verbose:
          echo "[REGCOMPILER]   Emitted ropTestTag for Some at PC=", c.prog.instructions.len - 1
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if not Some

        # Extract the value if it's Some
        if matchCase.pattern.bindName != "":
          # Unwrap the Some value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapOption, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg
          if c.verbose:
            echo "[REGCOMPILER]   Bound Some pattern variable '", matchCase.pattern.bindName, "' to unwrapped reg ", unwrappedReg

      of pkNone:
        # Check if it's None
        c.prog.emitABC(ropTestTag, matchReg, TAG_NONE.uint8, 0, c.makeDebugInfo(e.pos))  # Test if tag is None
        if c.verbose:
          echo "[REGCOMPILER]   Emitted ropTestTag for None at PC=", c.prog.instructions.len - 1
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if not None
        if c.verbose:
          echo "[REGCOMPILER]   Emitted ropJmp at PC=", c.prog.instructions.len - 1, " (will be patched)"

      of pkOk:
        # Check if it's an Ok value
        c.prog.emitABC(ropTestTag, matchReg, TAG_OK.uint8, 0, c.makeDebugInfo(e.pos))  # Test if tag is Ok
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))

        if matchCase.pattern.bindName != "":
          # Unwrap the Ok value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkErr:
        # Check if it's an Err value
        c.prog.emitABC(ropTestTag, matchReg, TAG_ERR.uint8, 0, c.makeDebugInfo(e.pos))  # Test if tag is Err
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))

        if matchCase.pattern.bindName != "":
          # Unwrap the Err value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkWildcard:
        # Wildcard always matches - no test needed
        discard

      of pkType:
        # Type pattern matching (for union types)
        # Check if the value has the correct type tag
        if c.verbose:
          echo "[REGCOMPILER]   Type pattern: ", $matchCase.pattern.typePattern.kind, " bind: ", matchCase.pattern.typeBind

        # Determine the tag for the type
        let expectedTag = case matchCase.pattern.typePattern.kind:
          of tkInt: TAG_INT
          of tkFloat: TAG_FLOAT
          of tkBool: TAG_BOOL
          of tkChar: TAG_CHAR
          of tkString: TAG_STRING
          of tkArray: TAG_ARRAY
          of tkObject: TAG_TABLE
          of tkUserDefined: TAG_TABLE  # User-defined types are objects (tables)
          else:
            if c.verbose:
              echo "[REGCOMPILER]   Warning: Unsupported type for pattern matching: ", $matchCase.pattern.typePattern.kind
            TAG_NIL

        # Test if the tag matches
        c.prog.emitABC(ropTestTag, matchReg, expectedTag.uint8, 0, c.makeDebugInfo(e.pos))
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if tag doesn't match

        # Bind the value if there's a binding variable
        if matchCase.pattern.typeBind != "":
          # The value is already in matchReg, just bind it
          c.allocator.regMap[matchCase.pattern.typeBind] = matchReg
          if c.verbose:
            echo "[REGCOMPILER]   Bound type pattern variable '", matchCase.pattern.typeBind, "' to reg ", matchReg

      # Compile the case body
      if matchCase.body.len > 0:
        if c.verbose:
          echo "[REGCOMPILER]   Match case body has ", matchCase.body.len, " statements"
          for idx, stmt in matchCase.body:
            echo "[REGCOMPILER]     Body stmt ", idx, " kind: ", stmt.kind
            if stmt.kind == skExpr:
              echo "[REGCOMPILER]       Expr kind: ", stmt.sexpr.kind

        # For match expressions, the body is typically a single expression statement
        # that should be the result of the match
        if matchCase.body.len == 1 and matchCase.body[0].kind == skExpr:
          # Single expression - this is the result
          if c.verbose:
            echo "[REGCOMPILER]   Case body starts at PC=", c.prog.instructions.len
          let exprReg = c.compileExpr(matchCase.body[0].sexpr)
          if c.verbose:
            echo "[REGCOMPILER]   Match case body expr compiled to reg ", exprReg, ", result reg is ", result
          if exprReg != result:
            c.prog.emitABC(ropMove, result, exprReg, 0)
            if c.verbose:
              echo "[REGCOMPILER]   Emitted ropMove from ", exprReg, " to ", result, " at PC=", c.prog.instructions.len - 1
            c.allocator.freeReg(exprReg)
        else:
          # Multiple statements - compile all but last, then last is result
          for stmt in matchCase.body[0..^2]:
            c.compileStmt(stmt)

          # Last statement is the result
          if matchCase.body[^1].kind == skExpr:
            let exprReg = c.compileExpr(matchCase.body[^1].sexpr)
            if exprReg != result:
              c.prog.emitABC(ropMove, result, exprReg, 0)
              c.allocator.freeReg(exprReg)
          else:
            c.compileStmt(matchCase.body[^1])

      # Jump to end after executing this case
      if i < e.cases.len - 1:  # Not the last case
        let jumpPos = c.prog.instructions.len
        # Use the match expression position for the jump
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))
        jumpToEndPositions.add(jumpPos)

      # Patch the jump to next case
      if shouldJumpToNext >= 0:
        c.prog.instructions[shouldJumpToNext].sbx =
          int16(c.prog.instructions.len - shouldJumpToNext - 1)

    # Patch all jumps to end
    for jumpPos in jumpToEndPositions:
      c.prog.instructions[jumpPos].sbx =
        int16(c.prog.instructions.len - jumpPos - 1)

    c.allocator.freeReg(matchReg)

  of ekObjectLiteral:
    # Handle object literal creation
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekObjectLiteral expression with ", e.fieldInits.len, " fields"
    result = c.allocator.allocReg()

    # Create a new table
    c.prog.emitABC(ropNewTable, result, 0, 0, c.makeDebugInfo(e.pos))

    # Collect provided field names
    var providedFields: seq[string] = @[]
    for fieldInit in e.fieldInits:
      providedFields.add(fieldInit.name)

    # Set each provided field
    for fieldInit in e.fieldInits:
      let fieldName = fieldInit.name
      let fieldExpr = fieldInit.value
      # Compile the field value
      let valueReg = c.compileExpr(fieldExpr)

      # Add field name to constants if not already there
      let fieldConstIdx = c.addStringConst(fieldName)

      # Emit ropSetField: R[tableReg][K[fieldConstIdx]] = R[valueReg]
      c.prog.emitABC(ropSetField, valueReg, result, uint8(fieldConstIdx))

      # Free the value register
      c.allocator.freeReg(valueReg)

      if c.verbose:
        echo "[REGCOMPILER] Set field '", fieldName, "' (const[", fieldConstIdx, "]) = reg ", valueReg

    # Add default values for missing fields
    if e.objectType != nil and e.objectType.kind == tkObject:
      for field in e.objectType.fields:
        if field.name notin providedFields and field.defaultValue.isSome:
          if c.verbose:
            echo "[REGCOMPILER] Adding default value for field '", field.name, "'"

          # Compile the default value expression
          let defaultExpr = field.defaultValue.get
          let valueReg = c.compileExpr(defaultExpr)

          # Add field name to constants
          let fieldConstIdx = c.addStringConst(field.name)

          # Set the default value
          c.prog.emitABC(ropSetField, valueReg, result, uint8(fieldConstIdx))

          # Free the value register
          c.allocator.freeReg(valueReg)

          if c.verbose:
            echo "[REGCOMPILER] Set default field '", field.name, "' (const[", fieldConstIdx, "]) = reg ", valueReg

  of ekFieldAccess:
    # Handle field access on objects
    if c.verbose:
      echo "[REGCOMPILER] Compiling ekFieldAccess expression: field '", e.fieldName, "'"

    # Compile the object expression
    let objReg = c.compileExpr(e.objectExpr)
    result = c.allocator.allocReg()

    # Add field name to constants if not already there
    let fieldConstIdx = c.addStringConst(e.fieldName)

    # Emit ropGetField: R[result] = R[objReg][K[fieldConstIdx]]
    c.prog.emitABC(ropGetField, result, objReg, uint8(fieldConstIdx), c.makeDebugInfo(e.pos))

    # Free the object register
    c.allocator.freeReg(objReg)

    if c.verbose:
      echo "[REGCOMPILER] Get field '", e.fieldName, "' (const[", fieldConstIdx, "]) from reg ", objReg, " to reg ", result

proc compileBinOp(c: var RegCompiler, op: BinOp, dest, left, right: uint8, debug: RegDebugInfo = RegDebugInfo()) =
  case op:
  of boAdd: c.prog.emitABC(ropAdd, dest, left, right, debug)
  of boSub: c.prog.emitABC(ropSub, dest, left, right, debug)
  of boMul: c.prog.emitABC(ropMul, dest, left, right, debug)
  of boDiv: c.prog.emitABC(ropDiv, dest, left, right, debug)
  of boMod: c.prog.emitABC(ropMod, dest, left, right, debug)
  of boEq: c.prog.emitABC(ropEqStore, dest, left, right, debug)
  of boNe: c.prog.emitABC(ropNeStore, dest, left, right, debug)
  of boLt: c.prog.emitABC(ropLtStore, dest, left, right, debug)
  of boLe: c.prog.emitABC(ropLeStore, dest, left, right, debug)
  of boGt: c.prog.emitABC(ropLtStore, dest, right, left, debug)  # Swap operands
  of boGe: c.prog.emitABC(ropLeStore, dest, right, left, debug)  # Swap operands
  of boAnd: c.prog.emitABC(ropAnd, dest, left, right, debug)
  of boOr: c.prog.emitABC(ropOr, dest, left, right, debug)

proc compileCall(c: var RegCompiler, e: Expr): uint8 =
  ## Compile function call
  result = c.allocator.allocReg()

  # Build complete argument list including default values
  var completeArgs = e.args

  # Look up the function declaration to get default parameter values
  if c.funInstances.hasKey(e.fname):
    let funcDecl = c.funInstances[e.fname]

    # Add default values for missing parameters
    if e.args.len < funcDecl.params.len:
      for i in e.args.len..<funcDecl.params.len:
        if funcDecl.params[i].defaultValue.isSome():
          completeArgs.add(funcDecl.params[i].defaultValue.get())
        else:
          # This shouldn't happen if the type checker is correct
          if c.verbose:
            echo "[REGCOMPILER] Warning: Missing argument for parameter ", i, " with no default value"

  if c.verbose:
    echo "[REGCOMPILER] compileCall: ", e.fname, " allocated reg ", result
    echo "[REGCOMPILER]   original args.len = ", e.args.len
    echo "[REGCOMPILER]   complete args.len = ", completeArgs.len

  # First, load the function name into the result register
  let funcNameIdx = c.addStringConst(e.fname)
  c.prog.emitABx(ropLoadK, result, funcNameIdx, c.makeDebugInfo(e.pos))
  if c.verbose:
    echo "[REGCOMPILER] Emitted ropLoadK for function name '", e.fname, "' to reg ", result, " from const[", funcNameIdx, "] at PC=", c.prog.instructions.len - 1

  # Reserve registers for arguments first
  let numArgs = completeArgs.len
  for i in 0..<numArgs:
    let targetReg = result + uint8(i) + 1
    # Make sure these registers are marked as allocated
    if targetReg >= c.allocator.nextReg:
      c.allocator.nextReg = targetReg + 1

  # Then compile arguments
  var argRegs: seq[uint8] = @[]
  for i, arg in completeArgs:
    if c.verbose:
      echo "[REGCOMPILER] Compiling argument ", i, " for function ", e.fname
      if arg.kind == ekString:
        echo "[REGCOMPILER]   String argument: '", arg.sval, "'"

    let targetReg = result + uint8(i) + 1

    # For variables, we can reference them directly
    if arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname):
      let sourceReg = c.allocator.regMap[arg.vname]
      if sourceReg != targetReg:
        c.prog.emitABC(ropMove, targetReg, sourceReg, 0)
        if c.verbose:
          echo "[REGCOMPILER]   Moving var '", arg.vname, "' from reg ", sourceReg, " to reg ", targetReg
    else:
      # For other expressions, compile them to a temporary register then move
      let tempReg = c.compileExpr(arg)
      if tempReg != targetReg:
        c.prog.emitABC(ropMove, targetReg, tempReg, 0)
        if c.verbose:
          echo "[REGCOMPILER]   Moving arg ", i, " from reg ", tempReg, " to reg ", targetReg
        c.allocator.freeReg(tempReg)
      else:
        if c.verbose:
          echo "[REGCOMPILER]   Arg ", i, " already in correct position: reg ", tempReg

    argRegs.add(targetReg)

  # Emit call instruction with function name register, number of args, and expected results
  let callDebug = c.makeDebugInfo(e.pos)
  c.prog.emitABC(ropCall, result, uint8(completeArgs.len), 1, callDebug)
  if c.verbose:
    echo "[REGCOMPILER] Emitted ropCall for ", e.fname, " at reg ", result, " with debug line ", e.pos.line

proc compileForLoop(c: var RegCompiler, s: Stmt) =
  ## Compile optimized for loop

  if s.farray.isSome():
    # For-in loop over array/string
    let arrReg = c.compileExpr(s.farray.get())

    # Allocate registers for loop state
    let idxReg = c.allocator.allocReg()  # Loop index
    let lenReg = c.allocator.allocReg()  # Array length
    let elemReg = c.allocator.allocReg(s.fvar)  # Current element (loop variable)

    # Initialize index to 0 - has debug info so we stop at the for statement once
    c.prog.emitAsBx(ropLoadK, idxReg, 0, c.makeDebugInfo(s.pos))

    # Get array length (internal operation after init - no debug info)
    c.prog.emitABC(ropLen, lenReg, arrReg, 0)

    # Create loop info for break/continue
    var loopInfo = LoopInfo(
      startLabel: c.prog.instructions.len,
      continueLabel: -1,  # Will be set later
      breakJumps: @[]
    )

    # Loop start
    let loopStart = c.prog.instructions.len

    # Check if index < length - add debug info so we break here on each iteration
    # ropLt with A=0: skip next if (B < C) is true
    # So when idx < len (should continue), skip the exit jump ✓
    # When idx >= len (should exit), execute the exit jump ✓
    c.prog.emitABC(ropLt, 0, idxReg, lenReg, c.makeDebugInfo(s.pos))  # Skip exit jump when idx < len
    let exitJmp = c.prog.instructions.len
    c.prog.emitAsBx(ropJmp, 0, 0)  # Jump to exit if idx >= len

    # Get current element: elemReg = arrReg[idxReg] (internal operation - no debug info)
    c.prog.emitABC(ropGetIndex, elemReg, arrReg, idxReg)

    # Push loop info before compiling body
    c.loopStack.add(loopInfo)

    # Compile loop body
    for stmt in s.fbody:
      c.compileStmt(stmt)

    # Continue label - where continue statements jump to
    c.loopStack[^1].continueLabel = c.prog.instructions.len

    # Increment index (internal operation - no debug info)
    c.prog.emitABx(ropAddI, idxReg, uint16(idxReg) or (1'u16 shl 8))  # idxReg += 1

    # Jump back to loop start (internal operation - no debug info)
    c.prog.emitAsBx(ropJmp, 0, int16(loopStart - c.prog.instructions.len - 1))

    # Patch exit jump
    c.prog.instructions[exitJmp].sbx = int16(c.prog.instructions.len - exitJmp - 1)

    # Patch all break jumps to jump here
    let breakPos = c.prog.instructions.len
    for breakJmp in c.loopStack[^1].breakJumps:
      c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

    # Pop loop info
    discard c.loopStack.pop()

    # Free registers
    c.allocator.freeReg(elemReg)
    c.allocator.freeReg(lenReg)
    c.allocator.freeReg(idxReg)
    c.allocator.freeReg(arrReg)

    return

  # Numeric for loop using ForPrep/ForLoop instructions
  # Extract loop bounds
  let startExpr = s.fstart.get()
  let endExpr = s.fend.get()

  # Save current register state
  let savedNextReg = c.allocator.nextReg

  # ForLoop requires three consecutive registers: idx, limit, step
  # We need to ensure they are allocated consecutively
  # First, remove the loop variable from the map if it exists (from a previous loop)
  if c.allocator.regMap.hasKey(s.fvar):
    c.allocator.regMap.del(s.fvar)

  # Now allocate three consecutive registers
  let idxReg = c.allocator.allocReg(s.fvar)
  let limitReg = idxReg + 1
  let stepReg = idxReg + 2

  # Make sure we account for these registers in the allocator
  c.allocator.nextReg = max(c.allocator.nextReg, stepReg + 1)

  # Initialize loop variables - first operation has debug info so we stop at for statement once
  let startReg = c.compileExpr(startExpr)
  c.prog.emitABC(ropMove, idxReg, startReg, 0, c.makeDebugInfo(s.pos))

  let endReg = c.compileExpr(endExpr)
  if s.finclusive:
    # For inclusive range (..), add 1 to the end value
    c.prog.emitABC(ropMove, limitReg, endReg, 0)  # First copy to limitReg
    c.prog.emitABx(ropAddI, limitReg, uint16(limitReg) or (1'u16 shl 8))  # Then add 1 in place
  else:
    # For exclusive range (..<), use end value as-is
    c.prog.emitABC(ropMove, limitReg, endReg, 0)

  # Step is always 1 for now
  c.prog.emitAsBx(ropLoadK, stepReg, 1)

  # Create loop info for break/continue
  var loopInfo = LoopInfo(
    startLabel: -1,  # Will be set at loop body start
    continueLabel: -1,  # Will be set later
    breakJumps: @[]
  )

  # ForPrep instruction - checks if loop should run at all (internal operation - no debug info)
  let prepPos = c.prog.instructions.len
  c.prog.emitAsBx(ropForPrep, idxReg, 0)  # Jump offset filled later

  # Mark loop start (where we'll jump back to)
  let loopStart = c.prog.instructions.len
  loopInfo.startLabel = loopStart

  # Save allocator state before loop body
  let loopSavedNextReg = c.allocator.nextReg

  # Push loop info before compiling body
  c.loopStack.add(loopInfo)

  # Compile loop body - DON'T reset allocator between statements!
  # Only reset at the start of each loop iteration (handled by runtime)
  for stmt in s.fbody:
    if c.verbose:
      echo "[REGCOMPILER] Loop body statement, nextReg = ", c.allocator.nextReg
    c.compileStmt(stmt)

  # Restore allocator after loop body
  c.allocator.nextReg = loopSavedNextReg

  # Continue label - where continue statements jump to
  c.loopStack[^1].continueLabel = c.prog.instructions.len

  # ForLoop instruction (increment and test) - internal operation, no debug info
  # Jump back to loop start (body) if continuing
  c.prog.emitAsBx(ropForLoop, idxReg,
                   int16(loopStart - c.prog.instructions.len - 1))

  # Patch ForPrep jump to skip to end if initial test fails
  # ForPrep should jump to the instruction AFTER ForLoop if the loop shouldn't run
  c.prog.instructions[prepPos].sbx =
    int16(c.prog.instructions.len - prepPos - 1)

  # Patch all break jumps to jump here
  let breakPos = c.prog.instructions.len
  for breakJmp in c.loopStack[^1].breakJumps:
    c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

  # Pop loop info
  discard c.loopStack.pop()

  # Restore register state (but keep loop variable if needed)
  # Only restore if loop variable is not used after loop
  c.allocator.nextReg = savedNextReg + 3  # Keep the 3 loop registers

proc compileStmt*(c: var RegCompiler, s: Stmt) =
  case s.kind:
  of skExpr:
    # Compile expression and free its register if not used
    if c.verbose:
      echo "[REGCOMPILER] Compiling expression statement at line ", s.pos.line, " expr kind = ", s.sexpr.kind, " expr pos = ", s.sexpr.pos.line
    let reg = c.compileExpr(s.sexpr)
    c.allocator.freeReg(reg)

  of skVar:
    # Variable declaration (let or var) - allocate register for the new variable
    if c.verbose:
      echo "[REGCOMPILER] Compiling ", (if s.vflag == vfLet: "let" else: "var"), " statement for variable: ", s.vname, " at line ", s.pos.line

    # Track variable declaration in lifetime tracker
    let currentPC = c.prog.instructions.len

    if s.vinit.isSome:
      if c.verbose:
        echo "[REGCOMPILER] Compiling init expression for ", s.vname, ", expr kind: ", s.vinit.get.kind
      let valReg = c.compileExpr(s.vinit.get)
      c.allocator.regMap[s.vname] = valReg

      # Variable is declared and defined at this point
      c.lifetimeTracker.declareVariable(s.vname, valReg, currentPC)
      c.lifetimeTracker.defineVariable(s.vname, currentPC)

      if c.verbose:
        echo "[REGCOMPILER] Variable ", s.vname, " allocated to reg ", valReg, " with initialization"
    else:
      # Uninitialized variable - allocate register with nil
      let reg = c.allocator.allocReg(s.vname)
      c.prog.emitABC(ropLoadNil, reg, 0, 0, c.makeDebugInfo(s.pos))

      # Variable is declared but not yet defined (holds nil)
      c.lifetimeTracker.declareVariable(s.vname, reg, currentPC)

      if c.verbose:
        echo "[REGCOMPILER] Variable ", s.vname, " allocated to reg ", reg, " (uninitialized)"

  of skAssign:
    # Check if variable already has a register
    let currentPC = c.prog.instructions.len

    if c.allocator.regMap.hasKey(s.aname):
      # Update existing register
      let destReg = c.allocator.regMap[s.aname]
      let valReg = c.compileExpr(s.aval)
      if valReg != destReg:
        c.prog.emitABC(ropMove, destReg, valReg, 0, c.makeDebugInfo(s.pos))
        # In debug mode, clear the source register to avoid confusion
        if c.debug:
          c.prog.emitABC(ropLoadNil, valReg, 0, 0)
        c.allocator.freeReg(valReg)

      # Mark variable as defined (if it wasn't already)
      c.lifetimeTracker.defineVariable(s.aname, currentPC)
    else:
      # New variable - allocate register
      let valReg = c.compileExpr(s.aval)
      c.allocator.regMap[s.aname] = valReg

      # Declare and define variable (implicit declaration through assignment)
      c.lifetimeTracker.declareVariable(s.aname, valReg, currentPC)
      c.lifetimeTracker.defineVariable(s.aname, currentPC)

  of skIf:
    if c.verbose:
      echo "[REGCOMPILER] Compiling if statement"
      echo "[REGCOMPILER]   Then body len = ", s.thenBody.len
      echo "[REGCOMPILER]   Else body len = ", s.elseBody.len
      if s.elseBody.len > 0:
        echo "[REGCOMPILER]   First else body statement: ", s.elseBody[0].kind
        if s.elseBody[0].kind == skIf:
          echo "[REGCOMPILER]   Detected elif chain"
    var jmpPos: int

    # Special handling for comparison conditions
    if s.cond.kind == ekBin and s.cond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
      let leftReg = c.compileExpr(s.cond.lhs)
      let rightReg = c.compileExpr(s.cond.rhs)

      # Emit comparison that jumps if condition is FALSE
      let debugInfo = c.makeDebugInfo(s.pos)
      case s.cond.bop:
      of boEq:
        c.prog.emitABC(ropEq, 0, leftReg, rightReg, debugInfo)  # Skip if NOT equal
      of boNe:
        c.prog.emitABC(ropEq, 1, leftReg, rightReg, debugInfo)  # Skip if equal
      of boLt:
        c.prog.emitABC(ropLt, 0, leftReg, rightReg, debugInfo)  # Skip if NOT less than
      of boLe:
        c.prog.emitABC(ropLe, 0, leftReg, rightReg, debugInfo)  # Skip if NOT less or equal
      of boGt:
        c.prog.emitABC(ropLt, 0, rightReg, leftReg, debugInfo)  # Skip if NOT greater (swap operands)
      of boGe:
        c.prog.emitABC(ropLe, 0, rightReg, leftReg, debugInfo)  # Skip if NOT greater or equal (swap operands)
      else:
        discard

      jmpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.pos))  # Jump to else/end if condition false

      c.allocator.freeReg(leftReg)
      c.allocator.freeReg(rightReg)
    else:
      # General expression condition
      let condReg = c.compileExpr(s.cond)
      c.prog.emitABC(ropTest, condReg, 0, 0, c.makeDebugInfo(s.pos))
      jmpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.pos))  # Placeholder jump
      c.allocator.freeReg(condReg)

    # Then branch
    for stmt in s.thenBody:
      c.compileStmt(stmt)

    # We need to jump over elif/else blocks after executing then branch
    var jumpToEndPositions: seq[int] = @[]
    if s.elifChain.len > 0 or s.elseBody.len > 0:
      let jumpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.pos))  # Jump to end after then branch
      jumpToEndPositions.add(jumpPos)

    # Patch first condition's false jump to here (start of elif chain or else)
    c.prog.instructions[jmpPos].sbx =
      int16(c.prog.instructions.len - jmpPos - 1)

    # Compile elif chain
    for elifClause in s.elifChain:
      if c.verbose:
        echo "[REGCOMPILER] Compiling elif clause"

      # Compile elif condition
      if elifClause.cond.kind == ekBin and elifClause.cond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
        let leftReg = c.compileExpr(elifClause.cond.lhs)
        let rightReg = c.compileExpr(elifClause.cond.rhs)

        # Emit comparison that jumps if condition is FALSE
        let debugInfo = c.makeDebugInfo(elifClause.cond.pos)
        case elifClause.cond.bop:
        of boEq:
          c.prog.emitABC(ropEq, 0, leftReg, rightReg, debugInfo)
        of boNe:
          c.prog.emitABC(ropEq, 1, leftReg, rightReg, debugInfo)
        of boLt:
          c.prog.emitABC(ropLt, 0, leftReg, rightReg, debugInfo)
        of boLe:
          c.prog.emitABC(ropLe, 0, leftReg, rightReg, debugInfo)
        of boGt:
          c.prog.emitABC(ropLt, 0, rightReg, leftReg, debugInfo)
        of boGe:
          c.prog.emitABC(ropLe, 0, rightReg, leftReg, debugInfo)
        else:
          discard

        c.allocator.freeReg(leftReg)
        c.allocator.freeReg(rightReg)
      else:
        # General expression condition
        let condReg = c.compileExpr(elifClause.cond)
        c.prog.emitABC(ropTest, condReg, 0, 0, c.makeDebugInfo(elifClause.cond.pos))
        c.allocator.freeReg(condReg)

      # Jump to next elif/else if condition is false
      let elifJmpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(elifClause.cond.pos))

      # Compile elif body
      for stmt in elifClause.body:
        c.compileStmt(stmt)

      # Jump to end after elif body
      let jumpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(elifClause.cond.pos))
      jumpToEndPositions.add(jumpPos)

      # Patch elif condition jump to here (next elif or else)
      c.prog.instructions[elifJmpPos].sbx =
        int16(c.prog.instructions.len - elifJmpPos - 1)

    # Compile else branch if present
    if s.elseBody.len > 0:
      if c.verbose:
        echo "[REGCOMPILER] Compiling else branch with ", s.elseBody.len, " statements"
      for stmt in s.elseBody:
        if c.verbose:
          echo "[REGCOMPILER]   Else body statement: ", stmt.kind
        c.compileStmt(stmt)

    # Patch all jumps to end
    for jumpPos in jumpToEndPositions:
      c.prog.instructions[jumpPos].sbx =
        int16(c.prog.instructions.len - jumpPos - 1)

  of skFor:
    # Always compile for loops for now
    c.compileForLoop(s)

  of skWhile:
    # Save current allocator state
    let savedNextReg = c.allocator.nextReg

    # Push loop info to stack for break/continue support
    c.loopStack.add(LoopInfo(
      startLabel: c.prog.instructions.len,
      continueLabel: 0,  # Will be set later
      breakJumps: @[]
    ))

    # Mark the loop start - this is where we jump back to
    let loopStart = c.prog.instructions.len

    # Compile the condition fresh each iteration
    # Special handling for comparison conditions
    if s.wcond.kind == ekBin and s.wcond.bop in {boEq, boNe, boLt, boLe, boGt, boGe}:
      let leftReg = c.compileExpr(s.wcond.lhs)
      let rightReg = c.compileExpr(s.wcond.rhs)

      # Emit comparison that jumps if condition is FALSE
      # Use s.pos (while statement) not s.wcond.pos (condition expression) for debugging
      let debugInfo = c.makeDebugInfo(s.pos)
      case s.wcond.bop:
      of boLt:
        c.prog.emitABC(ropLt, 0, leftReg, rightReg, debugInfo)  # Skip next if NOT less than
      of boLe:
        c.prog.emitABC(ropLe, 0, leftReg, rightReg, debugInfo)  # Skip next if NOT less or equal
      of boGt:
        c.prog.emitABC(ropLt, 0, rightReg, leftReg, debugInfo)  # Skip next if NOT greater (swap operands)
      of boGe:
        c.prog.emitABC(ropLe, 0, rightReg, leftReg, debugInfo)  # Skip next if NOT greater or equal (swap operands)
      of boEq:
        c.prog.emitABC(ropEq, 0, leftReg, rightReg, debugInfo)  # Skip next if NOT equal
      of boNe:
        c.prog.emitABC(ropEq, 1, leftReg, rightReg, debugInfo)  # Skip next if equal
      else:
        discard

      # Free comparison registers
      c.allocator.freeReg(leftReg)
      c.allocator.freeReg(rightReg)
    else:
      # General expression condition
      let condReg = c.compileExpr(s.wcond)
      c.prog.emitABC(ropTest, condReg, 0, 0, c.makeDebugInfo(s.pos))
      c.allocator.freeReg(condReg)

    # Jump to exit if condition is false
    let exitJmpPos = c.prog.instructions.len
    c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.wcond.pos))

    # Restore allocator state for body compilation
    c.allocator.nextReg = savedNextReg

    # Body
    for stmt in s.wbody:
      c.compileStmt(stmt)

    # Continue label - where continue statements jump to
    c.loopStack[^1].continueLabel = c.prog.instructions.len

    # Jump back to start to re-evaluate condition
    c.prog.emitAsBx(ropJmp, 0,
                     int16(loopStart - c.prog.instructions.len - 1))

    # Patch exit jump
    c.prog.instructions[exitJmpPos].sbx =
      int16(c.prog.instructions.len - exitJmpPos - 1)

    # Patch all break jumps to jump here
    let breakPos = c.prog.instructions.len
    for breakJmp in c.loopStack[^1].breakJumps:
      c.prog.instructions[breakJmp].sbx = int16(breakPos - breakJmp - 1)

    # Pop loop info
    discard c.loopStack.pop()

  of skReturn:
    let debug = c.makeDebugInfo(s.pos)
    if s.re.isSome():
      let retReg = c.compileExpr(s.re.get())
      c.prog.emitABC(ropReturn, 1, retReg, 0, debug)  # 1 result, in retReg
    else:
      c.prog.emitABC(ropReturn, 0, 0, 0, debug)  # 0 results

  of skBreak:
    # Break statement - jump out of current loop
    if c.loopStack.len > 0:
      # Add a jump that will be patched later
      let jmpPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.pos))
      c.loopStack[^1].breakJumps.add(jmpPos)
    else:
      echo "Warning: break statement outside of loop"

  of skComptime:
    # Comptime blocks should contain injected variables after foldComptime
    if c.verbose:
      echo "[REGCOMPILER] Processing comptime block with ", s.cbody.len, " statements"
    # Process the injected variable declarations
    for stmt in s.cbody:
      c.compileStmt(stmt)

  of skTypeDecl:
    # Type declarations - these are handled during type checking
    if c.verbose:
      echo "[REGCOMPILER] Skipping type declaration (handled during type checking)"

  of skImport:
    # Import statements - these are handled during parsing
    if c.verbose:
      echo "[REGCOMPILER] Skipping import statement (handled during parsing)"

  of skDiscard:
    # Discard statement - compile expressions and free their registers
    if c.verbose:
      echo "[REGCOMPILER] Compiling discard statement with ", s.dexprs.len, " expressions"
    for expr in s.dexprs:
      let reg = c.compileExpr(expr)
      c.allocator.freeReg(reg)

  of skFieldAssign:
    # Field assignment for objects
    if c.verbose:
      echo "[REGCOMPILER] Field assignment"

    # The faTarget should be a field access expression
    if s.faTarget.kind != ekFieldAccess:
      echo "Error: Field assignment target is not a field access"
      return

    # The object should be a simple variable for now
    if s.faTarget.objectExpr.kind != ekVar:
      echo "Error: Field assignment object is not a variable"
      return

    # Get the object register
    let objName = s.faTarget.objectExpr.vname
    if not c.allocator.regMap.hasKey(objName):
      echo "Error: Variable not found in register map: ", objName
      return
    let objReg = c.allocator.regMap[objName]

    # Compile the value to assign
    let valReg = c.compileExpr(s.faValue)

    # Get or add the field name to const pool
    let fieldConst = c.addStringConst(s.faTarget.fieldName)

    # Emit ropSetField to set object field: R[objReg][K[fieldConst]] = R[valReg]
    c.prog.emitABC(ropSetField, valReg, objReg, uint8(fieldConst), c.makeDebugInfo(s.pos))

    if c.verbose:
      echo "[REGCOMPILER] Set field '", s.faTarget.fieldName, "' (const[", fieldConst, "]) in object at reg ", objReg, " to value at reg ", valReg

    c.allocator.freeReg(valReg)

proc compileFunDecl*(c: var RegCompiler, name: string, params: seq[Param], retType: EtchType, body: seq[Stmt]) =
  # Reset allocator for new function - preserve max register count
  c.allocator = RegAllocator(
    nextReg: 0,
    maxRegs: uint8(MAX_REGISTERS),
    regMap: initTable[string, uint8]()
  )

  # Reset lifetime tracker for this function
  let startPC = c.prog.instructions.len
  c.lifetimeTracker = newLifetimeTracker()
  c.lifetimeTracker.enterScope(startPC)

  # Track parameters
  for param in params:
    let paramReg = c.allocator.allocReg(param.name)
    c.lifetimeTracker.declareVariable(param.name, paramReg, startPC)
    c.lifetimeTracker.defineVariable(param.name, startPC)

  # Compile function body
  for stmt in body:
    c.compileStmt(stmt)

  # Exit function scope
  let endPC = c.prog.instructions.len
  c.lifetimeTracker.exitScope(endPC)

  # Build and optimize lifetime data
  c.lifetimeTracker.buildPCMap()
  if c.optimizeLevel >= 1:
    c.lifetimeTracker.optimizeLifetimes()

  # Save lifetime data (allocate on heap)
  let lifetimeData = c.lifetimeTracker.exportFunctionData(name)
  var heapData = new(FunctionLifetimeData)
  heapData[] = lifetimeData
  c.prog.lifetimeData[name] = cast[pointer](heapData)
  GC_ref(heapData)  # Keep a GC reference to prevent collection

  # Debug: dump lifetime info if verbose
  if c.verbose:
    c.lifetimeTracker.dumpLifetimes()

  # Add implicit return if needed
  if c.prog.instructions.len == 0 or
     c.prog.instructions[^1].op != ropReturn:
    c.prog.emitABC(ropReturn, 0, 0, 0)  # No results

proc compileProgram*(p: ast.Program, optimizeLevel: int = 2, verbose: bool = false, debug: bool = true): RegBytecodeProgram =
  ## Compile AST to register-based bytecode with optimizations
  if verbose:
    echo "[REGCOMPILER] Starting compilation, funInstances count: ", p.funInstances.len
    for fname, _ in p.funInstances:
      echo "[REGCOMPILER]   Function available: ", fname

  var compiler = RegCompiler(
    prog: RegBytecodeProgram(
      functions: initTable[string, regvm.FunctionInfo](),
      cffiInfo: initTable[string, regvm.CFFIInfo](),
      lifetimeData: initTable[string, pointer]()
    ),
    allocator: RegAllocator(
      nextReg: 0,
      maxRegs: uint8(MAX_REGISTERS),
      regMap: initTable[string, uint8]()
    ),
    constMap: initTable[string, uint16](),
    loopStack: @[],
    optimizeLevel: optimizeLevel,
    verbose: verbose,
    debug: debug,
    funInstances: p.funInstances,
    lifetimeTracker: newLifetimeTracker()
  )

  # Populate C FFI info from AST - identify CFFI functions by their isCFFI flag
  for fname, funcDecl in p.funInstances:
    if funcDecl.isCFFI:
      # Extract base name from mangled name
      var baseName = fname
      let underscorePos = fname.find("__")
      if underscorePos >= 0:
        baseName = fname[0..<underscorePos]

      # For now, store minimal info - the runtime will handle the actual FFI calls
      # The library and symbol info will be populated by the compiler.nim from the global registry
      compiler.prog.cffiInfo[fname] = regvm.CFFIInfo(
        library: "",  # Will be filled by compiler.nim
        symbol: baseName,  # Use base name as symbol for now
        baseName: baseName,
        paramTypes: @[],  # Will be filled by compiler.nim
        returnType: ""    # Will be filled by compiler.nim
      )
      if verbose:
        echo "[REGCOMPILER] Identified C FFI function: ", fname, " -> ", baseName

  # Compile all functions except main first
  for fname, funcDecl in p.funInstances:
    let isBuiltin = funcDecl.body.len == 0  # Builtin functions have no body
    let isCFFI = compiler.prog.cffiInfo.hasKey(fname)
    if verbose:
      echo "[REGCOMPILER] Processing function: ", fname, " isBuiltin=", isBuiltin, " isCFFI=", isCFFI, " body.len=", funcDecl.body.len
    if fname != "main" and not isBuiltin and not isCFFI:  # Skip builtin and C FFI functions
      let startPos = compiler.prog.instructions.len

      if verbose:
        echo "[REGCOMPILER] Compiling function ", fname

      # Reset allocator for new function
      compiler.allocator = RegAllocator(
        nextReg: 0,
        maxRegs: uint8(MAX_REGISTERS),
        regMap: initTable[string, uint8]()
      )

      # Reset lifetime tracker for new function
      compiler.lifetimeTracker = newLifetimeTracker()
      compiler.lifetimeTracker.enterScope(startPos)  # Enter function scope

      # Allocate registers for parameters and map them
      for i, param in funcDecl.params:
        let paramReg = compiler.allocator.allocReg(param.name)
        # Track parameter as declared and defined at function entry
        compiler.lifetimeTracker.declareVariable(param.name, paramReg, startPos)
        compiler.lifetimeTracker.defineVariable(param.name, startPos)
        if verbose:
          echo "[REGCOMPILER] Allocated parameter '", param.name, "' to register ", paramReg

      # Compile function body
      for stmt in funcDecl.body:
        compiler.compileStmt(stmt)

      # Exit function scope
      let endPC = compiler.prog.instructions.len
      compiler.lifetimeTracker.exitScope(endPC)

      # Build PC map and optimize lifetimes
      compiler.lifetimeTracker.buildPCMap()
      if compiler.optimizeLevel >= 1:
        compiler.lifetimeTracker.optimizeLifetimes()

      # Save lifetime data for this function (allocate on heap)
      let lifetimeData = compiler.lifetimeTracker.exportFunctionData(fname)
      var heapData = new(FunctionLifetimeData)
      heapData[] = lifetimeData
      compiler.prog.lifetimeData[fname] = cast[pointer](heapData)
      GC_ref(heapData)  # Keep a GC reference to prevent collection

      # Debug: dump lifetime info if verbose
      if verbose:
        compiler.lifetimeTracker.dumpLifetimes()

      # Add implicit return if needed
      if compiler.prog.instructions.len == startPos or
         compiler.prog.instructions[^1].op != ropReturn:
        compiler.prog.emitABC(ropReturn, 0, 0, 0)

      let endPos = compiler.prog.instructions.len - 1

      # Store function info
      compiler.prog.functions[fname] = regvm.FunctionInfo(
        name: fname,
        startPos: startPos,
        endPos: endPos,
        numParams: funcDecl.params.len,
        numLocals: 0  # TODO: Calculate actual locals
      )

      if verbose:
        echo "[REGCOMPILER] Compiled function ", fname, " at ", startPos, "..", endPos

  # Compile global initialization if needed
  if p.globals.len > 0:
    if verbose:
      echo "[REGCOMPILER] Compiling ", p.globals.len, " global variables"

    # Save position for global init
    let globalInitStart = compiler.prog.instructions.len

    # Reset allocator for global init scope
    compiler.allocator = RegAllocator(
      nextReg: 0,
      maxRegs: uint8(MAX_REGISTERS),
      regMap: initTable[string, uint8]()
    )

    # Compile global variable initialization
    for globalStmt in p.globals:
      if globalStmt.kind == skVar:
        if globalStmt.vinit.isSome():
          # Compile the initialization expression
          let valueReg = compiler.compileExpr(globalStmt.vinit.get())
          # Store in global table
          let nameIdx = compiler.addStringConst(globalStmt.vname)
          compiler.prog.emitABx(ropSetGlobal, valueReg, nameIdx)
          compiler.allocator.freeReg(valueReg)

    # After global initialization, call main
    let mainNameReg = compiler.allocator.allocReg()
    let mainNameIdx = compiler.addStringConst("main")
    compiler.prog.emitABx(ropLoadK, mainNameReg, mainNameIdx)
    compiler.prog.emitABC(ropCall, mainNameReg, 0, 0)  # No args, no results expected from main
    compiler.prog.emitABC(ropReturn, 0, 0, 0)  # Return after main completes

    # Set entry point to global initialization
    compiler.prog.entryPoint = globalInitStart
    if verbose:
      echo "[REGCOMPILER] Entry point set to PC ", globalInitStart, " (<global> function)"

    # Register the global initialization code as a special function for debugging
    let globalInitEnd = compiler.prog.instructions.len - 1
    compiler.prog.functions["<global>"] = regvm.FunctionInfo(
      name: "<global>",
      startPos: globalInitStart,
      endPos: globalInitEnd,
      numParams: 0,
      numLocals: 0
    )

    if verbose:
      echo "[REGCOMPILER] Registered <global> initialization function at PC ", globalInitStart, "..", globalInitEnd
  else:
    # Set entry point to main (will be compiled next)
    compiler.prog.entryPoint = compiler.prog.instructions.len

  # Find and compile main function last
  if p.funInstances.hasKey("main"):
    let mainFunc = p.funInstances["main"]

    # Reset allocator for main
    compiler.allocator = RegAllocator(
      nextReg: 0,
      maxRegs: uint8(MAX_REGISTERS),
      regMap: initTable[string, uint8]()
    )

    let mainStartPos = compiler.prog.instructions.len
    compiler.compileFunDecl("main", mainFunc.params,
                            mainFunc.ret, mainFunc.body)
    let mainEndPos = compiler.prog.instructions.len

    # Store main function info
    compiler.prog.functions["main"] = regvm.FunctionInfo(
      name: "main",
      startPos: mainStartPos,
      endPos: mainEndPos,
      numParams: mainFunc.params.len,
      numLocals: 0
    )

    if verbose:
      echo "[REGCOMPILER] Compiled main function at ", mainStartPos, "..", mainEndPos

  # Apply optimization passes
  # TODO: Fix variant object field access in optimizeBytecode
  # if optimizeLevel >= 2:
  #   optimizeBytecode(compiler.prog)

  return compiler.prog

proc optimizeBytecode*(prog: var RegBytecodeProgram) =
  ## Apply bytecode optimization passes

  # Pass 1: Constant folding - evaluate constant expressions at compile time
  var i = 0
  while i < prog.instructions.len - 2:
    let curr = prog.instructions[i]
    let next = prog.instructions[i + 1]
    let third = prog.instructions[i + 2]

    # Pattern: LoadK, LoadK, Add/Sub/Mul/Div -> LoadK (folded result)
    if curr.op == ropLoadK and next.op == ropLoadK and
       third.op in {ropAdd, ropSub, ropMul, ropDiv}:
      # Check if the arithmetic operation uses the loaded constants
      if third.opType == 0 and third.b == curr.a and third.c == next.a:
        # Get the constant values based on instruction format
        let val1 = if curr.opType == 1: prog.constants[curr.bx]
                   elif curr.opType == 2: regvm.makeInt(int64(curr.sbx))
                   else: regvm.makeNil()
        let val2 = if next.opType == 1: prog.constants[next.bx]
                   elif next.opType == 2: regvm.makeInt(int64(next.sbx))
                   else: regvm.makeNil()

        # Fold if both are integers
        if regvm.isInt(val1) and regvm.isInt(val2):
          var foldedResult: regvm.V
          case third.op:
          of ropAdd:
            foldedResult = regvm.makeInt(regvm.getInt(val1) + regvm.getInt(val2))
          of ropSub:
            foldedResult = regvm.makeInt(regvm.getInt(val1) - regvm.getInt(val2))
          of ropMul:
            foldedResult = regvm.makeInt(regvm.getInt(val1) * regvm.getInt(val2))
          of ropDiv:
            if regvm.getInt(val2) != 0:
              foldedResult = regvm.makeInt(regvm.getInt(val1) div regvm.getInt(val2))
            else:
              inc i
              continue
          else:
            inc i
            continue

          # Replace three instructions with one LoadK
          prog.constants.add(foldedResult)
          prog.instructions[i] = RegInstruction(
            op: ropLoadK,
            a: third.a,
            opType: 1,
            bx: uint16(prog.constants.len - 1)
          )

          # Remove the next two instructions
          prog.instructions.delete(i + 1)
          prog.instructions.delete(i + 1)
          continue

    # Pattern: Consecutive jumps - remove unreachable code
    if curr.op == ropJmp and next.op notin {ropForLoop, ropForPrep}:
      # Mark next instruction as dead if it's not a jump target
      # (simplified - real implementation would track jump targets)
      discard

    # Pattern: Test + Jmp -> TestJmp (fused test and jump)
    if curr.op == ropTest and next.op == ropJmp:
      # Fuse into a combined test-and-jump instruction
      prog.instructions[i] = RegInstruction(
        op: ropCmpJmp,
        a: curr.a,
        opType: 3,
        ax: uint32(next.sbx shl 16)
      )
      prog.instructions.delete(i + 1)
      continue

    inc i

  # Pass 2: Common subexpression elimination (CSE)
  # Track computed values and reuse registers when same computation appears
  var valueMap: Table[string, uint8]  # Expression -> register mapping
  i = 0
  while i < prog.instructions.len:
    let instr = prog.instructions[i]

    # Build expression key for arithmetic operations
    if instr.op in {ropAdd, ropSub, ropMul, ropDiv} and instr.opType == 0:
      let key = $instr.op & ":" & $instr.b & ":" & $instr.c

      if valueMap.hasKey(key):
        # Replace with move instruction
        prog.instructions[i] = RegInstruction(
          op: ropMove,
          a: instr.a,
          opType: 0,
          b: valueMap[key],
          c: 0
        )
      else:
        # Remember this computation
        valueMap[key] = instr.a

    # Invalidate cache on writes
    if instr.op in {ropSetGlobal, ropSetIndex, ropCall}:
      valueMap.clear()

    inc i

  # Pass 3: Register renaming to reduce dependencies
  # This helps instruction-level parallelism in modern CPUs
  var regRemap: Table[uint8, uint8]
  var nextFreeReg = uint8(0)

  for i in 0..<prog.instructions.len:
    var instr = prog.instructions[i]

    # Remap source registers
    if instr.opType == 0:  # ABC format
      if regRemap.hasKey(instr.b):
        instr.b = regRemap[instr.b]
      if regRemap.hasKey(instr.c):
        instr.c = regRemap[instr.c]

    # Allocate new destination register if writing
    if instr.op in {ropLoadK, ropAdd, ropSub, ropMul, ropDiv, ropGetGlobal}:
      if not regRemap.hasKey(instr.a):
        regRemap[instr.a] = nextFreeReg
        inc nextFreeReg
      instr.a = regRemap[instr.a]

    prog.instructions[i] = instr