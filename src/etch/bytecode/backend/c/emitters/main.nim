proc emitMainWrapper(gen: var CGenerator) =
  ## Emit the main function wrapper
  gen.emit("\nint main(int argc, char** argv) {")
  gen.incIndent()
  gen.emit("etch_init_constants();")
  gen.emit("")
  gen.emit("// Reset coroutine state")
  gen.emit("etch_next_coro_id = 0;")
  gen.emit("etch_active_coro_id = -1;")
  gen.emit("for (int i = 0; i < ETCH_MAX_COROUTINES; i++) {")
  gen.emit("  etch_coroutines[i].state = CORO_DEAD;")
  gen.emit("}")

  # Call <global> function if it exists (initializes global variables and calls main)
  # Note: <global> will call main as a "transition", so we don't call main separately
  const GLOBAL_INIT_FUNCTION = "<global>"
  if gen.program.functions.hasKey(GLOBAL_INIT_FUNCTION):
    let globalSafeName = sanitizeFunctionName(GLOBAL_INIT_FUNCTION)
    gen.emit(&"func_{globalSafeName}();  // Initialize globals")
  else:
    # No <global> function, call main directly
    if gen.program.functions.hasKey(MAIN_FUNCTION_NAME):
      let safeName = sanitizeFunctionName(MAIN_FUNCTION_NAME)
      gen.emit(&"EtchV result = func_{safeName}();")
      # Don't print main's return value (matches bytecode VM behavior)
      gen.emit("// If main returns an int, use it as the exit code")
      gen.emit("if (result.kind == ETCH_VK_INT) {")
      gen.emit("  return (int)result.ival;")
      gen.emit("}")
    else:
      gen.emit("printf(\"No main function found\\n\");")

  # TODO: Run final cycle detection before exit
  gen.emit("")
  gen.emit("// Run cycle detection before exit")
  gen.emit("etch_heap_detect_cycles();")
  gen.emit("")
  gen.emit("return 0;")
  gen.decIndent()
  gen.emit("}")
