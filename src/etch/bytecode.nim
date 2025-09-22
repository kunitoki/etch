# bytecode.nim
# Bytecode generation for Etch programs

import std/[tables, options, hashes, sequtils]
import ast, serialize
export serialize

type
  CompilationContext* = object
    currentFunction*: string
    localVars*: seq[string]  # Variables in current scope
    sourceFile*: string
    includeDebugInfo*: bool  # Whether to include debug information
    astProgram*: Program  # Reference to the AST program for default parameter lookup

proc hashSourceAndFlags*(source: string, flags: CompilerFlags): string =
  ## Generate a hash of the source code + compiler flags for cache validation
  let sourceHash = hashes.hash(source)
  let flagsHash = hashes.hash(flags.includeDebugInfo)
  $hashes.hash($sourceHash & $flagsHash)

proc addConstant*(prog: var BytecodeProgram, value: string): int =
  ## Add a string constant to the pool and return its index
  for i, c in prog.constants:
    if c == value: return i
  prog.constants.add(value)
  prog.constants.high

proc emit*(prog: var BytecodeProgram, op: OpCode, arg: int64 = 0, sarg: string = "",
          pos: Pos = Pos(line: 0, col: 0, filename: ""), ctx: CompilationContext = CompilationContext()) =
  ## Emit a bytecode instruction with optional debug information
  var debug = DebugInfo()

  # Only include debug info if requested
  if ctx.includeDebugInfo:
    debug = DebugInfo(
      line: pos.line,
      col: pos.col,
      sourceFile: ctx.sourceFile,
      functionName: ctx.currentFunction,
      localVars: ctx.localVars
    )

    # Update line to instruction mapping
    if pos.line > 0:
      if not prog.lineToInstructionMap.hasKey(pos.line):
        prog.lineToInstructionMap[pos.line] = @[]
      prog.lineToInstructionMap[pos.line].add(prog.instructions.len)

  let instr = Instruction(op: op, arg: arg, sarg: sarg, debug: debug)
  prog.instructions.add(instr)

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

proc compileIntExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  prog.emit(opLoadInt, e.ival, pos = e.pos, ctx = ctx)

proc compileFloatExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  let idx = prog.addConstant($e.fval)
  prog.emit(opLoadFloat, idx, pos = e.pos, ctx = ctx)

proc compileStringExpr(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  let idx = prog.addConstant(e.sval)
  prog.emit(opLoadString, idx, pos = e.pos, ctx = ctx)

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

  # Check if this is a user-defined function with default parameters
  if ctx.astProgram.funInstances.hasKey(e.fname):
    let fn = ctx.astProgram.funInstances[e.fname]
    totalArgCount = fn.params.len

    # Push all arguments (provided + defaults) in reverse order
    for i in countdown(fn.params.high, 0):
      if i < e.args.len:
        prog.compileExpr(e.args[i], ctx)
      elif fn.params[i].defaultValue.isSome:
        prog.compileExpr(fn.params[i].defaultValue.get, ctx)
      else:
        prog.emit(opLoadInt, 0, pos = e.pos, ctx = ctx)
  else:
    # For built-in functions or when function not found, use provided arguments only
    for i in countdown(e.args.high, 0):
      prog.compileExpr(e.args[i], ctx)

  prog.emit(opCall, totalArgCount, e.fname, e.pos, ctx)

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

proc compileExpr*(prog: var BytecodeProgram, e: Expr, ctx: var CompilationContext) =
  case e.kind
  of ekInt: prog.compileIntExpr(e, ctx)
  of ekFloat: prog.compileFloatExpr(e, ctx)
  of ekString: prog.compileStringExpr(e, ctx)
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
  prog.compileExpr(s.cond, ctx)
  let jumpToElse = prog.instructions.len
  prog.emit(opJumpIfFalse, pos = s.pos, ctx = ctx)  # Will patch this address

  for stmt in s.thenBody:
    prog.compileStmt(stmt, ctx)

  let jumpToEnd = prog.instructions.len
  prog.emit(opJump, pos = s.pos, ctx = ctx)  # Jump past else block

  # Patch jumpToElse to point here
  prog.instructions[jumpToElse].arg = prog.instructions.len

  for stmt in s.elseBody:
    prog.compileStmt(stmt, ctx)

  # Patch jumpToEnd to point here
  prog.instructions[jumpToEnd].arg = prog.instructions.len

proc compileWhileStmt(prog: var BytecodeProgram, s: Stmt, ctx: var CompilationContext) =
  let loopStart = prog.instructions.len
  prog.compileExpr(s.wcond, ctx)
  let jumpToEnd = prog.instructions.len
  prog.emit(opJumpIfFalse, pos = s.pos, ctx = ctx)  # Will patch this

  for stmt in s.wbody:
    prog.compileStmt(stmt, ctx)

  prog.emit(opJump, loopStart, pos = s.pos, ctx = ctx)  # Jump back to condition
  prog.instructions[jumpToEnd].arg = prog.instructions.len

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
  of skExpr: prog.compileExprStmt(s, ctx)
  of skReturn: prog.compileReturnStmt(s, ctx)
  of skComptime: prog.compileComptimeStmt(s, ctx)

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


proc compileProgram*(astProg: Program, sourceHash: string, sourceFile: string = "", includeDebugInfo: bool = false): BytecodeProgram =
  ## Compile an AST program to bytecode (backward compatibility)
  let flags = CompilerFlags(includeDebugInfo: includeDebugInfo)
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
    includeDebugInfo: includeDebugInfo,
    astProgram: astProg
  )

  # Compile global variables
  for g in astProg.globals:
    if g.kind == skVar:
      result.globals.add(g.vname)
      ctx.localVars.add(g.vname)

      # Evaluate and store global variable value
      if g.vinit.isSome():
        let globalVal = evaluateConstantExpr(g.vinit.get())
        result.globalValues[g.vname] = globalVal
      else:
        # Default initialization based on type
        result.globalValues[g.vname] = GlobalValue(kind: tkInt, ival: 0)

      result.compileStmt(g, ctx)

  # Compile function instances
  for name, fn in astProg.funInstances:
    ctx.currentFunction = name
    ctx.localVars = @[]

    # Add function parameters to local vars
    for param in fn.params:
      ctx.localVars.add(param.name)

    # Always store function debug info (parameter names are essential for execution)
    let debugInfo = FunctionInfo(
      name: name,
      startLine: if includeDebugInfo: 0 else: 0,  # Could be enhanced to track actual lines
      endLine: if includeDebugInfo: 0 else: 0,
      parameterNames: fn.params.mapIt(it.name),  # Always needed for execution
      localVarNames: if includeDebugInfo: @[] else: @[]
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

