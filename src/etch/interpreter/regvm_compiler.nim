# regcompiler.nim
# Register-based bytecode compiler with aggressive optimizations

import std/[tables, macros, options, strutils, strformat, algorithm]
import ../common/[constants, types, logging]
import ../frontend/ast
import ./[regvm, regvm_lifetime]
#import regvm_optimizer


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
    currentFunction*: string          # Current function being compiled (for debug info)
    globalVars*: seq[string]          # Names of global variables
    hasDefers*: bool                  # True if current function has defer statements
    refVars*: Table[uint8, EtchType]  # Track ref-typed variables: register -> type
    types*: Table[string, EtchType]   # User-defined types for accessing field defaults

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
    log(c.verbose, &"String '{s}' already in const pool at index {c.constMap[s]}")
    return c.constMap[s]

  let v = regvm.makeString(s)
  result = c.addConst(v)
  c.constMap[s] = result
  log(c.verbose, &"Added string '{s}' to const pool at index {result}")

proc addFunctionIndex*(c: var RegCompiler, funcName: string): uint16 =
  ## Add function name to function table and return its index
  ## The function table maps indices to function names for fast direct calls
  for i, name in c.prog.functionTable:
    if name == funcName:
      return uint16(i)

  let idx = uint16(c.prog.functionTable.len)
  c.prog.functionTable.add(funcName)
  log(c.verbose, &"Added function '{funcName}' to function table at index {idx}")
  return idx

# Forward declarations
proc compileExpr*(c: var RegCompiler, e: Expr): uint8
proc compileStmt*(c: var RegCompiler, s: Stmt)
proc compileBinOp(c: var RegCompiler, op: BinOp, dest, left, right: uint8, debug: RegDebugInfo = RegDebugInfo())
proc compileCall(c: var RegCompiler, e: Expr): uint8

proc makeDebugInfo(c: RegCompiler, pos: Pos): RegDebugInfo =
  ## Create debug info from AST position (only if debug mode enabled)
  if c.debug:
    result = RegDebugInfo(
      line: pos.line,
      col: pos.col,
      sourceFile: pos.filename,
      functionName: c.currentFunction
    )
  else:
    result = RegDebugInfo()  # Empty debug info in release mode

proc needsArrayCleanup(typ: EtchType): bool =
  ## Recursively check if an array type contains refs/weaks that need cleanup
  if typ == nil:
    return false
  case typ.kind:
  of tkRef, tkWeak:
    return true
  of tkArray:
    return needsArrayCleanup(typ.inner)
  else:
    return false

proc emitDecRefsForScope(c: var RegCompiler, excludeReg: int = -1, removeFromTracking: bool = false) =
  ## Emit ropDecRef for all ref-typed variables in current scope
  ## This should be called before function returns or scope exits
  ## excludeReg: if >= 0, don't emit decRef for this register (for return values)
  ## removeFromTracking: if true, remove emitted registers from refVars to prevent double-decRef
  ## Emits in REVERSE register order to ensure proper destruction order
  log(c.verbose, &"emitDecRefsForScope: refVars count = {c.refVars.len}, excludeReg = {excludeReg}, removeFromTracking = {removeFromTracking}")

  # Collect all registers that need decRef
  var regsToDecRef: seq[uint8] = @[]
  for reg, typ in c.refVars:
    if excludeReg < 0 or reg != uint8(excludeReg):
      regsToDecRef.add(reg)

  # Sort in REVERSE order (highest register first) to ensure reverse allocation order
  regsToDecRef.sort(system.cmp[uint8], order = Descending)

  # Emit cleanup code in reverse register order
  for reg in regsToDecRef:
    let typ = c.refVars[reg]

    # Check if this is an array of refs or weaks (or nested arrays containing them)
    if typ.kind == tkArray and typ.inner != nil and (typ.inner.kind == tkRef or typ.inner.kind == tkWeak or (typ.inner.kind == tkArray and needsArrayCleanup(typ.inner))):
      # For arrays of refs, we need to DecRef each element
      log(c.verbose, &"Emitting DecRef cleanup for array[ref] in reg {reg}")

      # Get array length into a temp register
      let lenReg = c.allocator.allocReg()
      c.prog.emitABC(ropLen, lenReg, reg, 0)

      # Allocate registers for loop: index and element
      let idxReg = c.allocator.allocReg()
      let elemReg = c.allocator.allocReg()

      # Initialize index to length (we'll iterate backwards)
      c.prog.emitABC(ropMove, idxReg, lenReg, 0)

      # Loop start position
      let loopStart = c.prog.instructions.len

      # Decrement index by 1 first (so we go from length-1 down to 0)
      # ropSubI uses bx format: lower 8 bits = source reg, upper 8 bits = immediate
      c.prog.emitABx(ropSubI, idxReg, uint16(idxReg) or (uint16(1) shl 8))

      # Check if index >= 0 by testing 0 <= index
      let zeroConst = c.addConst(regvm.makeInt(0))
      let zeroReg = c.allocator.allocReg()
      c.prog.emitABx(ropLoadK, zeroReg, zeroConst)
      c.prog.emitABC(ropLe, 0, zeroReg, idxReg)  # Skip next instruction if 0 <= index (i.e., if index >= 0)

      # Jump to end if index < 0 (we skip this jump when index >= 0)
      let jmpEndPos = c.prog.instructions.len
      c.prog.emitAsBx(ropJmp, 0, 0)

      c.allocator.freeReg(zeroReg)

      # Get array element
      c.prog.emitABC(ropGetIndex, elemReg, reg, idxReg)

      # DecRef element
      c.prog.emitABC(ropDecRef, elemReg, 0, 0)

      # Jump back to loop start
      let jmpBackOffset = loopStart - c.prog.instructions.len - 1
      c.prog.emitAsBx(ropJmp, 0, int16(jmpBackOffset))

      # Patch jump to end
      c.prog.instructions[jmpEndPos].sbx = int16(c.prog.instructions.len - jmpEndPos - 1)

      # Free temporary registers
      c.allocator.freeReg(elemReg)
      c.allocator.freeReg(idxReg)
      c.allocator.freeReg(lenReg)

      log(c.verbose, &"Emitted array[ref] cleanup loop for reg {reg}")
    else:
      # Simple ref or weak - just emit DecRef
      c.prog.emitABC(ropDecRef, reg, 0, 0)
      log(c.verbose, &"Emitted ropDecRef for ref variable in reg {reg} at scope exit")

  # Remove from tracking if requested (for nested scopes)
  if removeFromTracking:
    for reg in regsToDecRef:
      c.refVars.del(reg)
      log(c.verbose, &"Removed reg {reg} from refVars tracking")

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
    log(c.verbose, &"Compiling integer {e.ival} to reg {result}")
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
    log(c.verbose, &"Compiling string expression: '{e.sval}'")
    let constIdx = c.addStringConst(e.sval)
    c.prog.emitABx(ropLoadK, result, constIdx, c.makeDebugInfo(e.pos))
    log(c.verbose, &"  Loaded to register {result} from const[{constIdx}]")

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
      log(c.verbose, &"Variable '{e.vname}' found in register {c.allocator.regMap[e.vname]}")
      return c.allocator.regMap[e.vname]
    else:
      # Load from global
      # IMPORTANT: Don't add globals to regMap - they can be modified elsewhere
      # and the cached register value would become stale
      log(c.verbose, &"Variable '{e.vname}' not in regMap, loading from global")
      result = c.allocator.allocReg()  # Don't pass name - don't cache globals
      let nameIdx = c.addStringConst(e.vname)
      c.prog.emitABx(ropGetGlobal, result, nameIdx, c.makeDebugInfo(e.pos))

  of ekBin:
    let leftReg = c.compileExpr(e.lhs)
    let rightReg = c.compileExpr(e.rhs)
    result = c.allocator.allocReg()
    log(c.verbose, &"Binary op: leftReg={leftReg} rightReg={rightReg} resultReg={result}")

    # Check for immediate optimizations
    if c.optimizeLevel >= 1 and e.rhs.kind == ekInt and
       e.rhs.ival >= -128 and e.rhs.ival <= 127:
      # Can use immediate version
      # Properly encode signed 8-bit immediate value using two's complement
      # For negative values, we need to convert to unsigned representation
      let imm8 = if e.rhs.ival < 0:
                   uint8(256 + e.rhs.ival)  # Two's complement: -1 becomes 255, -2 becomes 254, etc.
                 else:
                   uint8(e.rhs.ival)
      case e.bop:
      of boAdd:
        c.prog.emitABx(ropAddI, result, uint16(leftReg) or (uint16(imm8) shl 8), c.makeDebugInfo(e.pos))
      of boSub:
        c.prog.emitABx(ropSubI, result, uint16(leftReg) or (uint16(imm8) shl 8), c.makeDebugInfo(e.pos))
      of boMul:
        c.prog.emitABx(ropMulI, result, uint16(leftReg) or (uint16(imm8) shl 8), c.makeDebugInfo(e.pos))
      of boDiv:
        c.prog.emitABx(ropDivI, result, uint16(leftReg) or (uint16(imm8) shl 8), c.makeDebugInfo(e.pos))
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

    # Free the operand register after use
    c.allocator.freeReg(operandReg)

  of ekCall:
    result = c.compileCall(e)

  of ekArray:
    result = c.allocator.allocReg()
    log(c.verbose, &"Array expression allocated reg {result}")
    let debug = c.makeDebugInfo(e.pos)
    c.prog.emitABx(ropNewArray, result, uint16(e.elements.len), debug)

    # Set array elements
    for i, elem in e.elements:
      let elemReg = c.compileExpr(elem)
      # For now, always use the general SetIndex instruction
      # TODO: Optimize with immediate index using different encoding
      let idxReg = c.allocator.allocReg()
      let constIdx = c.addConst(regvm.makeInt(int64(i)))
      c.prog.emitABx(ropLoadK, idxReg, constIdx, debug)
      c.prog.emitABC(ropSetIndex, result, idxReg, elemReg, debug)
      c.allocator.freeReg(idxReg)
      c.allocator.freeReg(elemReg)

  of ekIndex:
    let arrReg = c.compileExpr(e.arrayExpr)
    result = c.allocator.allocReg()

    # Optimize for constant integer indices
    let debug = c.makeDebugInfo(e.pos)
    if c.optimizeLevel >= 1 and e.indexExpr.kind == ekInt and
       e.indexExpr.ival >= 0 and e.indexExpr.ival < 256:
      c.prog.emitABx(ropGetIndexI, result, uint16(arrReg) or (uint16(e.indexExpr.ival) shl 8), debug)
    else:
      let idxReg = c.compileExpr(e.indexExpr)
      c.prog.emitABC(ropGetIndex, result, arrReg, idxReg, debug)
      c.allocator.freeReg(idxReg)

    # Free array register after use
    c.allocator.freeReg(arrReg)

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

    # Create debug info for the entire new() expression (including argument preparation)
    let newDebug = c.makeDebugInfo(e.pos)

    # Set up argument in next register
    if initReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, initReg, 0, newDebug)
      c.allocator.freeReg(initReg)

    # Call new function using ropCall
    var instr = RegInstruction(
      op: ropCall,
      a: result,
      opType: 4,
      funcIdx: funcIdx,
      numArgs: 1,
      numResults: 1,
      debug: newDebug
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

    # Create debug info for the entire deref() expression (including argument preparation)
    let derefDebug = c.makeDebugInfo(e.pos)

    # Set up argument in next register
    if refReg != result + 1:
      c.prog.emitABC(ropMove, result + 1, refReg, 0, derefDebug)
      c.allocator.freeReg(refReg)

    # Call deref function using ropCall
    var instr = RegInstruction(
      op: ropCall,
      a: result,
      opType: 4,
      funcIdx: funcIdx,
      numArgs: 1,
      numResults: 1,
      debug: derefDebug
    )
    c.prog.instructions.add(instr)

  of ekNew:
    # Handle new for heap allocation using reference counting
    log(c.verbose, "Compiling ekNew expression with heap allocation")
    result = c.allocator.allocReg()

    # Determine if we're creating a scalar ref or an object ref
    let innerType = if e.typ != nil and e.typ.kind == tkRef: e.typ.inner else: nil
    let isScalarRef = innerType != nil and innerType.kind in {tkInt, tkFloat, tkBool, tkString, tkChar}

    if isScalarRef and e.initExpr.isSome:
      # Scalar reference: new(42) -> compile value and use ropNewRef with value
      log(c.verbose, "  Creating scalar heap reference")
      let valueReg = c.compileExpr(e.initExpr.get)

      # ropNewRef with B=valueReg, C=1 means "allocate scalar with this value"
      # C=1 is used as a flag to distinguish scalar allocation from table allocation
      c.prog.emitABC(ropNewRef, result, valueReg, 1, c.makeDebugInfo(e.pos))
      log(c.verbose, &"  Emitted ropNewRef for scalar from reg {valueReg} to {result}")

      c.allocator.freeReg(valueReg)
    else:
      # Object reference: new[T]{...} -> allocate table and initialize fields
      # Look up destructor function index for this type
      # Note: We encode as funcIdx+1, so 0 means "no destructor", 1 means funcIdx=0, etc.
      var destructorFuncIdx = 0'u8  # Default: no destructor (0 = none)
      if innerType != nil and innerType.destructor.isSome:
        let destructorName = innerType.destructor.get
        # Use addFunctionIndex to add destructor to functionTable if not already there
        let funcIdx = c.addFunctionIndex(destructorName)
        destructorFuncIdx = uint8(funcIdx + 1)  # Encode as index+1
        log(c.verbose, &"  Found destructor {destructorName} at function index {funcIdx}, encoded as {destructorFuncIdx}")

      # C=0 means table allocation, B=encoded destructor index (0 if none, funcIdx+1 otherwise)
      c.prog.emitABC(ropNewRef, result, destructorFuncIdx, 0, c.makeDebugInfo(e.pos))
      log(c.verbose, &"  Emitted ropNewRef for table at reg {result} with destructor encoded={destructorFuncIdx}")

      # If there's an init expression (object literal), initialize fields
      if e.initExpr.isSome:
        let initExpr = e.initExpr.get

        # The init expression should be an object literal
        if initExpr.kind == ekObjectLiteral:
          log(c.verbose, &"  Initializing {initExpr.fieldInits.len} fields for heap object")

          # Set each field on the heap object
          for fieldInit in initExpr.fieldInits:
            let fieldName = fieldInit.name
            let fieldExpr = fieldInit.value

            # Compile the field value
            let valueReg = c.compileExpr(fieldExpr)

            # Add field name to constants
            let fieldConstIdx = c.addStringConst(fieldName)

            # If storing a ref value, increment its reference count
            if fieldExpr.typ != nil and fieldExpr.typ.kind == tkRef:
              c.prog.emitABC(ropIncRef, valueReg, 0, 0, c.makeDebugInfo(fieldInit.value.pos))
              log(c.verbose, &"    Emitted ropIncRef for ref value in reg {valueReg} before storing in field")

            # Set field: heap_object[fieldName] = value
            # ropSetField: R[B][K[C]] = R[A]
            # So: B = result (heap ref), C = field name const, A = value reg
            c.prog.emitABC(ropSetField, valueReg, result, fieldConstIdx.uint8, c.makeDebugInfo(fieldInit.value.pos))
            log(c.verbose, &"    Set field '{fieldName}' from reg {valueReg}")

            c.allocator.freeReg(valueReg)
        else:
          # Non-object-literal init
          log(c.verbose, "  WARNING: ekNew with non-object-literal init expression for object type")
      else:
        # No init expression - check if type has field defaults and initialize them
        log(c.verbose, "  No init expression provided")

        # Look up the type to see if it has fields with default values
        if innerType != nil and innerType.kind == tkObject and innerType.fields.len > 0:
          log(c.verbose, &"  Object type has {innerType.fields.len} fields, checking for defaults")

          for field in innerType.fields:
            if field.defaultValue.isSome:
              log(c.verbose, &"  Initializing field '{field.name}' with default value")

              # Compile the default value expression
              let valueReg = c.compileExpr(field.defaultValue.get)

              # Add field name to constants
              let fieldConstIdx = c.addStringConst(field.name)

              # If storing a ref value, increment its reference count
              if field.fieldType.kind == tkRef:
                c.prog.emitABC(ropIncRef, valueReg, 0, 0, c.makeDebugInfo(field.defaultValue.get.pos))
                log(c.verbose, &"    Emitted ropIncRef for ref value in reg {valueReg} before storing in field")

              # Set field: heap_object[fieldName] = value
              c.prog.emitABC(ropSetField, valueReg, result, fieldConstIdx.uint8, c.makeDebugInfo(field.defaultValue.get.pos))
              log(c.verbose, &"    Set field '{field.name}' from reg {valueReg}")

              c.allocator.freeReg(valueReg)
        else:
          log(c.verbose, "  Created empty heap object")

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
      log(c.verbose, &"  Compiling match case {i} pattern: {matchCase.pattern.kind}")

      # Pattern matching - simplified version
      var shouldJumpToNext = -1
      let debug = c.makeDebugInfo(e.pos)

      case matchCase.pattern.kind:
      of pkSome:
        # Check if it's a some value
        # ropTestTag: skips next if tags MATCH
        # So if tag is some, skip the jump and execute case body
        # If tag is not some, execute jump to next case
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkSome), 0, debug)  # Test if tag is some
        log(c.verbose, &"  Emitted ropTestTag for some at PC={c.prog.instructions.len - 1}")
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, debug)  # Jump to next case if not some

        # Extract the value if it's some
        if matchCase.pattern.bindName != "":
          # Unwrap the some value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapOption, unwrappedReg, matchReg, 0, debug)
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg
          log(c.verbose, &"  Bound some pattern variable '{matchCase.pattern.bindName}' to unwrapped reg {unwrappedReg}")

      of pkNone:
        # Check if it's none
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkNone), 0, debug)  # Test if tag is none
        log(c.verbose, &"  Emitted ropTestTag for none at PC={c.prog.instructions.len - 1}")
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, debug)  # Jump to next case if not none
        log(c.verbose, &"  Emitted ropJmp at PC={c.prog.instructions.len - 1} (will be patched)");

      of pkOk:
        # Check if it's an ovalue
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkOk), 0, debug)  # Test if tag is ok
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, debug)

        if matchCase.pattern.bindName != "":
          # Unwrap the ok value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, debug)
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkErr:
        # Check if it's an error value
        c.prog.emitABC(ropTestTag, matchReg, uint8(vkErr), 0, debug)  # Test if tag is error
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, debug)

        if matchCase.pattern.bindName != "":
          # Unwrap the error value
          let unwrappedReg = c.allocator.allocReg()
          c.prog.emitABC(ropUnwrapResult, unwrappedReg, matchReg, 0, debug)
          c.allocator.regMap[matchCase.pattern.bindName] = unwrappedReg

      of pkWildcard:
        # Wildcard always matches - no test needed
        discard

      of pkType:
        # Type pattern matching (for union types)
        # Check if the value has the correct type tag
        log(c.verbose, &"  Type pattern: {matchCase.pattern.typePattern.kind} bind: {matchCase.pattern.typeBind}")

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
            log(c.verbose, &"  Warning: Unsupported type for pattern matching: {matchCase.pattern.typePattern.kind}")
            vkNil

        let debug = c.makeDebugInfo(e.pos)

        # Test if the kind matches
        c.prog.emitABC(ropTestTag, matchReg, uint8(expectedKind), 0, debug)
        shouldJumpToNext = c.prog.instructions.len
        c.prog.emitAsBx(ropJmp, 0, 0, debug)  # Jump to next case if tag doesn't match

        # Bind the value if there's a binding variable
        if matchCase.pattern.typeBind != "":
          # The value is already in matchReg, just bind it
          c.allocator.regMap[matchCase.pattern.typeBind] = matchReg
          log(c.verbose, &"  Bound type pattern variable '{matchCase.pattern.typeBind}' to reg {matchReg}")

      # Compile the case body
      if matchCase.body.len > 0:
        log(c.verbose, &"  Match case body has {matchCase.body.len} statements")
        if c.verbose:
          for idx, stmt in matchCase.body:
            echo "[REGCOMPILER]     Body stmt ", idx, " kind: ", stmt.kind
            if stmt.kind == skExpr:
              echo "[REGCOMPILER]       Expr kind: ", stmt.sexpr.kind

        # For match expressions, the body is typically a single expression statement
        # that should be the result of the match
        if matchCase.body.len == 1 and matchCase.body[0].kind == skExpr:
          # Single expression - this is the result
          log(c.verbose, &"  Case body starts at PC={c.prog.instructions.len}")
          let exprReg = c.compileExpr(matchCase.body[0].sexpr)
          log(c.verbose, &"  Match case body expr compiled to reg {exprReg} result reg is {result}")
          if exprReg != result:
            c.prog.emitABC(ropMove, result, exprReg, 0)
            log(c.verbose, &"  Emitted ropMove from {exprReg} to {result} at PC={c.prog.instructions.len - 1}")
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
    log(c.verbose, &"Compiling ekObjectLiteral expression with {e.fieldInits.len} fields")
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

      # If storing a ref value, increment its reference count
      if fieldExpr.typ != nil and fieldExpr.typ.kind == tkRef:
        c.prog.emitABC(ropIncRef, valueReg, 0, 0)
        log(c.verbose, &"  Emitted ropIncRef for ref value in reg {valueReg} before storing in field")

      # Emit ropSetField: R[tableReg][K[fieldConstIdx]] = R[valueReg]
      c.prog.emitABC(ropSetField, valueReg, result, uint8(fieldConstIdx))

      # Free the value register
      c.allocator.freeReg(valueReg)

      log(c.verbose, &"Set field '{fieldName}' (const[{fieldConstIdx}]) = reg {valueReg}")

    # Add default values for missing fields
    if e.objectType != nil and e.objectType.kind == tkObject:
      for field in e.objectType.fields:
        if field.name notin providedFields and field.defaultValue.isSome:
          log(c.verbose, &"Adding default value for field '{field.name}'")

          # Compile the default value expression
          let defaultExpr = field.defaultValue.get
          let valueReg = c.compileExpr(defaultExpr)

          # Add field name to constants
          let fieldConstIdx = c.addStringConst(field.name)

          # If storing a ref value, increment its reference count
          if defaultExpr.typ != nil and defaultExpr.typ.kind == tkRef:
            c.prog.emitABC(ropIncRef, valueReg, 0, 0)
            log(c.verbose, &"  Emitted ropIncRef for ref default value in reg {valueReg}")

          # Set the default value
          c.prog.emitABC(ropSetField, valueReg, result, uint8(fieldConstIdx))

          # Free the value register
          c.allocator.freeReg(valueReg)

          log(c.verbose, &"Set default field '{field.name}' (const[{fieldConstIdx}]) = reg {valueReg}")

  of ekFieldAccess:
    # Handle field access on objects
    log(c.verbose, &"Compiling ekFieldAccess expression: field '{e.fieldName}'")

    # Compile the object expression
    let objReg = c.compileExpr(e.objectExpr)
    result = c.allocator.allocReg()

    # Add field name to constants if not already there
    let fieldConstIdx = c.addStringConst(e.fieldName)

    # Emit ropGetField: R[result] = R[objReg][K[fieldConstIdx]]
    c.prog.emitABC(ropGetField, result, objReg, uint8(fieldConstIdx), c.makeDebugInfo(e.pos))

    # Free the object register
    c.allocator.freeReg(objReg)

    log(c.verbose, &"Get field '{e.fieldName}' (const[{fieldConstIdx}]) from reg {objReg} to reg {result}")

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

  of ekCompiles:
    # compiles{...} should have been folded to a boolean during comptime pass
    # If we reach here, something went wrong - return false as a fallback
    log(c.verbose, "Warning: ekCompiles reached bytecode compiler (should have been folded)")
    result = c.allocator.allocReg()
    c.prog.emitAsBx(ropLoadK, result, 0, c.makeDebugInfo(e.pos))  # Load false

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

proc isInlinableFunction(c: var RegCompiler, funcName: string): bool =
  ## Check if a function is suitable for inlining
  ## Criteria: very small, pure, non-recursive, simple control flow
  if not c.funInstances.hasKey(funcName):
    return false

  let funcDecl = c.funInstances[funcName]

  # Only inline very simple functions (single return statement)
  if funcDecl.body.len != 1:
    return false

  # Must be a single return statement with a simple expression
  let stmt = funcDecl.body[0]
  if stmt.kind != skReturn:
    return false

  if not stmt.re.isSome():
    return false

  let retExpr = stmt.re.get()

  # Only inline if the return expression is a simple binary operation or variable
  # Don't inline if it contains calls, control flow, or complex operations
  proc isSimpleExpr(e: Expr): bool =
    case e.kind:
    of ekVar, ekInt, ekFloat, ekString, ekBool, ekChar:
      return true
    of ekBin:
      # Only simple arithmetic and comparison operations
      return isSimpleExpr(e.lhs) and isSimpleExpr(e.rhs) and
             e.bop in {boAdd, boSub, boMul, boDiv, boMod, boEq, boNe, boLt, boLe, boGt, boGe}
    of ekUn:
      return isSimpleExpr(e.ue)
    else:
      return false

  if not isSimpleExpr(retExpr):
    return false

  return true

proc inlineFunction(c: var RegCompiler, funcName: string, argRegs: seq[uint8], resultReg: uint8) =
  ## Inline a function call by compiling its body with parameter substitution
  let funcDecl = c.funInstances[funcName]
  log(c.verbose, &"Inlining function {funcName} into register {resultReg}")

  # Create a parameter mapping: param name -> arg register
  var paramMap: Table[string, uint8]
  for i, param in funcDecl.params:
    if i < argRegs.len:
      paramMap[param.name] = argRegs[i]
      log(c.verbose, &"  Param '{param.name}' -> R{argRegs[i]}")

  # Save current register map and replace it with parameter map
  let savedRegMap = c.allocator.regMap
  c.allocator.regMap = paramMap

  # Compile function body
  for stmt in funcDecl.body:
    if stmt.kind == skReturn and stmt.re.isSome():
      # For return statements, compile the expression directly to resultReg
      let retExpr = stmt.re.get()
      let tempReg = c.compileExpr(retExpr)
      if tempReg != resultReg:
        c.prog.emitABC(ropMove, resultReg, tempReg, 0)
        c.allocator.freeReg(tempReg)
    else:
      c.compileStmt(stmt)

  # Restore register map
  c.allocator.regMap = savedRegMap

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
          log(c.verbose, &"Warning: Missing argument for parameter {i} with no default value")

  if c.verbose:
    log(c.verbose, &"compileCall: {e.fname} allocated reg {result}")
    log(c.verbose, &"   original args.len = {e.args.len}")
    log(c.verbose, &"   complete args.len = {completeArgs.len}")

  # Try to inline if optimization level >= 1
  if c.optimizeLevel >= 1 and c.isInlinableFunction(e.fname):
    log(c.verbose, &"Attempting to inline function {e.fname}")

    # Compile arguments to registers
    var argRegs: seq[uint8] = @[]
    for arg in completeArgs:
      let argReg = c.compileExpr(arg)
      argRegs.add(argReg)

    # Inline the function
    c.inlineFunction(e.fname, argRegs, result)

    # Free argument registers
    for argReg in argRegs:
      c.allocator.freeReg(argReg)

    log(c.verbose, &"Successfully inlined {e.fname}")
    return result

  # Get or create function index for direct calls
  let funcIdx = c.addFunctionIndex(e.fname)
  log(c.verbose, &"Function '{e.fname}' has index {funcIdx} in function table")

  # Create debug info for the entire call statement (including argument preparation)
  let callDebug = c.makeDebugInfo(e.pos)

  # Reserve registers for arguments first
  let numArgs = completeArgs.len
  for i in 0..<numArgs:
    let targetReg = result + uint8(i) + 1
    # Make sure these registers are marked as allocated
    if targetReg >= c.allocator.nextReg:
      c.allocator.setNextReg(targetReg + 1)

  # Then compile arguments
  var argRegs: seq[uint8] = @[]

  # Get parameter types for conversion checking
  var paramTypes: seq[EtchType] = @[]
  if c.funInstances.hasKey(e.fname):
    let funcDecl = c.funInstances[e.fname]
    for param in funcDecl.params:
      paramTypes.add(param.typ)

  for i, arg in completeArgs:
    log(c.verbose, &"Compiling argument {i} for function {e.fname}")
    log(c.verbose and arg.kind == ekString, &"   String argument: '{arg.sval}'")

    let targetReg = result + uint8(i) + 1
    var effectiveReg = targetReg

    # Compile argument to a temporary register first
    var tempReg: uint8
    if arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname):
      tempReg = c.allocator.regMap[arg.vname]
    else:
      tempReg = c.compileExpr(arg)

    # Check if we need ref->weak conversion
    let needsWeakConversion =
      i < paramTypes.len and
      paramTypes[i].kind == tkWeak and
      arg.typ != nil and arg.typ.kind == tkRef

    if needsWeakConversion:
      # Wrap ref in weak wrapper
      let weakReg = if tempReg == targetReg: c.allocator.allocReg() else: targetReg
      c.prog.emitABC(ropNewWeak, weakReg, tempReg, 0, callDebug)
      log(c.verbose, &"  Wrapping ref arg {i} in reg {tempReg} with weak wrapper in reg {weakReg}")
      # Free tempReg if it's not a variable register
      let isVarReg = arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname) and
                     tempReg == c.allocator.regMap[arg.vname]
      if not isVarReg:
        c.allocator.freeReg(tempReg)
      effectiveReg = weakReg
    elif tempReg != targetReg:
      # Normal move
      c.prog.emitABC(ropMove, targetReg, tempReg, 0, callDebug)
      log(c.verbose, &"  Moving arg {i} from reg {tempReg} to reg {targetReg}")
      if not (arg.kind == ekVar and c.allocator.regMap.hasKey(arg.vname)):
        c.allocator.freeReg(tempReg)
    else:
      log(c.verbose, &"  Arg {i} already in correct position: reg {tempReg}")

    argRegs.add(effectiveReg)

  # Emit ropCall instruction with function index
  # Uses opType=4 (function call format)
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
  log(c.verbose, &"Emitted ropCall for {e.fname} (index {funcIdx}) at reg {result} with {completeArgs.len} args at PC={c.prog.instructions.len - 1}")

  # Free argument registers after the call - they're no longer needed
  # The result register stays allocated as it may be used by the caller
  for argReg in argRegs:
    log(c.verbose, &"  Freed argument register {argReg} after call")
    c.allocator.freeReg(argReg)

proc compileForLoop(c: var RegCompiler, s: Stmt) =
  ## Compile optimized for loop

  if s.farray.isSome():
    # For-in loop over array/string
    let arrReg = c.compileExpr(s.farray.get())

    # Allocate registers for loop state
    let idxReg = c.allocator.allocReg()  # Loop index
    let lenReg = c.allocator.allocReg()  # Array length
    let elemReg = c.allocator.allocReg(s.fvar)  # Current element (loop variable)
    let debug = c.makeDebugInfo(s.pos)

    # Initialize index to 0 - has debug info so we stop at the for statement once
    let loopStartPC = c.prog.instructions.len
    c.prog.emitAsBx(ropLoadK, idxReg, 0, debug)

    # Track loop variable lifetime - declare at loop start (in current scope)
    c.lifetimeTracker.declareVariable(s.fvar, elemReg, loopStartPC)

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
    c.prog.emitABC(ropLt, 0, idxReg, lenReg, debug)  # Skip exit jump when idx < len
    let exitJmp = c.prog.instructions.len
    c.prog.emitAsBx(ropJmp, 0, 0)  # Jump to exit if idx >= len

    # Get current element: elemReg = arrReg[idxReg] (internal operation - no debug info)
    let getIndexPC = c.prog.instructions.len
    c.prog.emitABC(ropGetIndex, elemReg, arrReg, idxReg)

    # Mark loop variable as defined (gets its value from array)
    c.lifetimeTracker.defineVariable(s.fvar, getIndexPC)

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
  c.allocator.setNextReg(max(c.allocator.nextReg, stepReg + 1))

  # Initialize loop variables - first operation has debug info so we stop at for statement once
  let startReg = c.compileExpr(startExpr)
  let loopInitPC = c.prog.instructions.len
  c.prog.emitABC(ropMove, idxReg, startReg, 0, c.makeDebugInfo(s.pos))

  # Track loop variable lifetime - declare and define at loop initialization (in current scope)
  c.lifetimeTracker.declareVariable(s.fvar, idxReg, loopInitPC)
  c.lifetimeTracker.defineVariable(s.fvar, loopInitPC)

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
    log(c.verbose, &"Loop body statement, nextReg = {c.allocator.nextReg}")
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
  c.allocator.setNextReg(savedNextReg + 3)  # Keep the 3 loop registers

proc compileStmt*(c: var RegCompiler, s: Stmt) =
  case s.kind:
  of skExpr:
    # Compile expression and free its register if not used
    log(c.verbose, &"Compiling expression statement at line {s.pos.line} expr kind = {s.sexpr.kind} expr pos = {s.sexpr.pos.line}")
    let reg = c.compileExpr(s.sexpr)
    c.allocator.freeReg(reg)

  of skVar:
    # Variable declaration (let or var) - allocate register for the new variable
    let stmtType = if s.vflag == vfLet: "let" else: "var"
    log(c.verbose, &"Compiling {stmtType} statement for variable: {s.vname} at line {s.pos.line}")

    # Track variable declaration in lifetime tracker
    let currentPC = c.prog.instructions.len

    if s.vinit.isSome:
      log(c.verbose, &"Compiling init expression for {s.vname} expr kind: {s.vinit.get.kind}")
      let valReg = c.compileExpr(s.vinit.get)

      # Check if we need weak-to-strong conversion
      let varIsRef = s.vtype != nil and s.vtype.kind == tkRef
      let initIsWeak = s.vinit.get.typ != nil and s.vinit.get.typ.kind == tkWeak

      var finalReg = valReg
      if varIsRef and initIsWeak:
        # Promote weak to strong
        let strongReg = c.allocator.allocReg()
        c.prog.emitABC(ropWeakToStrong, strongReg, valReg, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Promoting weak ref in reg {valReg} to strong ref in reg {strongReg} for {s.vname}")
        # Don't free valReg - it might be a variable's register that's still in use
        finalReg = strongReg

      c.allocator.regMap[s.vname] = finalReg

      # Track ref-typed, weak-typed, and arrays containing refs/weaks for reference counting
      let needsTracking = s.vtype != nil and (
        s.vtype.kind == tkRef or
        s.vtype.kind == tkWeak or
        (s.vtype.kind == tkArray and needsArrayCleanup(s.vtype))
      )
      if needsTracking:
        c.refVars[finalReg] = s.vtype
        let typeName = case s.vtype.kind
          of tkRef: "ref"
          of tkWeak: "weak"
          of tkArray: "array[ref]"
          else: "unknown"
        log(c.verbose, &"Tracked {typeName} variable {s.vname} in reg {finalReg}")

      # Variable is declared and defined at this point
      c.lifetimeTracker.declareVariable(s.vname, finalReg, currentPC)
      c.lifetimeTracker.defineVariable(s.vname, currentPC)

      log(c.verbose, &"Variable {s.vname} allocated to reg {finalReg} with initialization")
    else:
      # Uninitialized variable - allocate register with nil
      let reg = c.allocator.allocReg(s.vname)
      c.prog.emitABC(ropLoadNil, reg, 0, 0, c.makeDebugInfo(s.pos))

      # Track ref-typed, weak-typed, and arrays containing refs/weaks even if uninitialized
      let needsTracking = s.vtype != nil and (
        s.vtype.kind == tkRef or
        s.vtype.kind == tkWeak or
        (s.vtype.kind == tkArray and needsArrayCleanup(s.vtype))
      )
      if needsTracking:
        c.refVars[reg] = s.vtype
        let typeName = case s.vtype.kind
          of tkRef: "ref"
          of tkWeak: "weak"
          of tkArray: "array[ref]"
          else: "unknown"
        log(c.verbose, &"Tracked {typeName} variable {s.vname} in reg {reg} (uninitialized)")

      # Variable is declared but not yet defined (holds nil)
      c.lifetimeTracker.declareVariable(s.vname, reg, currentPC)

      log(c.verbose, &"Variable {s.vname} allocated to reg {reg} (uninitialized)")

  of skAssign:
    # Check if variable already has a register
    let currentPC = c.prog.instructions.len

    if c.allocator.regMap.hasKey(s.aname):
      # Update existing register
      let destReg = c.allocator.regMap[s.aname]
      let valReg = c.compileExpr(s.aval)

      # Check if we need to handle type conversions
      let destIsWeak = c.refVars.hasKey(destReg) and c.refVars[destReg].kind == tkWeak
      let destIsRef = c.refVars.hasKey(destReg) and c.refVars[destReg].kind == tkRef
      let valueIsRef = s.aval.typ != nil and s.aval.typ.kind == tkRef
      let valueIsWeak = s.aval.typ != nil and s.aval.typ.kind == tkWeak

      # If assigning a weak value to a ref variable, promote weak to strong
      if destIsRef and valueIsWeak:
        # Promote weak to strong
        let strongReg = c.allocator.allocReg()
        c.prog.emitABC(ropWeakToStrong, strongReg, valReg, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Promoting weak ref in reg {valReg} to strong ref in reg {strongReg} for {s.aname}")

        # Decrement ref count of old value (if not nil)
        c.prog.emitABC(ropDecRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Emitted ropDecRef for old value in {s.aname} (reg {destReg})")

        # Move promoted value
        if strongReg != destReg:
          c.prog.emitABC(ropMove, destReg, strongReg, 0, c.makeDebugInfo(s.pos))
          c.allocator.freeReg(strongReg)

        # strongReg now contains the promoted ref, which already has correct refcount from weakToStrong
        log(c.verbose, &"Completed weak-to-strong promotion for {s.aname}")
      elif destIsWeak and valueIsRef:
        # If assigning a ref value to a weak variable, create weak wrapper
        # Create weak wrapper
        let weakReg = c.allocator.allocReg()
        c.prog.emitABC(ropNewWeak, weakReg, valReg, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Wrapping ref in reg {valReg} with weak wrapper in reg {weakReg} for {s.aname}")

        # Move weak wrapper to destination
        if weakReg != destReg:
          c.prog.emitABC(ropMove, destReg, weakReg, 0, c.makeDebugInfo(s.pos))
          c.allocator.freeReg(weakReg)
      elif destIsRef and valueIsRef:
        # Assigning ref to ref variable - handle reference counting
        # Decrement ref count of old value (if not nil)
        c.prog.emitABC(ropDecRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Emitted ropDecRef for old value in {s.aname} (reg {destReg})")

        # Move new value
        if valReg != destReg:
          c.prog.emitABC(ropMove, destReg, valReg, 0, c.makeDebugInfo(s.pos))

        # Increment ref count of new value
        c.prog.emitABC(ropIncRef, destReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"Emitted ropIncRef for new value in {s.aname} (reg {destReg})")
      else:
        # Normal non-ref assignment
        if valReg != destReg:
          c.prog.emitABC(ropMove, destReg, valReg, 0, c.makeDebugInfo(s.pos))

      # Clean up source register (only if it's not a variable's register)
      if valReg != destReg:
        # Check if this register belongs to a variable - if so, don't free/clear it
        var isVariableReg = false
        for varName, varReg in c.allocator.regMap:
          if varReg == valReg:
            isVariableReg = true
            break

        if not isVariableReg:
          if c.debug:
            c.prog.emitABC(ropLoadNil, valReg, 0, 0)
          c.allocator.freeReg(valReg)

      # Mark variable as defined (if it wasn't already)
      c.lifetimeTracker.defineVariable(s.aname, currentPC)
    elif s.aname in c.globalVars:
      # Assignment to global variable
      log(c.verbose, &"Assignment to global variable '{s.aname}'")
      let valReg = c.compileExpr(s.aval)
      let nameIdx = c.addStringConst(s.aname)
      c.prog.emitABx(ropSetGlobal, valReg, nameIdx, c.makeDebugInfo(s.pos))
      c.allocator.freeReg(valReg)
    else:
      # New local variable - allocate register
      let valReg = c.compileExpr(s.aval)
      c.allocator.regMap[s.aname] = valReg

      # Declare and define variable (implicit declaration through assignment)
      c.lifetimeTracker.declareVariable(s.aname, valReg, currentPC)
      c.lifetimeTracker.defineVariable(s.aname, currentPC)

  of skIf:
    if c.verbose:
      log(c.verbose, "Compiling if statement")
      log(c.verbose, &"   Then body len = {s.thenBody.len}")
      log(c.verbose, &"   Else body len = {s.elseBody.len}")
      if s.elseBody.len > 0:
        log(c.verbose, &"   First else body statement: {s.elseBody[0].kind}")
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
      log(c.verbose, &"Compiling else branch with {s.elseBody.len} statements")
      for stmt in s.elseBody:
        log(c.verbose, &"  Else body statement: {stmt.kind}")
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
    # Execute all registered defers before returning (only if function has defers)
    # Always emit an instruction to keep jump offsets consistent
    if c.hasDefers:
      c.prog.emitABC(ropExecDefers, 0, 0, 0, c.makeDebugInfo(s.pos))
    else:
      c.prog.emitABC(ropNoOp, 0, 0, 0, c.makeDebugInfo(s.pos))

    let debug = c.makeDebugInfo(s.pos)
    if s.re.isSome():
      let retReg = c.compileExpr(s.re.get())

      # Emit decRefs for all ref variables EXCEPT the one being returned
      # If returning a ref, don't decRef it (ownership transfers to caller)
      let returningRef = s.re.get().typ != nil and s.re.get().typ.kind == tkRef
      if returningRef:
        c.emitDecRefsForScope(excludeReg = int(retReg))
      else:
        c.emitDecRefsForScope()

      c.prog.emitABC(ropReturn, 1, retReg, 0, debug)  # 1 result, in retReg
    else:
      # Emit decRefs for all ref variables AFTER defers (defers might use the refs)
      c.emitDecRefsForScope()
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
    log(c.verbose, &"Processing comptime block with {s.cbody.len} statements")
    for stmt in s.cbody:
      c.compileStmt(stmt)

  of skDefer:
    # Defer statement - compile defer body and emit registration instruction
    c.hasDefers = true  # Mark that this function has defer statements
    log(c.verbose, &"Compiling defer block with {s.deferBody.len} statements")

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

    log(c.verbose, &"Defer body at PC {deferBodyStart}..{deferBodyEnd - 1} registration at PC {deferBodyEnd}")

  of skTypeDecl:
    # Type declarations - these are handled during type checking
    log(c.verbose, "Skipping type declaration (handled during type checking)")

  of skImport:
    # Import statements - these are handled during parsing
    log(c.verbose, "Skipping import statement (handled during parsing)")

  of skDiscard:
    # Discard statement - compile expressions and free their registers
    log(c.verbose, &"Compiling discard statement with {s.dexprs.len} expressions")
    for expr in s.dexprs:
      let reg = c.compileExpr(expr)
      c.allocator.freeReg(reg)

  of skBlock:
    # Unnamed scope block - compile all statements with proper scope management
    log(c.verbose, &"Compiling unnamed scope block with {s.blockBody.len} statements")
    let blockStartPC = c.prog.instructions.len
    c.lifetimeTracker.enterScope(blockStartPC)

    # Snapshot ref variables before entering block
    var refVarsSnapshot: seq[uint8] = @[]
    for reg in c.refVars.keys:
      refVarsSnapshot.add(reg)

    # Compile all statements in the block
    for stmt in s.blockBody:
      c.compileStmt(stmt)

    # Emit DecRefs only for ref variables declared in this block (not in parent scopes)
    var blockLocalRegs: seq[uint8] = @[]
    for reg, typ in c.refVars:
      if reg notin refVarsSnapshot:
        blockLocalRegs.add(reg)

    # Sort in REVERSE order and emit DecRefs
    blockLocalRegs.sort(system.cmp[uint8], order = Descending)
    for reg in blockLocalRegs:
      c.prog.emitABC(ropDecRef, reg, 0, 0)
      log(c.verbose, &"Emitted ropDecRef for block-local ref variable in reg {reg}")
      c.refVars.del(reg)  # Remove from tracking to prevent double-decRef at function exit

    # Exit the block scope
    let blockEndPC = c.prog.instructions.len
    c.lifetimeTracker.exitScope(blockEndPC)
    log(c.verbose, &"Exited unnamed scope block at PC {blockEndPC}")

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

      # Check if target field is weak[T] and value is ref[T]
      var finalValReg = valReg
      let targetIsWeak = s.faTarget.typ != nil and s.faTarget.typ.kind == tkWeak
      let valueIsRef = s.faValue.typ != nil and s.faValue.typ.kind == tkRef

      if targetIsWeak and valueIsRef:
        # Need to wrap the ref in a weak wrapper
        let weakReg = c.allocator.allocReg()
        c.prog.emitABC(ropNewWeak, weakReg, valReg, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"  Wrapping ref in reg {valReg} with weak wrapper in reg {weakReg}")
        finalValReg = weakReg

      # Get or add the field name to const pool
      let fieldConst = c.addStringConst(s.faTarget.fieldName)

      # If storing a ref value, increment its reference count
      if valueIsRef and not targetIsWeak:
        c.prog.emitABC(ropIncRef, finalValReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"  Emitted ropIncRef for ref value in reg {finalValReg} before storing in field")

      # Emit ropSetField to set object field: R[objReg][K[fieldConst]] = R[finalValReg]
      c.prog.emitABC(ropSetField, finalValReg, objReg, uint8(fieldConst), c.makeDebugInfo(s.pos))

      log(c.verbose, &"Set field '{s.faTarget.fieldName}' (const[{fieldConst}]) in object at reg {objReg} to value at reg {finalValReg}")

      if finalValReg != valReg:
        c.allocator.freeReg(finalValReg)
      c.allocator.freeReg(valReg)

    of ekIndex:
      # Array index assignment: arr[idx] = value
      # Compile the array expression
      let arrayReg = c.compileExpr(s.faTarget.arrayExpr)

      # Compile the index expression
      let indexReg = c.compileExpr(s.faTarget.indexExpr)

      # If the array element type is ref, we need to DecRef the old value before overwriting
      let arrayElemType = s.faTarget.typ
      if arrayElemType != nil and arrayElemType.kind == tkRef:
        # Get old value from array
        let oldValueReg = c.allocator.allocReg()
        c.prog.emitABC(ropGetIndex, oldValueReg, arrayReg, indexReg, c.makeDebugInfo(s.pos))
        log(c.verbose, &"  Got old ref value from array into reg {oldValueReg}")

        # DecRef old value (it will handle nil safely)
        c.prog.emitABC(ropDecRef, oldValueReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"  Emitted ropDecRef for old ref value before overwriting")

        c.allocator.freeReg(oldValueReg)

      # Compile the value to assign
      let valueReg = c.compileExpr(s.faValue)

      # If storing a ref value, increment its reference count
      if s.faValue.typ != nil and s.faValue.typ.kind == tkRef:
        c.prog.emitABC(ropIncRef, valueReg, 0, 0, c.makeDebugInfo(s.pos))
        log(c.verbose, &"  Emitted ropIncRef for ref value in reg {valueReg} before storing in array")

      # Emit SETINDEX instruction: R[arrayReg][R[indexReg]] = R[valueReg]
      c.prog.emitABC(ropSetIndex, arrayReg, indexReg, valueReg, c.makeDebugInfo(s.pos))

      # Free temporary registers
      c.allocator.freeReg(valueReg)
      c.allocator.freeReg(indexReg)
      c.allocator.freeReg(arrayReg)

    else:
      echo "Error: Field assignment target must be field access or array index" # TODO - implement proper error/warnings handling
      return

proc compileFunDecl*(c: var RegCompiler, name: string, params: seq[Param], retType: EtchType, body: seq[Stmt]): int =
  ## Compile a function declaration and return the maximum register used
  # Set current function for debug info
  c.currentFunction = name

  # Reset defer tracking for this function
  c.hasDefers = false

  # Reset allocator for new function - preserve max register count
  c.allocator = RegAllocator(
    nextReg: 0,
    maxRegs: uint8(MAX_REGISTERS),
    highWaterMark: 0,
    regMap: initTable[string, uint8]()
  )

  # Reset ref variable tracking for new function
  c.refVars = initTable[uint8, EtchType]()

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

  # Execute all registered defers at the end of the function (only if function has any)
  # Always emit an instruction to keep jump offsets consistent
  if c.hasDefers:
    c.prog.emitABC(ropExecDefers, 0, 0, 0)

  # Emit decRefs for all ref variables AFTER defers (defers might use the refs)
  c.emitDecRefsForScope()

  c.prog.emitABC(ropReturn, 0, 0, 0)

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

  # Save variable-to-register mapping for debugging
  c.prog.varMaps[name] = c.allocator.regMap

  # Debug: dump lifetime info if verbose
  if c.verbose:
    c.lifetimeTracker.dumpLifetimes()

  # Add implicit return if needed
  if c.prog.instructions.len == 0 or
     c.prog.instructions[^1].op != ropReturn:
    # Emit decRefs for all ref variables before implicit return
    c.emitDecRefsForScope()
    c.prog.emitABC(ropReturn, 0, 0, 0)  # No results

  # Return the maximum register count used (highWaterMark tracks the highest nextReg value)
  result = int(c.allocator.highWaterMark)

proc compileProgram*(p: ast.Program, optimizeLevel: int = 2, verbose: bool = false, debug: bool = true): RegBytecodeProgram =
  ## Compile AST to register-based bytecode with optimizations
  if verbose:
    log(verbose, &"Starting compilation, funInstances count: {p.funInstances.len}")
    for fname, _ in p.funInstances:
      log(verbose, &"   Function available: {fname}")

  var compiler = RegCompiler(
    prog: RegBytecodeProgram(
      functions: initTable[string, regvm.FunctionInfo](),
      cffiInfo: initTable[string, regvm.CFFIInfo](),
      lifetimeData: initTable[string, pointer](),
      varMaps: initTable[string, Table[string, uint8]]()
    ),
    allocator: RegAllocator(
      nextReg: 0,
      maxRegs: uint8(MAX_REGISTERS),
      highWaterMark: 0,
      regMap: initTable[string, uint8]()
    ),
    constMap: initTable[string, uint16](),
    loopStack: @[],
    globalVars: @[],
    optimizeLevel: optimizeLevel,
    verbose: verbose,
    debug: debug,
    funInstances: p.funInstances,
    lifetimeTracker: newLifetimeTracker(),
    refVars: initTable[uint8, EtchType](),
    types: p.types
  )

  # Collect global variable names FIRST - before compiling functions
  # This allows functions to know which variables are globals
  for globalStmt in p.globals:
    if globalStmt.kind == skVar:
      compiler.globalVars.add(globalStmt.vname)

  log(verbose, &"Collected {compiler.globalVars.len} global variables: {compiler.globalVars}")

  # Populate C FFI info from AST - identify CFFI functions by their isCFFI flag
  for fname, funcDecl in p.funInstances:
    if funcDecl.isCFFI:
      # Extract base name from mangled name
      var baseName = fname
      let underscorePos = fname.find(FUNCTION_NAME_SEPARATOR_STRING)
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

      log(verbose, &"Identified C FFI function: {fname} -> {baseName}")

  # Compile all functions except main first
  for fname, funcDecl in p.funInstances:
    let isBuiltin = funcDecl.body.len == 0  # Builtin functions have no body
    let isCFFI = compiler.prog.cffiInfo.hasKey(fname)

    log(verbose, &"Processing function: {fname} isBuiltin={isBuiltin} isCFFI={isCFFI} body.len={funcDecl.body.len}")

    if fname != MAIN_FUNCTION_NAME and not isBuiltin and not isCFFI:  # Skip builtin and C FFI functions
      let startPos = compiler.prog.instructions.len

      log(verbose, &"Compiling function {fname}")

      # Reset defer tracking for this function
      compiler.hasDefers = false

      # Reset allocator for new function
      compiler.allocator = RegAllocator(
        nextReg: 0,
        maxRegs: uint8(MAX_REGISTERS),
        highWaterMark: 0,
        regMap: initTable[string, uint8]()
      )

      # Reset ref variable tracking for new function
      compiler.refVars = initTable[uint8, EtchType]()

      # Reset lifetime tracker for new function
      compiler.lifetimeTracker = newLifetimeTracker()
      compiler.lifetimeTracker.enterScope(startPos)  # Enter function scope

      # Allocate registers for parameters and map them
      for i, param in funcDecl.params:
        let paramReg = compiler.allocator.allocReg(param.name)
        # Track parameter as declared and defined at function entry
        compiler.lifetimeTracker.declareVariable(param.name, paramReg, startPos)
        compiler.lifetimeTracker.defineVariable(param.name, startPos)
        log(verbose, &"Allocated parameter '{param.name}' to register {paramReg}")

      # Compile function body
      for stmt in funcDecl.body:
        compiler.compileStmt(stmt)

      # Execute all registered defers at the end of the function (only if function has any)
      # Always emit an instruction to keep jump offsets consistent
      if compiler.hasDefers:
        compiler.prog.emitABC(ropExecDefers, 0, 0, 0)
        compiler.prog.emitABC(ropReturn, 0, 0, 0)
      else:
        compiler.prog.emitABC(ropReturn, 0, 0, 0)

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
        # Emit decRefs for all ref variables before implicit return
        compiler.emitDecRefsForScope()
        compiler.prog.emitABC(ropReturn, 0, 0, 0)

      let endPos = compiler.prog.instructions.len - 1

      # Store function info with max register count
      let maxReg = int(compiler.allocator.highWaterMark)
      compiler.prog.functions[fname] = regvm.FunctionInfo(
        name: fname,
        startPos: startPos,
        endPos: endPos,
        numParams: funcDecl.params.len,
        maxRegister: maxReg
      )

      log(verbose, &"Compiled function {fname} at {startPos}..{endPos}")

  # Compile global initialization if needed
  if p.globals.len > 0:
    log(verbose, &"Compiling {p.globals.len} global variables")

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
          # Store in global table using ropInitGlobal (only sets if not already present)
          # This allows C API to override compile-time initialization
          let nameIdx = compiler.addStringConst(globalStmt.vname)
          compiler.prog.emitABx(ropInitGlobal, valueReg, nameIdx)
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
    log(verbose, &"Entry point set to PC {globalInitStart} ({GLOBAL_INIT_FUNCTION_NAME} function)")

    # Register the global initialization code as a special function for debugging
    let globalInitEnd = compiler.prog.instructions.len - 1
    let globalMaxReg = int(compiler.allocator.highWaterMark)
    compiler.prog.functions[GLOBAL_INIT_FUNCTION_NAME] = regvm.FunctionInfo(
      name: GLOBAL_INIT_FUNCTION_NAME,
      startPos: globalInitStart,
      endPos: globalInitEnd,
      numParams: 0,
      maxRegister: globalMaxReg
    )

    log(verbose, &"Registered {GLOBAL_INIT_FUNCTION_NAME} initialization function at PC {globalInitStart}..{globalInitEnd}")
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
    let mainMaxReg = compiler.compileFunDecl(MAIN_FUNCTION_NAME, mainFunc.params, mainFunc.ret, mainFunc.body)
    let mainEndPos = compiler.prog.instructions.len

    # Store main function info
    compiler.prog.functions[MAIN_FUNCTION_NAME] = regvm.FunctionInfo(
      name: MAIN_FUNCTION_NAME,
      startPos: mainStartPos,
      endPos: mainEndPos,
      numParams: mainFunc.params.len,
      maxRegister: mainMaxReg
    )

    log(verbose, &"Compiled main function at {mainStartPos}..{mainEndPos}")

  # Apply optimization passes, enable with only pass 1 and 2
  #if optimizeLevel >= 1:
  #  optimizeBytecode(compiler.prog)

  return compiler.prog
