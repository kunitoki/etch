# codegen.nim
# C code generation from Etch bytecode

import std/[strformat, tables, sequtils, strutils, sets, algorithm]
import ../../common/[types, values, constants, builtins]
import ../../interpreter/[bytecode, serialize]
import ../../frontend/ast

type
  CCodeGen* = object
    prog*: BytecodeProgram
    code*: seq[string]
    indent*: int
    currentFunction*: string
    localVars*: Table[string, int]  # Etch name -> stack index
    tempVarCounter*: int
    labelCounter*: int
    verbose*: bool
    functionPrototypes*: seq[string]
    definedStructs*: HashSet[string]
    nextVarIndex*: int

proc sanitizeName(name: string): string =
  ## Convert function names to valid C identifiers
  ## Operators are mapped to safe names
  if name.contains("__"):
    # Handle mangled operator names like "+__ii_i"
    let parts = name.split("__")
    if parts.len >= 1:
      let baseName = parts[0]
      let suffix = if parts.len > 1: "_" & parts[1..^1].join("_") else: ""
      result = case baseName
      of "+": "op_add" & suffix
      of "-": "op_sub" & suffix
      of "*": "op_mul" & suffix
      of "/": "op_div" & suffix
      of "%": "op_mod" & suffix
      of "==": "op_eq" & suffix
      of "!=": "op_neq" & suffix
      of "<": "op_lt" & suffix
      of "<=": "op_lte" & suffix
      of ">": "op_gt" & suffix
      of ">=": "op_gte" & suffix
      else: name  # Keep as is if not an operator
  else:
    result = case name
    of "+": "op_add"
    of "-": "op_sub"
    of "*": "op_mul"
    of "/": "op_div"
    of "%": "op_mod"
    of "==": "op_eq"
    of "!=": "op_neq"
    of "<": "op_lt"
    of "<=": "op_lte"
    of ">": "op_gt"
    of ">=": "op_gte"
    else: name

proc initCCodeGen*(prog: BytecodeProgram, verbose: bool = false): CCodeGen =
  CCodeGen(
    prog: prog,
    code: @[],
    indent: 0,
    currentFunction: "",
    localVars: initTable[string, int](),
    tempVarCounter: 0,
    labelCounter: 0,
    verbose: verbose,
    functionPrototypes: @[],
    definedStructs: initHashSet[string](),
    nextVarIndex: 0
  )

proc emit(gen: var CCodeGen, line: string) =
  gen.code.add(repeat("    ", gen.indent) & line)

proc emitRaw(gen: var CCodeGen, line: string) =
  gen.code.add(line)

proc newLabel(gen: var CCodeGen): string =
  result = &"L{gen.labelCounter}"
  inc gen.labelCounter

proc newTempVar(gen: var CCodeGen): string =
  result = &"tmp_{gen.tempVarCounter}"
  inc gen.tempVarCounter

proc typeToC(typ: EtchType): string =
  ## Convert Etch type to C type
  case typ.kind
  of tkInt: "int64_t"
  of tkFloat: "double"
  of tkString: "etch_string*"
  of tkBool: "bool"
  of tkChar: "char"
  of tkVoid: "void"
  of tkArray: &"etch_array*"  # Generic array pointer
  of tkObject: &"struct {sanitizeName(typ.name)}*"
  of tkOption: &"etch_option*"
  of tkResult: &"etch_result*"
  of tkUnion: &"etch_union_{sanitizeName(typ.name)}*"
  of tkGeneric, tkUserDefined, tkDistinct: &"etch_value*"  # Generic value type
  of tkRef: &"{typeToC(typ.inner)}*"  # Reference type
  of tkInferred: "etch_value*"  # Inferred type placeholder

proc emitRuntime(gen: var CCodeGen) =
  ## Emit the C runtime support code
  gen.emit("#include <stdio.h>")
  gen.emit("#include <stdlib.h>")
  gen.emit("#include <string.h>")
  gen.emit("#include <stdbool.h>")
  gen.emit("#include <stdint.h>")
  gen.emit("#include <math.h>")
  gen.emit("#include <time.h>")
  gen.emit("")

  # Value type for dynamic typing
  gen.emit("typedef enum {")
  gen.indent += 1
  gen.emit("VALUE_INT,")
  gen.emit("VALUE_FLOAT,")
  gen.emit("VALUE_STRING,")
  gen.emit("VALUE_BOOL,")
  gen.emit("VALUE_CHAR,")
  gen.emit("VALUE_NIL,")
  gen.emit("VALUE_ARRAY,")
  gen.emit("VALUE_STRUCT,")
  gen.emit("VALUE_OPTION,")
  gen.emit("VALUE_RESULT,")
  gen.emit("VALUE_UNION,")
  gen.emit("VALUE_REF")
  gen.indent -= 1
  gen.emit("} ValueType;")
  gen.emit("")

  # String type
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("char* data;")
  gen.emit("size_t length;")
  gen.indent -= 1
  gen.emit("} etch_string;")
  gen.emit("")

  # Dynamic array type
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("void** data;")
  gen.emit("size_t length;")
  gen.emit("size_t capacity;")
  gen.emit("ValueType element_type;")
  gen.indent -= 1
  gen.emit("} etch_array;")
  gen.emit("")

  # Option type
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("bool is_some;")
  gen.emit("void* value;")
  gen.indent -= 1
  gen.emit("} etch_option;")
  gen.emit("")

  # Result type
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("bool is_ok;")
  gen.emit("void* value;")
  gen.indent -= 1
  gen.emit("} etch_result;")
  gen.emit("")

  # Union type
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("const char* tag;  // Variant tag")
  gen.emit("void* value;       // Wrapped value")
  gen.indent -= 1
  gen.emit("} etch_union;")
  gen.emit("")

  # Forward declaration for etch_value (needed by etch_object)
  gen.emit("typedef struct etch_value etch_value;")
  gen.emit("")

  # Object type - simple key-value storage
  gen.emit("typedef struct {")
  gen.indent += 1
  gen.emit("char** keys;")
  gen.emit("etch_value* values;")
  gen.emit("size_t count;")
  gen.indent -= 1
  gen.emit("} etch_object;")
  gen.emit("")

  # Generic value type
  gen.emit("struct etch_value {")
  gen.indent += 1
  gen.emit("ValueType type;")
  gen.emit("union {")
  gen.indent += 1
  gen.emit("int64_t ival;")
  gen.emit("double fval;")
  gen.emit("etch_string* sval;")
  gen.emit("bool bval;")
  gen.emit("char cval;")
  gen.emit("etch_array* aval;")
  gen.emit("etch_union* uval;")
  gen.emit("void* ptr;")
  gen.indent -= 1
  gen.emit("} data;")
  gen.indent -= 1
  gen.emit("};")
  gen.emit("")

  # Runtime stack for dynamic execution
  gen.emit("static etch_value stack[10000];")
  gen.emit("static int sp = 0;")
  gen.emit("")

  # Helper functions
  gen.emit("static void push_int(int64_t val) {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_INT;")
  gen.emit("stack[sp].data.ival = val;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void push_float(double val) {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_FLOAT;")
  gen.emit("stack[sp].data.fval = val;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void push_string(etch_string* val) {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_STRING;")
  gen.emit("stack[sp].data.sval = val;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void push_bool(bool val) {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_BOOL;")
  gen.emit("stack[sp].data.bval = val;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void push_char(char val) {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_CHAR;")
  gen.emit("stack[sp].data.cval = val;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void push_nil() {")
  gen.indent += 1
  gen.emit("stack[sp].type = VALUE_NIL;")
  gen.emit("sp++;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static etch_value pop() {")
  gen.indent += 1
  gen.emit("return stack[--sp];")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  # String creation
  gen.emit("static etch_string* make_string(const char* str) {")
  gen.indent += 1
  gen.emit("etch_string* s = malloc(sizeof(etch_string));")
  gen.emit("s->length = strlen(str);")
  gen.emit("s->data = malloc(s->length + 1);")
  gen.emit("strcpy(s->data, str);")
  gen.emit("return s;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  # Array operations
  gen.emit("static etch_array* make_array(size_t initial_capacity, ValueType type) {")
  gen.indent += 1
  gen.emit("etch_array* arr = malloc(sizeof(etch_array));")
  gen.emit("arr->data = malloc(sizeof(void*) * initial_capacity);")
  gen.emit("arr->length = 0;")
  gen.emit("arr->capacity = initial_capacity;")
  gen.emit("arr->element_type = type;")
  gen.emit("return arr;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  gen.emit("static void array_push(etch_array* arr, void* elem) {")
  gen.indent += 1
  gen.emit("if (arr->length >= arr->capacity) {")
  gen.indent += 1
  gen.emit("arr->capacity *= 2;")
  gen.emit("arr->data = realloc(arr->data, sizeof(void*) * arr->capacity);")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("arr->data[arr->length++] = elem;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

  # Built-in print function (always adds newline, matching the VM behavior)
  gen.emit("static void builtin_print(etch_value val) {")
  gen.indent += 1
  gen.emit("switch (val.type) {")
  gen.emit("case VALUE_INT: printf(\"%lld\\n\", val.data.ival); break;")
  gen.emit("case VALUE_FLOAT: {")
  gen.indent += 1
  gen.emit("// Format float like Nim's $ operator")
  gen.emit("char buffer[32];")
  gen.emit("snprintf(buffer, sizeof(buffer), \"%.15g\", val.data.fval);")
  gen.emit("// Check if the number has no decimal point and add .0 if needed")
  gen.emit("if (strchr(buffer, '.') == NULL && strchr(buffer, 'e') == NULL) {")
  gen.indent += 1
  gen.emit("strcat(buffer, \".0\");")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("printf(\"%s\\n\", buffer);")
  gen.emit("break;")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("case VALUE_STRING: printf(\"%s\\n\", val.data.sval->data); break;")
  gen.emit("case VALUE_BOOL: printf(\"%s\\n\", val.data.bval ? \"true\" : \"false\"); break;")
  gen.emit("case VALUE_CHAR: printf(\"%c\\n\", val.data.cval); break;")
  gen.emit("case VALUE_NIL: printf(\"nil\\n\"); break;")
  gen.emit("case VALUE_REF: {")
  gen.emit("    if (val.data.ptr != NULL) {")
  gen.emit("        etch_value* deref_val = (etch_value*)val.data.ptr;")
  gen.emit("        builtin_print(*deref_val);")
  gen.emit("    } else {")
  gen.emit("        printf(\"nil\\n\");")
  gen.emit("    }")
  gen.emit("    break;")
  gen.emit("}")
  gen.emit("default: printf(\"<value>\\n\"); break;")
  gen.emit("}")
  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

proc compileInstruction(gen: var CCodeGen, instr: Instruction, idx: int, labels: Table[int, string]) =
  ## Compile a single bytecode instruction to C

  # Emit label if this instruction is a jump target
  if labels.hasKey(idx):
    gen.indent -= 1
    gen.emit(&"{labels[idx]}:")
    gen.indent += 1

  # Emit #line directive if we have debug info
  if instr.debug.line > 0 and instr.debug.sourceFile.len > 0:
    gen.emit(&"#line {instr.debug.line} \"{instr.debug.sourceFile}\"")

  if gen.verbose:
    gen.emit(&"// {instr.op} at instruction {idx}")

  case instr.op
  of opLoadInt:
    gen.emit(&"push_int({instr.arg});")

  of opLoadFloat:
    let floatStr = gen.prog.constants[instr.arg]
    gen.emit(&"push_float({floatStr});")

  of opLoadString:
    let str = gen.prog.constants[instr.arg]
    # Properly escape the string for C
    var escapedStr = ""
    for ch in str:
      case ch
      of '"': escapedStr.add("\\\"")
      of '\\': escapedStr.add("\\\\")
      of '\n': escapedStr.add("\\n")
      of '\r': escapedStr.add("\\r")
      of '\t': escapedStr.add("\\t")
      else: escapedStr.add(ch)
    gen.emit(&"push_string(make_string(\"{escapedStr}\"));")

  of opLoadChar:
    let ch = gen.prog.constants[instr.arg]
    if ch.len > 0:
      var escapedChar: string
      case ch[0]
      of '\'': escapedChar = "\\'"
      of '\\': escapedChar = "\\\\"
      of '\n': escapedChar = "\\n"
      of '\r': escapedChar = "\\r"
      of '\t': escapedChar = "\\t"
      of '\0': escapedChar = "\\0"
      else: escapedChar = $ch[0]
      gen.emit(&"push_char('{escapedChar}');")
    else:
      gen.emit("push_char('\\0');")

  of opLoadBool:
    let boolVal = if instr.arg != 0: "true" else: "false"
    gen.emit(&"push_bool({boolVal});")

  of opLoadNil:
    gen.emit("push_nil();")

  of opLoadVar:
    # Load variable from local vars
    if gen.localVars.hasKey(instr.sarg):
      let varIndex = gen.localVars[instr.sarg]
      gen.emit(&"// Load variable: {instr.sarg} from locals[{varIndex}]")
      gen.emit(&"stack[sp++] = locals[{varIndex}];")
    else:
      gen.emit(&"// Warning: Unknown variable: {instr.sarg}")
      gen.emit("push_int(0); // Undefined variable")

  of opStoreVar:
    # Store variable to local vars
    if not gen.localVars.hasKey(instr.sarg):
      gen.localVars[instr.sarg] = gen.nextVarIndex
      inc gen.nextVarIndex
    let varIndex = gen.localVars[instr.sarg]
    gen.emit(&"// Store to variable: {instr.sarg} at locals[{varIndex}]")
    gen.emit(&"locals[{varIndex}] = pop();")

  of opAdd:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_STRING && b.type == VALUE_STRING) {")
    gen.indent += 1
    gen.emit("// String concatenation")
    gen.emit("size_t len_a = a.data.sval->length;")
    gen.emit("size_t len_b = b.data.sval->length;")
    gen.emit("size_t new_len = len_a + len_b;")
    gen.emit("etch_string* result = malloc(sizeof(etch_string));")
    gen.emit("result->length = new_len;")
    gen.emit("result->data = malloc(new_len + 1);")
    gen.emit("memcpy(result->data, a.data.sval->data, len_a);")
    gen.emit("memcpy(result->data + len_a, b.data.sval->data, len_b);")
    gen.emit("result->data[new_len] = '\\0';")
    gen.emit("push_string(result);")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_ARRAY && b.type == VALUE_ARRAY) {")
    gen.indent += 1
    gen.emit("// Array concatenation")
    gen.emit("etch_array* arr_a = a.data.aval;")
    gen.emit("etch_array* arr_b = b.data.aval;")
    gen.emit("size_t total_len = arr_a->length + arr_b->length;")
    gen.emit("etch_array* result = make_array(total_len, arr_a->element_type);")
    gen.emit("// Copy elements from first array")
    gen.emit("for (size_t i = 0; i < arr_a->length; i++) {")
    gen.indent += 1
    gen.emit("array_push(result, arr_a->data[i]);")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("// Copy elements from second array")
    gen.emit("for (size_t i = 0; i < arr_b->length; i++) {")
    gen.indent += 1
    gen.emit("array_push(result, arr_b->data[i]);")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("etch_value res_val;")
    gen.emit("res_val.type = VALUE_ARRAY;")
    gen.emit("res_val.data.aval = result;")
    gen.emit("stack[sp++] = res_val;")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_int(a.data.ival + b.data.ival);")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_FLOAT || b.type == VALUE_FLOAT) {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_float(af + bf);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("// Type mismatch - push nil")
    gen.emit("push_nil();")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opSub:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_int(a.data.ival - b.data.ival);")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_FLOAT || b.type == VALUE_FLOAT) {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_float(af - bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMul:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_int(a.data.ival * b.data.ival);")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_FLOAT || b.type == VALUE_FLOAT) {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_float(af * bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opDiv:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_int(a.data.ival / b.data.ival);")
    gen.indent -= 1
    gen.emit("} else if (a.type == VALUE_FLOAT || b.type == VALUE_FLOAT) {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_float(af / bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMod:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("push_int(a.data.ival % b.data.ival);")
    gen.indent -= 1
    gen.emit("}")

  of opEq:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("bool eq = false;")
    gen.emit("if (a.type == b.type) {")
    gen.indent += 1
    gen.emit("switch (a.type) {")
    gen.emit("case VALUE_INT: eq = a.data.ival == b.data.ival; break;")
    gen.emit("case VALUE_FLOAT: eq = a.data.fval == b.data.fval; break;")
    gen.emit("case VALUE_BOOL: eq = a.data.bval == b.data.bval; break;")
    gen.emit("case VALUE_CHAR: eq = a.data.cval == b.data.cval; break;")
    gen.emit("case VALUE_STRING: eq = strcmp(a.data.sval->data, b.data.sval->data) == 0; break;")
    gen.emit("case VALUE_NIL: eq = true; break;")
    gen.emit("default: break;")
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("push_bool(eq);")
    gen.indent -= 1
    gen.emit("}")

  of opNe:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("bool ne = true;")
    gen.emit("if (a.type == b.type) {")
    gen.indent += 1
    gen.emit("switch (a.type) {")
    gen.emit("case VALUE_INT: ne = a.data.ival != b.data.ival; break;")
    gen.emit("case VALUE_FLOAT: ne = a.data.fval != b.data.fval; break;")
    gen.emit("case VALUE_BOOL: ne = a.data.bval != b.data.bval; break;")
    gen.emit("case VALUE_CHAR: ne = a.data.cval != b.data.cval; break;")
    gen.emit("case VALUE_STRING: ne = strcmp(a.data.sval->data, b.data.sval->data) != 0; break;")
    gen.emit("case VALUE_NIL: ne = false; break;")
    gen.emit("default: break;")
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("push_bool(ne);")
    gen.indent -= 1
    gen.emit("}")

  of opLt:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_bool(a.data.ival < b.data.ival);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_bool(af < bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opLe:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_bool(a.data.ival <= b.data.ival);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_bool(af <= bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opGt:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_bool(a.data.ival > b.data.ival);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_bool(af > bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opGe:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT && b.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_bool(a.data.ival >= b.data.ival);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("double af = (a.type == VALUE_FLOAT) ? a.data.fval : (double)a.data.ival;")
    gen.emit("double bf = (b.type == VALUE_FLOAT) ? b.data.fval : (double)b.data.ival;")
    gen.emit("push_bool(af >= bf);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opAnd:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("push_bool(a.data.bval && b.data.bval);")
    gen.indent -= 1
    gen.emit("}")

  of opOr:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value b = pop();")
    gen.emit("etch_value a = pop();")
    gen.emit("push_bool(a.data.bval || b.data.bval);")
    gen.indent -= 1
    gen.emit("}")

  of opNot:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value a = pop();")
    gen.emit("push_bool(!a.data.bval);")
    gen.indent -= 1
    gen.emit("}")

  of opNeg:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value a = pop();")
    gen.emit("if (a.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("push_int(-a.data.ival);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_float(-a.data.fval);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opJump:
    let target = int(instr.arg)
    if labels.hasKey(target):
      gen.emit(&"goto {labels[target]};")
    else:
      # Jump is outside this function - likely a return
      gen.emit("// Jump outside function bounds - treating as return")
      if gen.currentFunction == MAIN_FUNCTION_NAME:
        gen.emit("return 0;")
      else:
        gen.emit("return;")

  of opJumpIfFalse:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value cond = pop();")
    let target = int(instr.arg)
    if labels.hasKey(target):
      gen.emit(&"if (!cond.data.bval) goto {labels[target]};")
    else:
      # Jump is outside this function - conditional return
      gen.emit("if (!cond.data.bval) {")
      gen.indent += 1
      gen.emit("// Jump outside function bounds - treating as return")
      if gen.currentFunction == MAIN_FUNCTION_NAME:
        gen.emit("return 0;")
      else:
        gen.emit("return;")
      gen.indent -= 1
      gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opCall:
    let funcName = sanitizeName(instr.sarg)
    let argCount = instr.arg
    gen.emit(&"// Call {instr.sarg} with {argCount} arguments")

    # Pop arguments and store them temporarily (in reverse order for C calling convention)
    if argCount > 0:
      gen.emit("{")
      gen.indent += 1

      # Pop arguments in reverse order
      for i in countdown(int(argCount) - 1, 0):
        gen.emit(&"etch_value arg{i} = pop();")

      # Push them back for the function (for now, functions will pop their own args)
      for i in 0..<argCount:
        gen.emit(&"stack[sp++] = arg{i};")

      gen.indent -= 1
      gen.emit("}")

    # Call the function
    gen.emit(&"{funcName}();")

    # Functions should leave their return value on the stack
    # For void functions, we need to push nil
    # This is handled by the function itself

  of opCallBuiltin:
    let builtinId = instr.arg shr 16      # Extract builtin ID from upper 16 bits
    let argCount = instr.arg and 0xFFFF   # Extract arg count from lower 16 bits

    gen.emit(&"// Builtin call id={builtinId} with {argCount} args")

    # Handle known builtins based on BuiltinFuncId enum
    case builtinId
    of 0: # bfPrint
      gen.emit("{")
      gen.indent += 1
      if argCount > 0:
        gen.emit("etch_value val = pop();")
        gen.emit("builtin_print(val);")
      gen.emit("push_nil(); // print returns void")
      gen.indent -= 1
      gen.emit("}")

    of 1: # bfNew
      gen.emit("{")
      gen.indent += 1
      gen.emit("etch_value val = pop();")
      gen.emit("// TODO: Implement new builtin")
      gen.emit("push_nil();")
      gen.indent -= 1
      gen.emit("}")

    of 2: # bfDeref
      gen.emit("{")
      gen.indent += 1
      gen.emit("etch_value ref = pop();")
      gen.emit("if (ref.type == VALUE_REF && ref.data.ptr != NULL) {")
      gen.indent += 1
      gen.emit("etch_value* val_ptr = (etch_value*)ref.data.ptr;")
      gen.emit("stack[sp++] = *val_ptr;")
      gen.indent -= 1
      gen.emit("} else {")
      gen.indent += 1
      gen.emit("push_nil(); // Null reference")
      gen.indent -= 1
      gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 3: # bfRand
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value max_val = pop();")
        gen.emit("if (max_val.type == VALUE_INT && max_val.data.ival > 0) {")
        gen.indent += 1
        gen.emit("int result = rand() % (int)max_val.data.ival;")
        gen.emit("push_int(result);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_int(0);")
        gen.indent -= 1
        gen.emit("}")
      elif argCount == 2:
        gen.emit("etch_value max_val = pop();")
        gen.emit("etch_value min_val = pop();")
        gen.emit("if (max_val.type == VALUE_INT && min_val.type == VALUE_INT && max_val.data.ival >= min_val.data.ival) {")
        gen.indent += 1
        gen.emit("int range = (int)(max_val.data.ival - min_val.data.ival);")
        gen.emit("if (range > 0) {")
        gen.indent += 1
        gen.emit("int result = (rand() % range) + (int)min_val.data.ival;")
        gen.emit("push_int(result);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_int((int)min_val.data.ival);")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_int(0);")
        gen.indent -= 1
        gen.emit("}")
      else:
        gen.emit("push_int(0);")
      gen.indent -= 1
      gen.emit("}")

    of 4: # bfSeed
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value seed_val = pop();")
        gen.emit("if (seed_val.type == VALUE_INT) {")
        gen.indent += 1
        gen.emit("srand((unsigned int)seed_val.data.ival);")
        gen.indent -= 1
        gen.emit("}")
      elif argCount == 0:
        gen.emit("srand((unsigned int)time(NULL));")
      gen.emit("push_nil(); // seed returns void")
      gen.indent -= 1
      gen.emit("}")

    of 5: # bfReadFile
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value path_val = pop();")
        gen.emit("if (path_val.type == VALUE_STRING) {")
        gen.indent += 1
        gen.emit("FILE* file = fopen(path_val.data.sval->data, \"r\");")
        gen.emit("if (file != NULL) {")
        gen.indent += 1
        gen.emit("fseek(file, 0, SEEK_END);")
        gen.emit("long file_size = ftell(file);")
        gen.emit("fseek(file, 0, SEEK_SET);")
        gen.emit("char* buffer = malloc(file_size + 1);")
        gen.emit("fread(buffer, 1, file_size, file);")
        gen.emit("buffer[file_size] = '\\0';")
        gen.emit("fclose(file);")
        gen.emit("push_string(make_string(buffer));")
        gen.emit("free(buffer);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_string(make_string(\"\"));")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_string(make_string(\"\"));")
        gen.indent -= 1
        gen.emit("}")
      else:
        gen.emit("push_string(make_string(\"\"));")
      gen.indent -= 1
      gen.emit("}")

    of 6: # bfParseInt
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value str_val = pop();")
        gen.emit("if (str_val.type == VALUE_STRING) {")
        gen.indent += 1
        gen.emit("char* endptr;")
        gen.emit("long parsed = strtol(str_val.data.sval->data, &endptr, 10);")
        gen.emit("if (endptr != str_val.data.sval->data && *endptr == '\\0') {")
        gen.indent += 1
        gen.emit("// Successfully parsed - return Some(parsed)")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = true;")
        gen.emit("int64_t* val = malloc(sizeof(int64_t));")
        gen.emit("*val = parsed;")
        gen.emit("opt->value = val;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("// Failed to parse - return None")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("// Not a string - return None")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 7: # bfParseFloat
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value str_val = pop();")
        gen.emit("if (str_val.type == VALUE_STRING) {")
        gen.indent += 1
        gen.emit("char* endptr;")
        gen.emit("double parsed = strtod(str_val.data.sval->data, &endptr);")
        gen.emit("if (endptr != str_val.data.sval->data && *endptr == '\\0') {")
        gen.indent += 1
        gen.emit("// Successfully parsed - return Some(parsed)")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = true;")
        gen.emit("double* val = malloc(sizeof(double));")
        gen.emit("*val = parsed;")
        gen.emit("opt->value = val;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("// Failed to parse - return None")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("// Not a string - return None")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 8: # bfParseBool
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value str_val = pop();")
        gen.emit("if (str_val.type == VALUE_STRING) {")
        gen.indent += 1
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("if (strcmp(str_val.data.sval->data, \"true\") == 0) {")
        gen.indent += 1
        gen.emit("opt->is_some = true;")
        gen.emit("bool* val = malloc(sizeof(bool));")
        gen.emit("*val = true;")
        gen.emit("opt->value = val;")
        gen.indent -= 1
        gen.emit("} else if (strcmp(str_val.data.sval->data, \"false\") == 0) {")
        gen.indent += 1
        gen.emit("opt->is_some = true;")
        gen.emit("bool* val = malloc(sizeof(bool));")
        gen.emit("*val = false;")
        gen.emit("opt->value = val;")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.indent -= 1
        gen.emit("}")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("// Not a string - return None")
        gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
        gen.emit("opt->is_some = false;")
        gen.emit("opt->value = NULL;")
        gen.emit("etch_value result;")
        gen.emit("result.type = VALUE_OPTION;")
        gen.emit("result.data.ptr = opt;")
        gen.emit("stack[sp++] = result;")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 9: # bfToString
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value val = pop();")
        gen.emit("char buffer[256];")
        gen.emit("switch (val.type) {")
        gen.emit("case VALUE_INT:")
        gen.indent += 1
        gen.emit("snprintf(buffer, 256, \"%lld\", val.data.ival);")
        gen.emit("push_string(make_string(buffer));")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("case VALUE_FLOAT:")
        gen.indent += 1
        gen.emit("snprintf(buffer, 256, \"%f\", val.data.fval);")
        gen.emit("push_string(make_string(buffer));")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("case VALUE_BOOL:")
        gen.indent += 1
        gen.emit("push_string(make_string(val.data.bval ? \"true\" : \"false\"));")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("case VALUE_STRING:")
        gen.indent += 1
        gen.emit("stack[sp++] = val; // Already a string")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("case VALUE_CHAR:")
        gen.indent += 1
        gen.emit("buffer[0] = val.data.cval;")
        gen.emit("buffer[1] = '\\0';")
        gen.emit("push_string(make_string(buffer));")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("default:")
        gen.indent += 1
        gen.emit("push_string(make_string(\"<value>\"));")
        gen.emit("break;")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 10: # bfIsSome
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value opt_val = pop();")
        gen.emit("if (opt_val.type == VALUE_OPTION) {")
        gen.indent += 1
        gen.emit("etch_option* opt = (etch_option*)opt_val.data.ptr;")
        gen.emit("push_bool(opt->is_some);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_bool(false);")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    of 11: # bfIsNone
      gen.emit("{")
      gen.indent += 1
      if argCount == 1:
        gen.emit("etch_value opt_val = pop();")
        gen.emit("if (opt_val.type == VALUE_OPTION) {")
        gen.indent += 1
        gen.emit("etch_option* opt = (etch_option*)opt_val.data.ptr;")
        gen.emit("push_bool(!opt->is_some);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_bool(true);")
        gen.indent -= 1
        gen.emit("}")
      gen.indent -= 1
      gen.emit("}")

    else:
      gen.emit(&"// Unknown builtin {builtinId}")
      for i in 0..<argCount:
        gen.emit("pop(); // Pop argument")
      gen.emit("push_nil(); // Return placeholder")

  of opCallCFFI:
    gen.emit(&"// CFFI call to {instr.sarg} with {instr.arg} args")
    # Extract the base function name (before the type mangling)
    let fullName = instr.sarg
    let funcName = if fullName.contains("__"):
      fullName.split("__")[0]
    else:
      fullName
    let argCount = instr.arg

    # Handle known C math functions
    if funcName in ["sin", "cos", "tan", "sqrt", "exp", "log", "log10", "floor", "ceil", "fabs"]:
      if argCount == 1:
        gen.emit("{")
        gen.indent += 1
        gen.emit("etch_value arg = pop();")
        gen.emit("if (arg.type == VALUE_FLOAT) {")
        gen.indent += 1
        gen.emit(&"double result = {funcName}(arg.data.fval);")
        gen.emit("push_float(result);")
        gen.indent -= 1
        gen.emit("} else if (arg.type == VALUE_INT) {")
        gen.indent += 1
        gen.emit(&"double result = {funcName}((double)arg.data.ival);")
        gen.emit("push_float(result);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_nil();")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("}")
    elif funcName in ["pow", "atan2", "fmod"]:
      if argCount == 2:
        gen.emit("{")
        gen.indent += 1
        gen.emit("etch_value arg2 = pop();")
        gen.emit("etch_value arg1 = pop();")
        gen.emit("if ((arg1.type == VALUE_FLOAT || arg1.type == VALUE_INT) &&")
        gen.emit("    (arg2.type == VALUE_FLOAT || arg2.type == VALUE_INT)) {")
        gen.indent += 1
        gen.emit("double val1 = arg1.type == VALUE_FLOAT ? arg1.data.fval : (double)arg1.data.ival;")
        gen.emit("double val2 = arg2.type == VALUE_FLOAT ? arg2.data.fval : (double)arg2.data.ival;")
        gen.emit(&"double result = {funcName}(val1, val2);")
        gen.emit("push_float(result);")
        gen.indent -= 1
        gen.emit("} else {")
        gen.indent += 1
        gen.emit("push_nil();")
        gen.indent -= 1
        gen.emit("}")
        gen.indent -= 1
        gen.emit("}")
      else:
        gen.emit("push_nil(); // Wrong arg count")
    else:
      gen.emit(&"push_nil(); // Unknown CFFI function: {funcName}")

  of opReturn:
    gen.emit("// Return from function")
    if gen.currentFunction == MAIN_FUNCTION_NAME:
      gen.emit("return 0;")
    else:
      gen.emit("return;")

  of opPop:
    gen.emit("pop();")

  of opDup:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value val = stack[sp - 1];")
    gen.emit("stack[sp] = val;")
    gen.emit("sp++;")
    gen.indent -= 1
    gen.emit("}")


  of opMakeArray:
    gen.emit("{")
    gen.indent += 1
    gen.emit(&"size_t count = {instr.arg};")
    gen.emit("etch_array* arr = make_array(count > 0 ? count : 8, VALUE_INT);")
    gen.emit("for (size_t i = 0; i < count; i++) {")
    gen.indent += 1
    gen.emit("etch_value* val = malloc(sizeof(etch_value));")
    gen.emit("*val = stack[sp - count + i];")
    gen.emit("array_push(arr, val);")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("sp -= count;")
    gen.emit("stack[sp].type = VALUE_ARRAY;")
    gen.emit("stack[sp].data.aval = arr;")
    gen.emit("sp++;")
    gen.indent -= 1
    gen.emit("}")

  of opArrayGet:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value idx = pop();")
    gen.emit("etch_value arr = pop();")
    gen.emit("if (arr.type == VALUE_ARRAY && idx.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("etch_value* elem = (etch_value*)arr.data.aval->data[idx.data.ival];")
    gen.emit("stack[sp++] = *elem;")
    gen.indent -= 1
    gen.emit("} else if (arr.type == VALUE_STRING && idx.type == VALUE_INT) {")
    gen.indent += 1
    gen.emit("// String indexing")
    gen.emit("int index = (int)idx.data.ival;")
    gen.emit("if (index >= 0 && index < arr.data.sval->length) {")
    gen.indent += 1
    gen.emit("push_char(arr.data.sval->data[index]);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_nil(); // Index out of bounds")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_nil(); // Error case")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")


  of opArrayLen:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value arr = pop();")
    gen.emit("if (arr.type == VALUE_ARRAY) {")
    gen.indent += 1
    gen.emit("push_int((int64_t)arr.data.aval->length);")
    gen.indent -= 1
    gen.emit("} else if (arr.type == VALUE_STRING) {")
    gen.indent += 1
    gen.emit("push_int((int64_t)arr.data.sval->length);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_int(0);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMakeObject:
    gen.emit(&"// Create object with {instr.arg} fields")
    gen.emit("{")
    gen.indent += 1
    gen.emit(&"size_t field_count = {instr.arg};")
    gen.emit("etch_object* obj = malloc(sizeof(etch_object));")
    gen.emit("obj->count = field_count;")
    gen.emit("obj->keys = malloc(sizeof(char*) * field_count);")
    gen.emit("obj->values = malloc(sizeof(etch_value) * field_count);")
    gen.emit("")
    gen.emit("// Pop field names and values in reverse order")
    gen.emit("for (int i = field_count - 1; i >= 0; i--) {")
    gen.indent += 1
    gen.emit("etch_value key_val = pop(); // Field name")
    gen.emit("obj->values[i] = pop(); // Value")
    gen.emit("if (key_val.type == VALUE_STRING) {")
    gen.indent += 1
    gen.emit("obj->keys[i] = malloc(strlen(key_val.data.sval->data) + 1);")
    gen.emit("strcpy(obj->keys[i], key_val.data.sval->data);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("obj->keys[i] = malloc(10);")
    gen.emit("strcpy(obj->keys[i], \"unknown\");")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_STRUCT;")
    gen.emit("result.data.ptr = obj;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opObjectGet:
    gen.emit(&"// Get field {instr.sarg}")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value obj_val = pop();")
    gen.emit("if (obj_val.type == VALUE_STRUCT && obj_val.data.ptr != NULL) {")
    gen.indent += 1
    gen.emit("etch_object* obj = (etch_object*)obj_val.data.ptr;")
    gen.emit(&"const char* field_name = \"{instr.sarg}\";")
    gen.emit("bool found = false;")
    gen.emit("for (size_t i = 0; i < obj->count; i++) {")
    gen.indent += 1
    gen.emit("if (strcmp(obj->keys[i], field_name) == 0) {")
    gen.indent += 1
    gen.emit("stack[sp++] = obj->values[i];")
    gen.emit("found = true;")
    gen.emit("break;")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("if (!found) {")
    gen.indent += 1
    gen.emit("push_nil(); // Field not found")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_nil(); // Not an object")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opObjectSet:
    gen.emit(&"// Set field {instr.sarg}")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value new_value = pop();")
    gen.emit("etch_value obj_val = pop();")
    gen.emit("if (obj_val.type == VALUE_STRUCT && obj_val.data.ptr != NULL) {")
    gen.indent += 1
    gen.emit("etch_object* obj = (etch_object*)obj_val.data.ptr;")
    gen.emit(&"const char* field_name = \"{instr.sarg}\";")
    gen.emit("for (size_t i = 0; i < obj->count; i++) {")
    gen.indent += 1
    gen.emit("if (strcmp(obj->keys[i], field_name) == 0) {")
    gen.indent += 1
    gen.emit("obj->values[i] = new_value;")
    gen.emit("break;")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("push_nil();")
    gen.indent -= 1
    gen.emit("}")

  of opMakeOptionSome:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
    gen.emit("etch_value* val = malloc(sizeof(etch_value));")
    gen.emit("*val = pop();")
    gen.emit("opt->is_some = true;")
    gen.emit("opt->value = val;")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_OPTION;")
    gen.emit("result.data.ptr = opt;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opMakeOptionNone:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_option* opt = malloc(sizeof(etch_option));")
    gen.emit("opt->is_some = false;")
    gen.emit("opt->value = NULL;")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_OPTION;")
    gen.emit("result.data.ptr = opt;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opExtractSome:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value opt = pop();")
    gen.emit("if (opt.type == VALUE_OPTION) {")
    gen.indent += 1
    gen.emit("etch_option* o = (etch_option*)opt.data.ptr;")
    gen.emit("if (o->is_some) {")
    gen.indent += 1
    gen.emit("stack[sp++] = *(etch_value*)o->value;")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("printf(\"Error: unwrap on None\\n\");")
    gen.emit("exit(1);")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMakeResultOk:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_result* res = malloc(sizeof(etch_result));")
    gen.emit("etch_value* val = malloc(sizeof(etch_value));")
    gen.emit("*val = pop();")
    gen.emit("res->is_ok = true;")
    gen.emit("res->value = val;")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_RESULT;")
    gen.emit("result.data.ptr = res;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opMakeResultErr:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_result* res = malloc(sizeof(etch_result));")
    gen.emit("etch_value* val = malloc(sizeof(etch_value));")
    gen.emit("*val = pop();")
    gen.emit("res->is_ok = false;")
    gen.emit("res->value = val;")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_RESULT;")
    gen.emit("result.data.ptr = res;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opExtractOk:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value res = pop();")
    gen.emit("if (res.type == VALUE_RESULT) {")
    gen.indent += 1
    gen.emit("etch_result* r = (etch_result*)res.data.ptr;")
    gen.emit("if (r->is_ok) {")
    gen.indent += 1
    gen.emit("stack[sp++] = *(etch_value*)r->value;")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opExtractErr:
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value res = pop();")
    gen.emit("if (res.type == VALUE_RESULT) {")
    gen.indent += 1
    gen.emit("etch_result* r = (etch_result*)res.data.ptr;")
    gen.emit("if (!r->is_ok) {")
    gen.indent += 1
    gen.emit("stack[sp++] = *(etch_value*)r->value;")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMakeUnion:
    gen.emit(&"// Create union variant {instr.sarg}")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value val = pop();")
    gen.emit("etch_union* u = (etch_union*)malloc(sizeof(etch_union));")
    gen.emit(&"u->tag = \"{instr.sarg}\";")
    gen.emit("u->value = malloc(sizeof(etch_value));")
    gen.emit("*(etch_value*)u->value = val;")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_UNION;")
    gen.emit("result.data.uval = u;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")

  of opExtractUnion:
    gen.emit(&"// Extract union value for variant {instr.sarg}")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value u = pop();")
    gen.emit("if (u.type == VALUE_UNION && u.data.uval != NULL) {")
    gen.indent += 1
    gen.emit("etch_value* val = (etch_value*)u.data.uval->value;")
    gen.emit("stack[sp++] = *val;")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_nil();")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opMatchValue:
    gen.emit(&"// Match value against variant {instr.arg}")
    gen.emit("{")
    gen.indent += 1
    gen.emit("// Check if union variant matches")
    gen.emit("etch_value u = stack[sp - 1];  // Peek at value without popping")
    gen.emit("bool matches = false;")
    gen.emit("if (u.type == VALUE_UNION && u.data.uval != NULL) {")
    gen.indent += 1
    # Map variant IDs to type checks
    # Based on the bytecode pattern, 100 = int, 101 = float
    case instr.arg
    of 100:  # int variant
      gen.emit("etch_value* inner = (etch_value*)u.data.uval->value;")
      gen.emit("matches = (inner->type == VALUE_INT);")
    of 101:  # float variant
      gen.emit("etch_value* inner = (etch_value*)u.data.uval->value;")
      gen.emit("matches = (inner->type == VALUE_FLOAT);")
    else:
      gen.emit(&"// Unknown variant ID: {instr.arg}")
      gen.emit("matches = false;")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("push_bool(matches);")
    gen.indent -= 1
    gen.emit("}")

  of opNewRef:
    gen.emit(&"// Create reference")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value val = pop();")
    gen.emit("// Allocate reference structure")
    gen.emit("etch_value* ref_val = malloc(sizeof(etch_value));")
    gen.emit("*ref_val = val;")
    gen.emit("// Push reference as pointer")
    gen.emit("etch_value ref;")
    gen.emit("ref.type = VALUE_REF;")
    gen.emit("ref.data.ptr = ref_val;")
    gen.emit("stack[sp++] = ref;")
    gen.indent -= 1
    gen.emit("}")

  of opDeref:
    gen.emit(&"// Dereference")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value ref = pop();")
    gen.emit("if (ref.type == VALUE_REF && ref.data.ptr != NULL) {")
    gen.indent += 1
    gen.emit("etch_value* val_ptr = (etch_value*)ref.data.ptr;")
    gen.emit("stack[sp++] = *val_ptr;")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("push_nil(); // Null reference")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  of opCast:
    gen.emit(&"// Type cast (type={instr.arg})")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value source = pop();")
    case instr.arg:
    of 1:  # Cast to int
      gen.emit("// Cast to int")
      gen.emit("if (source.type == VALUE_FLOAT) {")
      gen.indent += 1
      gen.emit("push_int((int64_t)source.data.fval);")
      gen.indent -= 1
      gen.emit("} else if (source.type == VALUE_INT) {")
      gen.indent += 1
      gen.emit("stack[sp++] = source;  // Already int")
      gen.indent -= 1
      gen.emit("} else {")
      gen.indent += 1
      gen.emit("fprintf(stderr, \"Runtime error: invalid cast to int\\n\");")
      gen.emit("exit(1);")
      gen.indent -= 1
      gen.emit("}")
    of 2:  # Cast to float
      gen.emit("// Cast to float")
      gen.emit("if (source.type == VALUE_INT) {")
      gen.indent += 1
      gen.emit("push_float((double)source.data.ival);")
      gen.indent -= 1
      gen.emit("} else if (source.type == VALUE_FLOAT) {")
      gen.indent += 1
      gen.emit("stack[sp++] = source;  // Already float")
      gen.indent -= 1
      gen.emit("} else {")
      gen.indent += 1
      gen.emit("fprintf(stderr, \"Runtime error: invalid cast to float\\n\");")
      gen.emit("exit(1);")
      gen.indent -= 1
      gen.emit("}")
    of 3:  # Cast to string
      gen.emit("// Cast to string")
      gen.emit("if (source.type == VALUE_INT) {")
      gen.indent += 1
      gen.emit("char buffer[32];")
      gen.emit("sprintf(buffer, \"%lld\", source.data.ival);")
      gen.emit("push_string(buffer);")
      gen.indent -= 1
      gen.emit("} else if (source.type == VALUE_FLOAT) {")
      gen.indent += 1
      gen.emit("char buffer[32];")
      gen.emit("sprintf(buffer, \"%g\", source.data.fval);")
      gen.emit("push_string(buffer);")
      gen.indent -= 1
      gen.emit("} else {")
      gen.indent += 1
      gen.emit("fprintf(stderr, \"Runtime error: invalid cast to string\\n\");")
      gen.emit("exit(1);")
      gen.indent -= 1
      gen.emit("}")
    else:
      gen.emit("fprintf(stderr, \"Runtime error: unsupported cast type\\n\");")
      gen.emit("exit(1);")
    gen.indent -= 1
    gen.emit("}")

  of opArraySlice:
    gen.emit(&"// Array/String slice")
    gen.emit("{")
    gen.indent += 1
    gen.emit("etch_value end_val = pop();")
    gen.emit("etch_value start_val = pop();")
    gen.emit("etch_value arr_val = pop();")
    gen.emit("")
    gen.emit("if (arr_val.type == VALUE_ARRAY) {")
    gen.indent += 1
    gen.emit("etch_array* src = arr_val.data.aval;")
    gen.emit("int start = (start_val.type == VALUE_INT) ? start_val.data.ival : 0;")
    gen.emit("int end = (end_val.type == VALUE_INT) ? end_val.data.ival : src->length;")
    gen.emit("")
    gen.emit("// Clamp indices")
    gen.emit("if (start < 0) start = 0;")
    gen.emit("if (end > src->length) end = src->length;")
    gen.emit("if (start > end) start = end;")
    gen.emit("")
    gen.emit("// Create new array with sliced elements")
    gen.emit("etch_array* slice = make_array(end - start, src->element_type);")
    gen.emit("for (int i = start; i < end; i++) {")
    gen.indent += 1
    gen.emit("array_push(slice, src->data[i]);")
    gen.indent -= 1
    gen.emit("}")
    gen.emit("")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_ARRAY;")
    gen.emit("result.data.aval = slice;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("} else if (arr_val.type == VALUE_STRING) {")
    gen.indent += 1
    gen.emit("etch_string* src = arr_val.data.sval;")
    gen.emit("int start = (start_val.type == VALUE_INT) ? start_val.data.ival : 0;")
    gen.emit("int end = (end_val.type == VALUE_INT) ? end_val.data.ival : src->length;")
    gen.emit("")
    gen.emit("// Handle negative indices")
    gen.emit("if (start < 0) start = 0;")
    gen.emit("if (end < 0) end = src->length;")
    gen.emit("if (end > src->length) end = src->length;")
    gen.emit("if (start > end) start = end;")
    gen.emit("")
    gen.emit("// Create substring")
    gen.emit("size_t len = end - start;")
    gen.emit("etch_string* slice = malloc(sizeof(etch_string));")
    gen.emit("slice->length = len;")
    gen.emit("slice->data = malloc(len + 1);")
    gen.emit("memcpy(slice->data, src->data + start, len);")
    gen.emit("slice->data[len] = '\\0';")
    gen.emit("push_string(slice);")
    gen.indent -= 1
    gen.emit("} else {")
    gen.indent += 1
    gen.emit("// Not an array or string, push empty array")
    gen.emit("etch_array* empty = make_array(0, VALUE_INT);")
    gen.emit("etch_value result;")
    gen.emit("result.type = VALUE_ARRAY;")
    gen.emit("result.data.aval = empty;")
    gen.emit("stack[sp++] = result;")
    gen.indent -= 1
    gen.emit("}")
    gen.indent -= 1
    gen.emit("}")

  # Optimized opcodes
  of opLoadVarArrayGet:
    gen.emit(&"// Optimized load var and array get: {instr.sarg}")
    gen.emit("push_nil(); // Placeholder")

  of opLoadIntAddVar:
    gen.emit(&"// Optimized load int and add var")
    gen.emit("push_int(0); // Placeholder")

  of opLoadVarIntLt:
    gen.emit(&"// Optimized load var int less than")
    gen.emit("push_bool(false); // Placeholder")

proc compileFunction(gen: var CCodeGen, name: string, startIdx: int, endIdx: int) =
  ## Compile a function from bytecode instructions
  gen.currentFunction = name
  let funcName = sanitizeName(name)

  # Reset local variables tracking for this function
  gen.localVars.clear()
  gen.nextVarIndex = 0

  # Collect jump targets first
  var labels = initTable[int, string]()
  for i in startIdx..endIdx:
    let instr = gen.prog.instructions[i]
    if instr.op == opJump or instr.op == opJumpIfFalse:
      let target = int(instr.arg)
      # Only create labels for targets within this function's range
      if target >= startIdx and target <= endIdx:
        if not labels.hasKey(target):
          labels[target] = gen.newLabel()

  # Generate function
  if name == MAIN_FUNCTION_NAME:
    gen.emit("int main() {")
  else:
    gen.emit(&"void {funcName}() {{")

  gen.indent += 1

  # Declare local variables array
  gen.emit("etch_value locals[100]; // Local variables storage")
  gen.emit("")

  # Handle function parameters
  # Parse function name to get parameter info
  # Function names are mangled like "test__i_v" where i = int parameter, v = void return
  if name != MAIN_FUNCTION_NAME and name.contains("__"):
    let parts = name.split("__")
    if parts.len >= 2:
      let baseName = parts[0]
      let signature = parts[1]
      # Parse parameter types from signature (everything before the last underscore)
      let lastUnderscore = signature.rfind('_')
      if lastUnderscore > 0:
        let paramSignature = signature[0..<lastUnderscore]

        # Parse parameter types - handle primitive types as individual characters
        var paramTypes: seq[string] = @[]
        for pt in paramSignature.split('_'):
          if pt == "": continue
          # Handle multi-character type codes like "U123" for user types
          if pt.startsWith("U"):
            paramTypes.add(pt)
          else:
            # Split into individual characters for primitive types
            for ch in pt:
              paramTypes.add($ch)

        # Pop parameters from stack and store in locals
        if paramTypes.len > 0:
          gen.emit("// Pop function parameters from stack")

          # Try to get actual parameter names from functionInfo
          var paramNames: seq[string] = @[]
          if gen.prog.functionInfo.hasKey(name):
            paramNames = gen.prog.functionInfo[name].parameterNames

          # Parameters are already on the stack in order (pushed by caller)
          var paramIdx = 0
          for ptype in paramTypes:
            # Use actual parameter name if available, otherwise fallback to generic name
            var paramName = ""
            if paramIdx < paramNames.len:
              paramName = paramNames[paramIdx]
            else:
              # Fallback to generic names
              # For object types (starting with U), use 'p' as convention
              if ptype.startsWith("U"):
                paramName = "p"
              else:
                case paramIdx
                of 0: paramName = "x"
                of 1: paramName = "y"
                of 2: paramName = "z"
                else: paramName = &"param{paramIdx}"

            # Store parameter in locals
            gen.localVars[paramName] = paramIdx
            gen.emit(&"locals[{paramIdx}] = pop(); // Parameter: {paramName}")
            inc paramIdx
            inc gen.nextVarIndex
          gen.emit("")

  # Compile instructions, but skip redundant initial operations
  var skipNext = false
  for i in startIdx..endIdx:
    let instr = gen.prog.instructions[i]
    # Skip the initial push 0 + return pattern at the beginning
    if i == startIdx and instr.op == opLoadInt and instr.arg == 0:
      if i + 1 <= endIdx and gen.prog.instructions[i + 1].op == opReturn:
        skipNext = true
        continue
    if skipNext:
      skipNext = false
      continue

    gen.compileInstruction(instr, i, labels)

  gen.indent -= 1
  gen.emit("}")
  gen.emit("")

proc generateC*(prog: BytecodeProgram, verbose: bool = false): string =
  ## Generate C code from bytecode program
  var gen = initCCodeGen(prog, verbose)

  # Emit runtime support
  gen.emitRuntime()

  # Build function ranges from the functions table
  var functionRanges = initTable[string, tuple[start: int, endIdx: int]]()

  # Sort functions by their start instruction
  var sortedFuncs: seq[tuple[name: string, start: int]] = @[]
  for fname, startIdx in prog.functions:
    sortedFuncs.add((fname, startIdx))
  sortedFuncs.sort(proc(a, b: tuple[name: string, start: int]): int = cmp(a.start, b.start))

  # Determine function boundaries
  for i in 0..<sortedFuncs.len:
    let fname = sortedFuncs[i].name
    let startIdx = sortedFuncs[i].start
    let endIdx = if i + 1 < sortedFuncs.len:
      sortedFuncs[i + 1].start - 1
    else:
      prog.instructions.high

    # Skip built-in functions (they start at 0 and don't have real implementations)
    if startIdx > 0 or fname == MAIN_FUNCTION_NAME or (endIdx > startIdx):
      functionRanges[fname] = (startIdx, endIdx)
      if verbose:
        echo &"[C BACKEND] Function {fname}: instructions {startIdx}..{endIdx}"

  # Generate forward declarations for all functions
  for fname in functionRanges.keys:
    if fname != MAIN_FUNCTION_NAME:
      # Generate a simple void function declaration for now
      gen.emit(&"void {sanitizeName(fname)}();")

  if functionRanges.len > 0:
    gen.emit("")

  # Compile each function
  for fname, (startIdx, endIdx) in functionRanges:
    if endIdx >= startIdx:  # Only compile if we have instructions
      gen.compileFunction(fname, startIdx, endIdx)

  return gen.code.join("\n")

proc compileToC*(bytecodeFile: string, outputFile: string, verbose: bool = false) =
  ## Load bytecode and compile to C
  let prog = loadBytecode(bytecodeFile)
  let cCode = generateC(prog, verbose)
  writeFile(outputFile, cCode)
  if verbose:
    echo &"[C BACKEND] Generated C code written to {outputFile}"
