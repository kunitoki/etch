proc emitFusedFieldArithmetic(gen: var CGenerator, instr: Instruction, op: OpCode) =
  ## Emit code for fused field arithmetic instructions (load field, apply op, store back)
  let
    a = instr.a
    valueReg = instr.b
    fieldConst = instr.c
    opLabel = case op
      of opLoadAddStore: "LoadAddStore"
      of opLoadSubStore: "LoadSubStore"
      of opLoadMulStore: "LoadMulStore"
      of opLoadDivStore: "LoadDivStore"
      of opLoadModStore: "LoadModStore"
      else: "LoadFieldOp"
    opSymbol = case op
      of opLoadAddStore: "+="
      of opLoadSubStore: "-="
      of opLoadMulStore: "*="
      of opLoadDivStore: "/="
      of opLoadModStore: "%="
      else: "?="

  gen.emit(&"// {opLabel}: R[{a}][K[{fieldConst}]] {opSymbol} R[{valueReg}]")
  gen.emit("{")
  gen.incIndent()
  gen.emit(&"const char* fieldName = etch_constants[{fieldConst}].sval;")
  gen.emit(&"EtchV base = etch_get_field(r[{a}], fieldName);")
  gen.emit(&"EtchV rhs = r[{valueReg}];")
  gen.emit("EtchV updated;")

  case op
  of opLoadAddStore:
    gen.emit("if (base.kind == ETCH_VK_STRING && rhs.kind == ETCH_VK_STRING) {")
    gen.incIndent()
    gen.emit("updated = etch_concat_strings(base, rhs);")
    gen.decIndent()
    gen.emit("} else if (base.kind == ETCH_VK_ARRAY && rhs.kind == ETCH_VK_ARRAY) {")
    gen.incIndent()
    gen.emit("updated = etch_concat_arrays(base, rhs);")
    gen.decIndent()
    gen.emit("} else {")
    gen.incIndent()
    gen.emit("updated = etch_add(base, rhs);")
    gen.decIndent()
    gen.emit("}")
  of opLoadSubStore:
    gen.emit("updated = etch_sub(base, rhs);")
  of opLoadMulStore:
    gen.emit("updated = etch_mul(base, rhs);")
  of opLoadDivStore:
    gen.emit("updated = etch_div(base, rhs);")
  of opLoadModStore:
    gen.emit("updated = etch_mod(base, rhs);")
  else:
    gen.emit("updated = etch_make_nil();")

  gen.emit(&"etch_set_field(&r[{a}], fieldName, updated);")
  gen.decIndent()
  gen.emit("}")

proc emitFusedArrayArithmetic(gen: var CGenerator, instr: Instruction, op: OpCode) =
  ## Emit code for fused array[i] op= value instructions
  let
    arrReg = instr.a
    idxReg = instr.b
    valueReg = instr.c
    opLabel = case op
      of opGetAddSet: "GetAddSet"
      of opGetSubSet: "GetSubSet"
      of opGetMulSet: "GetMulSet"
      of opGetDivSet: "GetDivSet"
      of opGetModSet: "GetModSet"
      else: "GetArrayOp"
    opSymbol = case op
      of opGetAddSet: "+="
      of opGetSubSet: "-="
      of opGetMulSet: "*="
      of opGetDivSet: "/="
      of opGetModSet: "%="
      else: "?="
    opFunc = case op
      of opGetAddSet: "etch_add"
      of opGetSubSet: "etch_sub"
      of opGetMulSet: "etch_mul"
      of opGetDivSet: "etch_div"
      else: "etch_mod"

  gen.emit(&"// {opLabel}: R[{arrReg}][R[{idxReg}]] {opSymbol} R[{valueReg}]")
  gen.emit("{")
  gen.incIndent()
  gen.emit(&"EtchV base = etch_get_index(r[{arrReg}], r[{idxReg}]);")
  gen.emit(&"EtchV rhs = r[{valueReg}];")
  if op == opGetModSet:
    gen.emit("EtchV updated = etch_mod(base, rhs);")
  else:
    gen.emit(&"EtchV updated = {opFunc}(base, rhs);")
  gen.emit(&"etch_set_index(&r[{arrReg}], r[{idxReg}], updated);")
  gen.decIndent()
  gen.emit("}")

proc emitFusedArithmeticPrio(gen: var CGenerator, name: string, op1: string, op2: string, aReg: uint8, bReg: uint8, cReg: uint8, dReg: uint8) =
  gen.emit(&"// {name}: R[{aReg}] = (R[{bReg}] {op1} R[{cReg}]) {op2} R[{dReg}]")
  # Integer op1-op2
  gen.emit(&"if (r[{bReg}].kind == ETCH_VK_INT && r[{cReg}].kind == ETCH_VK_INT && r[{dReg}].kind == ETCH_VK_INT) {{")
  gen.emit(&"  r[{aReg}] = etch_make_int((r[{bReg}].ival {op1} r[{cReg}].ival) {op2} r[{dReg}].ival);")
  # Float op1-op2
  gen.emit(&"}} else if (r[{bReg}].kind == ETCH_VK_FLOAT && r[{cReg}].kind == ETCH_VK_FLOAT && r[{dReg}].kind == ETCH_VK_FLOAT) {{")
  gen.emit(&"  r[{aReg}] = etch_make_float((r[{bReg}].fval {op1} r[{cReg}].fval) {op2} r[{dReg}].fval);")
  # Generic op1-op2
  gen.emit(&"}} else if ((r[{bReg}].kind == ETCH_VK_INT || r[{bReg}].kind == ETCH_VK_FLOAT) &&")
  gen.emit(&"            (r[{cReg}].kind == ETCH_VK_INT || r[{cReg}].kind == ETCH_VK_FLOAT) &&")
  gen.emit(&"            (r[{dReg}].kind == ETCH_VK_INT || r[{dReg}].kind == ETCH_VK_FLOAT)) {{")
  gen.emit(&"  double bv = (r[{bReg}].kind == ETCH_VK_INT) ? (double)r[{bReg}].ival : r[{bReg}].fval;")
  gen.emit(&"  double cv = (r[{cReg}].kind == ETCH_VK_INT) ? (double)r[{cReg}].ival : r[{cReg}].fval;")
  gen.emit(&"  double dv = (r[{dReg}].kind == ETCH_VK_INT) ? (double)r[{dReg}].ival : r[{dReg}].fval;")
  gen.emit(&"  r[{aReg}] = etch_make_float((bv {op1} cv) {op2} dv);")
  gen.emit(&"}} else {{")
  gen.emit(&"  r[{aReg}] = etch_make_nil();")
  gen.emit(&"}}")

proc emitFusedArithmetic(gen: var CGenerator, name: string, op1: string, op2: string, aReg: uint8, bReg: uint8, cReg: uint8, dReg: uint8) =
  gen.emit(&"// {name}: R[{aReg}] = R[{bReg}] {op1} R[{cReg}] {op2} R[{dReg}]")
  # Integer op1-op2
  gen.emit(&"if (r[{bReg}].kind == ETCH_VK_INT && r[{cReg}].kind == ETCH_VK_INT && r[{dReg}].kind == ETCH_VK_INT) {{")
  gen.emit(&"  r[{aReg}] = etch_make_int(r[{bReg}].ival {op1} r[{cReg}].ival {op2} r[{dReg}].ival);")
  # Float op1-op2
  gen.emit(&"}} else if (r[{bReg}].kind == ETCH_VK_FLOAT && r[{cReg}].kind == ETCH_VK_FLOAT && r[{dReg}].kind == ETCH_VK_FLOAT) {{")
  gen.emit(&"  r[{aReg}] = etch_make_float(r[{bReg}].fval {op1} r[{cReg}].fval {op2} r[{dReg}].fval);")
  # Generic op1-op2
  gen.emit(&"}} else if ((r[{bReg}].kind == ETCH_VK_INT || r[{bReg}].kind == ETCH_VK_FLOAT) &&")
  gen.emit(&"            (r[{cReg}].kind == ETCH_VK_INT || r[{cReg}].kind == ETCH_VK_FLOAT) &&")
  gen.emit(&"            (r[{dReg}].kind == ETCH_VK_INT || r[{dReg}].kind == ETCH_VK_FLOAT)) {{")
  gen.emit(&"  double bv = (r[{bReg}].kind == ETCH_VK_INT) ? (double)r[{bReg}].ival : r[{bReg}].fval;")
  gen.emit(&"  double cv = (r[{cReg}].kind == ETCH_VK_INT) ? (double)r[{cReg}].ival : r[{cReg}].fval;")
  gen.emit(&"  double dv = (r[{dReg}].kind == ETCH_VK_INT) ? (double)r[{dReg}].ival : r[{dReg}].fval;")
  gen.emit(&"  r[{aReg}] = etch_make_float(bv {op1} cv {op2} dv);")
  gen.emit(&"}} else {{")
  gen.emit(&"  r[{aReg}] = etch_make_nil();")
  gen.emit(&"}}")

proc emitBinaryAddExpr(gen: var CGenerator, target: string, lhs: string, rhs: string) =
  let left = lhs
  let right = rhs
  gen.emit(&"if (({left}).kind == ETCH_VK_STRING && ({right}).kind == ETCH_VK_STRING) {{")
  gen.emit(&"  {target} = etch_concat_strings({left}, {right});")
  gen.emit(&"}} else if (({left}).kind == ETCH_VK_ARRAY && ({right}).kind == ETCH_VK_ARRAY) {{")
  gen.emit(&"  {target} = etch_concat_arrays({left}, {right});")
  gen.emit("} else {")
  gen.emit(&"  {target} = etch_add({left}, {right});")
  gen.emit("}")
