proc emitConstantValue(gen: var CGenerator, value: V, target: string) =
  ## Emit C code that assigns a VirtualMachine constant to the specified target (EtchV l-value)
  case value.kind
  of vkInt:
    gen.emit(&"{target} = etch_make_int({value.ival});")
  of vkFloat:
    gen.emit(&"{target} = etch_make_float({value.fval});")
  of vkBool:
    gen.emit(&"{target} = etch_make_bool({($value.bval).toLowerAscii()});")
  of vkChar:
    let ch =
      case value.cval
      of '\\': "\\\\"
      of '\'': "\\'"
      of '\n': "\\n"
      of '\t': "\\t"
      of '\r': "\\r"
      else: $value.cval
    gen.emit(&"{target} = etch_make_char('{ch}');")
  of vkNil:
    gen.emit(&"{target} = etch_make_nil();")
  of vkNone:
    gen.emit(&"{target} = etch_make_none();")
  of vkString:
    gen.emit(&"{target} = etch_make_string(\"{escapeCString(value.sval)}\");")
  of vkArray:
    let length = if value.aval != nil: value.aval[].len else: 0
    gen.emit(&"{target} = etch_make_array({length});")
    if length > 0:
      gen.emit(&"{target}.aval.len = {length};")
      for idx, elem in value.aval[]:
        emitConstantValue(gen, elem, &"{target}.aval.data[{idx}]")
  of vkSome, vkOk, vkErr:
    gen.emit(&"{target} = etch_make_nil(); // TODO: serialized option/result constant")
  of vkEnum:
    # Create enum constant with string value if available
    if value.enumStringVal.len > 0:
      gen.emit(&"{target} = etch_make_enum({value.enumTypeId}, {value.enumIntVal}); // Enum constant")
      gen.emit(&"{target}.enumVal.enumStringVal = strdup(\"{escapeCString(value.enumStringVal)}\");")
    else:
      gen.emit(&"{target} = etch_make_enum({value.enumTypeId}, {value.enumIntVal}); // Enum constant")
  of vkTypeDesc:
    gen.emit(&"{target} = etch_make_typedesc(\"{escapeCString(value.typeDescName)}\");")
  else:
    gen.emit(&"{target} = etch_make_nil(); // TODO: constant kind {value.kind} not handled")

proc emitConstantPool(gen: var CGenerator) =
  ## Emit the constant pool as a C array
  let poolSize = max(1, gen.program.constants.len)
  gen.emit(&"\n// Constant pool ({gen.program.constants.len} etch_constants)")
  gen.emit(&"#define ETCH_CONST_POOL_SIZE {poolSize}")
  gen.emit(&"EtchV etch_constants[{poolSize}];")
  gen.emit("\nvoid etch_init_constants(void) {")
  gen.incIndent()

  for i, constant in gen.program.constants:
    gen.emit("{")
    gen.incIndent()
    emitConstantValue(gen, constant, &"etch_constants[{i}]")
    gen.decIndent()
    gen.emit("}")

  gen.decIndent()
  gen.emit("}")
