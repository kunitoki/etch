proc emitSpawn(gen: var CGenerator, instr: Instruction, pc: int) =
  # Spawn a coroutine: R[A] = spawn(funcIdx=B, numArgs=C)
  # Arguments come from the pending call queue (like opCall); fall back to registers when empty
  let a = instr.a
  let funcIdx = instr.b
  let numArgs = instr.c
  let argsArrayName = &"__etch_spawn_args_{pc}"
  let argsPtrName = &"__etch_spawn_arg_ptr_{pc}"
  let argBaseName = &"__etch_spawn_arg_base_{pc}"
  let useQueueName = &"__etch_spawn_use_queue_{pc}"

  gen.emit(&"// Spawn coroutine for function index {funcIdx} with {numArgs} args")
  gen.emit(&"{{")
  gen.incIndent()
  if numArgs > 0:
    gen.emit(&"int {argBaseName} = __etch_call_arg_count - {numArgs};")
    gen.emit(&"if ({argBaseName} < 0) {argBaseName} = 0;")
    gen.emit(&"bool {useQueueName} = (__etch_call_arg_count >= {numArgs});")
    gen.emit(&"EtchV {argsArrayName}[{numArgs}];")
    gen.emit(&"if ({useQueueName}) {{")
    gen.emit(&"  for (int __etch_arg_i = 0; __etch_arg_i < {numArgs}; __etch_arg_i++) {{")
    gen.emit(&"    int __etch_arg_idx = {argBaseName} + __etch_arg_i;")
    gen.emit(&"    if (__etch_arg_idx >= 0 && __etch_arg_idx < __etch_call_arg_count) {{")
    gen.emit(&"      {argsArrayName}[__etch_arg_i] = __etch_call_args[__etch_arg_idx];")
    gen.emit(&"    }} else {{")
    gen.emit(&"      {argsArrayName}[__etch_arg_i] = etch_make_nil();")
    gen.emit(&"    }}")
    gen.emit(&"  }}")
    gen.emit(&"}} else {{")
    gen.emit(&"  // Legacy fallback: read args from registers next to target register")
    for i in 0..<int(numArgs):
      gen.emit(&"  {argsArrayName}[{i}] = r[{a + 1 + uint8(i)}];")
    gen.emit(&"}}")
    gen.emit(&"EtchV* {argsPtrName} = {argsArrayName};")
    gen.emit(&"__etch_call_arg_count = {argBaseName};")
    gen.emit(&"int coro_id = etch_coro_spawn({funcIdx}, {argsPtrName}, {numArgs});")
  else:
    gen.emit(&"int coro_id = etch_coro_spawn({funcIdx}, NULL, 0);")
  gen.emit(&"r[{a}] = etch_make_coroutine(coro_id);")
  gen.decIndent()
  gen.emit(&"}}")


proc emitResume(gen: var CGenerator, instr: Instruction, pc: int) =
  # Resume coroutine: R[A] = resume(R[B])
  let a = instr.a
  let coroReg = instr.b

  gen.emit(&"// Resume coroutine")
  gen.emit(&"{{")
  gen.incIndent()
  gen.emit(&"EtchV resume_payload = etch_make_nil();")
  gen.emit(&"bool resume_error = false;")
  gen.emit(&"const char* resume_error_msg = NULL;")
  gen.emit(&"char resume_error_buf[128];")
  gen.emit(&"resume_error_buf[0] = '\\0';")
  gen.emit(&"if (r[{coroReg}].kind != ETCH_VK_COROUTINE) {{")
  gen.emit(&"  resume_error = true;")
  gen.emit(&"  resume_error_msg = \"resume requires a coroutine value\";")
  gen.emit(&"}} else {{")
  gen.emit(&"  int coro_id = r[{coroReg}].coroId;")
  gen.emit(&"  if (coro_id < 0 || coro_id >= etch_next_coro_id) {{")
  gen.emit(&"    resume_error = true;")
  gen.emit(&"    resume_error_msg = \"invalid coroutine reference\";")
  gen.emit(&"  }} else {{")
  gen.emit(&"    EtchCoroutine* coro = &etch_coroutines[coro_id];")
  gen.emit(&"    if (coro->state == CORO_RUNNING) {{")
  gen.emit(&"      resume_error = true;")
  gen.emit(&"      snprintf(resume_error_buf, sizeof(resume_error_buf), \"coroutine %d is already running\", coro_id);")
  gen.emit(&"    }} else if (coro->state == CORO_COMPLETED || coro->state == CORO_DEAD) {{")
  gen.emit(&"      resume_error = true;")
  gen.emit(&"      resume_error_msg = \"cannot resume completed coroutine\";")
  gen.emit(&"    }} else {{")
  gen.emit(&"      int prev_active = etch_active_coro_id;")
  gen.emit(&"      etch_active_coro_id = coro_id;")
  gen.emit(&"      EtchV result = etch_make_nil();")
  gen.emit(&"      // Call coroutine function based on funcIdx")
  gen.emit(&"      switch (coro->funcIdx) {{")
  # Build function dispatch using the function table (which has correct ordering)
  for funcIdx, funcName in gen.program.functionTable:
    if gen.program.functions.hasKey(funcName):
      let funcInfo = gen.program.functions[funcName]
      let safeName = sanitizeFunctionName(funcName)
      gen.emit(&"    case {funcIdx}:")
      if funcInfo.kind == fkNative:
        # On first resume (READY state), pass arguments from coroutine registers
        # On subsequent resumes (SUSPENDED), registers are already restored by function
        if funcInfo.paramTypes.len > 0:
          var params = ""
          for i in 0 ..< funcInfo.paramTypes.len:
            if i > 0:
              params &= ", "
            # Pass argument from coroutine's saved registers if READY, else nil
            params &= &"(coro->state == CORO_READY ? coro->registers[{i}] : etch_make_nil())"
          gen.emit(&"      result = func_{safeName}({params});")
        else:
          gen.emit(&"      result = func_{safeName}();")
      else:
        # CFFI function - no coroutine support
        gen.emit(&"      result = etch_make_nil();  // CFFI functions don't support coroutines")
      gen.emit(&"      break;")
  gen.emit(&"    default:")
  gen.emit(&"      etch_panic(\"Unknown coroutine function\");")
  gen.emit(&"      result = etch_make_nil();")
  gen.emit(&"      break;")
  gen.emit(&"      }}")
  gen.emit(&"      etch_active_coro_id = prev_active;")
  gen.emit(&"      if (coro->state == CORO_SUSPENDED) {{")
  gen.emit(&"        resume_payload = coro->yieldValue;")
  gen.emit(&"      }} else {{")
  gen.emit(&"        coro->state = CORO_COMPLETED;")
  gen.emit(&"        coro->returnValue = result;")
  gen.emit(&"        resume_payload = result;")
  gen.emit(&"      }}")
  gen.emit(&"    }}")
  gen.emit(&"  }}")
  gen.emit(&"}}");
  gen.emit(&"if (resume_error) {{")
  gen.emit(&"  const char* errMsg = resume_error_buf[0] != '\\0' ? resume_error_buf : (resume_error_msg != NULL ? resume_error_msg : \"resume error\");")
  gen.emit(&"  r[{a}] = etch_make_err(etch_make_string(errMsg));")
  gen.emit(&"}} else {{")
  gen.emit(&"  r[{a}] = etch_make_ok(resume_payload);")
  gen.emit(&"}}")
  gen.decIndent()
  gen.emit(&"}}")

proc emitYield(gen: var CGenerator, instr: Instruction, pc: int) =
  # Yield from coroutine: yield(R[A]), PC saved for resume
  let a = instr.a
  gen.emit(&"// Yield from coroutine")
  gen.emit(&"{{")
  gen.incIndent()
  gen.emit(&"if (etch_active_coro_id >= 0) {{")
  gen.emit(&"  EtchCoroutine* coro = &etch_coroutines[etch_active_coro_id];")
  gen.emit(&"  coro->yieldValue = r[{a}];")
  gen.emit(&"  coro->state = CORO_SUSPENDED;")
  gen.emit(&"  coro->resumePC = {pc + 1};  // Resume at next instruction")
  # Save coroutine registers with deep copy for tables/arrays
  gen.emit(&"  for (int i = 0; i < {gen.currentFuncNumRegisters}; i++) {{")
  gen.emit(&"    if (r[i].kind == ETCH_VK_TABLE || r[i].kind == ETCH_VK_ARRAY) {{")
  gen.emit(&"      coro->registers[i] = etch_value_deep_copy(r[i]);")
  gen.emit(&"    }} else {{")
  gen.emit(&"      coro->registers[i] = r[i];")
  gen.emit(&"    }}")
  gen.emit(&"  }}")
  gen.emit(&"  coro->numRegisters = {gen.currentFuncNumRegisters};")
  # Save defer stack state (only if function has defers)
  if gen.deferTargets.len > 0 or gen.execDefersLocations.len > 0:
    gen.emit(&"  for (int i = 0; i < __etch_defer_count && i < ETCH_MAX_DEFER_STACK; i++) {{")
    gen.emit(&"    coro->deferStack[i] = __etch_defer_stack[i];")
    gen.emit(&"  }}")
    gen.emit(&"  coro->deferCount = __etch_defer_count;")
    gen.emit(&"  coro->deferReturnPC = __etch_defer_return_pc;")
  gen.emit(&"  int saved_coro_id = etch_active_coro_id;")
  gen.emit(&"  etch_active_coro_id = -1;  // Return to main")
  gen.emit(&"  return etch_coroutines[saved_coro_id].yieldValue;  // Return yielded value")
  gen.emit(&"}}")
  gen.decIndent()
  gen.emit(&"}}")


proc emitCoroutineDispatch(gen: var CGenerator) =
  ## Generate the coroutine dispatch function
  gen.emit("")
  gen.emit("// Coroutine dispatch - calls the correct function for a coroutine")
  gen.emit("static EtchV etch_coro_dispatch(int coroId) {")
  gen.incIndent()
  gen.emit("EtchCoroutine* coro = &etch_coroutines[coroId];")
  gen.emit("EtchV result = etch_make_nil();")
  gen.emit("switch (coro->funcIdx) {")

  for funcIdx, funcName in gen.program.functionTable:
    if gen.program.functions.hasKey(funcName):
      let funcInfo = gen.program.functions[funcName]
      let safeName = sanitizeFunctionName(funcName)
      gen.emit(&"  case {funcIdx}:")
      if funcInfo.kind == fkNative:
        # Native function - use paramTypes.len
        if funcInfo.paramTypes.len > 0:
          var params = ""
          for i in 0 ..< funcInfo.paramTypes.len:
            if i > 0:
              params &= ", "
            params &= &"(coro->state == CORO_READY ? coro->registers[{i}] : etch_make_nil())"
          gen.emit(&"    result = func_{safeName}({params});")
        else:
          gen.emit(&"    result = func_{safeName}();")
      else:
        # CFFI function - no direct coroutine support
        gen.emit(&"    result = etch_make_nil();  // CFFI functions don't support coroutines")
      gen.emit(&"    break;")

  gen.emit("  default:")
  gen.emit("    etch_panic(\"Unknown coroutine function\");")
  gen.emit("}")
  gen.emit("return result;")
  gen.decIndent()
  gen.emit("}")
