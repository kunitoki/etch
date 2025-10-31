# generator.nim
# C backend generator for Etch Register VM bytecode

import std/[tables, strformat, strutils]
import ../../common/[constants]
import ../../interpreter/[regvm]

type
  CGenerator* = object
    output: string
    indent: int
    labelCounter: int
    program: RegBytecodeProgram
    deferTargets: seq[int]  # Target PCs for defer blocks in current function
    execDefersLocations: seq[int]  # PCs where ExecDefers is called

proc newCGenerator(program: RegBytecodeProgram): CGenerator =
  CGenerator(output: "", indent: 0, labelCounter: 0, program: program, deferTargets: @[], execDefersLocations: @[])

proc emit(gen: var CGenerator, code: string) =
  gen.output.add(repeat("  ", gen.indent) & code & "\n")

proc incIndent(gen: var CGenerator) =
  inc gen.indent

proc decIndent(gen: var CGenerator) =
  dec gen.indent

proc sanitizeFunctionName(name: string): string =
  ## Sanitize function names for C by replacing operators with descriptive names
  ## Process multi-char operators first to avoid collisions
  result = name.multiReplace([
    ("==", "_eq_"), ("!=", "_ne_"), ("<=", "_le_"), (">=", "_ge_"),
    ("<", "_lt_"), (">", "_gt_"), ("::", "_scp_"), (":", "_col_"),
    ("+", "_pls_"), ("-", "_mns_"), ("*", "_mul_"), ("/", "_div_"),
    ("%", "_mod_"), ("!", "_not_"), ("&", "_and_"), ("|", "_or_"),
    ("^", "_xor_"), ("~", "_bnot_"), ("[", "_lbr_"), ("]", "_rbr_"),
    ("(", "_lp_"), (")", "_rp_"), (".", "_dot_"), (",", "_cma_"),
    ("=", "_asg_"), ("~", "_del_"), (" ", "_")
  ])

proc emitCRuntime*(gen: var CGenerator) =
  ## Emit the C runtime header with EtchV type implementation
  const runtimeHeader = slurp "runtime.h"
  gen.emit(runtimeHeader)

proc emitConstantPool(gen: var CGenerator) =
  ## Emit the constant pool as a C array
  let poolSize = max(1, gen.program.constants.len)
  gen.emit(&"\n// Constant pool ({gen.program.constants.len} etch_constants)")
  gen.emit(&"#define ETCH_CONST_POOL_SIZE {poolSize}")
  gen.emit(&"EtchV etch_constants[{poolSize}];")
  gen.emit("\nvoid etch_init_constants(void) {")
  gen.incIndent()

  for i, constant in gen.program.constants:
    case constant.kind
    of vkInt:
      gen.emit(&"etch_constants[{i}] = etch_make_int({constant.ival});")
    of vkFloat:
      gen.emit(&"etch_constants[{i}] = etch_make_float({constant.fval});")
    of vkBool:
      gen.emit(&"etch_constants[{i}] = etch_make_bool({($constant.bval).toLowerAscii()});")
    of vkChar:
      let charRepr = if constant.cval == '\'': "\\'"
                     elif constant.cval == '\\': "\\\\"
                     else: $constant.cval
      gen.emit(&"etch_constants[{i}] = etch_make_char('{charRepr}');")
    of vkNil:
      gen.emit(&"etch_constants[{i}] = etch_make_nil();")
    of vkNone:
      gen.emit(&"etch_constants[{i}] = etch_make_none();")
    of vkString:
      # Escape string properly
      let escaped = constant.sval.multiReplace([("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\t", "\\t")])
      gen.emit(&"etch_constants[{i}] = etch_make_string(\"{escaped}\");")
    else:
      gen.emit(&"// TODO: Unsupported constant type: {constant.kind}")
      gen.emit(&"etch_constants[{i}] = etch_make_nil();")

  gen.decIndent()
  gen.emit("}")

proc emitCFFIDeclarations(gen: var CGenerator) =
  ## Emit forward declarations for CFFI functions
  if gen.program.cffiInfo.len == 0:
    return

  gen.emit("\n// CFFI forward declarations")
  for funcName, info in gen.program.cffiInfo:
    # Generate parameter list
    var params = ""
    if info.paramTypes.len > 0:
      for i, paramType in info.paramTypes:
        if i > 0:
          params &= ", "
        # Map TypeKind strings to C types
        case paramType
        of "tkBool":
          params &= "bool"
        of "tkChar":
          params &= "char"
        of "tkInt":
          params &= "int64_t"
        of "tkFloat":
          params &= "double"
        else:
          params &= "void*"  # Default to void* for unknown types
    else:
      params = "void"

    # Map return type
    let returnType = case info.returnType
    of "tkVoid": "void"
    of "tkBool": "bool"
    of "tkChar": "char"
    of "tkInt": "int64_t"
    of "tkFloat": "double"
    else: "void*"

    gen.emit(&"extern {returnType} {info.symbol}({params});")

proc emitInstruction(gen: var CGenerator, instr: RegInstruction, pc: int) =
  ## Emit C code for a single RegVM instruction
  let a = instr.a

  # Debug output for opType 1 instructions
  when defined(debug):
    if instr.opType == 1:
      echo &"DEBUG PC {pc}: {instr.op} with opType 1"

  case instr.op
  of ropNoOp:
    gen.emit(&"// NoOp")

  of ropLoadK:
    # LoadK can be either ABx (constant pool index) or AsBx (immediate value)
    if instr.opType == 1:  # ABx format - constant pool index
      let bx = instr.bx
      gen.emit(&"r[{a}] = etch_constants[{bx}];  // LoadK from constant pool")
    elif instr.opType == 2:  # AsBx format - immediate value
      let sbx = instr.sbx
      gen.emit(&"r[{a}] = etch_make_int({sbx});  // LoadK immediate")

  of ropMove:
    if instr.opType == 0:
      let b = instr.b
      gen.emit(&"r[{a}] = r[{b}];  // Move")
    else:
      gen.emit(&"// TODO: Move with opType {instr.opType}")

  of ropLoadBool:
    if instr.opType == 0:
      let b = instr.b
      let c = instr.c
      gen.emit(&"r[{a}] = etch_make_bool({($bool(b)).toLowerAscii()});  // LoadBool")
      if c != 0:
        gen.emit(&"goto L{pc + 2};  // Skip next instruction")
    else:
      gen.emit(&"// TODO: LoadBool with opType {instr.opType}")

  of ropLoadNil:
    if instr.opType == 0:
      let b = instr.b
      gen.emit(&"// LoadNil: R[{a}]..R[{b}] = nil")
      gen.emit(&"for (int i = {a}; i <= {b}; i++) r[i] = etch_make_nil();")
    else:
      gen.emit(&"r[{a}] = etch_make_nil();  // LoadNil (single)")

  of ropLoadNone:
    gen.emit(&"r[{a}] = etch_make_none();  // LoadNone")

  of ropAdd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"// Add (with string/array concat support)")
    gen.emit(&"if (r[{b}].kind == VK_STRING && r[{c}].kind == VK_STRING) {{")
    gen.emit(&"  r[{a}] = etch_concat_strings(r[{b}], r[{c}]);")
    gen.emit(&"}} else if (r[{b}].kind == VK_ARRAY && r[{c}].kind == VK_ARRAY) {{")
    gen.emit(&"  r[{a}] = etch_concat_arrays(r[{b}], r[{c}]);")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_add(r[{b}], r[{c}]);")
    gen.emit(&"}}")

  of ropAddI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      # Reinterpret unsigned 8-bit value as signed using two's complement
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
      gen.emit(&"r[{a}] = etch_add(r[{regIdx}], etch_make_int({imm}));  // AddI")
    else:
      gen.emit(&"// TODO: AddI with opType {instr.opType}")

  of ropSub:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_sub(r[{b}], r[{c}]);  // Sub")

  of ropSubI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      # Reinterpret unsigned 8-bit value as signed using two's complement
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
      gen.emit(&"r[{a}] = etch_sub(r[{regIdx}], etch_make_int({imm}));  // SubI")
    else:
      gen.emit(&"// TODO: SubI with opType {instr.opType}")

  of ropMul:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mul(r[{b}], r[{c}]);  // Mul")

  of ropMulI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      # Reinterpret unsigned 8-bit value as signed using two's complement
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
      gen.emit(&"r[{a}] = etch_mul(r[{regIdx}], etch_make_int({imm}));  // MulI")
    else:
      gen.emit(&"// TODO: MulI with opType {instr.opType}")

  of ropDiv:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_div(r[{b}], r[{c}]);  // Div")

  of ropDivI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      # Reinterpret unsigned 8-bit value as signed using two's complement
      let imm8 = uint8((instr.bx shr 8) and 0xFF)
      let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
      gen.emit(&"r[{a}] = etch_div(r[{regIdx}], etch_make_int({imm}));  // MulI")
    else:
      gen.emit(&"// TODO: MulI with opType {instr.opType}")

  of ropMod:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mod(r[{b}], r[{c}]);  // Mod")

  of ropPow:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_pow(r[{b}], r[{c}]);  // Pow")

  of ropUnm:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_unm(r[{b}]);  // Unm")

  of ropEq:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_eq" else: "!etch_eq"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Eq")

  of ropLt:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_lt" else: "!etch_lt"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Lt")

  of ropLe:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_le" else: "!etch_le"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Le")

  of ropEqStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_eq(r[{b}], r[{c}]));  // EqStore")

  of ropLtStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_lt(r[{b}], r[{c}]));  // LtStore")

  of ropLeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_le(r[{b}], r[{c}]));  // LeStore")

  of ropNeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_eq(r[{b}], r[{c}]));  // NeStore")

  of ropNot:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_not(r[{b}]);  // Not")

  of ropAnd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_and(r[{b}], r[{c}]);  // And")

  of ropOr:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_or(r[{b}], r[{c}]);  // Or")

  of ropJmp:
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"goto L{target};  // Jmp")

  of ropTest:
    let c = instr.c
    if c == 1:
      # Skip if value is nil or (bool and false)
      gen.emit(&"if (r[{a}].kind == VK_NIL || (r[{a}].kind == VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")
    else:
      # Skip if value is NOT nil and NOT (bool and false)
      gen.emit(&"if (r[{a}].kind != VK_NIL && !(r[{a}].kind == VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")

  of ropNewArray:
    if instr.opType == 1:
      let size = instr.bx
      gen.emit(&"r[{a}] = etch_make_array({size});  // NewArray")
      gen.emit(&"r[{a}].aval.len = {size};  // Set array length")
      gen.emit(&"for (size_t i = 0; i < {size}; i++) r[{a}].aval.data[i] = etch_make_nil();")
    else:
      gen.emit(&"// TODO: NewArray with opType {instr.opType}")

  of ropGetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_index(r[{b}], r[{c}]);  // GetIndex")

  of ropSetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_index(&r[{a}], r[{b}], r[{c}]);  // SetIndex")

  of ropGetIndexI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let idx = instr.bx shr 8
      gen.emit(&"r[{a}] = etch_get_index(r[{regIdx}], etch_make_int({idx}));  // GetIndexI")
    else:
      gen.emit(&"// TODO: GetIndexI with opType {instr.opType}")

  of ropSetIndexI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let idx = instr.bx shr 8
      gen.emit(&"etch_set_index(&r[{a}], etch_make_int({idx}), r[{regIdx}]);  // SetIndexI")
    else:
      gen.emit(&"// TODO: SetIndexI with opType {instr.opType}")

  of ropLen:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_get_length(r[{b}]);  // Len")

  of ropWrapSome:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_some(r[{b}]);  // WrapSome")

  of ropWrapOk:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_ok(r[{b}]);  // WrapOk")

  of ropWrapErr:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_err(r[{b}]);  // WrapErr")

  of ropReturn:
    # ropReturn: A = number of results, B = starting register
    # If A is 0, return nil; if A is 1, return r[B]
    if instr.opType == 0:  # ABC format
      let numResults = a
      let retReg = instr.b
      if numResults == 0:
        gen.emit(&"return etch_make_nil();  // Return (no value)")
      elif numResults == 1:
        gen.emit(&"return r[{retReg}];  // Return")
      else:
        gen.emit(&"// TODO: Multiple return values not yet supported")
        gen.emit(&"return r[{retReg}];  // Return first value")
    else:
      gen.emit(&"return etch_make_nil();  // Return (no value)")

  of ropExecDefers:
    gen.emit(&"// ExecDefers: execute all deferred blocks in LIFO order")
    gen.emit(&"if (__etch_defer_count > 0) {{")
    gen.emit(&"  __defer_return_pc = {pc};  // Save return point")
    gen.emit(&"  int __etch_defer_pc = __etch_defer_stack[--__etch_defer_count];  // Pop defer")
    gen.emit(&"  switch (__etch_defer_pc) {{")
    # Generate case statements for all defer targets
    for target in gen.deferTargets:
      gen.emit(&"    case {target}: goto L{target};")
    gen.emit(&"  }}")
    gen.emit(&"}}")

  of ropPushDefer:
    if instr.opType == 2:  # AsBx format - signed offset
      let offset = instr.sbx
      let targetPC = pc + offset
      gen.emit(&"// PushDefer: register defer block at L{targetPC}")
      gen.emit(&"__etch_defer_stack[__etch_defer_count++] = {targetPC};")

  of ropDeferEnd:
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
    gen.emit(&"  switch (__defer_return_pc) {{")
    # Generate cases for all ExecDefers locations (return points)
    for returnPC in gen.execDefersLocations:
      gen.emit(&"    case {returnPC}: goto L{returnPC};")
    gen.emit(&"    default: break;  // Should not reach here")
    gen.emit(&"  }}")
    gen.emit(&"}}")

  of ropSlice:
    let b = instr.b
    let c = instr.c
    # R[A] = R[B][R[C]:R[C+1]] - start index in R[C], end index in R[C+1]
    gen.emit(&"// Slice: R[{a}] = R[{b}][R[{c}]:R[{c+1}]]")
    gen.emit(&"r[{a}] = etch_slice_op(r[{b}], r[{c}], r[{c + 1}]);  // Slice")

  of ropNewTable:
    gen.emit(&"r[{a}] = etch_make_table();  // NewTable")

  of ropGetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_field(r[{b}], etch_constants[{c}].sval);  // GetField")

  of ropSetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_field(&r[{b}], etch_constants[{c}].sval, r[{a}]);  // SetField")

  of ropNewRef:
    # Allocate heap object: C=1 for scalar, C=0 for table
    # B contains encoded destructor index (funcIdx+1, 0 if no destructor)
    if instr.opType == 0:
      let b = instr.b
      let c = instr.c

      # Decode destructor function index (B is encoded as funcIdx+1, 0 means no destructor)
      let destructorEncoded = b
      var destructorPtr = "NULL"
      if destructorEncoded > 0:
        let funcIdx = int(destructorEncoded - 1)
        if funcIdx < gen.program.functionTable.len:
          let funcName = sanitizeFunctionName(gen.program.functionTable[funcIdx])
          destructorPtr = &"func_{funcName}"

      if c == 1:
        # Scalar allocation - note: for scalars, destructor is called on the scalar value itself
        # The destructor function index would be in a different instruction/context for scalars
        # For now, scalars typically don't have destructors in the current design
        gen.emit(&"// NewRef: allocate scalar heap object from R[{b}] (no destructor for scalars)")
        gen.emit(&"r[{a}] = etch_make_ref(etch_heap_alloc_scalar(r[{b}], NULL));")
      else:
        # Table allocation - B contains the destructor function index
        gen.emit(&"// NewRef: allocate table heap object with destructor={destructorPtr}")
        gen.emit(&"r[{a}] = etch_make_ref(etch_heap_alloc_table({destructorPtr}));")
    else:
      gen.emit(&"// TODO: NewRef with opType {instr.opType}")

  of ropIncRef:
    # Increment reference count of R[A]
    gen.emit(&"// IncRef: increment ref count for R[{a}]")
    gen.emit(&"if (r[{a}].kind == VK_REF) {{")
    gen.emit(&"  etch_heap_inc_ref(r[{a}].refId);")
    gen.emit(&"}}")

  of ropDecRef:
    # Decrement reference count of R[A]
    gen.emit(&"// DecRef: decrement ref count for R[{a}]")
    gen.emit(&"if (r[{a}].kind == VK_REF) {{")
    gen.emit(&"  etch_heap_dec_ref(r[{a}].refId);")
    gen.emit(&"}}")

  of ropNewWeak:
    # Create weak reference to R[B]
    let b = instr.b
    gen.emit(&"// NewWeak: create weak ref to R[{b}]")
    gen.emit(&"if (r[{b}].kind == VK_REF) {{")
    gen.emit(&"  r[{a}] = etch_make_weak(etch_heap_alloc_weak(r[{b}].refId));")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of ropWeakToStrong:
    # Promote weak ref R[B] to strong ref in R[A]
    let b = instr.b
    gen.emit(&"// WeakToStrong: promote weak R[{b}] to strong R[{a}]")
    gen.emit(&"if (r[{b}].kind == VK_WEAK) {{")
    gen.emit(&"  int strongId = etch_heap_weak_to_strong(r[{b}].weakId);")
    gen.emit(&"  if (strongId > 0) {{")
    gen.emit(&"    r[{a}] = etch_make_ref(strongId);")
    gen.emit(&"  }} else {{")
    gen.emit(&"    r[{a}] = etch_make_nil();")
    gen.emit(&"  }}")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of ropCheckCycles:
    # Trigger cycle detection
    gen.emit(&"// CheckCycles: detect reference cycles")
    gen.emit(&"etch_heap_detect_cycles();")

  of ropCast:
    let b = instr.b
    let targetKind = instr.c  # VKind enum value
    gen.emit(&"r[{a}] = etch_cast_value(r[{b}], {targetKind});  // Cast")

  of ropTestTag:
    let tag = instr.b
    let vkind = VKind(tag)
    case vkind
    of vkNil:
      gen.emit(&"if (r[{a}].kind == VK_NIL) goto L{pc + 2};  // TestTag Nil - skip Jmp if match")
    of vkBool:
      gen.emit(&"if (r[{a}].kind == VK_BOOL) goto L{pc + 2};  // TestTag Bool - skip Jmp if match")
    of vkChar:
      gen.emit(&"if (r[{a}].kind == VK_CHAR) goto L{pc + 2};  // TestTag Char - skip Jmp if match")
    of vkInt:
      gen.emit(&"if (r[{a}].kind == VK_INT) goto L{pc + 2};  // TestTag Int - skip Jmp if match")
    of vkFloat:
      gen.emit(&"if (r[{a}].kind == VK_FLOAT) goto L{pc + 2};  // TestTag Float - skip Jmp if match")
    of vkString:
      gen.emit(&"if (r[{a}].kind == VK_STRING) goto L{pc + 2};  // TestTag String - skip Jmp if match")
    of vkArray:
      gen.emit(&"if (r[{a}].kind == VK_ARRAY) goto L{pc + 2};  // TestTag Array - skip Jmp if match")
    of vkTable:
      gen.emit(&"if (r[{a}].kind == VK_TABLE) goto L{pc + 2};  // TestTag Table - skip Jmp if match")
    of vkSome:
      gen.emit(&"if (r[{a}].kind == VK_SOME) goto L{pc + 2};  // TestTag Some - skip Jmp if match")
    of vkNone:
      gen.emit(&"if (r[{a}].kind == VK_NONE) goto L{pc + 2};  // TestTag None - skip Jmp if match")
    of vkOk:
      gen.emit(&"if (r[{a}].kind == VK_OK) goto L{pc + 2};  // TestTag Ok - skip Jmp if match")
    of vkErr:
      gen.emit(&"if (r[{a}].kind == VK_ERR) goto L{pc + 2};  // TestTag Error - skip Jmp if match")
    of vkRef:
      gen.emit(&"if (r[{a}].kind == VK_REF) goto L{pc + 2};  // TestTag Ref - skip Jmp if match")
    of vkWeak:
      gen.emit(&"if (r[{a}].kind == VK_WEAK) goto L{pc + 2};  // TestTag Weak - skip Jmp if match")

  of ropUnwrapOption:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == VK_SOME) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapOption")

  of ropUnwrapResult:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == VK_OK || r[{b}].kind == VK_ERR) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapResult (Ok or Error)")

  of ropIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_in(r[{b}], r[{c}]));  // In")

  of ropNotIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_in(r[{b}], r[{c}]));  // NotIn")

  of ropForPrep:
    # For loop preparation: set up loop variables
    # A = iterator variable, sBx = jump offset to loop end
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForPrep: setup for loop")
    gen.emit(&"if (r[{a}].kind == VK_INT && r[{a + 1}].kind == VK_INT) {{")
    gen.emit(&"  if (r[{a}].ival >= r[{a + 1}].ival) goto L{target};  // Empty range")
    gen.emit(&"}}")

  of ropForLoop:
    # For loop increment and test: increment iterator and check if done
    # A = iterator variable, sBx = jump offset back to loop start
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForLoop: increment and test")
    gen.emit(&"r[{a}].ival++;  // Increment iterator")
    gen.emit(&"if (r[{a}].ival < r[{a + 1}].ival) goto L{target};  // Continue loop")

  of ropCall:
    # Function call: A = result register, funcIdx = function index, numArgs = arg count
    if instr.opType == 4:
      let resultReg = a
      let funcIdx = instr.funcIdx
      let numArgs = instr.numArgs

      # Get function name from function table
      if int(funcIdx) < gen.program.functionTable.len:
        let funcName = gen.program.functionTable[int(funcIdx)]

        # Handle builtin functions
        case funcName
        of "print":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"etch_print_value(r[{argReg}]);  // Call print")
            gen.emit("printf(\"\\n\");")
          else:
            gen.emit(&"// TODO: print with {numArgs} args")

        of "seed":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_INT) {{")
            gen.emit(&"  etch_srand((uint64_t)r[{argReg}].ival);")
            gen.emit(&"}}")

        of "rand":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t maxInt = r[{argReg}].ival;")
            gen.emit(&"  if (maxInt > 0) {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)maxInt));")
            gen.emit(&"  }} else {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"  }}")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"}}")
          elif numArgs == 2:
            let arg1Reg = resultReg + 1
            let arg2Reg = resultReg + 2
            gen.emit(&"if (r[{arg1Reg}].kind == VK_INT && r[{arg2Reg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t minInt = r[{arg1Reg}].ival;")
            gen.emit(&"  int64_t maxInt = r[{arg2Reg}].ival;")
            gen.emit(&"  int64_t range = maxInt - minInt;")
            gen.emit(&"  if (range > 0) {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)range) + minInt);")
            gen.emit(&"  }} else {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int(minInt);")
            gen.emit(&"  }}")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"}}")

        of "toString":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_string(etch_to_string(r[{argReg}]));  // toString")

        of "readFile":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_read_file(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_string(\"\");")
            gen.emit(&"}}")

        of "parseInt":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_int(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "parseFloat":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_float(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "parseBool":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_bool(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "isSome":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_SOME);  // isSome")

        of "isNone":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_NONE);  // isNone")

        of "isOk":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_OK);  // isOk")

        of "isErr":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_ERR);  // isErr")

        of "arrayNew":
          if numArgs == 2:
            let sizeReg = resultReg + 1
            let defaultReg = resultReg + 2
            gen.emit(&"if (r[{sizeReg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t size = r[{sizeReg}].ival;")
            gen.emit(&"  EtchV arr = etch_make_array(size);")
            gen.emit(&"  for (int64_t i = 0; i < size; i++) {{")
            gen.emit(&"    arr.aval.data[i] = r[{defaultReg}];")
            gen.emit(&"  }}")
            gen.emit(&"  arr.aval.len = size;")
            gen.emit(&"  r[{resultReg}] = arr;")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_array(0);")
            gen.emit(&"}}")

        of "new":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = r[{argReg}];  // new (pass through)")
          else:
            gen.emit(&"r[{resultReg}] = etch_make_nil();")

        of "deref":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"// deref: dereference heap object")
            gen.emit(&"if (r[{argReg}].kind == VK_REF) {{")
            gen.emit(&"  int objId = r[{argReg}].refId;")
            gen.emit(&"  if (objId > 0 && objId < etch_next_heap_id) {{")
            gen.emit(&"    if (etch_heap[objId].kind == HOK_SCALAR) {{")
            gen.emit(&"      r[{resultReg}] = etch_heap[objId].scalarValue;")
            gen.emit(&"    }} else if (etch_heap[objId].kind == HOK_TABLE) {{")
            gen.emit(&"      // For table refs, keep as ref (table lives in heap)")
            gen.emit(&"      r[{resultReg}] = r[{argReg}];")
            gen.emit(&"    }} else {{")
            gen.emit(&"      r[{resultReg}] = etch_make_nil();")
            gen.emit(&"    }}")
            gen.emit(&"  }} else {{")
            gen.emit(&"    r[{resultReg}] = etch_make_nil();")
            gen.emit(&"  }}")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_nil();")
            gen.emit(&"}}")
          else:
            gen.emit(&"r[{resultReg}] = etch_make_nil();")

        else:
          # Check if this is a CFFI function
          if gen.program.cffiInfo.hasKey(funcName):
            let cffiInfo = gen.program.cffiInfo[funcName]
            let symbol = cffiInfo.symbol

            # Build argument list - convert from EtchV to C types based on signature
            var args = ""
            if numArgs > 0:
              for i in 0 ..< int(numArgs):
                if i > 0:
                  args &= ", "
                let argReg = resultReg.int + 1 + i
                # Convert based on parameter type
                if i < cffiInfo.paramTypes.len:
                  let paramType = cffiInfo.paramTypes[i]
                  case paramType
                  of "tkFloat":
                    args &= &"r[{argReg}].fval"
                  of "tkInt":
                    args &= &"r[{argReg}].ival"
                  of "tkChar":
                    args &= &"r[{argReg}].cval"
                  of "tkBool":
                    args &= &"r[{argReg}].bval"
                  else:
                    args &= &"r[{argReg}]"  # Pass whole EtchV struct
                else:
                  args &= &"r[{argReg}].fval"  # Default to float

            # Generate direct C function call with return type conversion
            gen.emit(&"// CFFI call to {cffiInfo.library}.{symbol}")
            case cffiInfo.returnType
            of "tkFloat":
              gen.emit(&"r[{resultReg}] = etch_make_float({symbol}({args}));")
            of "tkInt":
              gen.emit(&"r[{resultReg}] = etch_make_int({symbol}({args}));")
            of "tkBool":
              gen.emit(&"r[{resultReg}] = etch_make_bool({symbol}({args}));")
            of "tkChar":
              gen.emit(&"r[{resultReg}] = etch_make_char({symbol}({args}));")
            of "tkVoid":
              gen.emit(&"{symbol}({args});")
              gen.emit(&"r[{resultReg}] = etch_make_nil();")
            else:
              gen.emit(&"r[{resultReg}] = etch_make_float({symbol}({args}));")  # Default to float
          # User-defined function call
          elif gen.program.functions.hasKey(funcName):
            let funcInfo = gen.program.functions[funcName]
            let safeName = sanitizeFunctionName(funcName)

            # Build argument list
            var args = ""
            if funcInfo.numParams > 0:
              for i in 0 ..< funcInfo.numParams:
                if i > 0:
                  args &= ", "
                let argReg = resultReg.int + 1 + i
                args &= &"r[{argReg}]"

            gen.emit(&"r[{resultReg}] = func_{safeName}({args});  // Call user function")
          else:
            gen.emit(&"// TODO: Call to unknown function '{funcName}'")
      else:
        gen.emit(&"// TODO: Invalid function index {funcIdx}")
    else:
      gen.emit(&"// TODO: ropCall with unexpected opType {instr.opType}")

  of ropGetGlobal:
    if instr.opType == 1:
      let bx = instr.bx
      gen.emit(&"// GetGlobal: R[{a}] = globals[K[{bx}]]")
      gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
      gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
      gen.emit(&"  r[{a}] = etch_get_global(name);")
      gen.emit(&"}} else {{")
      gen.emit(&"  r[{a}] = etch_make_nil();")
      gen.emit(&"}}")
    else:
      gen.emit(&"// TODO: GetGlobal with opType {instr.opType}")

  of ropSetGlobal:
    if instr.opType == 1:
      let bx = instr.bx
      gen.emit(&"// SetGlobal: globals[K[{bx}]] = R[{a}]")
      gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
      gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
      gen.emit(&"  etch_set_global(name, r[{a}]);")
      gen.emit(&"}}")
    else:
      gen.emit(&"// TODO: SetGlobal with opType {instr.opType}")

  of ropInitGlobal:
    if instr.opType == 1:
      let bx = instr.bx
      gen.emit(&"// InitGlobal: globals[K[{bx}]] = R[{a}] (only if not already set)")
      gen.emit(&"if ({bx} < ETCH_CONST_POOL_SIZE) {{")
      gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
      gen.emit(&"  if (!etch_has_global(name)) {{")
      gen.emit(&"    etch_set_global(name, r[{a}]);")
      gen.emit(&"  }}")
      gen.emit(&"}}")
    else:
      gen.emit(&"// TODO: InitGlobal with opType {instr.opType}")

  of ropTailCall, ropTestSet:
    gen.emit(&"// TODO: Implement {instr.op}")

  of ropAddAdd:
    # R[A] = R[B] + R[C] + R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"// AddAdd: R[{a}] = R[{bReg}] + R[{cReg}] + R[{dReg}]")
    # Try string concatenation first
    gen.emit(&"if (r[{bReg}].kind == VK_STRING && r[{cReg}].kind == VK_STRING && r[{dReg}].kind == VK_STRING) {{")
    gen.emit(&"  size_t len1 = strlen(r[{bReg}].sval);")
    gen.emit(&"  size_t len2 = strlen(r[{cReg}].sval);")
    gen.emit(&"  size_t len3 = strlen(r[{dReg}].sval);")
    gen.emit(&"  char* result = malloc(len1 + len2 + len3 + 1);")
    gen.emit(&"  strcpy(result, r[{bReg}].sval);")
    gen.emit(&"  strcat(result, r[{cReg}].sval);")
    gen.emit(&"  strcat(result, r[{dReg}].sval);")
    gen.emit(&"  r[{a}] = etch_make_string(result);")
    # Integer addition
    gen.emit(&"}} else if (r[{bReg}].kind == VK_INT && r[{cReg}].kind == VK_INT && r[{dReg}].kind == VK_INT) {{")
    gen.emit(&"  r[{a}] = etch_make_int(r[{bReg}].ival + r[{cReg}].ival + r[{dReg}].ival);")
    # Float addition
    gen.emit(&"}} else if ((r[{bReg}].kind == VK_INT || r[{bReg}].kind == VK_FLOAT) &&")
    gen.emit(&"           (r[{cReg}].kind == VK_INT || r[{cReg}].kind == VK_FLOAT) &&")
    gen.emit(&"           (r[{dReg}].kind == VK_INT || r[{dReg}].kind == VK_FLOAT)) {{")
    gen.emit(&"  double bv = (r[{bReg}].kind == VK_INT) ? (double)r[{bReg}].ival : r[{bReg}].fval;")
    gen.emit(&"  double cv = (r[{cReg}].kind == VK_INT) ? (double)r[{cReg}].ival : r[{cReg}].fval;")
    gen.emit(&"  double dv = (r[{dReg}].kind == VK_INT) ? (double)r[{dReg}].ival : r[{dReg}].fval;")
    gen.emit(&"  r[{a}] = etch_make_float(bv + cv + dv);")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of ropMulAdd:
    # R[A] = R[B] * R[C] + R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"// MulAdd: R[{a}] = R[{bReg}] * R[{cReg}] + R[{dReg}]")
    # Integer mul-add
    gen.emit(&"if (r[{bReg}].kind == VK_INT && r[{cReg}].kind == VK_INT && r[{dReg}].kind == VK_INT) {{")
    gen.emit(&"  r[{a}] = etch_make_int(r[{bReg}].ival * r[{cReg}].ival + r[{dReg}].ival);")
    # Float mul-add
    gen.emit(&"}} else if ((r[{bReg}].kind == VK_INT || r[{bReg}].kind == VK_FLOAT) &&")
    gen.emit(&"           (r[{cReg}].kind == VK_INT || r[{cReg}].kind == VK_FLOAT) &&")
    gen.emit(&"           (r[{dReg}].kind == VK_INT || r[{dReg}].kind == VK_FLOAT)) {{")
    gen.emit(&"  double bv = (r[{bReg}].kind == VK_INT) ? (double)r[{bReg}].ival : r[{bReg}].fval;")
    gen.emit(&"  double cv = (r[{cReg}].kind == VK_INT) ? (double)r[{cReg}].ival : r[{cReg}].fval;")
    gen.emit(&"  double dv = (r[{dReg}].kind == VK_INT) ? (double)r[{dReg}].ival : r[{dReg}].fval;")
    gen.emit(&"  r[{a}] = etch_make_float(bv * cv + dv);")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of ropCmpJmp, ropIncTest, ropLoadAddStore, ropGetAddSet:
    gen.emit(&"// TODO: Fused instruction {instr.op}")

  else:
    gen.emit(&"// TODO: Implement {instr.op}")

proc emitFunction(gen: var CGenerator, funcName: string, info: FunctionInfo) =
  ## Emit a C function from RegVM bytecode
  let safeName = sanitizeFunctionName(funcName)
  gen.emit(&"\n// Function: {funcName}")

  # Check if function uses defer blocks
  var hasDefer = false
  var deferTargets: seq[int] = @[]
  var execDefersLocations: seq[int] = @[]
  for pc in info.startPos ..< info.endPos:
    if pc < gen.program.instructions.len:
      let instr = gen.program.instructions[pc]
      if instr.op == ropPushDefer:
        hasDefer = true
        if instr.opType == 2:
          let offset = instr.sbx
          let targetPC = pc + offset
          if targetPC notin deferTargets:
            deferTargets.add(targetPC)
      elif instr.op == ropExecDefers:
        # Track ExecDefers locations for defer jumps (but don't set hasDefer)
        if pc notin execDefersLocations:
          execDefersLocations.add(pc)

  # Generate parameter list
  var params = ""
  if info.numParams > 0:
    for i in 0 ..< info.numParams:
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
  gen.emit(&"EtchV r[{numRegisters}];")
  gen.emit("// Initialize registers to nil")
  gen.emit(&"for (int i = 0; i < {numRegisters}; i++) r[i] = etch_make_nil();")

  # Defer stack for defer blocks (only if function uses defer)
  if hasDefer:
    gen.emit("")
    gen.emit("// Defer stack")
    gen.emit("int __etch_defer_stack[32];  // Stack of PC locations for defer blocks")
    gen.emit("int __etch_defer_count = 0;")
    gen.emit("int __defer_return_pc = -1;")

  # Copy parameters to registers
  if info.numParams > 0:
    gen.emit("")
    gen.emit("// Copy parameters to registers")
    for i in 0 ..< info.numParams:
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
        gen.emitInstruction(gen.program.instructions[pc], pc)
      except FieldDefect as e:
        let instr = gen.program.instructions[pc]
        echo &"ERROR at PC {pc}: {instr.op} (opType={instr.opType}): {e.msg}"
        raise

  # Default return
  gen.emit(&"L{info.endPos}:")
  gen.emit("return etch_make_nil();")

  gen.decIndent()
  gen.emit("}")

proc emitMainWrapper(gen: var CGenerator) =
  ## Emit the main function wrapper
  gen.emit("\nint main(int argc, char** argv) {")
  gen.incIndent()
  gen.emit("etch_init_constants();")

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
      gen.emit("if (result.kind == VK_INT) {")
      gen.emit("  return (int)result.ival;")
      gen.emit("}")
    else:
      gen.emit("printf(\"No main function found\\n\");")

  # Run final cycle detection before exit
  gen.emit("")
  gen.emit("// Run cycle detection before exit")
  gen.emit("etch_heap_detect_cycles();")
  gen.emit("")
  gen.emit("return 0;")
  gen.decIndent()
  gen.emit("}")

proc generateCCode*(program: RegBytecodeProgram): string =
  ## Main entry point: generate complete C code from RegVM bytecode
  var gen = newCGenerator(program)

  # Emit runtime
  gen.emitCRuntime()

  # Emit constant pool
  gen.emitConstantPool()

  # Emit CFFI forward declarations
  gen.emitCFFIDeclarations()

  # Emit forward declarations for all functions
  gen.emit("\n// Forward declarations")
  for funcName, info in program.functions:
    let safeName = sanitizeFunctionName(funcName)
    var params = ""
    if info.numParams > 0:
      for i in 0 ..< info.numParams:
        if i > 0:
          params &= ", "
        params &= &"EtchV p{i}"
    else:
      params = "void"
    gen.emit(&"EtchV func_{safeName}({params});")

  # Emit all functions
  for funcName, info in program.functions:
    gen.emitFunction(funcName, info)

  # Emit main wrapper
  gen.emitMainWrapper()

  return gen.output
