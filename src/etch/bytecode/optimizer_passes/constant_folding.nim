# constant_folding.nim
# Compile-time evaluation of constant expressions

import std/[math, strformat]
import ../../common/logging
import ../../core/[vm, vm_types]


proc isConstantLoad(instr: Instruction): bool =
  ## Check if instruction loads a constant
  instr.op == opLoadK and instr.opType == ifmtABx


proc getConstantValue(instr: Instruction, constants: seq[V]): V =
  ## Get the constant value loaded by opLoadK
  if instr.opType != ifmtABx:
    raise newException(ValueError, "Expected ifmtABx format for opLoadK, got " & $instr.opType)
  constants[instr.bx]


proc canFoldConstants(left: V, right: V, op: OpCode): bool =
  ## Check if we can fold two constants with the given operation
  if left.kind != right.kind:
    return false

  case op:
  of opAdd, opAddInt, opAddFloat, opSub, opSubInt, opSubFloat,
     opMul, opMulInt, opMulFloat, opDiv, opDivInt, opDivFloat,
     opMod, opModInt, opModFloat, opPow:
    return left.kind in {vkInt, vkFloat}
  of opNeStore, opEq, opEqInt, opEqFloat,
     opLt, opLtInt, opLtFloat,
     opLe, opLeInt, opLeFloat,
     opEqStore, opEqStoreInt, opEqStoreFloat,
     opLtStore, opLtStoreInt, opLtStoreFloat,
     opLeStore, opLeStoreInt, opLeStoreFloat:
    return left.kind in {vkInt, vkFloat, vkBool}
  of opAnd, opOr:
    return left.kind == vkBool and right.kind == vkBool
  else:
    return false


proc foldConstants(left: V, right: V, op: OpCode): V =
  ## Fold two constants with the given operation
  case op:
  # Addition
  of opAdd, opAddInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeInt(left.ival + right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval + right.fval)
  of opAddFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval + right.fval)

  # Subtraction
  of opSub, opSubInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeInt(left.ival - right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval - right.fval)
  of opSubFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval - right.fval)

  # Multiplication
  of opMul, opMulInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeInt(left.ival * right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval * right.fval)
  of opMulFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval * right.fval)

  # Division
  of opDiv, opDivInt:
    if left.kind == vkInt and right.kind == vkInt and right.ival != 0:
      return makeInt(left.ival div right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval / right.fval)
  of opDivFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(left.fval / right.fval)

  # Modulo
  of opMod, opModInt:
    if left.kind == vkInt and right.kind == vkInt and right.ival != 0:
      return makeInt(left.ival mod right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(`mod`(left.fval, right.fval))
  of opModFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(`mod`(left.fval, right.fval))

  # Power/Exponentiation
  of opPow:
    if left.kind == vkInt and right.kind == vkInt:
      # For integers, convert to float for pow, then back to int if result is whole
      let floatResult = pow(float64(left.ival), float64(right.ival))
      if floatResult == float64(int64(floatResult)) and floatResult.classify != fcInf:
        return makeInt(int64(floatResult))
      else:
        return makeFloat(floatResult)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeFloat(pow(left.fval, right.fval))

  # Equality
  of opEq, opEqInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival == right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval == right.fval)
    elif left.kind == vkBool and right.kind == vkBool:
      return makeBool(left.bval == right.bval)
  of opEqFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval == right.fval)

  # Inequality
  of opNeStore:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival != right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval != right.fval)
    elif left.kind == vkBool and right.kind == vkBool:
      return makeBool(left.bval != right.bval)

  # Less than
  of opLt, opLtInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival < right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval < right.fval)
  of opLtFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval < right.fval)

  # Less than or equal
  of opLe, opLeInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival <= right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval <= right.fval)
  of opLeFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval <= right.fval)

  # Store comparison results
  of opEqStore:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival == right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval == right.fval)
    elif left.kind == vkBool and right.kind == vkBool:
      return makeBool(left.bval == right.bval)
  of opEqStoreInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival == right.ival)
  of opEqStoreFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval == right.fval)

  of opLtStore:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival < right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval < right.fval)
  of opLtStoreInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival < right.ival)
  of opLtStoreFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval < right.fval)

  of opLeStore:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival <= right.ival)
    elif left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval <= right.fval)
  of opLeStoreInt:
    if left.kind == vkInt and right.kind == vkInt:
      return makeBool(left.ival <= right.ival)
  of opLeStoreFloat:
    if left.kind == vkFloat and right.kind == vkFloat:
      return makeBool(left.fval <= right.fval)

  # Logical operations
  of opAnd:
    if left.kind == vkBool and right.kind == vkBool:
      return makeBool(left.bval and right.bval)
  of opOr:
    if left.kind == vkBool and right.kind == vkBool:
      return makeBool(left.bval or right.bval)

  else:
    discard

  # Fallback - shouldn't reach here if canFoldConstants is correct
  return left


proc optimizeConstantFolding*(instructions: seq[InstructionEntry], constants: var seq[V], verbose: bool = false): seq[InstructionEntry] =
  ## Perform constant folding optimization
  logOptimizer(verbose, "Starting constant folding optimization pass")

  result = instructions
  var foldedCount = 0
  var i = 0

  while i < result.len - 2:
    # Look for pattern: LoadK r1, c1; LoadK r2, c2; Op r3, r1, r2
    let load1 = result[i].instr
    let load2 = result[i+1].instr
    let opInstr = result[i+2].instr

    if isConstantLoad(load1) and isConstantLoad(load2) and
       opInstr.opType == ifmtABC and opInstr.b == load1.a and opInstr.c == load2.a:

      let const1 = getConstantValue(load1, constants)
      let const2 = getConstantValue(load2, constants)

      if canFoldConstants(const1, const2, opInstr.op):
        let foldedValue = foldConstants(const1, const2, opInstr.op)

        # Add the folded constant to the constant pool
        let constIdx = uint16(constants.len)
        constants.add(foldedValue)

        # Replace the three instructions with a single LoadK
        result[i].instr = Instruction(op: opLoadK, opType: ifmtABx, a: opInstr.a, bx: constIdx)
        result[i].debug = result[i+2].debug  # Keep debug info from the operation

        # Mark the other instructions as no-ops
        result[i+1].instr = Instruction(op: opNoOp)
        result[i+2].instr = Instruction(op: opNoOp)

        foldedCount += 1
        logOptimizer(verbose, &"Folded constants at {i}-{i+2}: {const1} {opInstr.op} {const2} -> {foldedValue}")

        i += 3  # Skip the folded instructions
        continue

    i += 1

  if foldedCount > 0:
    logOptimizer(verbose, &"Folded {foldedCount} constant expressions")

  return result
