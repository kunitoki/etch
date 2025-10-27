import std/[unittest, osproc]
import ../src/etch/interpreter/[regvm, regvm_serialize]
import test_utils

suite "Bytecode Dumping":
  let etchExe = findEtchExecutable()

  test "Bytecode can be loaded and inspected":
    # Compile the example first
    discard execProcess(etchExe & " examples/fn_order.etch")

    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")

    # Verify bytecode loaded correctly
    check prog.entryPoint >= 0
    check prog.instructions.len > 0

  test "Instructions have debug information":
    # Compile the example first
    discard execProcess(etchExe & " examples/fn_order.etch")

    let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")

    # Check that at least some instructions have debug info
    var hasDebugInfo = false
    for instr in prog.instructions:
      if instr.debug.line > 0:
        hasDebugInfo = true
        break

    check hasDebugInfo
