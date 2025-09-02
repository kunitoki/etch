

proc compileNilExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling nil to reg {result}")
  c.prog.emitABC(opLoadNil, result, result, 0, c.makeDebugInfo(e.pos))


proc compileBoolExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling bool {e.bval} to reg {result}")
  c.prog.emitABC(opLoadBool, result, if e.bval: 1 else: 0, 0, c.makeDebugInfo(e.pos))


proc compileCharExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling char {e.cval} to reg {result}")
  let constIdx = c.addConst(makeChar(e.cval))
  c.prog.emitABx(opLoadK, result, constIdx, c.makeDebugInfo(e.pos))
  logCompiler(c.verbose, &"  Loaded to register {result} from const[{constIdx}]")


proc compileIntExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling integer {e.ival} to reg {result}")
  if e.ival >= -32768 and e.ival <= 32767:
    # Small integer - can use immediate encoding
    c.prog.emitAsBx(opLoadK, result, int16(e.ival), c.makeDebugInfo(e.pos))
  else:
    # Large integer - need constant pool
    let constIdx = c.addConst(makeInt(e.ival))
    c.prog.emitABx(opLoadK, result, constIdx, c.makeDebugInfo(e.pos))


proc compileFloatExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling float {e.fval} to reg {result}")
  let constIdx = c.addConst(makeFloat(e.fval))
  c.prog.emitABx(opLoadK, result, constIdx, c.makeDebugInfo(e.pos))
  logCompiler(c.verbose, &"  Loaded to register {result} from const[{constIdx}]")


proc compileStringExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling string '{e.sval}' to reg {result}")
  let constIdx = c.addStringConst(e.sval)
  c.prog.emitABx(opLoadK, result, constIdx, c.makeDebugInfo(e.pos))
  logCompiler(c.verbose, &"  Loaded to register {result} from const[{constIdx}]")


proc compileTypeofExpression(c: var Compiler, e: Expression): uint8 =
  result = c.allocator.allocReg()
  logCompiler(c.verbose, &"Compiling typeof to reg {result}")
  let innerType = e.typeofExpression.typ
  let constIdx = c.addConst(makeTypeDesc($innerType))
  c.prog.emitABx(opLoadK, result, constIdx, c.makeDebugInfo(e.pos))
  logCompiler(c.verbose, &"  Loaded to register {result} from const[{constIdx}]")


proc compileVarExpression(c: var Compiler, e: Expression): uint8 =
  # Track variable use for lifetime analysis
  let currentPC = c.prog.instructions.len
  c.lifetimeTracker.useVariable(e.vname, currentPC)

  # Check if variable already in register
  if c.allocator.regMap.hasKey(e.vname):
    logCompiler(c.verbose, &"Variable '{e.vname}' found in register {c.allocator.regMap[e.vname]}")
    return c.allocator.regMap[e.vname]
  else:
    # If this name corresponds to a known function instance, construct a
    # closure for the (top-level) function value with empty captures.
    var fnName = e.vname
    if not c.funInstances.hasKey(fnName):
      # Try to find a mangled instance whose base name matches
      for fname, _ in c.funInstances:
        if functionNameFromSignature(fname) == e.vname:
          fnName = fname
          break

    if c.funInstances.hasKey(fnName):
      logCompiler(c.verbose, &"Variable '{e.vname}' is a function (resolved as {fnName}), creating closure")
      result = c.allocator.allocReg()

      let callDebug = c.makeDebugInfo(e.pos)

      # Queue function index constant argument
      let funcIdx = c.addFunctionIndex(fnName)
      let funcIdxConst = c.addConst(makeInt(int64(funcIdx)))
      c.prog.emitABx(opArgImm, 0, funcIdxConst, callDebug)

      # Create empty captures array and queue it as second argument
      let capturesReg = c.allocator.allocReg()
      c.prog.emitABx(opNewArray, capturesReg, uint16(0), callDebug)
      c.prog.emitABC(opArg, capturesReg, 0, 0, callDebug)
      c.allocator.freeReg(capturesReg)

      # Emit call to __make_closure with queued args
      c.emitCallInstruction(result, "__make_closure", 2, 1, callDebug)

      return result

    # Load from global
    # IMPORTANT: Don't add globals to regMap - they can be modified elsewhere
    # and the cached register value would become stale
    logCompiler(c.verbose, &"Variable '{e.vname}' not in regMap, loading from global")
    result = c.allocator.allocReg()  # Don't pass name - don't cache globals
    let nameIdx = c.addStringConst(e.vname)
    c.prog.emitABx(opGetGlobal, result, nameIdx, c.makeDebugInfo(e.pos))
