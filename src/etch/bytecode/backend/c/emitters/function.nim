proc emitReturn(gen: var CGenerator, instr: Instruction) =
  # opReturn: A = number of results, B = starting register
  # If A is 0, return nil; if A is 1, return r[B]
  doAssert instr.opType == ifmtABC

  let numResults = instr.a
  let retReg = instr.b
  if numResults == 0:
    gen.emit(&"return etch_make_nil();  // Return (no value)")
  elif numResults == 1:
    gen.emit(&"return r[{retReg}];  // Return")
  else:
    gen.emit(&"// TODO: Multiple return values not yet supported")
    gen.emit(&"return r[{retReg}];  // Return first value")


proc emitFunction(gen: var CGenerator, funcName: string, info: FunctionInfo) =
  ## Emit a C function from VirtualMachine bytecode
  # Only emit C code for native functions, skip CFFI functions
  if info.kind != fkNative:
    return

  let safeName = sanitizeFunctionName(funcName)
  gen.emit(&"\n// Function: {funcName}")

  # Check if function uses defer blocks
  var hasDefer = false
  var deferTargets: seq[int] = @[]
  var execDefersLocations: seq[int] = @[]
  for pc in info.startPos ..< info.endPos:
    if pc < gen.program.instructions.len:
      let instr = gen.program.instructions[pc]
      if instr.op == opPushDefer:
        hasDefer = true
        if instr.opType == ifmtAsBx:
          let offset = instr.sbx
          let targetPC = pc + offset
          if targetPC notin deferTargets:
            deferTargets.add(targetPC)
      elif instr.op == opExecDefers:
        # Track ExecDefers locations for defer jumps (but don't set hasDefer)
        if pc notin execDefersLocations:
          execDefersLocations.add(pc)

  # Generate parameter list
  var params = ""
  if info.paramTypes.len > 0:
    for i in 0 ..< info.paramTypes.len:
      if i > 0:
        params &= ", "
      params &= &"EtchV p{i}"
  else:
    params = "void"

  gen.emit(&"EtchV func_{safeName}({params}) {{")
  gen.incIndent()

  # Allocate registers based on actual usage
  # maxRegister is the highWaterMark (next register to allocate), so we need maxRegister+1 slots
  # to accommodate indices 0 through maxRegister
  let numRegisters = max(1, info.maxRegister + 1)
  gen.currentFuncNumRegisters = numRegisters  # Store for use in instructions
  gen.emit(&"EtchV r[{numRegisters}];")
  gen.emit("// Initialize registers to nil")
  gen.emit(&"for (int i = 0; i < {numRegisters}; i++) r[i] = etch_make_nil();")
  gen.emit("EtchV __etch_call_args[ETCH_MAX_CALL_ARGS];")
  gen.emit("int __etch_call_arg_count = 0;")

  # Defer stack for defer blocks (only if function uses defer)
  if hasDefer:
    gen.emit("")
    gen.emit("// Defer stack")
    gen.emit("int __etch_defer_stack[ETCH_MAX_DEFER_STACK]; // Stack of PC locations for defer blocks")
    gen.emit("int __etch_defer_count = 0;")
    gen.emit("int __etch_defer_return_pc = -1;")

  # Add coroutine resume logic BEFORE parameter copy
  gen.emit("")
  gen.emit("// Coroutine resume logic")
  gen.emit("if (etch_active_coro_id >= 0) {")
  gen.emit("  EtchCoroutine* coro = &etch_coroutines[etch_active_coro_id];")
  gen.emit("  if (coro->state == CORO_SUSPENDED || coro->state == CORO_CLEANUP) {")
  gen.emit("    bool isCleanup = (coro->state == CORO_CLEANUP);")
  gen.emit("    // Restore registers (skip parameter copy)")
  gen.emit(&"    for (int i = 0; i < coro->numRegisters && i < {numRegisters}; i++) {{")
  gen.emit("      r[i] = coro->registers[i];")
  gen.emit("    }")
  # Only restore defer state if function has defers
  if deferTargets.len > 0 or execDefersLocations.len > 0:
    gen.emit("    // Restore defer stack state")
    gen.emit("    for (int i = 0; i < coro->deferCount && i < 32; i++) {")
    gen.emit("      __etch_defer_stack[i] = coro->deferStack[i];")
    gen.emit("    }")
    gen.emit("    __etch_defer_count = coro->deferCount;")
    gen.emit("    __etch_defer_return_pc = coro->deferReturnPC;")
  gen.emit("    coro->state = CORO_RUNNING;")
  gen.emit("    // Jump to resume point")
  if deferTargets.len > 0 or execDefersLocations.len > 0:
    gen.emit("    if (isCleanup) {")
    gen.emit("      // Cleanup mode: jump directly to defer execution")
    if execDefersLocations.len > 0:
      let deferPC = execDefersLocations[0]
      gen.emit(&"      goto L{deferPC};")
    else:
      gen.emit("      return etch_make_nil();  // No defers, just return")
    gen.emit("    }")
  gen.emit("    switch (coro->resumePC) {")
  # We'll add cases for each PC that comes after a yield
  for pc in info.startPos ..< info.endPos:
    if pc < gen.program.instructions.len:
      if pc > info.startPos:  # Don't add case for start
        let prevPC = pc - 1
        if prevPC >= info.startPos and prevPC < gen.program.instructions.len:
          let prevInstr = gen.program.instructions[prevPC]
          if prevInstr.op == opYield:
            gen.emit(&"      case {pc}: goto L{pc};")
  gen.emit("    }")
  gen.emit("  }")
  gen.emit("}")

  # Copy parameters to registers (only on first call, not on resume)
  if info.paramTypes.len > 0:
    gen.emit("")
    gen.emit("// Copy parameters to registers (only on first call)")
    for i in 0 ..< info.paramTypes.len:
      gen.emit(&"r[{i}] = p{i};")

  gen.emit("")

  # Store defer targets for this function
  gen.deferTargets = deferTargets
  gen.execDefersLocations = execDefersLocations

  # Emit instructions with labels
  for pc in info.startPos ..< info.endPos:
    # Emit label for this instruction (for jumps)
    gen.emit(&"L{pc}:")
    if pc < gen.program.instructions.len:
      try:
        gen.emitInstruction(gen.program.instructions[pc], gen.program.debugInfo[pc], pc)
      except FieldDefect as e:
        let instr = gen.program.instructions[pc]
        echo &"ERROR at PC {pc}: {instr.op} (opType={instr.opType}): {e.msg}"
        raise

  # Default return
  gen.emit(&"L{info.endPos}:")
  gen.emit("return etch_make_nil();")

  gen.decIndent()
  gen.emit("}")


proc emitFunctionDispatchHelper(gen: var CGenerator) =
  ## Generate helper for calling Etch functions by index (used by closures)
  gen.emit("")
  gen.emit("EtchV etch_call_function_by_index(int funcIdx, EtchV* args, int numArgs) {")
  gen.incIndent()
  gen.emit("switch (funcIdx) {")
  for funcIdx, funcName in gen.program.functionTable:
    if gen.program.functions.hasKey(funcName):
      let funcInfo = gen.program.functions[funcName]
      let safeName = sanitizeFunctionName(funcName)
      gen.emit(&"  case {funcIdx}:")
      if funcInfo.kind == fkNative:
        if funcInfo.paramTypes.len > 0:
          var params = ""
          for i in 0 ..< funcInfo.paramTypes.len:
            if i > 0:
              params &= ", "
            params &= &"args[{i}]"
          gen.emit(&"    if (numArgs < {funcInfo.paramTypes.len} || args == NULL) etch_panic(\"Invalid argument count for function {funcName}\");")
          gen.emit(&"    return func_{safeName}({params});")
        else:
          gen.emit(&"    return func_{safeName}();")
      else:
        gen.emit(&"    return etch_make_nil();")
  gen.emit("  default:")
  gen.emit("    etch_panic(\"Unknown function index\");")
  gen.emit("    return etch_make_nil();")
  gen.emit("}")
  gen.decIndent()
  gen.emit("}")
