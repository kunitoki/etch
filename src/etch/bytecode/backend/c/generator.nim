# generator.nim
# C backend generator for Etch Register VM bytecode

import std/[tables, strformat, strutils]
import ../../../common/[constants, builtins]
import ../../../core/vm_types


type
  CGenerator* = object
    output: string
    indent: int
    labelCounter: int
    program: BytecodeProgram
    deferTargets: seq[int]  # Target PCs for defer blocks in current function
    execDefersLocations: seq[int]  # PCs where ExecDefers is called
    currentFuncNumRegisters: int  # Number of registers in current function


proc emitInstruction(gen: var CGenerator, instr: Instruction, debugInfo: DebugInfo, pc: int)


proc newCGenerator(program: BytecodeProgram): CGenerator =
  CGenerator(
    output: "",
    indent: 0,
    labelCounter: 0,
    program: program,
    deferTargets: @[],
    execDefersLocations: @[],
    currentFuncNumRegisters: 0)


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


proc vkindToCKind(targetKind: VKind): string =
  result = case targetKind:
    of vkInt: "ETCH_VK_INT"
    of vkFloat: "ETCH_VK_FLOAT"
    of vkBool: "ETCH_VK_BOOL"
    of vkChar: "ETCH_VK_CHAR"
    of vkNil: "ETCH_VK_NIL"
    of vkString: "ETCH_VK_STRING"
    of vkArray: "ETCH_VK_ARRAY"
    of vkTable: "ETCH_VK_TABLE"
    of vkEnum: "ETCH_VK_ENUM"
    of vkSome: "ETCH_VK_SOME"
    of vkNone: "ETCH_VK_NONE"
    of vkOk: "ETCH_VK_OK"
    of vkErr: "ETCH_VK_ERR"
    of vkRef: "ETCH_VK_REF"
    of vkClosure: "ETCH_VK_CLOSURE"
    of vkWeak: "ETCH_VK_WEAK"
    of vkCoroutine: "ETCH_VK_COROUTINE"
    of vkTypeDesc: "ETCH_VK_TYPEDESC"
    else: "ETCH_VK_INT"  # Default fallback


proc escapeCString(s: string): string =
  s.multiReplace([
    ("\\", "\\\\"),
    ("\"", "\\\""),
    ("\n", "\\n"),
    ("\t", "\\t"),
    ("\r", "\\r")
  ])


proc convertToCType(etchType: string): string =
    result = case etchType
    of "tkVoid": "void"
    of "tkBool": "bool"
    of "tkChar": "char"
    of "tkInt": "int64_t"
    of "tkFloat": "double"
    else: "void*"


include emitters/arithmetic
include emitters/call
include emitters/cffi
include emitters/constant
include emitters/coroutine
include emitters/cruntime
include emitters/defers
include emitters/function
include emitters/globals
include emitters/main
include emitters/refs
include emitters/testtag


proc emitInstruction(gen: var CGenerator, instr: Instruction, debugInfo: DebugInfo, pc: int) =
  ## Emit C code for a single VirtualMachine instruction
  let a = instr.a

  when defined(debug):
    gen.emit(&"#line {debugInfo.line} \"{debugInfo.sourceFile}\"")

  case instr.op
  of opNoOp:
    gen.emit(&"// NoOp")

  of opLoadK:
    # LoadK can be either ABx (constant pool index) or AsBx (immediate value)
    if instr.opType == ifmtABx:
      let bx = instr.bx
      gen.emit(&"r[{a}] = etch_constants[{bx}];  // LoadK from constant pool")
    elif instr.opType == ifmtAsBx:
      let sbx = instr.sbx
      gen.emit(&"r[{a}] = etch_make_int({sbx});  // LoadK immediate")

  of opMove:
    doAssert instr.opType == ifmtABC
    let b = instr.b
    gen.emit(&"r[{a}] = r[{b}];  // Move")

  of opLoadBool:
    doAssert instr.opType == ifmtABC
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool({($bool(b)).toLowerAscii()});  // LoadBool")
    if c != 0:
      gen.emit(&"goto L{pc + 2};  // Skip next instruction")

  of opLoadNil:
    doAssert instr.opType == ifmtABC
    let b = instr.b
    gen.emit(&"// LoadNil: R[{a}]..R[{b}] = nil")
    gen.emit(&"for (int i = {a}; i <= {b}; i++) r[i] = etch_make_nil();")

  of opLoadNone:
    gen.emit(&"r[{a}] = etch_make_none();  // LoadNone")

  of opAdd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"// Add (with string/array concat support)")
    gen.emitBinaryAddExpr(&"r[{a}]", &"r[{b}]", &"r[{c}]")

  of opAddI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
    gen.emit(&"r[{a}] = etch_add(r[{regIdx}], etch_make_int({imm}));  // AddI")

  of opSub:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_sub(r[{b}], r[{c}]);  // Sub")

  of opSubI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
    gen.emit(&"r[{a}] = etch_sub(r[{regIdx}], etch_make_int({imm}));  // SubI")

  of opMul:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mul(r[{b}], r[{c}]);  // Mul")

  of opMulI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
    gen.emit(&"r[{a}] = etch_mul(r[{regIdx}], etch_make_int({imm}));  // MulI")

  of opDiv:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_div(r[{b}], r[{c}]);  // Div")

  of opDivI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
    gen.emit(&"r[{a}] = etch_div(r[{regIdx}], etch_make_int({imm}));  // DivI")

  of opMod:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mod(r[{b}], r[{c}]);  // Mod")

  of opModI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let imm = if imm8 < 128: int(imm8) else: int(imm8) - 256
    gen.emit(&"r[{a}] = etch_mod(r[{regIdx}], etch_make_int({imm}));  // ModI")

  of opAndI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let immBool = imm8 != 0
    gen.emit(&"r[{a}] = etch_make_bool((r[{regIdx}].kind == ETCH_VK_BOOL) ? (r[{regIdx}].bval && {immBool}) : false);  // AndI")

  of opOrI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let imm8 = uint8((instr.bx shr 8) and 0xFF)
    let immBool = imm8 != 0
    gen.emit(&"r[{a}] = etch_make_bool((r[{regIdx}].kind == ETCH_VK_BOOL) ? (r[{regIdx}].bval || {immBool}) : {immBool});  // OrI")

  # Type-specialized integer arithmetic (no runtime type checks)
  of opAddInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // AddInt (specialized)")
    gen.emit(&"r[{a}].ival = r[{b}].ival + r[{c}].ival;")

  of opSubInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // SubInt (specialized)")
    gen.emit(&"r[{a}].ival = r[{b}].ival - r[{c}].ival;")

  of opMulInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // MulInt (specialized)")
    gen.emit(&"r[{a}].ival = r[{b}].ival * r[{c}].ival;")

  of opDivInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // DivInt (specialized)")
    gen.emit(&"r[{a}].ival = r[{b}].ival / r[{c}].ival;")

  of opModInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // ModInt (specialized)")
    gen.emit(&"r[{a}].ival = r[{b}].ival % r[{c}].ival;")

  # Type-specialized float arithmetic (no runtime type checks)
  of opAddFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // AddFloat (specialized)")
    gen.emit(&"r[{a}].fval = r[{b}].fval + r[{c}].fval;")

  of opSubFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // SubFloat (specialized)")
    gen.emit(&"r[{a}].fval = r[{b}].fval - r[{c}].fval;")

  of opMulFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // MulFloat (specialized)")
    gen.emit(&"r[{a}].fval = r[{b}].fval * r[{c}].fval;")

  of opDivFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // DivFloat (specialized)")
    gen.emit(&"r[{a}].fval = r[{b}].fval / r[{c}].fval;")

  of opModFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // ModFloat (specialized)")
    gen.emit(&"r[{a}].fval = fmod(r[{b}].fval, r[{c}].fval);")

  of opPow:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_pow(r[{b}], r[{c}]);  // Pow")

  of opUnm:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_unm(r[{b}]);  // Unm")

  of opEq:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_eq" else: "!etch_eq"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Eq")

  of opLt:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_lt" else: "!etch_lt"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Lt")

  of opLtJmp:
    if instr.opType == ifmtAx:
      let b = uint8((instr.ax shr 16) and 0xFF)
      let c = uint8((instr.ax shr 24) and 0xFF)
      let offset = int(int16(instr.ax and 0xFFFF))
      let target = pc + 1 + offset
      let branchWhen = instr.a != 0
      if branchWhen:
        gen.emit(&"if (etch_lt(r[{b}], r[{c}])) goto L{target};  // LtJmp")
      else:
        gen.emit(&"if (!etch_lt(r[{b}], r[{c}])) goto L{target};  // LtJmp invert")
    else:
      let target = pc + 1 + instr.sbx
      gen.emit(&"if (etch_lt(r[{instr.b}], r[{instr.c}])) goto L{target};  // LtJmp")

  of opLe:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_le" else: "!etch_le"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Le")

  of opEqInt:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "==" else: "!="
    gen.emit(&"if (r[{b}].ival {cond} r[{c}].ival) goto L{pc + 2};  // EqInt")

  of opLtInt:
    let b = instr.b
    let c = instr.c
    let cond = if a == 0: "<" else: ">="
    gen.emit(&"if (r[{b}].ival {cond} r[{c}].ival) goto L{pc + 2};  // LtInt")

  of opLeInt:
    let b = instr.b
    let c = instr.c
    let cond = if a == 0: "<=" else: ">"
    gen.emit(&"if (r[{b}].ival {cond} r[{c}].ival) goto L{pc + 2};  // LeInt")

  of opEqFloat:
    let b = instr.b
    let c = instr.c
    let cond = if a == 0: "==" else: "!="
    gen.emit(&"if (r[{b}].fval {cond} r[{c}].fval) goto L{pc + 2};  // EqFloat")

  of opLtFloat:
    let b = instr.b
    let c = instr.c
    let cond = if a == 0: "<" else: ">="
    gen.emit(&"if (r[{b}].fval {cond} r[{c}].fval) goto L{pc + 2};  // LtFloat")

  of opLeFloat:
    let b = instr.b
    let c = instr.c
    let cond = if a == 0: "<=" else: ">"
    gen.emit(&"if (r[{b}].fval {cond} r[{c}].fval) goto L{pc + 2};  // LeFloat")

  of opEqStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_eq(r[{b}], r[{c}]));  // EqStore")

  of opLtStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_lt(r[{b}], r[{c}]));  // LtStore")

  of opLeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_le(r[{b}], r[{c}]));  // LeStore")

  of opNeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_eq(r[{b}], r[{c}]));  // NeStore")

  of opEqStoreInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].ival == r[{c}].ival);  // EqStoreInt")

  of opLtStoreInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].ival < r[{c}].ival);  // LtStoreInt")

  of opLeStoreInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].ival <= r[{c}].ival);  // LeStoreInt")

  of opEqStoreFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].fval == r[{c}].fval);  // EqStoreFloat")

  of opLtStoreFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].fval < r[{c}].fval);  // LtStoreFloat")

  of opLeStoreFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(r[{b}].fval <= r[{c}].fval);  // LeStoreFloat")

  of opNot:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_not(r[{b}]);  // Not")

  of opAnd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_and(r[{b}], r[{c}]);  // And")

  of opOr:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_or(r[{b}], r[{c}]);  // Or")

  of opJmp:
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"goto L{target};  // Jmp")

  of opTest:
    let c = instr.c
    if c == 1:
      # Skip if value is nil or (bool and false)
      gen.emit(&"if (r[{a}].kind == ETCH_VK_NIL || (r[{a}].kind == ETCH_VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")
    else:
      # Skip if value is NOT nil and NOT (bool and false)
      gen.emit(&"if (r[{a}].kind != ETCH_VK_NIL && !(r[{a}].kind == ETCH_VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")

  of opNewArray:
    doAssert instr.opType == ifmtABx
    let size = instr.bx
    gen.emit(&"r[{a}] = etch_make_array({size});  // NewArray")
    gen.emit(&"r[{a}].aval.len = {size};  // Set array length")
    gen.emit(&"for (size_t i = 0; i < {size}; i++) r[{a}].aval.data[i] = etch_make_nil();")

  of opGetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_index(r[{b}], r[{c}]);  // GetIndex")

  of opSetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_index(&r[{a}], r[{b}], r[{c}]);  // SetIndex")

  of opGetIndexI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"r[{a}] = etch_get_index(r[{regIdx}], etch_make_int({idx}));  // GetIndexI")

  of opSetIndexI:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"etch_set_index(&r[{a}], etch_make_int({idx}), r[{regIdx}]);  // SetIndexI")

  of opGetIndexInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_index(r[{b}], r[{c}]);  // GetIndexInt (type-specialized)")

  of opGetIndexFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_index(r[{b}], r[{c}]);  // GetIndexFloat (type-specialized)")

  of opGetIndexIInt:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"r[{a}] = etch_get_index(r[{regIdx}], etch_make_int({idx}));  // GetIndexIInt (type-specialized)")

  of opGetIndexIFloat:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"r[{a}] = etch_get_index(r[{regIdx}], etch_make_int({idx}));  // GetIndexIFloat (type-specialized)")

  of opSetIndexInt:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_index(&r[{a}], r[{b}], r[{c}]);  // SetIndexInt (type-specialized)")

  of opSetIndexFloat:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_index(&r[{a}], r[{b}], r[{c}]);  // SetIndexFloat (type-specialized)")

  of opSetIndexIInt:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"etch_set_index(&r[{a}], etch_make_int({idx}), r[{regIdx}]);  // SetIndexIInt (type-specialized)")

  of opSetIndexIFloat:
    doAssert instr.opType == ifmtABx
    let regIdx = instr.bx and 0xFF
    let idx = instr.bx shr 8
    gen.emit(&"etch_set_index(&r[{a}], etch_make_int({idx}), r[{regIdx}]);  // SetIndexIFloat (type-specialized)")

  of opConcatArray:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_concat_array(r[{b}], r[{c}]);  // ConcatArray")

  of opLen:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_get_length(r[{b}]);  // Len")

  of opWrapSome:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_some(r[{b}]);  // WrapSome")

  of opWrapOk:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_ok(r[{b}]);  // WrapOk")

  of opWrapErr:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_err(r[{b}]);  // WrapErr")

  of opReturn:
    gen.emitReturn(instr)

  of opExecDefers:
    gen.emitExecDefers(pc)

  of opPushDefer:
    gen.emitPushDefers(instr, pc)

  of opDeferEnd:
    gen.emitEndDefers()

  of opSlice:
    let b = instr.b
    let c = instr.c
    # R[A] = R[B][R[C]:R[C+1]] - start index in R[C], end index in R[C+1]
    gen.emit(&"// Slice: R[{a}] = R[{b}][R[{c}]:R[{c+1}]]")
    gen.emit(&"r[{a}] = etch_slice_op(r[{b}], r[{c}], r[{c + 1}]);  // Slice")

  of opNewTable:
    gen.emit(&"r[{a}] = etch_make_table();  // NewTable")

  of opGetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_field(r[{b}], etch_constants[{c}].sval);  // GetField")

  of opSetRef:
    let b = instr.b
    gen.emit(&"etch_set_ref_value(r[{a}], r[{b}]);  // SetRef")

  of opSetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_field(&r[{b}], etch_constants[{c}].sval, r[{a}]);  // SetField")

  of opNewRef:
    # Allocate heap object: C=1 for scalar, C=0 for table
    # B contains encoded destructor index (funcIdx+1, 0 if no destructor)
    doAssert instr.opType == ifmtABC
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
    elif c == 2:
      # Array allocation - B contains the source array register, not a destructor
      gen.emit(&"// NewRef: allocate array heap object from R[{b}]")
      gen.emit(&"if (r[{b}].kind != ETCH_VK_ARRAY) {{")
      gen.emit(&"  r[{a}] = etch_make_nil();")
      gen.emit(&"}} else {{")
      gen.emit(&"  size_t array_size = r[{b}].aval.len;")
      gen.emit(&"  int array_id = etch_heap_alloc_array(array_size);")
      gen.emit(&"  // Copy elements from source array to heap array")
      gen.emit(&"  for (size_t i = 0; i < array_size; i++) {{")
      gen.emit(&"    etch_heap_set_array_element(array_id, i, r[{b}].aval.data[i]);")
      gen.emit(&"  }}")
      gen.emit(&"  r[{a}] = etch_make_ref(array_id);")
      gen.emit(&"}}")
    else:
      # Table allocation (c == 0) - B contains the destructor function index
      gen.emit(&"// NewRef: allocate table heap object with destructor={destructorPtr}")
      gen.emit(&"r[{a}] = etch_make_ref(etch_heap_alloc_table({destructorPtr}));")

  of opIncRef:
    # Increment reference count of R[A]
    gen.emit(&"// IncRef: retain value stored in R[{a}]")
    gen.emit(&"etch_value_retain(r[{a}]);")

  of opDecRef:
    # Decrement reference count of R[A]
    gen.emit(&"// DecRef: release value stored in R[{a}]")
    gen.emit(&"etch_value_release(r[{a}]);")

  of opNewWeak:
    # Create weak reference to R[B]
    let b = instr.b
    gen.emit(&"// NewWeak: create weak ref to R[{b}]")
    gen.emit(&"if (r[{b}].kind == ETCH_VK_REF) {{")
    gen.emit(&"  r[{a}] = etch_make_weak(etch_heap_alloc_weak(r[{b}].refId));")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of opWeakToStrong:
    # Promote weak ref R[B] to strong ref in R[A]
    let b = instr.b
    gen.emit(&"// WeakToStrong: promote weak R[{b}] to strong R[{a}]")
    gen.emit(&"if (r[{b}].kind == ETCH_VK_WEAK) {{")
    gen.emit(&"  int strongId = etch_heap_weak_to_strong(r[{b}].weakId);")
    gen.emit(&"  if (strongId > 0) {{")
    gen.emit(&"    r[{a}] = etch_make_ref(strongId);")
    gen.emit(&"  }} else {{")
    gen.emit(&"    r[{a}] = etch_make_nil();")
    gen.emit(&"  }}")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_make_nil();")
    gen.emit(&"}}")

  of opCheckCycles:
    # Trigger cycle detection and collection
    gen.emit(&"// CheckCycles: detect and collect reference cycles")
    gen.emit(&"etch_heap_collect_cycles(r, {gen.currentFuncNumRegisters});")

  of opCast:
    let b = instr.b
    let targetKindStr = vkindToCKind(VKind(instr.c))
    gen.emit(&"r[{a}] = etch_cast_value(r[{b}], {targetKindStr});  // Cast")

  of opTestTag:
    gen.emitTestTag(instr, pc)

  of opUnwrapOption:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == ETCH_VK_SOME) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapOption")

  of opUnwrapResult:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == ETCH_VK_OK || r[{b}].kind == ETCH_VK_ERR) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapResult (Ok or Error)")

  of opIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_in(r[{b}], r[{c}]));  // In")

  of opNotIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_in(r[{b}], r[{c}]));  // NotIn")

  of opForPrep:
    # For loop preparation: set up loop variables
    # A = iterator variable, sBx = jump offset to loop end
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForPrep: setup for loop")
    gen.emit(&"if (r[{a}].kind == ETCH_VK_INT && r[{a + 1}].kind == ETCH_VK_INT) {{")
    gen.emit(&"  if (r[{a}].ival >= r[{a + 1}].ival) goto L{target};  // Empty range")
    gen.emit(&"}}")

  of opForIntPrep:
    # Specialized int for prep (idx, limit, step)
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForIntPrep: skip if already outside range")
    gen.emit(&"if ((r[{a}+2].ival > 0 && r[{a}].ival >= r[{a}+1].ival) || (r[{a}+2].ival <= 0 && r[{a}].ival <= r[{a}+1].ival)) goto L{target};")

  of opForLoop:
    # For loop increment and test: increment iterator and check if done
    # A = iterator variable, sBx = jump offset back to loop start
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForLoop: increment and test")
    gen.emit(&"r[{a}].ival++;  // Increment iterator")
    gen.emit(&"if (r[{a}].ival < r[{a + 1}].ival) goto L{target};  // Continue loop")

  of opForIntLoop:
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForIntLoop: increment and test (int specialized)")
    gen.emit(&"r[{a}].ival += r[{a}+2].ival;")
    gen.emit(&"if ((r[{a}+2].ival > 0 && r[{a}].ival < r[{a}+1].ival) || (r[{a}+2].ival <= 0 && r[{a}].ival > r[{a}+1].ival)) goto L{target};")

  of opArg:
    gen.emit("if (__etch_call_arg_count < ETCH_MAX_CALL_ARGS) {")
    gen.emit(&"  __etch_call_args[__etch_call_arg_count++] = r[{a}];  // Arg")
    gen.emit("} else {")
    gen.emit("  __etch_call_args[ETCH_MAX_CALL_ARGS - 1] = etch_make_nil();")
    gen.emit("}")

  of opArgImm:
    doAssert instr.opType == ifmtABx
    let bx = instr.bx
    gen.emit("if (__etch_call_arg_count < ETCH_MAX_CALL_ARGS) {")
    gen.emit(&"  __etch_call_args[__etch_call_arg_count++] = etch_constants[{bx}];  // ArgImm")
    gen.emit("} else {")
    gen.emit("  __etch_call_args[ETCH_MAX_CALL_ARGS - 1] = etch_make_nil();")
    gen.emit("}")

  of opCall:
    gen.emitCall(instr, pc)

  of opCallBuiltin:
    gen.emitCallBuiltin(instr, pc)

  of opCallHost:
    gen.emitCallHost(instr, pc)

  of opCallFFI:
    gen.emitCallFFI(instr, pc)

  of opInitGlobal:
    gen.execInitGlobal(instr)

  of opGetGlobal:
    gen.execGetGlobal(instr)

  of opSetGlobal:
    gen.execSetGlobal(instr)

  of opAddAdd:
    # R[A] = R[B] + R[C] + R[D]
    doAssert instr.opType == ifmtABC
    let bReg = instr.b
    let cReg = instr.c
    gen.emit(&"// AddAdd: R[{a}] = R[{a}] + R[{bReg}] + R[{cReg}]")
    gen.emit("{")
    gen.incIndent()
    gen.emit("EtchV __etch_addadd_tmp;")
    gen.emitBinaryAddExpr("__etch_addadd_tmp", &"r[{a}]", &"r[{bReg}]")
    gen.emit("EtchV __etch_addadd_res;")
    gen.emitBinaryAddExpr("__etch_addadd_res", "__etch_addadd_tmp", &"r[{cReg}]")
    gen.emit(&"r[{a}] = __etch_addadd_res;")
    gen.decIndent()
    gen.emit("}")

  of opAddAddInt:
    # R[A] = R[B] + R[C] + R[D]
    doAssert instr.opType == ifmtABC
    let bReg = instr.b
    let cReg = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // AddAddInt")
    gen.emit(&"r[{a}].ival += r[{bReg}].ival + r[{cReg}].ival;")

  of opAddAddFloat:
    # R[A] = R[B] + R[C] + R[D]
    doAssert instr.opType == ifmtABC
    let bReg = instr.b
    let cReg = instr.c
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // AddAddFloat")
    gen.emit(&"r[{a}].fval += r[{bReg}].fval + r[{cReg}].fval;")

  of opMulAdd:
    # R[A] = R[B] * R[C] + R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("MulAdd", "*", "+", a, bReg, cReg, dReg)

  of opMulAddFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // MulAddFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval * r[{cReg}].fval + r[{dReg}].fval;")

  of opSubSub:
    # R[A] = R[B] - R[C] - R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("SubSub", "-", "-", a, bReg, cReg, dReg)

  of opSubSubInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // SubSubInt")
    gen.emit(&"r[{a}].ival = r[{bReg}].ival - r[{cReg}].ival - r[{dReg}].ival;")

  of opSubSubFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // SubSubFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval - r[{cReg}].fval - r[{dReg}].fval;")

  of opMulSub:
    # R[A] = R[B] * R[C] - R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("MulSub", "*", "-", a, bReg, cReg, dReg)

  of opMulSubInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // MulSubInt")
    gen.emit(&"r[{a}].ival = r[{bReg}].ival * r[{cReg}].ival - r[{dReg}].ival;")

  of opMulSubFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // MulSubFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval * r[{cReg}].fval - r[{dReg}].fval;")

  of opSubMul:
    # R[A] = R[B] - R[C] * R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("SubMul", "-", "*", a, bReg, cReg, dReg)

  of opSubMulInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // SubMulInt")
    gen.emit(&"r[{a}].ival = r[{bReg}].ival - r[{cReg}].ival * r[{dReg}].ival;")

  of opSubMulFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // SubMulFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval - r[{cReg}].fval * r[{dReg}].fval;")

  of opDivAdd:
    # R[A] = R[B] / R[C] + R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("DivAdd", "/", "+", a, bReg, cReg, dReg)

  of opDivAddInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // DivAddInt")
    gen.emit(&"r[{a}].ival = r[{bReg}].ival / r[{cReg}].ival + r[{dReg}].ival;")

  of opDivAddFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // DivAddFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval / r[{cReg}].fval + r[{dReg}].fval;")

  of opAddSub:
    # R[A] = R[B] + R[C] - R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmetic("AddSub", "+", "-", a, bReg, cReg, dReg)

  of opAddSubInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // AddSubInt")
    gen.emit(&"r[{a}].ival = r[{bReg}].ival + r[{cReg}].ival - r[{dReg}].ival;")

  of opAddSubFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // AddSubFloat")
    gen.emit(&"r[{a}].fval = r[{bReg}].fval + r[{cReg}].fval - r[{dReg}].fval;")

  of opAddMul:
    # R[A] = (R[B] + R[C]) * R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmeticPrio("AddMul", "+", "*", a, bReg, cReg, dReg)

  of opAddMulInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // AddMulInt")
    gen.emit(&"r[{a}].ival = (r[{bReg}].ival + r[{cReg}].ival) * r[{dReg}].ival;")

  of opAddMulFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // AddMulFloat")
    gen.emit(&"r[{a}].fval = (r[{bReg}].fval + r[{cReg}].fval) * r[{dReg}].fval;")

  of opSubDiv:
    # R[A] = (R[B] - R[C]) / R[D]
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emitFusedArithmeticPrio("SubDiv", "-", "/", a, bReg, cReg, dReg)

  of opSubDivInt:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // SubDivInt")
    gen.emit(&"r[{a}].ival = (r[{bReg}].ival - r[{cReg}].ival) / r[{dReg}].ival;")

  of opSubDivFloat:
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_FLOAT;  // SubDivFloat")
    gen.emit(&"r[{a}].fval = (r[{bReg}].fval - r[{cReg}].fval) / r[{dReg}].fval;")

  of opMulAddInt:
    # R[A] = R[D] + (R[B] * R[C]) specialized for integers
    let bReg = uint8(instr.ax and 0xFF)
    let cReg = uint8((instr.ax shr 8) and 0xFF)
    let dReg = uint8((instr.ax shr 16) and 0xFF)
    gen.emit(&"r[{a}].kind = ETCH_VK_INT;  // MulAddInt")
    gen.emit(&"r[{a}].ival = r[{dReg}].ival + r[{bReg}].ival * r[{cReg}].ival;")

  of opLoadAddStore:
    gen.emitFusedFieldArithmetic(instr, opLoadAddStore)

  of opLoadSubStore:
    gen.emitFusedFieldArithmetic(instr, opLoadSubStore)

  of opLoadMulStore:
    gen.emitFusedFieldArithmetic(instr, opLoadMulStore)

  of opLoadDivStore:
    gen.emitFusedFieldArithmetic(instr, opLoadDivStore)

  of opLoadModStore:
    gen.emitFusedFieldArithmetic(instr, opLoadModStore)

  of opGetAddSet:
    gen.emitFusedArrayArithmetic(instr, opGetAddSet)

  of opGetSubSet:
    gen.emitFusedArrayArithmetic(instr, opGetSubSet)

  of opGetMulSet:
    gen.emitFusedArrayArithmetic(instr, opGetMulSet)

  of opGetDivSet:
    gen.emitFusedArrayArithmetic(instr, opGetDivSet)

  of opGetModSet:
    gen.emitFusedArrayArithmetic(instr, opGetModSet)

  of opSpawn:
    gen.emitSpawn(instr, pc)

  of opYield:
    gen.emitYield(instr, pc)

  of opResume:
    gen.emitResume(instr, pc)

  of opCmpJmp:
    # A: Comparison type (0=Eq, 1=Ne, 2=Lt, 3=Le, 4=Gt, 5=Ge)
    # Ax: [Offset:16][C:8][B:8]
    let b = uint8(instr.ax and 0xFF)
    let c = uint8((instr.ax shr 8) and 0xFF)
    let offset = int(int16((instr.ax shr 16) and 0xFFFF))
    let target = pc + 1 + offset

    var cond = case instr.a:
      of 0: &"etch_eq(r[{b}], r[{c}])"
      of 1: &"!etch_eq(r[{b}], r[{c}])"
      of 2: &"etch_lt(r[{b}], r[{c}])"
      of 3: &"etch_le(r[{b}], r[{c}])"
      of 4: &"etch_lt(r[{c}], r[{b}])"
      of 5: &"etch_le(r[{c}], r[{b}])"
      else: "0"

    gen.emit(&"if ({cond}) goto L{target};  // CmpJmp")

  of opCmpJmpInt:
    let b = uint8(instr.ax and 0xFF)
    let c = uint8((instr.ax shr 8) and 0xFF)
    let offset = int(int16((instr.ax shr 16) and 0xFFFF))
    let target = pc + 1 + offset

    var cond = case instr.a:
      of 0: &"r[{b}].ival == r[{c}].ival"
      of 1: &"r[{b}].ival != r[{c}].ival"
      of 2: &"r[{b}].ival < r[{c}].ival"
      of 3: &"r[{b}].ival <= r[{c}].ival"
      of 4: &"r[{b}].ival > r[{c}].ival"
      of 5: &"r[{b}].ival >= r[{c}].ival"
      else: "0"

    gen.emit(&"if ({cond}) goto L{target};  // CmpJmpInt")

  of opCmpJmpFloat:
    let b = uint8(instr.ax and 0xFF)
    let c = uint8((instr.ax shr 8) and 0xFF)
    let offset = int(int16((instr.ax shr 16) and 0xFFFF))
    let target = pc + 1 + offset

    var cond = case instr.a:
      of 0: &"r[{b}].fval == r[{c}].fval"
      of 1: &"r[{b}].fval != r[{c}].fval"
      of 2: &"r[{b}].fval < r[{c}].fval"
      of 3: &"r[{b}].fval <= r[{c}].fval"
      of 4: &"r[{b}].fval > r[{c}].fval"
      of 5: &"r[{b}].fval >= r[{c}].fval"
      else: "0"

    gen.emit(&"if ({cond}) goto L{target};  // CmpJmpFloat")

  of opTailCall, opTestSet, opIncTest:
    gen.emit(&"// TODO: Implement {instr.op}")

  else:
    gen.emit(&"// TODO: Implement {instr.op}")


proc generateCCode*(program: BytecodeProgram): string =
  ## Main entry point: generate complete C code from VirtualMachine bytecode
  var gen = newCGenerator(program)

  # Emit runtime
  gen.emitCRuntime()

  # Emit constant pool
  gen.emitConstantPool()

  # Emit CFFI forward declarations
  gen.emitCFFIDeclarations()

  # Emit forward declarations for all native functions
  gen.emit("\n// Forward declarations")
  for funcName, info in program.functions:
    if info.kind == fkNative:
      let safeName = sanitizeFunctionName(funcName)
      var params = ""
      if info.paramTypes.len > 0:
        for i in 0 ..< info.paramTypes.len:
          if i > 0:
            params &= ", "
          params &= &"EtchV p{i}"
      else:
        params = "void"
      gen.emit(&"EtchV func_{safeName}({params});")

  # Emit all native functions (CFFI functions are handled via declarations)
  for funcName, info in program.functions:
    gen.emitFunction(funcName, info)

  # Emit helper used for closure invocation
  gen.emitFunctionDispatchHelper()

  # Emit coroutine dispatch function
  gen.emitCoroutineDispatch()

  # Emit main wrapper
  gen.emitMainWrapper()

  return gen.output
