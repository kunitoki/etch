import std/[unittest]
import ../src/etch/core/[vm, vm_types]
import ../src/etch/bytecode/serialize
import test_utils

suite "Bytecode Dumping":
  let etchExe = findEtchExecutable()

  test "Bytecode can be loaded and inspected":
    # Compile the example first using --gen vm (now supports caching)
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    let prog = loadBytecode("examples/__etch__/fn_order.etcx")

    # Verify bytecode loaded correctly
    check prog.entryPoint >= 0
    check prog.instructions.len > 0

  test "Instructions have debug information":
    # Compile the example first using --gen vm (now supports caching)
    check compileEtchFile(etchExe, "examples/fn_order.etch")

    let prog = loadBytecode("examples/__etch__/fn_order.etcx")

    # Check that at least some instructions have debug info
    var hasDebugInfo = false
    for i, instr in prog.instructions:
      if i < prog.debugInfo.len and prog.debugInfo[i].line > 0:
        hasDebugInfo = true
        break

    check hasDebugInfo
