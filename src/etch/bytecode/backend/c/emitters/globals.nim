proc execInitGlobal(gen: var CGenerator, instr: Instruction) =
  doAssert instr.opType == ifmtABx

  let a = instr.a
  let bx = instr.bx
  gen.emit(&"// InitGlobal: globals[K[{bx}]] = R[{a}] (only if not already set)")
  gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
  gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
  gen.emit(&"  if (!etch_has_global(name)) {{")
  gen.emit(&"    etch_set_global(name, r[{a}]);")
  gen.emit(&"  }}")
  gen.emit(&"}}")


proc execGetGlobal(gen: var CGenerator, instr: Instruction) =
  doAssert instr.opType == ifmtABx

  let a = instr.a
  let bx = instr.bx
  gen.emit(&"// GetGlobal: R[{a}] = globals[K[{bx}]]")
  gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
  gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
  gen.emit(&"  r[{a}] = etch_get_global(name);")
  gen.emit(&"}} else {{")
  gen.emit(&"  r[{a}] = etch_make_nil();")
  gen.emit(&"}}")


proc execSetGlobal(gen: var CGenerator, instr: Instruction) =
  doAssert instr.opType == ifmtABx

  let a = instr.a
  let bx = instr.bx
  gen.emit(&"// SetGlobal: globals[K[{bx}]] = R[{a}]")
  gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
  gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
  gen.emit(&"  etch_set_global(name, r[{a}]);")
  gen.emit(&"}}")
