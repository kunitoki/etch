import std/[options, unittest]
import etch/compiler
import etch/common/types
import etch/bytecode/frontend/ast
import etch/core/[vm, vm_types]

const DebugGlobalsEtch = "tests/test_debug_globals.etch"

proc compileDebugGlobalsBytecode(): (Program, BytecodeProgram) =
  var opts = CompilerOptions(
    sourceFile: DebugGlobalsEtch,
    sourceString: none(string),
    runVirtualMachine: false,
    verbose: false,
    debug: false,
    profile: false,
    force: true,
    gcCycleInterval: none(int)
  )
  let (prog, hash, evalGlobals) = parseAndTypecheck(opts)
  let bytecode = compileProgramWithGlobals(prog, hash, evalGlobals, opts.sourceFile, opts)
  (prog, bytecode)

proc stringConstant(bytecode: BytecodeProgram, idx: int): string =
  if idx >= 0 and idx < bytecode.constants.len:
    let value = bytecode.constants[idx]
    if value.kind == vkString:
      return value.sval
  ""

proc findGlobalInit(bytecode: BytecodeProgram, name: string): int =
  for i, instr in bytecode.instructions:
    if instr.op == opInitGlobal and instr.opType == ifmtABx:
      if stringConstant(bytecode, int(instr.bx)) == name:
        return i
  -1

proc callFunctionName(bytecode: BytecodeProgram, instr: Instruction): string =
  if instr.opType == ifmtCall:
    let idx = int(instr.funcIdx)
    if idx >= 0 and idx < bytecode.functionTable.len:
      return bytecode.functionTable[idx]
  ""

suite "Debug Globals":
  test "Color globals call rgb directly":
    let (_, bytecode) = compileDebugGlobalsBytecode()
    let colorGlobals = @["COLOR_WHITE", "COLOR_DARKGRAY", "COLOR_RED", "COLOR_ORANGE", "COLOR_YELLOW", "COLOR_GREEN", "COLOR_BLUE"]

    for name in colorGlobals:
      let initIdx = findGlobalInit(bytecode, name)
      check initIdx > 0

      let callInstr = bytecode.instructions[initIdx - 1]
      check callInstr.op == opCall
      check callInstr.opType == ifmtCall
      check callFunctionName(bytecode, callInstr) == "rgb::iii:i"
      if callInstr.opType == ifmtCall:
        check callInstr.numArgs == 3
        check callInstr.numResults == 1

  test "Color globals remain let bindings":
    let (prog, _) = compileDebugGlobalsBytecode()
    let colorGlobals = @["COLOR_WHITE", "COLOR_DARKGRAY", "COLOR_RED", "COLOR_ORANGE", "COLOR_YELLOW", "COLOR_GREEN", "COLOR_BLUE"]

    for name in colorGlobals:
      var found = false
      for g in prog.globals:
        if g.kind == skVar and g.vname == name:
          found = true
          check g.vflag == vfLet
          check g.vinit.isSome
      check found
