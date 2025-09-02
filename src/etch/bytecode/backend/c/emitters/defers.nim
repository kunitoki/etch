proc emitExecDefers(gen: var CGenerator, pc: int) =
  gen.emit(&"// ExecDefers: execute all deferred blocks in LIFO order")
  gen.emit(&"if (__etch_defer_count > 0) {{")
  gen.emit(&"  __etch_defer_return_pc = {pc};  // Save return point")
  gen.emit(&"  int __etch_defer_pc = __etch_defer_stack[--__etch_defer_count];  // Pop defer")
  gen.emit(&"  switch (__etch_defer_pc) {{")
  for target in gen.deferTargets:
    gen.emit(&"    case {target}: goto L{target};")
  gen.emit(&"  }}")
  gen.emit(&"}}")


proc emitPushDefers(gen: var CGenerator, instr: Instruction, pc: int) =
    doAssert instr.opType == ifmtAsBx

    let offset = instr.sbx
    let targetPC = pc + offset
    gen.emit(&"// PushDefer: register defer block at L{targetPC}")
    gen.emit(&"__etch_defer_stack[__etch_defer_count++] = {targetPC};")


proc emitEndDefers(gen: var CGenerator) =
  gen.emit(&"// DeferEnd: end of defer block")
  gen.emit(&"if (__etch_defer_count > 0) {{")
  gen.emit(&"  // More defers to execute")
  gen.emit(&"  int __etch_defer_pc = __etch_defer_stack[--__etch_defer_count];")
  gen.emit(&"  switch (__etch_defer_pc) {{")
  for target in gen.deferTargets:
    gen.emit(&"    case {target}: goto L{target};")
  gen.emit(&"  }}")
  gen.emit(&"}} else {{")
  gen.emit(&"  // All defers executed, return to saved PC")
  gen.emit(&"  switch (__etch_defer_return_pc) {{")
  # Generate cases for all ExecDefers locations (return points)
  for returnPC in gen.execDefersLocations:
    gen.emit(&"    case {returnPC}: goto L{returnPC};")
  gen.emit(&"    default: break;  // Should not reach here")
  gen.emit(&"  }}")
  gen.emit(&"}}")
