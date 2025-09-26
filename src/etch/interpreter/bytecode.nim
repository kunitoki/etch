# bytecode.nim
# Bytecode generation for Etch programs

import std/[tables, options, hashes, sequtils, strformat, strutils]
import ../frontend/ast, serialize
import ../common/[logging, types, constants]
export serialize

type
  LoopContext = object
    breakJumps*: seq[int]  # Instructions that need to be patched to jump out of loop

  CompilationContext* = object
    currentFunction*: string
    localVars*: seq[string]  # Variables in current scope
    sourceFile*: string
    astProgram*: Program  # Reference to the AST program for default parameter lookup
    loopStack*: seq[LoopContext]  # Stack of nested loops for break handling

proc hashSourceAndFlags*(source: string, flags: CompilerFlags): string =
  ## Generate a hash of the source code + compiler flags for cache validation
  let sourceHash = hashes.hash(source)
  $sourceHash

proc addConstant*(prog: var BytecodeProgram, value: string): int =
  ## Add a string constant to the pool and return its index
  for i, c in prog.constants:
    if c == value: return i
  prog.constants.add(value)
  prog.constants.high

proc emit*(prog: var BytecodeProgram, op: OpCode, arg: int64 = 0, sarg: string = "",
          pos: Pos = Pos(line: 0, col: 0, filename: ""), ctx: CompilationContext = CompilationContext()) =
  ## Emit a bytecode instruction
  let debug = if prog.compilerFlags.debug:
    DebugInfo(
      line: pos.line,
      col: pos.col,
      sourceFile: if pos.filename.len > 0: pos.filename else: ctx.sourceFile,
      functionName: ctx.currentFunction,
      localVars: ctx.localVars
    )
  else:
    DebugInfo()  # Empty debug info when not debugging

  let instr = Instruction(op: op, arg: arg, sarg: sarg, debug: debug)
  prog.instructions.add(instr)

  # Verbose logging for debug investigation
  if prog.compilerFlags.verbose:
    let instrIdx = prog.instructions.high
    echo &"[BYTECODE] Instruction {instrIdx}: {op} at line {pos.line}, col {pos.col} (func: {ctx.currentFunction})"

  # Build line-to-instruction mapping for debugging only when debug flag is set
  if prog.compilerFlags.debug and pos.line > 0:
    if not prog.lineToInstructionMap.hasKey(pos.line):
      prog.lineToInstructionMap[pos.line] = @[]
    prog.lineToInstructionMap[pos.line].add(prog.instructions.high)

proc compileBinOp*(prog: var BytecodeProgram, op: BinOp, pos: Pos, ctx: CompilationContext) =
  case op
  of boAdd: prog.emit(opAdd, pos = pos, ctx = ctx)
  of boSub: prog.emit(opSub, pos = pos, ctx = ctx)
  of boMul: prog.emit(opMul, pos = pos, ctx = ctx)
  of boDiv: prog.emit(opDiv, pos = pos, ctx = ctx)
  of boMod: prog.emit(opMod, pos = pos, ctx = ctx)
  of boEq: prog.emit(opEq, pos = pos, ctx = ctx)
  of boNe: prog.emit(opNe, pos = pos, ctx = ctx)
  of boLt: prog.emit(opLt, pos = pos, ctx = ctx)
  of boLe: prog.emit(opLe, pos = pos, ctx = ctx)
  of boGt: prog.emit(opGt, pos = pos, ctx = ctx)
  of boGe: prog.emit(opGe, pos = pos, ctx = ctx)
  of boAnd: prog.emit(opAnd, pos = pos, ctx = ctx)
  of boOr: prog.emit(opOr, pos = pos, ctx = ctx)

proc compileConstantExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext, op: OpCode, getValue: proc(e: Expr): string) =
  let idx = prog.addConstant(getValue(e))
  prog.emit(op, idx, pos = e.pos, ctx = ctx)

proc compileIntExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opLoadInt, e.ival, pos = e.pos, ctx = ctx)

proc compileFloatExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  compileConstantExpr(prog, e, ctx, opLoadFloat, proc(e: Expr): string = $e.fval)

proc compileStringExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  compileConstantExpr(prog, e, ctx, opLoadString, proc(e: Expr): string = e.sval)

proc compileCharExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  compileConstantExpr(prog, e, ctx, opLoadChar, proc(e: Expr): string = $e.cval)

proc compileBoolExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opLoadBool, if e.bval: 1 else: 0, pos = e.pos, ctx = ctx)

proc compileVarExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opLoadVar, 0, e.vname, e.pos, ctx)

proc compileExpr*(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)

proc compileUnaryExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileBinaryExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileCallExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileNewRefExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileDerefExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileArrayExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileIndexExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileSliceExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileArrayLenExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileCastExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileOptionSomeExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileOptionNoneExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileResultOkExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileResultErrExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)
proc compileMatchExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext)

proc compileUnaryExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.ue, ctx)
  case e.uop
  of uoNeg: prog.emit(opNeg, pos = e.pos, ctx = ctx)
  of uoNot: prog.emit(opNot, pos = e.pos, ctx = ctx)

proc compileBinaryExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.lhs, ctx)
  prog.compileExpr(e.rhs, ctx)
  prog.compileBinOp(e.bop, e.pos, ctx)

proc compileCallExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  var totalArgCount = e.args.len
  var resolvedFunctionName = e.fname

  # Try to find the function instance, first by exact name, then by resolving overloads
  var foundFunction: FunDecl = nil
  if ctx.astProgram.funInstances.hasKey(e.fname):
    foundFunction = ctx.astProgram.funInstances[e.fname]
    resolvedFunctionName = e.fname
  else:
    # Function not found by simple name, try to resolve by finding matching signatures
    # Look for functions that match the base name
    for instanceName, fn in ctx.astProgram.funInstances:
      # Check if this is an overload of our function
      # The mangled name format is: functionName__paramTypes_returnType
      if instanceName.startsWith(e.fname & "__"):
        # For simple resolution, just check if the parameter count matches
        # In a full implementation, we'd want to check parameter types too
        if fn.params.len == e.args.len:
          foundFunction = fn
          resolvedFunctionName = instanceName
          break
        elif fn.params.len > e.args.len:
          # Check if remaining parameters have defaults
          var hasDefaults = true
          for i in e.args.len..<fn.params.len:
            if not fn.params[i].defaultValue.isSome:
              hasDefaults = false
              break
          if hasDefaults:
            foundFunction = fn
            resolvedFunctionName = instanceName
            break

  if foundFunction != nil:
    totalArgCount = foundFunction.params.len

    # Push all arguments (provided + defaults) in forward order
    for i in 0..<foundFunction.params.len:
      if i < e.args.len:
        prog.compileExpr(e.args[i], ctx)
      elif foundFunction.params[i].defaultValue.isSome:
        prog.compileExpr(foundFunction.params[i].defaultValue.get, ctx)
      else:
        prog.emit(opLoadInt, 0, pos = e.pos, ctx = ctx)
  else:
    # For built-in functions or when function not found, use provided arguments only
    for i in countdown(e.args.high, 0):
      prog.compileExpr(e.args[i], ctx)

  # Debug output for function resolution
  if prog.compilerFlags.verbose:
    echo &"[BYTECODE] Function call: {e.fname} -> {resolvedFunctionName} (args: {totalArgCount})"

  prog.emit(opCall, totalArgCount, resolvedFunctionName, e.pos, ctx)

proc compileNewRefExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.init, ctx)
  prog.emit(opNewRef, pos = e.pos, ctx = ctx)

proc compileDerefExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.refExpr, ctx)
  prog.emit(opDeref, pos = e.pos, ctx = ctx)

proc compileArrayExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  for elem in e.elements:
    prog.compileExpr(elem, ctx)
  prog.emit(opMakeArray, e.elements.len, pos = e.pos, ctx = ctx)

proc compileIndexExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.arrayExpr, ctx)
  prog.compileExpr(e.indexExpr, ctx)
  prog.emit(opArrayGet, pos = e.pos, ctx = ctx)

proc compileSliceExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.sliceExpr, ctx)
  if e.startExpr.isSome:
    prog.compileExpr(e.startExpr.get, ctx)
  else:
    prog.emit(opLoadInt, -1, pos = e.pos, ctx = ctx)
  if e.endExpr.isSome:
    prog.compileExpr(e.endExpr.get, ctx)
  else:
    prog.emit(opLoadInt, -1, pos = e.pos, ctx = ctx)
  prog.emit(opArraySlice, pos = e.pos, ctx = ctx)

proc compileArrayLenExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.lenExpr, ctx)
  prog.emit(opArrayLen, pos = e.pos, ctx = ctx)

proc compileCastExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.castExpr, ctx)
  let castTypeCode = case e.castType.kind:
    of tkInt: 1
    of tkFloat: 2
    of tkString: 3
    else: 0
  prog.emit(opCast, castTypeCode, pos = e.pos, ctx = ctx)

proc compileNilExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opLoadNil, pos = e.pos, ctx = ctx)

proc compileOptionSomeExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.someExpr, ctx)
  prog.emit(opMakeOptionSome, pos = e.pos, ctx = ctx)

proc compileOptionNoneExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opMakeOptionNone, pos = e.pos, ctx = ctx)

proc compileResultOkExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.okExpr, ctx)
  prog.emit(opMakeResultOk, pos = e.pos, ctx = ctx)

proc compileResultErrExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.compileExpr(e.errExpr, ctx)
  prog.emit(opMakeResultErr, pos = e.pos, ctx = ctx)

proc compileObjectLiteralExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  # Compile object literal: { field1: value1, field2: value2, ... }
  # Stack layout: value1, "field1", value2, "field2", ...
  for field in e.fieldInits:
    # Push field value first, then field name (reverse order for stack)
    prog.compileExpr(field.value, ctx)
    let fieldNameIndex = prog.addConstant(field.name)
    prog.emit(opLoadString, fieldNameIndex, pos = e.pos, ctx = ctx)

  # Create object with specified number of fields
  prog.emit(opMakeObject, e.fieldInits.len, pos = e.pos, ctx = ctx)

proc compileFieldAccessExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  # Compile field access: obj.field
  prog.compileExpr(e.objectExpr, ctx)  # Compile the object expression
  prog.emit(opObjectGet, 0, e.fieldName, e.pos, ctx)  # Field name as string argument


proc compileExpr*(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  case e.kind
  of ekInt: prog.compileIntExpr(e, ctx)
  of ekFloat: prog.compileFloatExpr(e, ctx)
  of ekString: prog.compileStringExpr(e, ctx)
  of ekChar: prog.compileCharExpr(e, ctx)
  of ekBool: prog.compileBoolExpr(e, ctx)
  of ekVar: prog.compileVarExpr(e, ctx)
  of ekUn: prog.compileUnaryExpr(e, ctx)
  of ekBin: prog.compileBinaryExpr(e, ctx)
  of ekCall: prog.compileCallExpr(e, ctx)
  of ekNewRef: prog.compileNewRefExpr(e, ctx)
  of ekDeref: prog.compileDerefExpr(e, ctx)
  of ekArray: prog.compileArrayExpr(e, ctx)
  of ekIndex: prog.compileIndexExpr(e, ctx)
  of ekSlice: prog.compileSliceExpr(e, ctx)
  of ekArrayLen: prog.compileArrayLenExpr(e, ctx)
  of ekCast: prog.compileCastExpr(e, ctx)
  of ekNil: prog.compileNilExpr(e, ctx)
  of ekOptionSome: prog.compileOptionSomeExpr(e, ctx)
  of ekOptionNone: prog.compileOptionNoneExpr(e, ctx)
  of ekResultOk: prog.compileResultOkExpr(e, ctx)
  of ekResultErr: prog.compileResultErrExpr(e, ctx)
  of ekMatch: prog.compileMatchExpr(e, ctx)
  of ekObjectLiteral:
    prog.compileObjectLiteralExpr(e, ctx)
  of ekFieldAccess:
    prog.compileFieldAccessExpr(e, ctx)
  of ekNew:
    # Compile new expression: new(value) or new[Type]{value}
    if e.initExpr.isSome:
      # Initialize with provided value
      prog.compileExpr(e.initExpr.get, ctx)
    else:
      # Initialize with default value based on type
      if e.newType.kind == tkInt:
        prog.emit(opLoadInt, 0, pos = e.pos, ctx = ctx)
      elif e.newType.kind == tkFloat:
        prog.emit(opLoadFloat, 0, pos = e.pos, ctx = ctx)
      elif e.newType.kind == tkBool:
        prog.emit(opLoadBool, 0, pos = e.pos, ctx = ctx)
      elif e.newType.kind == tkString:
        let emptyStrIndex = prog.addConstant("")
        prog.emit(opLoadString, emptyStrIndex, pos = e.pos, ctx = ctx)
      else:
        # Default to zero for unknown types
        prog.emit(opLoadInt, 0, pos = e.pos, ctx = ctx)

    # Create reference (allocate on heap)
    prog.emit(opNewRef, pos = e.pos, ctx = ctx)

proc compileStmt*(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext)

proc compileVarStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  ctx.localVars.add(s.vname)

  if s.vinit.isSome:
    prog.compileExpr(s.vinit.get, ctx)
  else:
    # Default initialization
    case s.vtype.kind
    of tkInt: prog.emit(opLoadInt, 0, pos = s.pos, ctx = ctx)
    of tkFloat:
      let idx = prog.addConstant("0.0")
      prog.emit(opLoadFloat, idx, pos = s.pos, ctx = ctx)
    of tkString:
      let idx = prog.addConstant("")
      prog.emit(opLoadString, idx, pos = s.pos, ctx = ctx)
    of tkBool: prog.emit(opLoadBool, 0, pos = s.pos, ctx = ctx)
    else: prog.emit(opLoadInt, 0, pos = s.pos, ctx = ctx)  # fallback
  prog.emit(opStoreVar, 0, s.vname, s.pos, ctx)

proc compileAssignStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  prog.compileExpr(s.aval, ctx)
  prog.emit(opStoreVar, 0, s.aname, s.pos, ctx)

proc compileIfStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  var jumpToNexts: seq[int] = @[]  # Jumps to the next elif/else clause
  var jumpToEnds: seq[int] = @[]   # Jumps to the end of the entire if-elif-else chain

  # Main if condition
  prog.compileExpr(s.cond, ctx)
  let jumpToElif = prog.instructions.len
  prog.emit(opJumpIfFalse, pos = s.cond.pos, ctx = ctx)  # Use condition position for better debugging
  jumpToNexts.add(jumpToElif)

  # Then body
  for stmt in s.thenBody:
    prog.compileStmt(stmt, ctx)

  # Jump to end after then body (skip elif/else)
  let jumpToEndFromThen = prog.instructions.len
  prog.emit(opJump, pos = s.pos, ctx = ctx)
  jumpToEnds.add(jumpToEndFromThen)

  # Patch first jump to point to the first elif (or else if no elif)
  prog.instructions[jumpToElif].arg = prog.instructions.len

  # Compile elif chain
  for i, elifClause in s.elifChain:
    # Compile elif condition
    prog.compileExpr(elifClause.cond, ctx)
    let jumpToNextElif = prog.instructions.len
    prog.emit(opJumpIfFalse, pos = elifClause.cond.pos, ctx = ctx)  # Use elif condition position
    jumpToNexts.add(jumpToNextElif)

    # Compile elif body
    for stmt in elifClause.body:
      prog.compileStmt(stmt, ctx)

    # Jump to end after elif body
    let jumpToEndFromElif = prog.instructions.len
    prog.emit(opJump, pos = elifClause.cond.pos, ctx = ctx)  # Use elif position
    jumpToEnds.add(jumpToEndFromElif)

    # Patch previous jump to next to point here (to next elif condition)
    if i < s.elifChain.len - 1:
      prog.instructions[jumpToNextElif].arg = prog.instructions.len

  # Patch last elif jump to point to else body (if it exists)
  if s.elifChain.len > 0:
    prog.instructions[jumpToNexts[^1]].arg = prog.instructions.len

  # Compile else body
  for stmt in s.elseBody:
    prog.compileStmt(stmt, ctx)

  # Patch all jumps to end to point here
  for jumpToEnd in jumpToEnds:
    prog.instructions[jumpToEnd].arg = prog.instructions.len

proc compileWhileStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  let loopStart = prog.instructions.len
  prog.compileExpr(s.wcond, ctx)
  let jumpToEnd = prog.instructions.len
  prog.emit(opJumpIfFalse, pos = s.pos, ctx = ctx)  # Will patch this

  # Push loop context for break statements
  ctx.loopStack.add(LoopContext(breakJumps: @[]))

  for stmt in s.wbody:
    prog.compileStmt(stmt, ctx)

  prog.emit(opJump, loopStart, pos = s.pos, ctx = ctx)  # Jump back to condition
  prog.instructions[jumpToEnd].arg = prog.instructions.len

  # Patch all break jumps in this loop
  let loopContext = ctx.loopStack.pop()
  for breakJump in loopContext.breakJumps:
    prog.instructions[breakJump].arg = prog.instructions.len

proc compileForStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  ctx.localVars.add(s.fvar)

  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayTempVar = "__array_temp"
    let indexTempVar = "__index_temp"
    ctx.localVars.add(arrayTempVar)
    ctx.localVars.add(indexTempVar)

    # Store array in temp variable
    prog.compileExpr(s.farray.get(), ctx)
    prog.emit(opStoreVar, 0, arrayTempVar, s.pos, ctx)

    # Initialize index to 0
    prog.emit(opLoadInt, 0, pos = s.pos, ctx = ctx)
    prog.emit(opStoreVar, 0, indexTempVar, s.pos, ctx)

    let loopStart = prog.instructions.len

    # Check condition: index < array.len
    prog.emit(opLoadVar, 0, indexTempVar, s.pos, ctx)
    prog.emit(opLoadVar, 0, arrayTempVar, s.pos, ctx)
    prog.emit(opArrayLen, pos = s.pos, ctx = ctx)
    prog.emit(opLt, pos = s.pos, ctx = ctx)

    let jumpToEnd = prog.instructions.len
    prog.emit(opJumpIfFalse, pos = s.pos, ctx = ctx)  # Will patch this

    # Load array element into loop variable: x = array[index]
    prog.emit(opLoadVar, 0, arrayTempVar, s.pos, ctx)
    prog.emit(opLoadVar, 0, indexTempVar, s.pos, ctx)
    prog.emit(opArrayGet, pos = s.pos, ctx = ctx)
    prog.emit(opStoreVar, 0, s.fvar, s.pos, ctx)

    # Push loop context for break statements
    ctx.loopStack.add(LoopContext(breakJumps: @[]))

    # Execute loop body
    for stmt in s.fbody:
      prog.compileStmt(stmt, ctx)

    # Increment index
    prog.emit(opLoadVar, 0, indexTempVar, s.pos, ctx)
    prog.emit(opLoadInt, 1, pos = s.pos, ctx = ctx)
    prog.emit(opAdd, pos = s.pos, ctx = ctx)
    prog.emit(opStoreVar, 0, indexTempVar, s.pos, ctx)

    prog.emit(opJump, loopStart, pos = s.pos, ctx = ctx)  # Jump back to condition
    prog.instructions[jumpToEnd].arg = prog.instructions.len

    # Patch all break jumps in this loop
    let loopContext = ctx.loopStack.pop()
    for breakJump in loopContext.breakJumps:
      prog.instructions[breakJump].arg = prog.instructions.len

  else:
    # Range iteration: for x in start..end or for x in start..<end
    # Initialize loop variable with start value
    prog.compileExpr(s.fstart.get(), ctx)
    prog.emit(opStoreVar, 0, s.fvar, s.pos, ctx)

    let loopStart = prog.instructions.len

    # Check condition: loop_var <= end_value (inclusive) or loop_var < end_value (exclusive)
    prog.emit(opLoadVar, 0, s.fvar, s.pos, ctx)
    prog.compileExpr(s.fend.get(), ctx)
    if s.finclusive:
      prog.emit(opLe, pos = s.pos, ctx = ctx)  # inclusive: <=
    else:
      prog.emit(opLt, pos = s.pos, ctx = ctx)  # exclusive: <

    let jumpToEnd = prog.instructions.len
    prog.emit(opJumpIfFalse, pos = s.pos, ctx = ctx)  # Will patch this

    # Push loop context for break statements
    ctx.loopStack.add(LoopContext(breakJumps: @[]))

    # Execute loop body
    for stmt in s.fbody:
      prog.compileStmt(stmt, ctx)

    # Increment loop variable
    prog.emit(opLoadVar, 0, s.fvar, s.pos, ctx)
    prog.emit(opLoadInt, 1, pos = s.pos, ctx = ctx)
    prog.emit(opAdd, pos = s.pos, ctx = ctx)
    prog.emit(opStoreVar, 0, s.fvar, s.pos, ctx)

    prog.emit(opJump, loopStart, pos = s.pos, ctx = ctx)  # Jump back to condition
    prog.instructions[jumpToEnd].arg = prog.instructions.len

    # Patch all break jumps in this loop
    let loopContext = ctx.loopStack.pop()
    for breakJump in loopContext.breakJumps:
      prog.instructions[breakJump].arg = prog.instructions.len

proc compileBreakStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  if ctx.loopStack.len == 0:
    # This should be caught by type checker, but handle gracefully
    prog.emit(opLoadInt, 0, pos = s.pos, ctx = ctx)  # No-op
    return

  # Add a jump instruction that will be patched later
  let breakJump = prog.instructions.len
  prog.emit(opJump, 0, pos = s.pos, ctx = ctx)  # Will be patched to jump out of loop
  ctx.loopStack[^1].breakJumps.add(breakJump)

proc compileExprStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  prog.compileExpr(s.sexpr, ctx)
  prog.emit(opPop, pos = s.pos, ctx = ctx)  # Discard result

proc compileReturnStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  if s.re.isSome:
    prog.compileExpr(s.re.get, ctx)
  prog.emit(opReturn, pos = s.pos, ctx = ctx)

proc compileComptimeStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  # Comptime blocks should contain injected statements by this point
  for stmt in s.cbody:
    prog.compileStmt(stmt, ctx)

proc compileStmt*(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  case s.kind
  of skVar: prog.compileVarStmt(s, ctx)
  of skAssign: prog.compileAssignStmt(s, ctx)
  of skIf: prog.compileIfStmt(s, ctx)
  of skWhile: prog.compileWhileStmt(s, ctx)
  of skFor: prog.compileForStmt(s, ctx)
  of skBreak: prog.compileBreakStmt(s, ctx)
  of skExpr: prog.compileExprStmt(s, ctx)
  of skReturn: prog.compileReturnStmt(s, ctx)
  of skComptime: prog.compileComptimeStmt(s, ctx)
  of skTypeDecl:
    # Type declarations don't generate runtime code
    discard

proc compileMatchExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  # Compile the expression to be matched
  prog.compileExpr(e.matchExpr, ctx)

  # Create jump table for each pattern case
  var caseJumps: seq[int] = @[]
  var endJumps: seq[int] = @[]

  for i, matchCase in e.cases:
    # Duplicate the matched value for pattern testing
    prog.emit(opDup, pos = e.pos, ctx = ctx)

    # Emit pattern matching code
    case matchCase.pattern.kind:
    of pkSome:
      # Check if option is Some and extract value
      prog.emit(opMatchValue, 1, pos = e.pos, ctx = ctx) # 1 = check for Some
      let jumpToNext = prog.instructions.len
      prog.emit(opJumpIfFalse, pos = e.pos, ctx = ctx) # Jump if not Some
      caseJumps.add(jumpToNext)

      # Extract and bind value
      prog.emit(opExtractSome, pos = e.pos, ctx = ctx)
      prog.emit(opStoreVar, 0, matchCase.pattern.bindName, e.pos, ctx)

    of pkNone:
      # Check if option is None
      prog.emit(opMatchValue, 0, pos = e.pos, ctx = ctx) # 0 = check for None
      let jumpToNext = prog.instructions.len
      prog.emit(opJumpIfFalse, pos = e.pos, ctx = ctx) # Jump if not None
      caseJumps.add(jumpToNext)

    of pkOk:
      # Check if result is Ok and extract value
      prog.emit(opMatchValue, 2, pos = e.pos, ctx = ctx) # 2 = check for Ok
      let jumpToNext = prog.instructions.len
      prog.emit(opJumpIfFalse, pos = e.pos, ctx = ctx) # Jump if not Ok
      caseJumps.add(jumpToNext)

      # Extract and bind value
      prog.emit(opExtractOk, pos = e.pos, ctx = ctx)
      prog.emit(opStoreVar, 0, matchCase.pattern.bindName, e.pos, ctx)

    of pkErr:
      # Check if result is Error and extract value
      prog.emit(opMatchValue, 3, pos = e.pos, ctx = ctx) # 3 = check for Err
      let jumpToNext = prog.instructions.len
      prog.emit(opJumpIfFalse, pos = e.pos, ctx = ctx) # Jump if not Err
      caseJumps.add(jumpToNext)

      # Extract and bind error value
      prog.emit(opExtractErr, pos = e.pos, ctx = ctx)
      prog.emit(opStoreVar, 0, matchCase.pattern.bindName, e.pos, ctx)

    of pkWildcard:
      # Wildcard always matches
      discard

    # Pop the matched value (consumed by pattern test)
    prog.emit(opPop, pos = e.pos, ctx = ctx)

    # Compile case body - treat last statement as expression result
    for i, stmt in matchCase.body:
      if i == matchCase.body.len - 1 and stmt.kind == skExpr:
        # Last statement is an expression - compile as expression (don't pop result)
        prog.compileExpr(stmt.sexpr, ctx)
      else:
        # Regular statement - compile normally
        prog.compileStmt(stmt, ctx)

    # Jump to end of match expression
    let jumpToEnd = prog.instructions.len
    prog.emit(opJump, pos = e.pos, ctx = ctx)
    endJumps.add(jumpToEnd)

    # Patch jump to next case (if this pattern didn't match)
    if i < caseJumps.len:
      prog.instructions[caseJumps[i]].arg = prog.instructions.len

  # Patch all jumps to end
  for jump in endJumps:
    prog.instructions[jump].arg = prog.instructions.len

proc canEvaluateConstantExpr(expr: Expr): bool =
  ## Check if an expression can be safely evaluated at compile time
  ## Returns true for simple constants and arithmetic, false for function calls
  case expr.kind
  of ekInt, ekFloat, ekBool, ekString, ekChar:
    return true
  of ekBin:
    # Binary expressions can be evaluated if both operands can be evaluated
    return canEvaluateConstantExpr(expr.lhs) and canEvaluateConstantExpr(expr.rhs)
  of ekCall, ekVar:
    # Function calls and variables need runtime evaluation
    return false
  else:
    # For safety, assume complex expressions need runtime evaluation
    return false

proc evaluateConstantExpr(expr: Expr): GlobalValue =
  ## Evaluate simple constant expressions for global variable initialization
  ## For complex expressions, this will be handled by the compilation pipeline
  case expr.kind
  of ekInt:
    return GlobalValue(kind: tkInt, ival: expr.ival)
  of ekFloat:
    return GlobalValue(kind: tkFloat, fval: expr.fval)
  of ekBool:
    return GlobalValue(kind: tkBool, bval: expr.bval)
  of ekString:
    return GlobalValue(kind: tkString, sval: expr.sval)
  of ekChar:
    return GlobalValue(kind: tkChar, cval: expr.cval)
  of ekBin:
    # Handle simple binary arithmetic operations
    let left = evaluateConstantExpr(expr.lhs)
    let right = evaluateConstantExpr(expr.rhs)
    if left.kind == tkInt and right.kind == tkInt:
      case expr.bop
      of boAdd:
        return GlobalValue(kind: tkInt, ival: left.ival + right.ival)
      of boSub:
        return GlobalValue(kind: tkInt, ival: left.ival - right.ival)
      of boMul:
        return GlobalValue(kind: tkInt, ival: left.ival * right.ival)
      of boDiv:
        if right.ival != 0:
          return GlobalValue(kind: tkInt, ival: left.ival div right.ival)
        else:
          return GlobalValue(kind: tkInt, ival: 0)
      else:
        return GlobalValue(kind: tkInt, ival: 0)
    else:
      return GlobalValue(kind: tkInt, ival: 0)
  else:
    # For other complex expressions (function calls, etc.), default to integer 0
    # This will be handled by the compilation pipeline with proper VM evaluation
    return GlobalValue(kind: tkInt, ival: 0)



proc compileProgram*(astProg: Program, sourceHash: string, sourceFile: string = "", flags: CompilerFlags = CompilerFlags()): BytecodeProgram =
  ## Compile an AST program to bytecode
  logBytecode(flags, "Starting bytecode generation")

  result = BytecodeProgram(
    instructions: @[],
    constants: @[],
    functions: initTable[string, int](),
    sourceHash: sourceHash,
    globals: @[],
    globalValues: initTable[string, GlobalValue](),
    sourceFile: sourceFile,
    functionInfo: initTable[string, FunctionInfo](),
    lineToInstructionMap: initTable[int, seq[int]](),
    compilerFlags: flags
  )

  var ctx = CompilationContext(
    currentFunction: "global",
    localVars: @[],
    sourceFile: sourceFile,
    astProgram: astProg,
    loopStack: @[]
  )

  # Compile global variables
  logBytecode(flags, "Compiling " & $astProg.globals.len & " global variables")
  var globalInitCode: seq[Stmt] = @[]

  for g in astProg.globals:
    if g.kind == skVar:
      logBytecode(flags, "Compiling global variable: " & g.vname)
      result.globals.add(g.vname)
      ctx.localVars.add(g.vname)

      # For simple constant expressions, evaluate at compile time for optimization
      # For complex expressions (like function calls), let them execute at runtime
      if g.vinit.isSome():
        if canEvaluateConstantExpr(g.vinit.get()):
          let globalVal = evaluateConstantExpr(g.vinit.get())
          result.globalValues[g.vname] = globalVal
          # Skip runtime bytecode generation for pre-computed values
        else:
          # Complex expression - add to global initialization function
          globalInitCode.add(g)
      else:
        # Default initialization based on type
        result.globalValues[g.vname] = GlobalValue(kind: tkInt, ival: 0)
        # No runtime bytecode needed for default initialization

  # Create global initialization function if needed
  if globalInitCode.len > 0:
    logBytecode(flags, "Creating global initialization function with " & $globalInitCode.len & " statements")
    ctx.currentFunction = GLOBAL_INIT_FUNC_NAME
    ctx.localVars = @[]

    let globalInitAddr = result.instructions.len
    result.functions[GLOBAL_INIT_FUNC_NAME] = globalInitAddr

    # Compile all global initialization statements
    for stmt in globalInitCode:
      result.compileStmt(stmt, ctx)

    # End with return
    result.emit(opReturn, ctx = ctx)

  # Compile function instances
  logBytecode(flags, "Compiling " & $astProg.funInstances.len & " function instances")
  for name, fn in astProg.funInstances:
    logBytecode(flags, "Compiling function: " & name)
    ctx.currentFunction = name
    ctx.localVars = @[]

    # Add function parameters to local vars
    for param in fn.params:
      ctx.localVars.add(param.name)

    # Always store function debug info (parameter names are essential for execution)
    let debugInfo = FunctionInfo(
      name: name,
      startLine: 0,
      endLine: 0,
      parameterNames: fn.params.mapIt(it.name),  # Always needed for execution
      localVarNames: @[]
    )
    result.functionInfo[name] = debugInfo

    result.functions[name] = result.instructions.len
    for stmt in fn.body:
      result.compileStmt(stmt, ctx)

    # Add implicit return for void functions
    if fn.ret.kind == tkVoid:
      # Push void value onto stack before returning
      result.emit(opLoadInt, 0, pos = Pos(line: 0, col: 0, filename: ""), ctx = ctx)
      result.emit(opReturn, ctx = ctx)

