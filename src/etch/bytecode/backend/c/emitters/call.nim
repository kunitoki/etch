type
  ArgExprProc = proc(idx: int): string {.closure.}

  CallArgsInfo = object
    numArgs: int
    argsPtrName: string
    argExpr: ArgExprProc


proc makeArgExpr(argsPtrName: string, numArgs: int): ArgExprProc =
  result = proc(idx: int): string =
    if numArgs == 0:
      "etch_make_nil()"
    elif idx < numArgs:
      &"{argsPtrName}[{idx}]"
    else:
      "etch_make_nil()"


proc emitCallArgsSetup(gen: var CGenerator, instr: Instruction, pc: int): CallArgsInfo =
  let numArgs = int(instr.numArgs)
  let argsArrayName = &"__etch_call_args_{pc}"
  let argsPtrName = &"__etch_call_arg_ptr_{pc}"
  let argsCountName = &"__etch_call_arg_len_{pc}"
  let argBaseName = &"__etch_call_arg_base_{pc}"

  gen.emit("  // Materialize queued arguments for call (treat queue as stack)")
  gen.emit(&"  int {argsCountName} = {numArgs};")
  gen.emit(&"  int {argBaseName} = __etch_call_arg_count - {numArgs};")
  gen.emit(&"  if ({argBaseName} < 0) {argBaseName} = 0;")
  if numArgs > 0:
    gen.emit(&"  EtchV {argsArrayName}[{numArgs}];")
    gen.emit(&"  for (int __etch_arg_i = 0; __etch_arg_i < {numArgs}; __etch_arg_i++) {{")
    gen.emit(&"    int __etch_arg_idx = {argBaseName} + __etch_arg_i;")
    gen.emit(&"    if (__etch_arg_idx >= 0 && __etch_arg_idx < __etch_call_arg_count) {{")
    gen.emit(&"      {argsArrayName}[__etch_arg_i] = __etch_call_args[__etch_arg_idx];")
    gen.emit("    } else {")
    gen.emit(&"      {argsArrayName}[__etch_arg_i] = etch_make_nil();")
    gen.emit("    }")
    gen.emit("  }")
    gen.emit(&"  EtchV* {argsPtrName} = {argsArrayName};")
  else:
    gen.emit(&"  EtchV* {argsPtrName} = NULL;")
  gen.emit(&"  __etch_call_arg_count = {argBaseName};")

  result.numArgs = numArgs
  result.argsPtrName = argsPtrName
  result.argExpr = makeArgExpr(argsPtrName, numArgs)


proc emitCallNative(gen: var CGenerator, funcName: string, resultReg: uint8, argsInfo: CallArgsInfo) =
  let safeName = sanitizeFunctionName(funcName)
  var args = ""
  if argsInfo.numArgs > 0:
    for i in 0 ..< argsInfo.numArgs:
      if i > 0:
        args &= ", "
      args &= argsInfo.argExpr(i)

  let callExpr = if args.len == 0: &"func_{safeName}()" else: &"func_{safeName}({args})"
  gen.emit(&"  r[{resultReg}] = {callExpr};  // Call user function")


proc emitCallCffi(gen: var CGenerator, funcName: string, funcInfo: FunctionInfo, resultReg: uint8,
                  argsInfo: CallArgsInfo) =
  let symbol = funcInfo.symbol
  var args = ""
  if argsInfo.numArgs > 0:
    for i in 0 ..< argsInfo.numArgs:
      if i > 0:
        args &= ", "
      let argVal = argsInfo.argExpr(i)
      if i < funcInfo.paramTypes.len:
        case funcInfo.paramTypes[i]
        of "tkFloat": args &= &"{argVal}.fval"
        of "tkInt": args &= &"{argVal}.ival"
        of "tkChar": args &= &"{argVal}.cval"
        of "tkBool": args &= &"{argVal}.bval"
        else: args &= &"{argVal}"
      else:
        args &= &"{argVal}.fval"

  gen.emit(&"  // CFFI call to {symbol}")
  case funcInfo.returnType
  of "tkFloat":
    gen.emit(&"  r[{resultReg}] = etch_make_float({symbol}({args}));")
  of "tkInt":
    gen.emit(&"  r[{resultReg}] = etch_make_int({symbol}({args}));")
  of "tkBool":
    gen.emit(&"  r[{resultReg}] = etch_make_bool({symbol}({args}));")
  of "tkChar":
    gen.emit(&"  r[{resultReg}] = etch_make_char({symbol}({args}));")
  of "tkVoid":
    gen.emit(&"  {symbol}({args});")
    gen.emit(&"  r[{resultReg}] = etch_make_nil();")
  else:
    gen.emit(&"  r[{resultReg}] = etch_make_float({symbol}({args}));")


proc emitSetNil(gen: var CGenerator, resultReg: uint8) =
  gen.emit(&"  r[{resultReg}] = etch_make_nil();")


proc emitBuiltinCall(gen: var CGenerator, builtin: BuiltinFuncId, resultReg: uint8, argsInfo: CallArgsInfo) =
  let argExpr = argsInfo.argExpr
  let argsPtrName = argsInfo.argsPtrName

  case builtin
  of bfPrint:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  etch_print_value({argVal});")
      gen.emit("  printf(\"\\n\");")
    emitSetNil(gen, resultReg)

  of bfSeed:
    if argsInfo.numArgs == 0:
      gen.emit("  etch_srand(0);")
    elif argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_INT) {{ etch_srand((uint64_t){argVal}.ival); }}")
    emitSetNil(gen, resultReg)

  of bfRand:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_INT) {{")
      gen.emit(&"    int64_t maxInt = {argVal}.ival;")
      gen.emit(&"    if (maxInt > 0) {{")
      gen.emit(&"      r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)maxInt));")
      gen.emit("    } else {")
      gen.emit(&"      r[{resultReg}] = etch_make_int(0);")
      gen.emit("    }")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_int(0);")
      gen.emit("  }")
    elif argsInfo.numArgs == 2:
      let argMin = argExpr(0)
      let argMax = argExpr(1)
      gen.emit(&"  if ({argMin}.kind == ETCH_VK_INT && {argMax}.kind == ETCH_VK_INT) {{")
      gen.emit(&"    int64_t minInt = {argMin}.ival;")
      gen.emit(&"    int64_t maxInt = {argMax}.ival;")
      gen.emit(&"    int64_t range = maxInt - minInt;")
      gen.emit(&"    if (range > 0) {{")
      gen.emit(&"      r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)range) + minInt);")
      gen.emit("    } else {")
      gen.emit(&"      r[{resultReg}] = etch_make_int(minInt);")
      gen.emit("    }")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_int(0);")
      gen.emit("  }")
    else:
      gen.emit(&"  r[{resultReg}] = etch_make_int(0);")

  of bfReadFile:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_STRING) {{")
      gen.emit(&"    r[{resultReg}] = etch_read_file({argVal}.sval);")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_err(etch_make_string(\"unexpected arguments to readFile\"));")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfParseInt:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_STRING) {{")
      gen.emit(&"    r[{resultReg}] = etch_parse_int({argVal}.sval);")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_err(etch_make_string(\"unexpected arguments to parseInt\"));")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfParseFloat:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_STRING) {{")
      gen.emit(&"    r[{resultReg}] = etch_parse_float({argVal}.sval);")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_err(etch_make_string(\"unexpected arguments to parseFloat\"));")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfParseBool:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_STRING) {{")
      gen.emit(&"    r[{resultReg}] = etch_parse_bool({argVal}.sval);")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_err(etch_make_string(\"unexpected arguments to parseBool\"));")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfIsSome:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  r[{resultReg}] = etch_make_bool({argVal}.kind == ETCH_VK_SOME);")
    else:
      emitSetNil(gen, resultReg)

  of bfIsNone:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  r[{resultReg}] = etch_make_bool({argVal}.kind == ETCH_VK_NONE);")
    else:
      emitSetNil(gen, resultReg)

  of bfIsOk:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  r[{resultReg}] = etch_make_bool({argVal}.kind == ETCH_VK_OK);")
    else:
      emitSetNil(gen, resultReg)

  of bfIsErr:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  r[{resultReg}] = etch_make_bool({argVal}.kind == ETCH_VK_ERR);")
    else:
      emitSetNil(gen, resultReg)

  of bfArrayNew:
    if argsInfo.numArgs == 2:
      let sizeVal = argExpr(0)
      let defaultVal = argExpr(1)
      gen.emit(&"  if ({sizeVal}.kind == ETCH_VK_INT) {{")
      gen.emit(&"    int64_t size = {sizeVal}.ival;")
      gen.emit(&"    EtchV arr = etch_make_array(size);")
      gen.emit(&"    for (int64_t i = 0; i < size; i++) {{")
      gen.emit(&"      arr.aval.data[i] = {defaultVal};")
      gen.emit("    }")
      gen.emit("    arr.aval.len = size;")
      gen.emit(&"    r[{resultReg}] = arr;")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_array(0);")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfNew:
    if argsInfo.numArgs == 1:
      gen.emit(&"  r[{resultReg}] = {argExpr(0)};")
    else:
      emitSetNil(gen, resultReg)

  of bfDeref:
    if argsInfo.numArgs == 1:
      let argVal = argExpr(0)
      gen.emit(&"  if ({argVal}.kind == ETCH_VK_REF) {{")
      gen.emit(&"    int objId = {argVal}.refId;")
      gen.emit(&"    if (objId > 0 && objId < etch_next_heap_id) {{")
      gen.emit(&"      if (etch_heap[objId].kind == ETCH_HOK_SCALAR) {{")
      gen.emit(&"        r[{resultReg}] = etch_heap[objId].scalarValue;")
      gen.emit("      } else if (etch_heap[objId].kind == ETCH_HOK_TABLE) {")
      gen.emit(&"        r[{resultReg}] = {argVal};")
      gen.emit("      } else if (etch_heap[objId].kind == ETCH_HOK_ARRAY) {")
      gen.emit(&"        // Convert heap array to stack array for dereferencing")
      gen.emit(&"        r[{resultReg}].kind = ETCH_VK_ARRAY;")
      gen.emit(&"        r[{resultReg}].aval.data = etch_heap[objId].array.elements;")
      gen.emit(&"        r[{resultReg}].aval.len = etch_heap[objId].array.len;")
      gen.emit(&"        r[{resultReg}].aval.cap = etch_heap[objId].array.len;")
      gen.emit("      } else {")
      gen.emit(&"        r[{resultReg}] = etch_make_nil();")
      gen.emit("      }")
      gen.emit("    } else {")
      gen.emit(&"      r[{resultReg}] = etch_make_nil();")
      gen.emit("    }")
      gen.emit("  } else {")
      gen.emit(&"    r[{resultReg}] = etch_make_nil();")
      gen.emit("  }")
    else:
      emitSetNil(gen, resultReg)

  of bfMakeClosure:
    if argsInfo.numArgs == 2:
      let funcVal = argExpr(0)
      let capturesVal = argExpr(1)
      gen.emit(&"  r[{resultReg}] = etch_builtin_make_closure({funcVal}, {capturesVal});")
    else:
      emitSetNil(gen, resultReg)

  of bfInvokeClosure:
    if argsInfo.numArgs == 0:
      emitSetNil(gen, resultReg)
    else:
      let closureVal = argExpr(0)
      let userArgs = argsInfo.numArgs - 1
      if userArgs > 0:
        gen.emit(&"  r[{resultReg}] = etch_builtin_invoke_closure({closureVal}, &{argsPtrName}[1], {userArgs});")
      else:
        gen.emit(&"  r[{resultReg}] = etch_builtin_invoke_closure({closureVal}, NULL, 0);")


proc emitUnsupportedHostCall(gen: var CGenerator, funcName: string) =
  let escaped = escapeCString(funcName)
  gen.emit(&"  etch_panic(\"Host function '{escaped}' is not supported in the C backend\");")


proc emitCall(gen: var CGenerator, instr: Instruction, pc: int) =
  doAssert instr.opType == ifmtCall

  gen.emit("{")
  let argsInfo = gen.emitCallArgsSetup(instr, pc)
  let resultReg = instr.a
  let funcIdx = int(instr.funcIdx)

  if funcIdx >= gen.program.functionTable.len:
    gen.emit(&"  etch_panic(\"Invalid function index {funcIdx}\");")
    gen.emit("}")
    return

  let funcName = gen.program.functionTable[funcIdx]
  if gen.program.functions.hasKey(funcName):
    let funcInfo = gen.program.functions[funcName]
    case funcInfo.kind
    of fkNative:
      gen.emitCallNative(funcName, resultReg, argsInfo)
    of fkCFFI:
      gen.emitCallCffi(funcName, funcInfo, resultReg, argsInfo)
    of fkBuiltin:
      doAssert funcInfo.builtinId.int <= ord(BuiltinFuncId.high)
      gen.emitBuiltinCall(BuiltinFuncId(funcInfo.builtinId), resultReg, argsInfo)
    of fkHost:
      gen.emitUnsupportedHostCall(funcName)
  else:
    if isBuiltin(funcName):
      let builtinId = getBuiltinId(funcName)
      gen.emitBuiltinCall(builtinId, resultReg, argsInfo)
    else:
      gen.emitCallNative(funcName, resultReg, argsInfo)

  gen.emit("}")


proc emitCallBuiltin(gen: var CGenerator, instr: Instruction, pc: int) =
  doAssert instr.opType == ifmtCall

  gen.emit("{")

  let builtinIdx = int(instr.funcIdx)
  doAssert builtinIdx >= 0 and builtinIdx <= ord(BuiltinFuncId.high)

  let argsInfo = gen.emitCallArgsSetup(instr, pc)
  gen.emitBuiltinCall(BuiltinFuncId(builtinIdx), instr.a, argsInfo)

  gen.emit("}")


proc emitCallFFI(gen: var CGenerator, instr: Instruction, pc: int) =
  doAssert instr.opType == ifmtCall

  gen.emit("{")

  let resultReg = instr.a
  let funcIdx = int(instr.funcIdx)
  doAssert funcIdx < gen.program.functionTable.len

  let funcName = gen.program.functionTable[funcIdx]
  doAssert gen.program.functions.hasKey(funcName)

  let funcInfo = gen.program.functions[funcName]
  doAssert funcInfo.kind == fkCFFI

  let argsInfo = gen.emitCallArgsSetup(instr, pc)
  gen.emitCallCffi(funcName, funcInfo, resultReg, argsInfo)

  gen.emit("}")


proc emitCallHost(gen: var CGenerator, instr: Instruction, pc: int) =
  doAssert instr.opType == ifmtCall

  gen.emit("{")
  discard gen.emitCallArgsSetup(instr, pc)  # Drain queued args

  let funcIdx = int(instr.funcIdx)
  doAssert funcIdx < gen.program.functionTable.len

  let funcName = gen.program.functionTable[funcIdx]
  gen.emitUnsupportedHostCall(funcName)

  gen.emit("}")
