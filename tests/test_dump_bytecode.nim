import std/osproc
import ../src/etch/interpreter/[regvm, regvm_serialize]

# Compile the example first
discard execProcess("./etch examples/fn_order.etch")

let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")

echo "Entry point: ", prog.entryPoint
echo "\nInstructions:"
for i, instr in prog.instructions:
  echo "PC ", i, ": op=", instr.op, " debug: line=", instr.debug.line, " file=", instr.debug.sourceFile
