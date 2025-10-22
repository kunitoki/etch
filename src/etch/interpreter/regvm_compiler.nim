# regcompiler.nim
# Register-based bytecode compiler with aggressive optimizations

import std/[tables, macros, options, strutils, strformat]
import ../common/[constants, types, logging]
import ../frontend/ast
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


# Logging helper for VM compilation
macro log(verbose: untyped, msg: untyped): untyped =
  result = quote do:
    if `verbose`:
      logCompiler(true, `msg`)


# Helper to add constants
proc addConst*(c: var RegCompiler, val: regvm.V): uint16 =
  # Check if constant already exists (constant folding)
  for i, existing in c.prog.constants:
    if existing.kind == val.kind:
      case val.kind:
      of vkString:
        if existing.sval == val.sval:
          return uint16(i)
      of vkFloat:
        if existing.fval == val.fval:
          return uint16(i)
      of vkInt:
        if existing.ival == val.ival:
          return uint16(i)
      of vkBool:
        if existing.bval == val.bval:
          return uint16(i)
      of vkChar:
        if existing.cval == val.cval:
          return uint16(i)
      of vkNil:
        return uint16(i)  # All nils are equal
      else:
        discard

  c.prog.constants.add(val)
  return uint16(c.prog.constants.len - 1)

proc addStringConst*(c: var RegCompiler, s: string): uint16 =
  if c.constMap.hasKey(s):
    log(c.verbose, fmt"String '{s}' already in const pool at index {c.constMap[s]}")
    return c.constMap[s]

  let v = regvm.makeString(s)
  result = c.addConst(v)
  c.constMap[s] = result
  log(c.verbose, fmt"Added string '{s}' to const pool at index {result}")

proc addFunctionIndex*(c: var RegCompiler, funcName: string): uint16 =
  ## Add function name to function table and return its index
  ## The function table maps indices to function names for fast direct calls
  for i, name in c.prog.functionTable:
    if name == funcName:
      return uint16(i)

  let idx = uint16(c.prog.functionTable.len)
  c.prog.functionTable.add(funcName)
  log(c.verbose, fmt"Added function '{funcName}' to function table at index {idx}")
  return idx

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
proc tryFuseArithmetic(c: var RegCompiler, e: Expr): tuple[fused: bool, reg: uint8] =
  ## Try to generate fused arithmetic instructions
  ## Returns (fused=true, reg=destReg) if fusion succeeded, (fused=false, reg=0) otherwise
  if e.kind != ekBin:
    return (false, 0'u8)

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
    return (true, destReg)

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
    return (true, destReg)

  return (false, 0'u8)

proc compileExpr*(c: var RegCompiler, e: Expr): uint8 =
  ## Compile expression to register, return register number

  # Try instruction fusion first (if optimization enabled)
  if c.optimizeLevel >= 2:
    let (fused, reg) = c.tryFuseArithmetic(e)
    if fused:
      return reg  # Return the actual destination register from fusion

  case e.kind:
  of ekInt:
    result = c.allocator.allocReg()
    log(c.verbose, fmt"Compiling integer {e.ival} to reg {result}")
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
    log(c.verbose, fmt"Compiling string expression: '{e.sval}'")
    let constIdx = c.addStringConst(e.sval)
    c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))
    log(c.verbose, fmt"  Loaded to register {result} from const[{constIdx}]")

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

    # Determine cast type code - map TypeKind to VKind ordinals
    let castTypeCode = case e.castType.kind:
      of tkInt: ord(vkInt)       # 0
      of tkFloat: ord(vkFloat)   # 1
      of tkBool: ord(vkBool)     # 2
      of tkChar: ord(vkChar)     # 3
      of tkString: ord(vkString) # 5
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
      log(c.verbose, fmt"Variable '{e.vname}' found in register {c.allocator.regMap[e.vname]}")
      return c.allocator.regMap[e.vname]
    else:
      # Load from global
      log(c.verbose, fmt"Variable '{e.vname}' not in regMap, loading from global")
      result = c.allocator.allocReg(e.vname)
      let nameIdx = c.addStringConst(e.vname)
      c.prog.emitABx(ropGetGlobal, result, nameIdx, c.makeDebugInfo(e.pos))

  of ekBin:
    let leftReg = c.compileExpr(e.lhs)
    let rightReg = c.compileExpr(e.rhs)
    result = c.allocator.allocReg()
    log(c.verbose, fmt"Binary op: leftReg={leftReg} rightReg={rightReg} resultReg={result}")

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
    log(c.verbose, fmt"Array expression allocated reg {result}")
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
    log(c.verbose, "Compiling slice expression")

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
    log(c.verbose, "Compiling ekNewRef expression")
    # Compile the init expression
    let initReg = c.compileExpr(e.init)

    # Allocate result register
    result = c.allocator.allocReg()

    # Get function index for "new"
    let funcIdx = c.addFunctionIndex("new")

    # Set up argument in next register
    if initReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, initReg, 0)
      c.allocator.freeReg(initReg)

    # Call new function using ropCall
    var instr = RegInstruction(
      op: ropCall,
      a: result,
      opType: 4,
      funcIdx: funcIdx,
      numArgs: 1,
      numResults: 1,
      debug: c.makeDebugInfo(e.pos)
    )
    c.prog.instructions.add(instr)

  of ekDeref:
    # Handle deref(ref) for dereferencing
    log(c.verbose, "Compiling ekDeref expression")
    # Compile the ref expression
    let refReg = c.compileExpr(e.refExpr)

    # Allocate result register
    result = c.allocator.allocReg()

    # Get function index for "deref"
    let funcIdx = c.addFunctionIndex("deref")

    # Set up argument in next register
    if refReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, refReg, 0)
      c.allocator.freeReg(refReg)

    # Call deref function using ropCall
    var instr = RegInstruction(
      op: ropCall,
      a: result,
      opType: 4,
      funcIdx: funcIdx,
      numArgs: 1,
      numResults: 1,
      debug: c.makeDebugInfo(e.pos)
    )
    c.prog.instructions.add(instr)

  of ekNew:
    # Handle new for heap allocation (similar to ekNewRef)
    log(c.verbose, "Compiling ekNew expression")
    # If there's an init expression, compile it
    if e.initExpr.isSome:
      let initReg = c.compileExpr(e.initExpr.get)

      # Allocate result register
      result = c.allocator.allocReg()

      # Get function index for "new"
      let funcIdx = c.addFunctionIndex("new")

      # Set up argument in next register
      if initReg != result + 1:
        c.prog.emitABC(ropMove, result + 1, initReg, 0)
        c.allocator.freeReg(initReg)

      # Call new function using ropCall
      var instr = RegInstruction(
        op: ropCall,
        a: result,
        opType: 4,
        funcIdx: funcIdx,
        numArgs: 1,
        numResults: 1,
        debug: c.makeDebugInfo(e.pos)
      )
      c.prog.instructions.add(instr)
    else:
      # No init expression - just return nil for now
      result = c.allocator.allocReg()
      c.prog.emitABC(ropLoadNil, result, result, 0)

  of ekOptionSome:
    # Handle some(value) for option types
    log(c.verbose, "Compiling ekOptionSome expression")
    # Compile the inner value first
    let innerReg = c.compileExpr(e.someExpr)
    result = c.allocator.allocReg()
    # Wrap it as some
    c.prog.emitABC(ropWrapSome, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekOptionNone:
    # Handle none for option types
    log(c.verbose, "Compiling ekOptionNone expression")
    result = c.allocator.allocReg()
    # Create a none value
    c.prog.emitABC(ropLoadNone, result, 0, 0, c.makeDebugInfo(e.pos))

  of ekResultOk:
    # Handle ok(value) for result types
    log(c.verbose, "Compiling ekResultOk expression")
    # Compile the inner value first
    let innerReg = c.compileExpr(e.okExpr)
    result = c.allocator.allocReg()
    # Wrap it as ok
    c.prog.emitABC(ropWrapOk, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekResultErr:
    # Handle error(msg) for result types
    log(c.verbose, "Compiling ekResultErr expression")
    # Compile the error message first
    let innerReg = c.compileExpr(e.errExpr)
    result = c.allocator.allocReg()
    # Wrap it as error
    c.prog.emitABC(ropWrapErr, result, innerReg, 0, c.makeDebugInfo(e.pos))
    if innerReg != result:
      c.allocator.freeReg(innerReg)

  of ekMatch:
    # Handle match expressions properly
    log(c.verbose, "Compiling ekMatch expression")

    # Compile the expression to match against
    let matchReg = c.compileExpr(e.matchExpr)
    result = c.allocator.allocReg()

    var jumpToEndPositions: seq[int] = @[]

    # Compile each case
    for i, matchCase in e.cases:
      log(c.verbose, fmt"  Compiling match case {i} pattern: {matchCase.pattern.kind}")

      # Pattern matching - simplified version
      var shouldJumpToNext = -1

      case matchCase.pattern.kind:
      of pkSome:
        # Check if it's a some value
        # ropTestTag: skips next if tags MATCH
        # So if tag is some, skip the jump and execute case body
        # If tag is not some, execute jump to next case
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkSome), 0, c.makeDebugInfo(e.pos))  # Test if tag is some
        log(c.verbose, fmt"  Emitted ropTestTag for some at PC={c.prog.instructions.len - 1}")
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if not some

        # Extract the value if it's some
        if matchCase.pattern.bindName != "":
          # Unwrap the some value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapOption, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg
          log(c.verbose, fmt"  Bound some pattern variable '{matchCase.pattern.bindName}' to unwrapped reg {unwrappedReg}")

      of pkNone:
        # Check if it's none
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkNone), 0, c.makeDebugInfo(e.pos))  # Test if tag is none
        log(c.verbose, fmt"  Emitted ropTestTag for none at PC={c.prog.instructions.len - 1}")
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if not none
        log(c.verbose, fmt"  Emitted ropJmp at PC={c.prog.instructions.len - 1} (will be patched)");

      of pkOk:
        # Check if it's an ovalue
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkOk), 0, c.makeDebugInfo(e.pos))  # Test if tag is ok
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))

        if matchCase.pattern.bindName != "":
          # Unwrap the ok value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkErr:
        # Check if it's an error value
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkErr), 0, c.makeDebugInfo(e.pos))  # Test if tag is error
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))

        if matchCase.pattern.bindName != "":
          # Unwrap the error value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, c.makeDebugInfo(e.pos))
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkWildcard:
        # Wildcard always matches - no test needed
        discard

      of pkType:
        # Type pattern matching (for union types)
        # Check if the value has the correct type tag
        log(c.verbose, fmt"  Type pattern: {matchCase.pattern.typePattern.kind} bind: {matchCase.pattern.typeBind}")

        # Determine the VKind for the type
        let expectedKind = case matchCase.pattern.typePattern.kind:
          of tkInt: vkInt
          of tkFloat: vkFloat
          of tkBool: vkBool
          of tkChar: vkChar
          of tkString: vkString
          of tkArray: vkArray
          of tkObject: vkTable
          of tkUserDefined: vkTable  # User-defined types are objects (tables)
          else:
            log(c.verbose, fmt"  Warning: Unsupported type for pattern matching: {matchCase.pattern.typePattern.kind}")
            vkNil

        # Test if the kind matches
        c.prog.emitABC(ropTestTag, matchReg, uint8(expectedKind), 0, c.makeDebugInfo(e.pos))
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))  # Jump to next case if tag doesn't match

        # Bind the value if there's a binding variable
        if matchCase.pattern.typeBind != "":
          # The value is already in matchReg, just bind it
          c.allocator.regMap[matchCase.pattern.typeBind] = matchReg
          log(c.verbose, fmt"  Bound type pattern variable '{matchCase.pattern.typeBind}' to reg {matchReg}")

      # Compile the case body
      if matchCase.body.len > 0:
        log(c.verbose, fmt"  Match case body has {matchCase.body.len} statements")
        if c.verbose:
          for idx, stmt in matchCase.body:
            echo "[REGCOMPILER]     Body stmt ", idx, " kind: ", stmt.kind
            if stmt.kind == skExpr:
              echo "[REGCOMPILER]       Expr kind: ", stmt.sexpr.kind

        # For match expressions, the body is typically a single expression statement
        # that should be the result of the match
        if matchCase.body.len == 1 and matchCase.body[0].kind == skExpr:
          # Single expression - this is the result
          log(c.verbose, fmt"  Case body starts at PC={c.prog.instructions.len}")
          let exprReg = c.compileExpr(matchCase.body[0].sexpr)
          log(c.verbose, fmt"  Match case body expr compiled to reg {exprReg} result reg is {result}")
          if exprReg != result:
            c.prog.emitABC(ropMove, result, exprReg, 0)
            log(c.verbose, fmt"  Emitted ropMove from {exprReg} to {result} at PC={c.prog.instructions.len - 1}")
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
    log(c.verbose, fmt"Compiling ekObjectLiteral expression with {e.fieldInits.len} fields")
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

      log(c.verbose, fmt"Set field '{fieldName}' (const[{fieldConstIdx}]) = reg {valueReg}")

    # Add default values for missing fields
    if e.objectType != nil and e.objectType.kind == tkObject:
      for field in e.objectType.fields:
        if field.name notin providedFields and field.defaultValue.isSome:
          log(c.verbose, fmt"Adding default value for field '{field.name}'")

          # Compile the default value expression
          let defaultExpr = field.defaultValue.get
          let valueReg = c.compileExpr(defaultExpr)

          # Add field name to constants
          let fieldConstIdx = c.addStringConst(field.name)

          # Set the default value
          c.prog.emitABC(ropSetField, valueReg, result, uint8(fieldConstIdx))

          # Free the value register
          c.allocator.freeReg(valueReg)

          log(c.verbose, fmt"Set default field '{field.name}' (const[{fieldConstIdx}]) = reg {valueReg}")

  of ekFieldAccess:
    # Handle field access on objects
    log(c.verbose, fmt"Compiling ekFieldAccess expression: field '{e.fieldName}'")

    # Compile the object expression
    let objReg = c.compileExpr(e.objectExpr)
    result = c.allocator.allocReg()

    # Add field name to constants if not already there
    let fieldConstIdx = c.addStringConst(e.fieldName)

    # Emit ropGetField: R[result] = R[objReg][K[fieldConstIdx]]
    c.prog.emitABC(ropGetField, result, objReg, uint8(fieldConstIdx), c.makeDebugInfo(e.pos))

    # Free the object register
    c.allocator.freeReg(objReg)

    log(c.verbose, fmt"Get field '{e.fieldName}' (const[{fieldConstIdx}]) from reg {objReg} to reg {result}")

  of ekIf:
    # Handle if-expressions
    log(c.verbose, "Compiling ekIf expression")

    result = c.allocator.allocReg()
    var jumpToEndPositions: seq[int] = @[]

    # Compile condition
    let condReg = c.compileExpr(e.ifCond)

    # Test condition and jump if false
    c.prog.emitABC(ropTest, condReg, 0, 0, c.makeDebugInfo(e.pos))
    c.allocator.freeReg(condReg)

    let skipThenJmp = c.prog.instructions.len
    c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(e.pos))

    # Compile then branch - result goes to result register
    for i, stmt in e.ifThen:
      if i == e.ifThen.len - 1 and stmt.kind == skExpr:
        # Last statement is an expression - compile it to result register
        let thenReg = c.compileExpr(stmt.sexpr)
        if thenReg != result:
          c.prog.emitABC(ropMove, result, thenReg, 0)
          c.allocator.freeReg(thenReg)
      else:
        c.compileStmt(stmt)

    # Jump to end after then
    jumpToEndPositions.add(c.prog.instructions.len)
    c.prog.emitAsBx(ropJmp, 0, 0)

    # Patch skip-then jump
    let afterThen = c.prog.instructions.len
    c.prog.instructions[skipThenJmp].sbx = int16(afterThen - skipThenJmp - 1)

    # Compile elif chain
    for elifCase in e.ifElifChain:
      let elifCondReg = c.compileExpr(elifCase.cond)
      c.prog.emitABC(ropTest, elifCondReg, 0, 0)
      c.allocator.freeReg(elifCondReg)

      let skipElifJmp = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0)

      for i, stmt in elifCase.body:
        if i == elifCase.body.len - 1 and stmt.kind == skExpr:
          let elifReg = c.compileExpr(stmt.sexpr)
          if elifReg != result:
            c.prog.emitABC(ropMove, result, elifReg, 0)
            c.allocator.freeReg(elifReg)
        else:
          c.compileStmt(stmt)

      jumpToEndPositions.add(c.prog.instructions.len)
      c.prog.emitAsBx(ropJmp, 0, 0)

      let afterElif = c.prog.instructions.len
      c.prog.instructions[skipElifJmp].sbx = int16(afterElif - skipElifJmp - 1)

    # Compile else branch
    for i, stmt in e.ifElse:
      if i == e.ifElse.len - 1 and stmt.kind == skExpr:
        let elseReg = c.compileExpr(stmt.sexpr)
        if elseReg != result:
          c.prog.emitABC(ropMove, result, elseReg, 0)
          c.allocator.freeReg(elseReg)
      else:
        c.compileStmt(stmt)

    # Patch all jumps to end
    let endPos = c.prog.instructions.len
    for jmpPos in jumpToEndPositions:
      c.prog.instructions[jmpPos].sbx = int16(endPos - jmpPos - 1)

  of ekComptime:
    # Compile-time expression should have been folded during comptime pass
    # If we reach here, just compile the inner expression (it should be a constant now)
    log(c.verbose, "Compiling ekComptime expression (should have been folded)")
    result = c.compileExpr(e.comptimeExpr)

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
  of boIn: c.prog.emitABC(ropIn, dest, left, right, debug)
  of boNotIn: c.prog.emitABC(ropNotIn, dest, left, right, debug)

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
          log(c.verbose, fmt"Warning: Missing argument for parameter {i} with no default value")

  log(c.verbose, fmt"compileCall: {e.fname} allocated reg {result}")
  log(c.verbose, fmt"   original args.len = {e.args.len}")
  log(c.verbose, fmt"   complete args.len = {completeArgs.len}")

  # Get or create function index for direct calls
  let funcIdx = c.addFunctionIndex(e.fname)
  log(c.verbose, fmt"Function '{e.fname}' has index {funcIdx} in function table")

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
    log(c.verbose, fmt"Compiling argument {i} for function {e.fname}")
    log(c.verbose and arg.kind == ekString, fmt"   String argument: '{arg.sval}'")

    let targetReg = result + uint8(i) + 1

    # For variables, we can reference them directly
    if arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname):
      let sourceReg = c.allocator.regMap[arg.vname]
      if sourceReg != targetReg:
        c.prog.emitABC(ropMove, targetReg, sourceReg, 0)
        log(c.verbose, fmt"  Moving var '{arg.vname}' from reg {sourceReg} to reg {targetReg}")
    else:
      # For other expressions, compile them to a temporary register then move
      let tempReg = c.compileExpr(arg)
      if tempReg != targetReg:
        c.prog.emitABC(ropMove, targetReg, tempReg, 0)
        log(c.verbose, fmt"  Moving arg {i} from reg {tempReg} to reg {targetReg}")
        c.allocator.freeReg(tempReg)
      else:
        log(c.verbose, fmt"  Arg {i} already in correct position: reg {tempReg}")

    argRegs.add(targetReg)

  # Emit ropCall instruction with function index
  # Uses opType=4 (function call format)
  let callDebug = c.makeDebugInfo(e.pos)
  var instr = RegInstruction(
    op: ropCall,
    a: result,
    opType: 4,
    funcIdx: funcIdx,
    numArgs: uint8(completeArgs.len),
    numResults: 1,  # Always 1 result for now
    debug: callDebug
  )
  c.prog.instructions.add(instr)
  log(c.verbose, fmt"Emitted ropCall for {e.fname} (index {funcIdx}) at reg {result} with {completeArgs.len} args at PC={c.prog.instructions.len - 1}")

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
    log(c.verbose, fmt"Loop body statement, nextReg = {c.allocator.nextReg}")
    c.compileStmt(stmt)

  # Restore allocator after loop body
  c.allocator.nextReg = loopSavedNextReg

  # Continue label - where continue statements jump to
  c.loopStack[^1].continueLabel = c.prog.instructions.len

  # ForLoop instruction (increment and test) - internal operation, no debug info
  # Jump back to loop start (body) if continuing
  c.prog.emitAsBx(ropForLoop, idxReg, int16(loopStart - c.prog.instructions.len - 1))

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
    log(c.verbose, fmt"Compiling expression statement at line {s.pos.line} expr kind = {s.sexpr.kind} expr pos = {s.sexpr.pos.line}")
    let reg = c.compileExpr(s.sexpr)
    c.allocator.freeReg(reg)

  of skVar:
    # Variable declaration (let or var) - allocate register for the new variable
    let stmtType = if s.vflag == vfLet: "let" else: "var"
    log(c.verbose, fmt"Compiling {stmtType} statement for variable: {s.vname} at line {s.pos.line}")

    # Track variable declaration in lifetime tracker
    let currentPC = c.prog.instructions.len

    if s.vinit.isSome:
      log(c.verbose, fmt"Compiling init expression for {s.vname} expr kind: {s.vinit.get.kind}")
      let valReg = c.compileExpr(s.vinit.get)
      c.allocator.regMap[s.vname] = valReg

      # Variable is declared and defined at this point
      c.lifetimeTracker.declareVariable(s.vname, valReg, currentPC)
      c.lifetimeTracker.defineVariable(s.vname, currentPC)

      log(c.verbose, fmt"Variable {s.vname} allocated to reg {valReg} with initialization")
    else:
      # Uninitialized variable - allocate register with nil
      let reg = c.allocator.allocReg(s.vname)
      c.prog.emitABC(ropLoadNil, reg, 0, 0, c.makeDebugInfo(s.pos))

      # Variable is declared but not yet defined (holds nil)
      c.lifetimeTracker.declareVariable(s.vname, reg, currentPC)

      log(c.verbose, fmt"Variable {s.vname} allocated to reg {reg} (uninitialized)")

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
    log(c.verbose, "Compiling if statement")
    if c.verbose:
      log(c.verbose, fmt"   Then body len = {s.thenBody.len}")
      log(c.verbose, fmt"   Else body len = {s.elseBody.len}")
      if s.elseBody.len > 0:
        log(c.verbose, fmt"   First else body statement: {s.elseBody[0].kind}")
        if s.elseBody[0].kind == skIf:
          log(c.verbose, "   Detected elif chain")
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
      log(c.verbose, "Compiling elif clause")

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
      log(c.verbose, fmt"Compiling else branch with {s.elseBody.len} statements")
      for stmt in s.elseBody:
        log(c.verbose, fmt"  Else body statement: {stmt.kind}")
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
    # Execute all registered defers before returning
    c.prog.emitABC(ropExecDefers, 0, 0, 0, c.makeDebugInfo(s.pos))

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
      echo "Warning: break statement outside of loop" # TODO - implement proper error/warnings handling

  of skComptime:
    # Comptime blocks should contain injected variables after foldComptime
    log(c.verbose, fmt"Processing comptime block with {s.cbody.len} statements")
    for stmt in s.cbody:
      c.compileStmt(stmt)

  of skDefer:
    # Defer statement - compile defer body and emit registration instruction
    log(c.verbose, fmt"Compiling defer block with {s.deferBody.len} statements")

    # Emit jump over defer body (we'll patch this later)
    let jumpOverPos = c.prog.instructions.len
    c.prog.emitAsBx(ropJmp, 0, 0, c.makeDebugInfo(s.pos))

    # Mark the start of defer body
    let deferBodyStart = c.prog.instructions.len

    # Compile defer body statements
    for stmt in s.deferBody:
      c.compileStmt(stmt)

    # Emit defer end marker
    c.prog.emitABC(ropDeferEnd, 0, 0, 0, c.makeDebugInfo(s.pos))

    # Patch the jump to skip over defer body
    let deferBodyEnd = c.prog.instructions.len
    c.prog.instructions[jumpOverPos].sbx = int16(deferBodyEnd - jumpOverPos - 1)

    # Emit PushDefer instruction to register this defer (at the skip location)
    # The offset points back to the defer body start
    let offsetToDefer = deferBodyStart - deferBodyEnd
    c.prog.emitAsBx(ropPushDefer, 0, int16(offsetToDefer), c.makeDebugInfo(s.pos))

    log(c.verbose, fmt"Defer body at PC {deferBodyStart}..{deferBodyEnd - 1} registration at PC {deferBodyEnd}")

  of skTypeDecl:
    # Type declarations - these are handled during type checking
    log(c.verbose, "Skipping type declaration (handled during type checking)")

  of skImport:
    # Import statements - these are handled during parsing
    log(c.verbose, "Skipping import statement (handled during parsing)")

  of skDiscard:
    # Discard statement - compile expressions and free their registers
    log(c.verbose, fmt"Compiling discard statement with {s.dexprs.len} expressions")
    for expr in s.dexprs:
      let reg = c.compileExpr(expr)
      c.allocator.freeReg(reg)

  of skFieldAssign:
    # Field or array index assignment
    log(c.verbose, "Field/index assignment")

    case s.faTarget.kind:
    of ekFieldAccess:
      # Field assignment for objects
      # The object should be a simple variable for now
      if s.faTarget.objectExpr.kind != ekVar:
        echo "Error: Field assignment object is not a variable" # TODO - implement proper error/warnings handling
        return

      # Get the object register
      let objName = s.faTarget.objectExpr.vname
      if not c.allocator.regMap.hasKey(objName):
        echo "Error: Variable not found in register map: ", objName # TODO - implement proper error/warnings handling
        return

      let objReg = c.allocator.regMap[objName]

      # Compile the value to assign
      let valReg = c.compileExpr(s.faValue)

      # Get or add the field name to const pool
      let fieldConst = c.addStringConst(s.faTarget.fieldName)

      # Emit ropSetField to set object field: R[objReg][K[fieldConst]] = R[valReg]
      c.prog.emitABC(ropSetField, valReg, objReg, uint8(fieldConst), c.makeDebugInfo(s.pos))

      log(c.verbose, fmt"Set field '{s.faTarget.fieldName}' (const[{fieldConst}]) in object at reg {objReg} to value at reg {valReg}")

      c.allocator.freeReg(valReg)

    of ekIndex:
      # Array index assignment: arr[idx] = value
      # Compile the array expression
      let arrayReg = c.compileExpr(s.faTarget.arrayExpr)

      # Compile the index expression
      let indexReg = c.compileExpr(s.faTarget.indexExpr)

      # Compile the value to assign
      let valueReg = c.compileExpr(s.faValue)

      # Emit SETINDEX instruction: R[arrayReg][R[indexReg]] = R[valueReg]
      c.prog.emitABC(ropSetIndex, arrayReg, indexReg, valueReg, c.makeDebugInfo(s.pos))

      # Free temporary registers
      c.allocator.freeReg(valueReg)
      c.allocator.freeReg(indexReg)
      c.allocator.freeReg(arrayReg)

    else:
      echo "Error: Field assignment target must be field access or array index" # TODO - implement proper error/warnings handling
      return

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

  # Execute all registered defers at the end of the function
  c.prog.emitABC(ropExecDefers, 0, 0, 0)

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
    log(verbose, fmt"Starting compilation, funInstances count: {p.funInstances.len}")
    for fname, _ in p.funInstances:
      log(verbose, fmt"   Function available: {fname}")

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
        library: "",       # Will be filled by compiler.nim
        libraryPath: "",   # Will be filled by compiler.nim
        symbol: baseName,  # Use base name as symbol for now
        baseName: baseName,
        paramTypes: @[],   # Will be filled by compiler.nim
        returnType: ""     # Will be filled by compiler.nim
      )

      log(verbose, fmt"Identified C FFI function: {fname} -> {baseName}")

  # Compile all functions except main first
  for fname, funcDecl in p.funInstances:
    let isBuiltin = funcDecl.body.len == 0  # Builtin functions have no body
    let isCFFI = compiler.prog.cffiInfo.hasKey(fname)

    log(verbose, fmt"Processing function: {fname} isBuiltin={isBuiltin} isCFFI={isCFFI} body.len={funcDecl.body.len}")

    if fname != MAIN_FUNCTION_NAME and not isBuiltin and not isCFFI:  # Skip builtin and C FFI functions
      let startPos = compiler.prog.instructions.len

      log(verbose, fmt"Compiling function {fname}")

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
        log(verbose, fmt"Allocated parameter '{param.name}' to register {paramReg}")

      # Compile function body
      for stmt in funcDecl.body:
        compiler.compileStmt(stmt)

      # Execute all registered defers at the end of the function
      compiler.prog.emitABC(ropExecDefers, 0, 0, 0)

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

      log(verbose, fmt"Compiled function {fname} at {startPos}..{endPos}")

  # Compile global initialization if needed
  if p.globals.len > 0:
    log(verbose, fmt"Compiling {p.globals.len} global variables")

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

    # After global initialization, call main using ropCall
    let mainNameReg = compiler.allocator.allocReg()
    let mainFuncIdx = compiler.addFunctionIndex(MAIN_FUNCTION_NAME)

    # Call main function using ropCall
    var mainInstr = RegInstruction(
      op: ropCall,
      a: mainNameReg,
      opType: 4,
      funcIdx: mainFuncIdx,
      numArgs: 0,
      numResults: 0,
      debug: RegDebugInfo()  # Empty debug info for global initialization
    )
    compiler.prog.instructions.add(mainInstr)
    compiler.prog.emitABC(ropReturn, 0, 0, 0)  # Return after main completes

    # Set entry point to global initialization
    compiler.prog.entryPoint = globalInitStart
    log(verbose, fmt"Entry point set to PC {globalInitStart} ({GLOBAL_INIT_FUNCTION_NAME} function)")

    # Register the global initialization code as a special function for debugging
    let globalInitEnd = compiler.prog.instructions.len - 1
    compiler.prog.functions[GLOBAL_INIT_FUNCTION_NAME] = regvm.FunctionInfo(
      name: GLOBAL_INIT_FUNCTION_NAME,
      startPos: globalInitStart,
      endPos: globalInitEnd,
      numParams: 0,
      numLocals: 0
    )

    log(verbose, fmt"Registered {GLOBAL_INIT_FUNCTION_NAME} initialization function at PC {globalInitStart}..{globalInitEnd}")
  else:
    # Set entry point to main (will be compiled next)
    compiler.prog.entryPoint = compiler.prog.instructions.len

  # Find and compile main function last
  if p.funInstances.hasKey(MAIN_FUNCTION_NAME):
    let mainFunc = p.funInstances[MAIN_FUNCTION_NAME]

    # Reset allocator for main
    compiler.allocator = RegAllocator(
      nextReg: 0,
      maxRegs: uint8(MAX_REGISTERS),
      regMap: initTable[string, uint8]()
    )

    let mainStartPos = compiler.prog.instructions.len
    compiler.compileFunDecl(MAIN_FUNCTION_NAME, mainFunc.params, mainFunc.ret, mainFunc.body)
    let mainEndPos = compiler.prog.instructions.len

    # Store main function info
    compiler.prog.functions[MAIN_FUNCTION_NAME] = regvm.FunctionInfo(
      name: MAIN_FUNCTION_NAME,
      startPos: mainStartPos,
      endPos: mainEndPos,
      numParams: mainFunc.params.len,
      numLocals: 0
    )

    log(verbose, fmt"Compiled main function at {mainStartPos}..{mainEndPos}")

  # Apply optimization passes
  # Enable with only Pass 1 and 2 (disable Pass 3 which seems buggy)
  if optimizeLevel >= 1:
    optimizeBytecode(compiler.prog)

  return compiler.prog

proc optimizeBytecode*(prog: var RegBytecodeProgram) =
  ## Apply bytecode optimization passes (TODO)

  # Pass 1: Constant folding for consecutive LoadK followed by arithmetic
  # Pattern: LoadK imm1 -> R0; LoadK imm2 -> R1; Add R2 = R0 + R1 => LoadK (imm1+imm2) -> R2
  var i = 0
  while i < prog.instructions.len:
    inc i
