# vm.nim
# Simple AST interpreter acting as Etch VM (used both at runtime and for comptime eval)

import std/[tables, options, strformat, strutils, math, times, random]
import ast, bytecode

type
  V* = object
    kind*: TypeKind
    ival*: int64
    fval*: float64
    bval*: bool
    sval*: string
    # Ref represented as reference to heap slot
    refId*: int
    # Array represented as sequence of values
    aval*: seq[V]

  HeapCell = ref object
    alive: bool
    val: V

  Frame* = ref object
    vars*: Table[string, V]
    returnAddress*: int  # For bytecode execution

  VM* = ref object
    # AST interpreter state
    heap*: seq[HeapCell]
    funs*: Table[string, FunDecl]
    injectedStmts*: seq[Stmt]  # Queue for statements to inject from comptime

    # Bytecode interpreter state
    stack*: seq[V]
    callStack*: seq[Frame]
    program*: BytecodeProgram
    pc*: int  # Program counter
    globals*: Table[string, V]
    mode*: VMMode

  VMMode* = enum
    vmAST,      # AST interpretation mode
    vmBytecode  # Bytecode execution mode

proc vInt(x: int64): V = V(kind: tkInt, ival: x)
proc vFloat(x: float64): V = V(kind: tkFloat, fval: x)
proc vString(x: string): V = V(kind: tkString, sval: x)
proc vBool(x: bool): V = V(kind: tkBool, bval: x)
proc vRef(id: int): V = V(kind: tkRef, refId: id)
proc vArray(elements: seq[V]): V = V(kind: tkArray, aval: elements)

proc alloc(vm: VM; v: V): V =
  vm.heap.add HeapCell(alive: true, val: v)
  vRef(vm.heap.high)

proc loadVar(fr: Frame; name: string): V =
  if not fr.vars.hasKey(name): raise newException(ValueError, "VM unknown var " & name)
  fr.vars[name]

#proc storeVar(fr: Frame; name: string; v: V) =
#  fr.vars[name] = v

proc truthy(v: V): bool =
  case v.kind
  of tkBool: v.bval
  of tkInt: v.ival != 0
  of tkFloat: v.fval != 0.0
  else: false

proc evalExpr*(vm: VM; fr: Frame; e: Expr): V =
  case e.kind
  of ekInt: return vInt(e.ival)
  of ekFloat: return vFloat(e.fval)
  of ekString: return vString(e.sval)
  of ekBool: return vBool(e.bval)
  of ekVar:  return loadVar(fr, e.vname)
  of ekUn:
    let a = vm.evalExpr(fr, e.ue)
    case e.uop
    of uoNeg: return vInt(-a.ival)
    of uoNot: return vBool(not truthy(a))
  of ekBin:
    let a = vm.evalExpr(fr, e.lhs)
    let b = vm.evalExpr(fr, e.rhs)
    case e.bop
    of boAdd:
      if a.kind == tkInt: return vInt(a.ival + b.ival)
      else: return vFloat(a.fval + b.fval)
    of boSub:
      if a.kind == tkInt: return vInt(a.ival - b.ival)
      else: return vFloat(a.fval - b.fval)
    of boMul:
      if a.kind == tkInt: return vInt(a.ival * b.ival)
      else: return vFloat(a.fval * b.fval)
    of boDiv:
      if a.kind == tkInt: return vInt(a.ival div b.ival)
      else: return vFloat(a.fval / b.fval)
    of boMod:
      if a.kind == tkInt: return vInt(a.ival mod b.ival)
      else: return vFloat(math.mod(a.fval, b.fval))
    of boEq:
      if a.kind == tkInt: return vBool(a.ival == b.ival)
      else: return vBool(a.fval == b.fval)
    of boNe:
      if a.kind == tkInt: return vBool(a.ival != b.ival)
      else: return vBool(a.fval != b.fval)
    of boLt:
      if a.kind == tkInt: return vBool(a.ival < b.ival)
      else: return vBool(a.fval < b.fval)
    of boLe:
      if a.kind == tkInt: return vBool(a.ival <= b.ival)
      else: return vBool(a.fval <= b.fval)
    of boGt:
      if a.kind == tkInt: return vBool(a.ival > b.ival)
      else: return vBool(a.fval > b.fval)
    of boGe:
      if a.kind == tkInt: return vBool(a.ival >= b.ival)
      else: return vBool(a.fval >= b.fval)
    of boAnd: return vBool(a.truthy and b.truthy)
    of boOr:  return vBool(a.truthy or b.truthy)
  of ekCall:
    # builtins
    if e.fname == "print":
      let vv = vm.evalExpr(fr, e.args[0])
      case vv.kind
      of tkBool: echo (if vv.bval: "true" else: "false")
      of tkInt: echo vv.ival
      of tkFloat: echo vv.fval
      of tkString: echo vv.sval
      else: echo "<ref>"
      return V(kind: tkVoid)
    if e.fname == "newref":
      let vv = vm.evalExpr(fr, e.args[0])
      return vm.alloc(vv)
    if e.fname == "deref":
      let rr = vm.evalExpr(fr, e.args[0])
      if rr.kind != tkRef: raise newException(ValueError, "deref on non-ref")
      let cell = vm.heap[rr.refId]
      if cell.isNil or not cell.alive: raise newException(ValueError, "nil ref")
      return cell.val
    if e.fname == "rand":
      # rand(max, [min]) - generate random int from min to max (inclusive)
      let maxVal = vm.evalExpr(fr, e.args[0])
      let minVal = if e.args.len > 1: vm.evalExpr(fr, e.args[1]) else: vInt(0)
      if maxVal.kind != tkInt or minVal.kind != tkInt:
        raise newException(ValueError, "rand arguments must be int")
      let minI = minVal.ival
      let maxI = maxVal.ival
      if minI > maxI:
        raise newException(ValueError, "rand: min cannot be greater than max")
      # Simple random generation using system time (not cryptographically secure)
      let range = maxI - minI + 1
      if range <= 0:
        raise newException(ValueError, "rand: invalid range")
      # Use current time in nanoseconds as seed for simple randomness
      let timeVal = getTime().toUnix() * 1000000 + getTime().nanosecond
      let res = minI + (timeVal mod range)
      return vInt(int64(res))
    if e.fname == "seed":
      # seed(value) - set random seed for deterministic testing
      if e.args.len != 1: raise newException(ValueError, "seed expects 1 arg")
      let seedVal = vm.evalExpr(fr, e.args[0])
      if seedVal.kind != tkInt: raise newException(ValueError, "seed expects int")
      randomize(int(seedVal.ival))
      return V(kind: tkVoid)
    if e.fname.startsWith("assume"): return V(kind: tkVoid)
    if e.fname == "readFile":
      if e.args.len != 1: raise newException(ValueError, "readFile expects 1 arg")
      let pathArg = vm.evalExpr(fr, e.args[0])
      if pathArg.kind != tkString: raise newException(ValueError, "readFile expects string path")
      try:
        let content = readFile(pathArg.sval)
        return vString(content)
      except:
        return vString("") # Return empty string on error
    if e.fname == "inject":
      if e.args.len != 3: raise newException(ValueError, "inject expects 3 args: name, type, value")
      let nameArg = vm.evalExpr(fr, e.args[0])
      let typeArg = vm.evalExpr(fr, e.args[1])
      let valueArg = vm.evalExpr(fr, e.args[2])

      if nameArg.kind != tkString or typeArg.kind != tkString:
        raise newException(ValueError, "inject name and type must be strings")

      # Create the appropriate type
      var varType: EtchType
      case typeArg.sval
      of "int": varType = tInt()
      of "string": varType = tString()
      of "bool": varType = tBool()
      else: raise newException(ValueError, "inject: unsupported type " & typeArg.sval)

      # Create initialization expression based on value
      var initExpr: Expr
      case typeArg.sval
      of "string":
        if valueArg.kind != tkString:
          raise newException(ValueError, "inject: string value must be string")
        initExpr = Expr(kind: ekString, sval: valueArg.sval, typ: tString(), pos: Pos(line: 0, col: 0, filename: ""))
      of "int":
        if valueArg.kind != tkInt:
          raise newException(ValueError, "inject: int value must be int")
        initExpr = Expr(kind: ekInt, ival: valueArg.ival, typ: tInt(), pos: Pos(line: 0, col: 0, filename: ""))
      of "bool":
        if valueArg.kind != tkBool:
          raise newException(ValueError, "inject: bool value must be bool")
        initExpr = Expr(kind: ekBool, bval: valueArg.bval, typ: tBool(), pos: Pos(line: 0, col: 0, filename: ""))
      else:
        raise newException(ValueError, "inject: unsupported type")

      # Create variable statement
      let stmt = Stmt(
        kind: skVar,
        vname: nameArg.sval,
        vtype: varType,
        vinit: some(initExpr),
        pos: Pos(line: 0, col: 0, filename: "")
      )

      # Add to injection queue
      vm.injectedStmts.add(stmt)
      return V(kind: tkVoid)
    # user functions (monomorphized name)
    if not vm.funs.hasKey(e.fname):
      raise newException(ValueError, "VM unknown function " & e.fname)
    let fn = vm.funs[e.fname]
    var newF = Frame(vars: initTable[string, V]())
    # Copy globals to new frame
    for k, v in fr.vars:
      newF.vars[k] = v
    for i, p in fn.params:
      if i < e.args.len:
        # Use provided argument
        newF.vars[p.name] = vm.evalExpr(fr, e.args[i])
      elif p.defaultValue.isSome:
        # Use default value
        newF.vars[p.name] = vm.evalExpr(fr, p.defaultValue.get)
      else:
        # This should not happen if type checker is correct
        raise newException(ValueError, &"Missing argument for parameter {p.name}")
    # run body
    for st in fn.body:
      # emulate returns via exception-lite
      case st.kind
      of skReturn:
        if st.re.isSome():
          return vm.evalExpr(newF, st.re.get())
        else:
          return V(kind: tkVoid)
      of skVar:
        if st.vinit.isSome():
          newF.vars[st.vname] = vm.evalExpr(newF, st.vinit.get())
        else:
          newF.vars[st.vname] = vInt(0)
      of skAssign:
        newF.vars[st.aname] = vm.evalExpr(newF, st.aval)
      of skIf:
        var executed = false
        # Check main condition
        if vm.evalExpr(newF, st.cond).truthy:
          executed = true
          for ss in st.thenBody:
            if ss.kind == skReturn:
              if ss.re.isSome(): return vm.evalExpr(newF, ss.re.get())
              return V(kind: tkVoid)
            elif ss.kind == skExpr:
              discard vm.evalExpr(newF, ss.sexpr)
            else:
              # RECURSE shallowly
              case ss.kind
              of skVar:
                if ss.vinit.isSome(): newF.vars[ss.vname] = vm.evalExpr(newF, ss.vinit.get())
                else: newF.vars[ss.vname] = vInt(0)
              of skAssign:
                newF.vars[ss.aname] = vm.evalExpr(newF, ss.aval)
              else: discard

        # Check elif chain
        if not executed:
          for elifBranch in st.elifChain:
            if vm.evalExpr(newF, elifBranch.cond).truthy:
              executed = true
              for ss in elifBranch.body:
                if ss.kind == skReturn:
                  if ss.re.isSome(): return vm.evalExpr(newF, ss.re.get())
                  return V(kind: tkVoid)
                elif ss.kind == skExpr:
                  discard vm.evalExpr(newF, ss.sexpr)
                else:
                  # RECURSE shallowly
                  case ss.kind
                  of skVar:
                    if ss.vinit.isSome(): newF.vars[ss.vname] = vm.evalExpr(newF, ss.vinit.get())
                    else: newF.vars[ss.vname] = vInt(0)
                  of skAssign:
                    newF.vars[ss.aname] = vm.evalExpr(newF, ss.aval)
                  else: discard
              break

        # Execute else branch if nothing else executed
        if not executed:
          for ss in st.elseBody:
            if ss.kind == skReturn:
              if ss.re.isSome(): return vm.evalExpr(newF, ss.re.get())
              return V(kind: tkVoid)
            elif ss.kind == skExpr:
              discard vm.evalExpr(newF, ss.sexpr)
      of skWhile:
        while vm.evalExpr(newF, st.wcond).truthy:
          for ss in st.wbody:
            if ss.kind == skReturn:
              if ss.re.isSome(): return vm.evalExpr(newF, ss.re.get())
              return V(kind: tkVoid)
            elif ss.kind == skExpr:
              discard vm.evalExpr(newF, ss.sexpr)
            elif ss.kind == skAssign:
              newF.vars[ss.aname] = vm.evalExpr(newF, ss.aval)
            elif ss.kind == skVar:
              if ss.vinit.isSome(): newF.vars[ss.vname] = vm.evalExpr(newF, ss.vinit.get())
              else: newF.vars[ss.vname] = vInt(0)
      of skComptime:
        # Comptime blocks should be empty by runtime (executed during compilation)
        discard
      of skExpr:
        discard vm.evalExpr(newF, st.sexpr)
    return V(kind: tkVoid)
  of ekComptime:
    # By the time VM sees this at runtime it should be replaced; but just eval inner:
    return vm.evalExpr(fr, e.inner)
  of ekNewRef:
    let vv = vm.evalExpr(fr, e.init)
    return vm.alloc(vv)
  of ekDeref:
    let rr = vm.evalExpr(fr, e.refExpr)
    if rr.kind != tkRef: raise newException(ValueError, "deref on non-ref")
    let cell = vm.heap[rr.refId]
    if cell.isNil or not cell.alive: raise newException(ValueError, "nil ref")
    return cell.val
  of ekArray:
    # Evaluate all elements and create array
    var elements: seq[V] = @[]
    for elem in e.elements:
      elements.add(vm.evalExpr(fr, elem))
    return vArray(elements)
  of ekIndex:
    # Evaluate array and index
    let arr = vm.evalExpr(fr, e.arrayExpr)
    let idx = vm.evalExpr(fr, e.indexExpr)
    if arr.kind != tkArray: raise newException(ValueError, "indexing on non-array")
    if idx.kind != tkInt: raise newException(ValueError, "array index must be int")
    if idx.ival < 0 or idx.ival >= arr.aval.len:
      raise newException(ValueError, &"array index {idx.ival} out of bounds [0, {arr.aval.len-1}]")
    return arr.aval[idx.ival]
  of ekSlice:
    # Evaluate array
    let arr = vm.evalExpr(fr, e.sliceExpr)
    if arr.kind != tkArray: raise newException(ValueError, "slicing on non-array")

    # Evaluate start and end indices
    let startIdx = if e.startExpr.isSome:
                     let s = vm.evalExpr(fr, e.startExpr.get)
                     if s.kind != tkInt: raise newException(ValueError, "slice start must be int")
                     max(0, s.ival)
                   else:
                     0
    let endIdx = if e.endExpr.isSome:
                   let e = vm.evalExpr(fr, e.endExpr.get)
                   if e.kind != tkInt: raise newException(ValueError, "slice end must be int")
                   min(arr.aval.len, e.ival)
                 else:
                   arr.aval.len

    # Create slice (ensure valid bounds)
    let actualStart = max(0, min(startIdx, arr.aval.len))
    let actualEnd = max(actualStart, min(endIdx, arr.aval.len))

    if actualStart >= actualEnd:
      return vArray(@[])  # Empty array
    else:
      return vArray(arr.aval[actualStart..<actualEnd])
  of ekArrayLen:
    # Array length operator: #array -> int
    let arr = vm.evalExpr(fr, e.lenExpr)
    if arr.kind != tkArray: raise newException(ValueError, "length operator # on non-array")
    return vInt(arr.aval.len.int64)
  of ekCast:
    # Explicit cast: evaluate source expression and convert to target type
    let source = vm.evalExpr(fr, e.castExpr)
    case e.castType.kind
    of tkInt:
      case source.kind
      of tkFloat: return vInt(source.fval.int64)
      else: raise newException(ValueError, "invalid cast to int")
    of tkFloat:
      case source.kind
      of tkInt: return vFloat(source.ival.float64)
      else: raise newException(ValueError, "invalid cast to float")
    of tkString:
      case source.kind
      of tkInt: return vString($source.ival)
      of tkFloat: return vString($source.fval)
      else: raise newException(ValueError, "invalid cast to string")
    else: raise newException(ValueError, "unsupported cast type")
  of ekNil:
    # nil reference
    return vRef(-1)  # Use -1 to indicate nil reference

proc runMain*(prog: Program; mainName="main") =
  # collect instantiated functions + main
  var vm = VM(mode: vmAST, heap: @[], funs: initTable[string, FunDecl]())
  for k, f in prog.funInstances: vm.funs[k] = f
  # Allow non-generic main as 'main<>' too
  if prog.funInstances.hasKey("main<>"):
    vm.funs["main<>"] = prog.funInstances["main<>"]
  # Execute globals: assign default 0/int or false/bool by VM on demand
  var fr = Frame(vars: initTable[string, V]())
  for g in prog.globals:
    case g.kind
    of skVar:
      if g.vinit.isSome(): fr.vars[g.vname] = vm.evalExpr(fr, g.vinit.get())
      else: fr.vars[g.vname] = vInt(0)
    else: discard
  if vm.funs.hasKey("main") or vm.funs.hasKey("main<>"):
    discard vm.evalExpr(fr, Expr(kind: ekCall, fname: (if vm.funs.hasKey("main"): "main" else: "main<>"), args: @[], pos: Pos(line:0,col:0,filename:"")))
  else:
    raise newException(ValueError, "No main() function found")

# Bytecode VM functionality
proc push(vm: VM; val: V) =
  vm.stack.add(val)

proc pop(vm: VM): V =
  if vm.stack.len == 0:
    raise newException(ValueError, "Stack underflow")
  result = vm.stack[^1]
  vm.stack.setLen(vm.stack.len - 1)

proc peek(vm: VM): V =
  if vm.stack.len == 0:
    raise newException(ValueError, "Stack empty")
  vm.stack[^1]

proc getVar(vm: VM, name: string): V =
  # Check current frame first
  if vm.callStack.len > 0:
    let frame = vm.callStack[^1]
    if frame.vars.hasKey(name):
      return frame.vars[name]

  # Check globals
  if vm.globals.hasKey(name):
    return vm.globals[name]

  raise newException(ValueError, "Unknown variable: " & name)

proc setVar(vm: VM, name: string, value: V) =
  # Set in current frame if we're in a function, otherwise global
  if vm.callStack.len > 0:
    vm.callStack[^1].vars[name] = value
  else:
    vm.globals[name] = value

proc executeInstruction*(vm: VM): bool =
  ## Execute a single bytecode instruction. Returns false when program should halt.
  if vm.pc >= vm.program.instructions.len:
    return false

  let instr = vm.program.instructions[vm.pc]
  vm.pc += 1

  case instr.op
  of opLoadInt:
    vm.push(vInt(instr.arg))
  of opLoadFloat:
    let floatStr = vm.program.constants[instr.arg]
    vm.push(vFloat(parseFloat(floatStr)))
  of opLoadString:
    let str = vm.program.constants[instr.arg]
    vm.push(vString(str))
  of opLoadBool:
    vm.push(vBool(instr.arg != 0))
  of opLoadVar:
    let val = vm.getVar(instr.sarg)
    vm.push(val)
  of opStoreVar:
    let val = vm.pop()
    vm.setVar(instr.sarg, val)
  of opAdd:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vInt(a.ival + b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vFloat(a.fval + b.fval))
    else:
      raise newException(ValueError, "Type mismatch in addition")
  of opSub:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vInt(a.ival - b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vFloat(a.fval - b.fval))
    else:
      raise newException(ValueError, "Type mismatch in subtraction")
  of opMul:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vInt(a.ival * b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vFloat(a.fval * b.fval))
    else:
      raise newException(ValueError, "Type mismatch in multiplication")
  of opDiv:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      if b.ival == 0:
        raise newException(ValueError, "Division by zero")
      vm.push(vInt(a.ival div b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      if b.fval == 0.0:
        raise newException(ValueError, "Division by zero")
      vm.push(vFloat(a.fval / b.fval))
    else:
      raise newException(ValueError, "Type mismatch in division")
  of opMod:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      if b.ival == 0:
        raise newException(ValueError, "Modulo by zero")
      vm.push(vInt(a.ival mod b.ival))
    else:
      raise newException(ValueError, "Modulo requires integers")
  of opEq:
    let b = vm.pop()
    let a = vm.pop()
    let res = case a.kind:
      of tkInt: a.ival == b.ival
      of tkFloat: a.fval == b.fval
      of tkBool: a.bval == b.bval
      of tkString: a.sval == b.sval
      else: false
    vm.push(vBool(res))
  of opNe:
    let b = vm.pop()
    let a = vm.pop()
    let res = case a.kind:
      of tkInt: a.ival != b.ival
      of tkFloat: a.fval != b.fval
      of tkBool: a.bval != b.bval
      of tkString: a.sval != b.sval
      else: true
    vm.push(vBool(res))
  of opLt:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vBool(a.ival < b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vBool(a.fval < b.fval))
    else:
      raise newException(ValueError, "Type mismatch in comparison")
  of opLe:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vBool(a.ival <= b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vBool(a.fval <= b.fval))
    else:
      raise newException(ValueError, "Type mismatch in comparison")
  of opGt:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vBool(a.ival > b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vBool(a.fval > b.fval))
    else:
      raise newException(ValueError, "Type mismatch in comparison")
  of opGe:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkInt and b.kind == tkInt:
      vm.push(vBool(a.ival >= b.ival))
    elif a.kind == tkFloat and b.kind == tkFloat:
      vm.push(vBool(a.fval >= b.fval))
    else:
      raise newException(ValueError, "Type mismatch in comparison")
  of opAnd:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkBool and b.kind == tkBool:
      vm.push(vBool(a.bval and b.bval))
    else:
      raise newException(ValueError, "Logical AND requires bools")
  of opOr:
    let b = vm.pop()
    let a = vm.pop()
    if a.kind == tkBool and b.kind == tkBool:
      vm.push(vBool(a.bval or b.bval))
    else:
      raise newException(ValueError, "Logical OR requires bools")
  of opNot:
    let a = vm.pop()
    if a.kind == tkBool:
      vm.push(vBool(not a.bval))
    else:
      raise newException(ValueError, "Logical NOT requires bool")
  of opNeg:
    let a = vm.pop()
    if a.kind == tkInt:
      vm.push(vInt(-a.ival))
    elif a.kind == tkFloat:
      vm.push(vFloat(-a.fval))
    else:
      raise newException(ValueError, "Negation requires numeric type")
  of opJump:
    vm.pc = int(instr.arg)
  of opJumpIfFalse:
    let condition = vm.pop()
    if not truthy(condition):
      vm.pc = int(instr.arg)
  of opCall:
    let funcName = instr.sarg
    let argCount = int(instr.arg)

    # Handle builtin functions using enhanced AST interpreter built-ins
    if funcName == "print":
      let arg = vm.pop()
      case arg.kind
      of tkString: echo arg.sval
      of tkInt: echo arg.ival
      of tkFloat: echo arg.fval
      of tkBool: echo if arg.bval: "true" else: "false"
      else: echo "<ref>"
      vm.push(V(kind: tkVoid))
      return true

    if funcName == "newref":
      let arg = vm.pop()
      let refVal = vm.alloc(arg)
      vm.push(refVal)
      return true

    if funcName == "deref":
      let refVal = vm.pop()
      if refVal.kind != tkRef:
        raise newException(ValueError, "deref on non-ref")
      let cell = vm.heap[refVal.refId]
      if cell.isNil or not cell.alive:
        raise newException(ValueError, "nil ref")
      vm.push(cell.val)
      return true

    if funcName == "rand":
      if argCount == 1:
        let maxVal = vm.pop()
        if maxVal.kind == tkInt and maxVal.ival > 0:
          let res = rand(int(maxVal.ival))
          vm.push(vInt(int64(res)))
        else:
          vm.push(vInt(0))
      elif argCount == 2:
        # Stack order: args are pushed in reverse, so we pop them in original order
        # For rand(max, min): first pop gets max, second pop gets min
        let maxVal = vm.pop()  # This is args[0] (max = 100)
        let minVal = vm.pop()  # This is args[1] (min = 20)
        if maxVal.kind == tkInt and minVal.kind == tkInt and maxVal.ival >= minVal.ival:
          let res = rand(int(maxVal.ival - minVal.ival)) + int(minVal.ival)
          vm.push(vInt(int64(res)))
        else:
          vm.push(vInt(0))
      return true

    if funcName == "seed":
      if argCount == 1:
        let seedVal = vm.pop()
        if seedVal.kind == tkInt:
          randomize(int(seedVal.ival))
        vm.push(V(kind: tkVoid))
      return true

    if funcName == "readFile":
      if argCount == 1:
        let pathArg = vm.pop()
        if pathArg.kind == tkString:
          try:
            let content = readFile(pathArg.sval)
            vm.push(vString(content))
          except:
            vm.push(vString(""))
        else:
          vm.push(vString(""))
      return true

    # User-defined function call
    if not vm.program.functions.hasKey(funcName):
      raise newException(ValueError, "Unknown function: " & funcName)

    # Create new frame
    let newFrame = Frame(
      vars: initTable[string, V](),
      returnAddress: vm.pc
    )

    # Pop arguments and collect them (they're already in reverse order from stack)
    var args: seq[V] = @[]
    for i in 0..<argCount:
      args.add(vm.pop())  # Add to end - this gives us correct parameter order

    # Get parameter names from function debug info
    if vm.program.functionDebugInfo.hasKey(funcName):
      let debugInfo = vm.program.functionDebugInfo[funcName]
      for i in 0..<min(args.len, debugInfo.parameterNames.len):
        newFrame.vars[debugInfo.parameterNames[i]] = args[i]
    else:
      # Fallback: use generic parameter names if debug info is not available
      for i in 0..<args.len:
        newFrame.vars["param" & $i] = args[i]

    vm.callStack.add(newFrame)
    vm.pc = vm.program.functions[funcName]
  of opReturn:
    if vm.callStack.len == 0:
      return false  # Exit program

    let frame = vm.callStack.pop()
    vm.pc = frame.returnAddress
  of opNewRef:
    let value = vm.pop()
    let refVal = vm.alloc(value)
    vm.push(refVal)
  of opDeref:
    let refVal = vm.pop()
    if refVal.kind == tkRef:
      if refVal.refId >= 0 and refVal.refId < vm.heap.len:
        let cell = vm.heap[refVal.refId]
        if cell.alive:
          vm.push(cell.val)
        else:
          raise newException(ValueError, "Dereferencing dead reference")
      else:
        raise newException(ValueError, "Invalid reference")
    else:
      raise newException(ValueError, "Deref expects reference")
  of opMakeArray:
    # Pop N elements from stack and create array
    let count = instr.arg
    var elements: seq[V] = @[]
    for i in 0..<count:
      elements.insert(vm.pop(), 0)  # Insert at beginning to maintain order
    vm.push(vArray(elements))
  of opArrayGet:
    # Pop index and array, push element
    let index = vm.pop()
    let array = vm.pop()
    if array.kind != tkArray:
      raise newException(ValueError, "Array get expects array")
    if index.kind != tkInt:
      raise newException(ValueError, "Array index must be int")
    if index.ival < 0 or index.ival >= array.aval.len:
      raise newException(ValueError, &"Array index {index.ival} out of bounds")
    vm.push(array.aval[index.ival])
  of opArraySlice:
    # Pop end, start, array, push slice
    let endVal = vm.pop()
    let startVal = vm.pop()
    let array = vm.pop()
    if array.kind != tkArray:
      raise newException(ValueError, "Array slice expects array")

    let startIdx = if startVal.kind == tkInt and startVal.ival != -1: startVal.ival else: 0
    let endIdx = if endVal.kind == tkInt and endVal.ival != -1: endVal.ival else: array.aval.len

    let actualStart = max(0, min(startIdx, array.aval.len))
    let actualEnd = max(actualStart, min(endIdx, array.aval.len))

    if actualStart >= actualEnd:
      vm.push(vArray(@[]))
    else:
      vm.push(vArray(array.aval[actualStart..<actualEnd]))
  of opArrayLen:
    # Pop array and push its length as int
    let array = vm.pop()
    if array.kind != tkArray:
      raise newException(ValueError, "Array length expects array")
    vm.push(vInt(array.aval.len.int64))
  of opLoadNil:
    # Push nil reference
    vm.push(vRef(-1))
  of opCast:
    # Pop value and cast to target type based on instruction argument
    let source = vm.pop()
    let castTypeCode = instr.arg
    case castTypeCode:
    of 1:  # Cast to int
      case source.kind:
      of tkFloat: vm.push(vInt(source.fval.int64))
      of tkInt: vm.push(source)  # Already int, pass through
      else: raise newException(ValueError, "invalid cast to int")
    of 2:  # Cast to float
      case source.kind:
      of tkInt: vm.push(vFloat(source.ival.float64))
      of tkFloat: vm.push(source)  # Already float, pass through
      else: raise newException(ValueError, "invalid cast to float")
    of 3:  # Cast to string
      case source.kind:
      of tkInt: vm.push(vString($source.ival))
      of tkFloat: vm.push(vString($source.fval))
      else: raise newException(ValueError, "invalid cast to string")
    else: 
      raise newException(ValueError, "unsupported cast type")
  of opPop:
    discard vm.pop()
  of opDup:
    let val = vm.peek()
    vm.push(val)

  return true

proc runBytecode*(vm: VM): int =
  ## Run the bytecode program. Returns exit code.
  try:
    # Initialize globals with stored values
    for globalName in vm.program.globals:
      if vm.program.globalValues.hasKey(globalName):
        let gv = vm.program.globalValues[globalName]
        case gv.kind
        of tkInt:
          vm.globals[globalName] = V(kind: tkInt, ival: gv.ival)
        of tkFloat:
          vm.globals[globalName] = V(kind: tkFloat, fval: gv.fval)
        of tkBool:
          vm.globals[globalName] = V(kind: tkBool, bval: gv.bval)
        of tkString:
          vm.globals[globalName] = V(kind: tkString, sval: gv.sval)
        else:
          vm.globals[globalName] = vInt(0)  # Default for unsupported types
      else:
        vm.globals[globalName] = vInt(0)  # Default initialization

    # Start execution from main function if it exists
    if vm.program.functions.hasKey("main"):
      vm.pc = vm.program.functions["main"]
    else:
      echo "No main function found"
      return 1

    # Execute instructions
    while vm.executeInstruction():
      discard

    return 0
  except Exception as e:
    echo "Runtime error: ", e.msg
    if vm.program.sourceFile.len > 0 and vm.pc > 0 and vm.pc <= vm.program.instructions.len:
      let instr = vm.program.instructions[vm.pc - 1]
      if instr.debug.line > 0:
        echo "  at line ", instr.debug.line, " in ", instr.debug.sourceFile
    return 1

proc newBytecodeVM*(program: BytecodeProgram): VM =
  ## Create a new bytecode VM instance
  VM(
    mode: vmBytecode,
    stack: @[],
    heap: @[],
    callStack: @[],
    program: program,
    pc: 0,
    globals: initTable[string, V]()
  )
