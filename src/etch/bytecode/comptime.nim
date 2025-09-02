# comptime.nim
# Compile-time evaluation and injection helpers for Etch

import std/[tables, options]
import ../common/[types]
import ../bytecode/prover/[function_evaluation, types]
import ../bytecode/frontend/ast
import ../bytecode/compiler
import ../core/[vm_execution, vm, vm_types]
import ../bytecode/typechecker/[statements, types as tc_types]



proc hasImpureExpression(e: Expression): bool


proc hasImpureCalls(s: Statement): bool =
  case s.kind
  of skExpression:
    return hasImpureExpression(s.sexpr)
  of skVar:
    if s.vinit.isSome:
      return hasImpureExpression(s.vinit.get)
  of skAssign:
    return hasImpureExpression(s.aval)
  of skCompoundAssign:
    return hasImpureExpression(s.crhs)
  of skIf:
    if hasImpureExpression(s.cond): return true
    for stmt in s.thenBody:
      if hasImpureCalls(stmt): return true
    for stmt in s.elseBody:
      if hasImpureCalls(stmt): return true
  of skWhile:
    if hasImpureExpression(s.wcond): return true
    for stmt in s.wbody:
      if hasImpureCalls(stmt): return true
  of skFor:
    if s.farray.isSome and hasImpureExpression(s.farray.get): return true
    if s.fstart.isSome and hasImpureExpression(s.fstart.get): return true
    if s.fend.isSome and hasImpureExpression(s.fend.get): return true
    for stmt in s.fbody:
      if hasImpureCalls(stmt): return true
  of skReturn:
    if s.re.isSome:
      return hasImpureExpression(s.re.get)
  else:
    discard
  return false


proc hasImpureExpression(e: Expression): bool =
  case e.kind
  of ekCall:
    if e.fname in ["print", "seed", "rand", "readFile"]:
      return true
    for arg in e.args:
      if hasImpureExpression(arg): return true
  of ekBin:
    return hasImpureExpression(e.lhs) or hasImpureExpression(e.rhs)
  of ekUn:
    return hasImpureExpression(e.ue)
  of ekArray:
    for elem in e.elements:
      if hasImpureExpression(elem): return true
  of ekIndex:
    return hasImpureExpression(e.arrayExpression) or hasImpureExpression(e.indexExpression)
  of ekSlice:
    if hasImpureExpression(e.sliceExpression): return true
    if e.startExpression.isSome and hasImpureExpression(e.startExpression.get): return true
    if e.endExpression.isSome and hasImpureExpression(e.endExpression.get): return true
  of ekNewRef:
    return hasImpureExpression(e.init)
  of ekDeref:
    return hasImpureExpression(e.refExpression)
  of ekCast:
    return hasImpureExpression(e.castExpression)
  else:
    discard
  return false


proc isPureFunction(fn: FunctionDeclaration): bool =
  for stmt in fn.body:
    if hasImpureCalls(stmt):
      return false
  return true


type
  InjectCallInfo = object
    name: string
    typeStr: string
    pos: Pos

proc resolveInjectedType(typeStr: string): EtchType
proc collectInjectCallsInExpression(e: Expression; injects: var seq[InjectCallInfo])
proc collectInjectCallsInStatement(s: Statement; injects: var seq[InjectCallInfo])

proc foldExpression(prog: Program, e: var Expression)
proc foldStatement(prog: Program, s: var Statement)


proc resolveInjectedType(typeStr: string): EtchType =
  case typeStr
  of "string": tString()
  of "int": tInt()
  of "bool": tBool()
  of "float": tFloat()
  else: tString()


proc collectInjectCallsInExpression(e: Expression; injects: var seq[InjectCallInfo]) =
  if e.isNil:
    return
  case e.kind
  of ekCall:
    if e.fname == "inject" and e.args.len == 3:
      let nameExpr = e.args[0]
      let typeExpr = e.args[1]
      if nameExpr.kind == ekString and typeExpr.kind == ekString:
        injects.add(InjectCallInfo(name: nameExpr.sval, typeStr: typeExpr.sval, pos: e.pos))
    for arg in e.args:
      collectInjectCallsInExpression(arg, injects)
    if e.callTarget != nil:
      collectInjectCallsInExpression(e.callTarget, injects)
  of ekBin:
    collectInjectCallsInExpression(e.lhs, injects)
    collectInjectCallsInExpression(e.rhs, injects)
  of ekUn:
    collectInjectCallsInExpression(e.ue, injects)
  of ekArray:
    for elem in e.elements:
      collectInjectCallsInExpression(elem, injects)
  of ekIndex:
    collectInjectCallsInExpression(e.arrayExpression, injects)
    collectInjectCallsInExpression(e.indexExpression, injects)
  of ekSlice:
    collectInjectCallsInExpression(e.sliceExpression, injects)
    if e.startExpression.isSome:
      collectInjectCallsInExpression(e.startExpression.get, injects)
    if e.endExpression.isSome:
      collectInjectCallsInExpression(e.endExpression.get, injects)
  of ekArrayLen:
    collectInjectCallsInExpression(e.lenExpression, injects)
  of ekNewRef:
    collectInjectCallsInExpression(e.init, injects)
  of ekDeref:
    collectInjectCallsInExpression(e.refExpression, injects)
  of ekCast:
    collectInjectCallsInExpression(e.castExpression, injects)
  of ekOptionSome:
    collectInjectCallsInExpression(e.someExpression, injects)
  of ekResultOk:
    collectInjectCallsInExpression(e.okExpression, injects)
  of ekResultErr:
    collectInjectCallsInExpression(e.errExpression, injects)
  of ekResultPropagate:
    collectInjectCallsInExpression(e.propagateExpression, injects)
  of ekMatch:
    collectInjectCallsInExpression(e.matchExpression, injects)
    for mc in e.cases:
      for stmt in mc.body:
        collectInjectCallsInStatement(stmt, injects)
  of ekObjectLiteral:
    for field in e.fieldInits:
      collectInjectCallsInExpression(field.value, injects)
  of ekFieldAccess:
    collectInjectCallsInExpression(e.objectExpression, injects)
  of ekNew:
    if e.initExpression.isSome:
      collectInjectCallsInExpression(e.initExpression.get, injects)
  of ekIf:
    collectInjectCallsInExpression(e.ifCond, injects)
    for stmt in e.ifThen:
      collectInjectCallsInStatement(stmt, injects)
    for branch in e.ifElifChain:
      collectInjectCallsInExpression(branch.cond, injects)
      for stmt in branch.body:
        collectInjectCallsInStatement(stmt, injects)
    for stmt in e.ifElse:
      collectInjectCallsInStatement(stmt, injects)
  of ekComptime:
    collectInjectCallsInExpression(e.comptimeExpression, injects)
  of ekCompiles:
    for stmt in e.compilesBlock:
      collectInjectCallsInStatement(stmt, injects)
  of ekTuple:
    for elem in e.tupleElements:
      collectInjectCallsInExpression(elem, injects)
  of ekYield:
    if e.yieldValue.isSome:
      collectInjectCallsInExpression(e.yieldValue.get, injects)
  of ekResume:
    collectInjectCallsInExpression(e.resumeValue, injects)
  of ekSpawn:
    collectInjectCallsInExpression(e.spawnExpression, injects)
  of ekSpawnBlock:
    for stmt in e.spawnBody:
      collectInjectCallsInStatement(stmt, injects)
  of ekChannelNew:
    if e.channelCapacity.isSome:
      collectInjectCallsInExpression(e.channelCapacity.get, injects)
  of ekChannelSend:
    collectInjectCallsInExpression(e.sendChannel, injects)
    collectInjectCallsInExpression(e.sendValue, injects)
  of ekChannelRecv:
    collectInjectCallsInExpression(e.recvChannel, injects)
  of ekLambda:
    for stmt in e.lambdaBody:
      collectInjectCallsInStatement(stmt, injects)
    for param in e.lambdaParams:
      if param.defaultValue.isSome:
        collectInjectCallsInExpression(param.defaultValue.get, injects)
  else:
    discard


proc collectInjectCallsInStatement(s: Statement; injects: var seq[InjectCallInfo]) =
  if s.isNil:
    return
  case s.kind
  of skVar:
    if s.vinit.isSome:
      collectInjectCallsInExpression(s.vinit.get, injects)
  of skAssign:
    collectInjectCallsInExpression(s.aval, injects)
  of skCompoundAssign:
    collectInjectCallsInExpression(s.crhs, injects)
  of skFieldAssign:
    collectInjectCallsInExpression(s.faTarget, injects)
    collectInjectCallsInExpression(s.faValue, injects)
  of skIf:
    collectInjectCallsInExpression(s.cond, injects)
    for stmt in s.thenBody:
      collectInjectCallsInStatement(stmt, injects)
    for branch in s.elifChain:
      collectInjectCallsInExpression(branch.cond, injects)
      for stmt in branch.body:
        collectInjectCallsInStatement(stmt, injects)
    for stmt in s.elseBody:
      collectInjectCallsInStatement(stmt, injects)
  of skWhile:
    collectInjectCallsInExpression(s.wcond, injects)
    for stmt in s.wbody:
      collectInjectCallsInStatement(stmt, injects)
  of skFor:
    if s.farray.isSome:
      collectInjectCallsInExpression(s.farray.get, injects)
    else:
      if s.fstart.isSome:
        collectInjectCallsInExpression(s.fstart.get, injects)
      if s.fend.isSome:
        collectInjectCallsInExpression(s.fend.get, injects)
    for stmt in s.fbody:
      collectInjectCallsInStatement(stmt, injects)
  of skExpression:
    collectInjectCallsInExpression(s.sexpr, injects)
  of skReturn:
    if s.re.isSome:
      collectInjectCallsInExpression(s.re.get, injects)
  of skComptime:
    for stmt in s.cbody:
      collectInjectCallsInStatement(stmt, injects)
  of skDiscard:
    for expr in s.dexprs:
      collectInjectCallsInExpression(expr, injects)
  of skDefer:
    for stmt in s.deferBody:
      collectInjectCallsInStatement(stmt, injects)
  of skBlock:
    for stmt in s.blockBody:
      collectInjectCallsInStatement(stmt, injects)
  of skTupleUnpack:
    collectInjectCallsInExpression(s.tupInit, injects)
  of skObjectUnpack:
    collectInjectCallsInExpression(s.objInit, injects)
  else:
    discard


proc foldExpression(prog: Program, e: var Expression) =
  case e.kind
  of ekBin:
    foldExpression(prog, e.lhs); foldExpression(prog, e.rhs)

    # Constant fold binary operations on integer and float literals
    if e.lhs.kind == ekInt and e.rhs.kind == ekInt:
      # Both operands are integer constants - fold the operation
      var foldedValue: Option[int64] = none[int64]()

      case e.bop:
      of boAdd:
        # Check for overflow before folding
        let a = e.lhs.ival
        let b = e.rhs.ival
        if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b):
          discard  # Overflow would occur - don't fold, let prover catch it
        else:
          foldedValue = some(a + b)
      of boSub:
        let a = e.lhs.ival
        let b = e.rhs.ival
        if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b):
          discard  # Overflow would occur - don't fold
        else:
          foldedValue = some(a - b)
      of boMul:
        let a = e.lhs.ival
        let b = e.rhs.ival
        # Check for multiplication overflow
        if b != 0 and ((a > 0 and b > 0 and a > high(int64) div b) or
                       (a > 0 and b < 0 and b < low(int64) div a) or
                       (a < 0 and b > 0 and a < low(int64) div b) or
                       (a < 0 and b < 0 and a != 0 and b < high(int64) div a)):
          discard  # Overflow would occur - don't fold
        else:
          foldedValue = some(a * b)
      of boDiv:
        if e.rhs.ival == 0:
          discard  # Division by zero - don't fold, let prover catch it
        elif e.lhs.ival == low(int64) and e.rhs.ival == -1:
          discard  # Overflow case: IMin / -1 - don't fold
        else:
          foldedValue = some(e.lhs.ival div e.rhs.ival)
      of boMod:
        if e.rhs.ival == 0:
          discard  # Modulo by zero - don't fold
        else:
          foldedValue = some(e.lhs.ival mod e.rhs.ival)
      of boEq:
        e = Expression(kind: ekBool, bval: e.lhs.ival == e.rhs.ival, pos: e.pos)
        return
      of boNe:
        e = Expression(kind: ekBool, bval: e.lhs.ival != e.rhs.ival, pos: e.pos)
        return
      of boLt:
        e = Expression(kind: ekBool, bval: e.lhs.ival < e.rhs.ival, pos: e.pos)
        return
      of boLe:
        e = Expression(kind: ekBool, bval: e.lhs.ival <= e.rhs.ival, pos: e.pos)
        return
      of boGt:
        e = Expression(kind: ekBool, bval: e.lhs.ival > e.rhs.ival, pos: e.pos)
        return
      of boGe:
        e = Expression(kind: ekBool, bval: e.lhs.ival >= e.rhs.ival, pos: e.pos)
        return
      else:
        discard  # Other operations not foldable for integers

      if foldedValue.isSome:
        e = Expression(kind: ekInt, ival: foldedValue.get, pos: e.pos)

    elif e.lhs.kind == ekFloat and e.rhs.kind == ekFloat:
      # Both operands are float constants - fold the operation
      case e.bop:
      of boAdd:
        e = Expression(kind: ekFloat, fval: e.lhs.fval + e.rhs.fval, pos: e.pos)
      of boSub:
        e = Expression(kind: ekFloat, fval: e.lhs.fval - e.rhs.fval, pos: e.pos)
      of boMul:
        e = Expression(kind: ekFloat, fval: e.lhs.fval * e.rhs.fval, pos: e.pos)
      of boDiv:
        if e.rhs.fval != 0.0:
          e = Expression(kind: ekFloat, fval: e.lhs.fval / e.rhs.fval, pos: e.pos)
      of boEq:
        e = Expression(kind: ekBool, bval: e.lhs.fval == e.rhs.fval, pos: e.pos)
      of boNe:
        e = Expression(kind: ekBool, bval: e.lhs.fval != e.rhs.fval, pos: e.pos)
      of boLt:
        e = Expression(kind: ekBool, bval: e.lhs.fval < e.rhs.fval, pos: e.pos)
      of boLe:
        e = Expression(kind: ekBool, bval: e.lhs.fval <= e.rhs.fval, pos: e.pos)
      of boGt:
        e = Expression(kind: ekBool, bval: e.lhs.fval > e.rhs.fval, pos: e.pos)
      of boGe:
        e = Expression(kind: ekBool, bval: e.lhs.fval >= e.rhs.fval, pos: e.pos)
      else:
        discard  # Other operations not foldable for floats

    elif e.lhs.kind == ekBool and e.rhs.kind == ekBool:
      # Both operands are boolean constants - fold logical operations
      case e.bop:
      of boAnd:
        e = Expression(kind: ekBool, bval: e.lhs.bval and e.rhs.bval, pos: e.pos)
      of boOr:
        e = Expression(kind: ekBool, bval: e.lhs.bval or e.rhs.bval, pos: e.pos)
      of boEq:
        e = Expression(kind: ekBool, bval: e.lhs.bval == e.rhs.bval, pos: e.pos)
      of boNe:
        e = Expression(kind: ekBool, bval: e.lhs.bval != e.rhs.bval, pos: e.pos)
      else:
        discard

    elif e.lhs.kind == ekString and e.rhs.kind == ekString:
      # Both operands are string constants - fold string concatenation
      case e.bop:
      of boAdd:  # String concatenation
        e = Expression(kind: ekString, sval: e.lhs.sval & e.rhs.sval, pos: e.pos)
      of boEq:
        e = Expression(kind: ekBool, bval: e.lhs.sval == e.rhs.sval, pos: e.pos)
      of boNe:
        e = Expression(kind: ekBool, bval: e.lhs.sval != e.rhs.sval, pos: e.pos)
      else:
        discard
  of ekUn:
    foldExpression(prog, e.ue)

    # Constant fold unary operations
    case e.uop:
    of uoNeg:
      if e.ue.kind == ekInt:
        # Check for overflow (negating IMin would overflow)
        if e.ue.ival != low(int64):
          e = Expression(kind: ekInt, ival: -e.ue.ival, pos: e.pos)
      elif e.ue.kind == ekFloat:
        e = Expression(kind: ekFloat, fval: -e.ue.fval, pos: e.pos)
    of uoNot:
      if e.ue.kind == ekBool:
        e = Expression(kind: ekBool, bval: not e.ue.bval, pos: e.pos)
  of ekCall:
    for i in 0..<e.args.len: foldExpression(prog, e.args[i])

    if prog.funInstances.hasKey(e.fname):
      let fn = prog.funInstances[e.fname]

      if isPureFunction(fn):
        var allConstLiterals = true
        var argInfos: seq[Info] = @[]

        for arg in e.args:
          case arg.kind
          of ekInt:
            argInfos.add(infoConst(arg.ival))
          of ekFloat:
            argInfos.add(infoConst(int64(arg.fval)))
          of ekBool:
            argInfos.add(infoConst(if arg.bval: 1'i64 else: 0'i64))
          of ekString:
            allConstLiterals = false
            break
          else:
            allConstLiterals = false
            break

        if allConstLiterals and argInfos.len == fn.params.len:
          let evalResult = tryEvaluatePureFunction(e, argInfos, fn, prog)
          if evalResult.isSome:
            e = Expression(kind: ekInt, ival: evalResult.get, pos: e.pos)
  of ekNewRef:
    foldExpression(prog, e.init)
  of ekDeref:
    foldExpression(prog, e.refExpression)
  of ekCast:
    foldExpression(prog, e.castExpression)
  of ekArray:
    for i in 0..<e.elements.len: foldExpression(prog, e.elements[i])
  of ekIndex:
    foldExpression(prog, e.arrayExpression)
    foldExpression(prog, e.indexExpression)
  of ekSlice:
    foldExpression(prog, e.sliceExpression)
    if e.startExpression.isSome: foldExpression(prog, e.startExpression.get)
    if e.endExpression.isSome: foldExpression(prog, e.endExpression.get)
  of ekIf:
    foldExpression(prog, e.ifCond)
    for i in 0..<e.ifThen.len: foldStatement(prog, e.ifThen[i])
    for i in 0..<e.ifElifChain.len:
      foldExpression(prog, e.ifElifChain[i].cond)
      for j in 0..<e.ifElifChain[i].body.len: foldStatement(prog, e.ifElifChain[i].body[j])
    for i in 0..<e.ifElse.len: foldStatement(prog, e.ifElse[i])
  of ekComptime:
    foldExpression(prog, e.comptimeExpression)

    # Try to evaluate the expression at compile-time
    if e.comptimeExpression.kind == ekCall:
      let call = e.comptimeExpression

      # Special handling for readFile which should be evaluated at compile-time
      if call.fname == "readFile" and call.args.len == 1 and call.args[0].kind == ekString:
        let filename = call.args[0].sval
        try:
          let content = readFile(filename)
          e = Expression(kind: ekString, sval: content, pos: e.pos)
        except Exception as ex:
          echo "Warning: Failed to read file '", filename, "' at compile-time: ", ex.msg
          echo "Exception: ", ex.getStackTrace()
      else:
        # For other functions, try to evaluate using the prover
        if prog.funInstances.hasKey(call.fname):
          let fn = prog.funInstances[call.fname]
          if isPureFunction(fn):
            var allConstLiterals = true
            var argInfos: seq[Info] = @[]

            for arg in call.args:
              case arg.kind
              of ekInt:
                argInfos.add(infoConst(arg.ival))
              of ekFloat:
                argInfos.add(infoConst(int64(arg.fval)))
              of ekBool:
                argInfos.add(infoConst(if arg.bval: 1'i64 else: 0'i64))
              else:
                allConstLiterals = false
                break

            if allConstLiterals and argInfos.len == fn.params.len:
              let evalResult = tryEvaluatePureFunction(call, argInfos, fn, prog)
              if evalResult.isSome:
                e = Expression(kind: ekInt, ival: evalResult.get, pos: e.pos)
    elif e.comptimeExpression.kind in [ekInt, ekFloat, ekString, ekBool]:
      # Already a constant, just use it
      e = e.comptimeExpression
  of ekCompiles:
    # Only evaluate if the type environment has been captured
    # This will be empty on the first fold pass (before typechecking)
    # and populated on the second pass (after typechecking)
    if e.compilesEnv.len == 0:
      # Skip for now - will be evaluated in second fold pass after typechecking
      discard
    else:
      # Try to compile the block and return true/false based on success
      var compiles = true
      try:
        # Create an isolated scope with captured outer scope types
        # This allows the compiles block to reference outer variables
        var isolatedScope = tc_types.Scope(
          types: e.compilesEnv,  # Use captured type environment
          flags: initTable[string, VarFlag](),
          userTypes: initTable[string, EtchType](),
          prog: prog
        )

        # Create a dummy function declaration for typechecking
        var dummyFd = FunctionDeclaration(
          name: "__compiles_check__",
          typarams: @[],
          params: @[],
          ret: tVoid(),
          hasExplicitReturnType: true,
          body: e.compilesBlock,
          isExported: false,
          isCFFI: false,
          isHost: false
        )

        # Try to typecheck each statement in the block
        var subst = initTable[string, EtchType]()
        for stmt in e.compilesBlock:
          typecheckStatement(prog, dummyFd, isolatedScope, stmt, subst)
      except Exception:
        # If any exception occurs during typechecking, the code doesn't compile
        compiles = false

      # Replace the compiles expression with a boolean literal
      e = Expression(kind: ekBool, bval: compiles, typ: tBool(), pos: e.pos)
  else: discard


proc foldStatement(prog: Program, s: var Statement) =
  case s.kind
  of skVar:
    if s.vinit.isSome:
      var x = s.vinit.get
      foldExpression(prog, x)
      s.vinit = some(x)
      if s.vtype.kind == tkGeneric and s.vtype.name == "__comptime_infer__":
        case x.kind
        of ekInt:
          s.vtype = ast.tInt()
        of ekFloat:
          s.vtype = ast.tFloat()
        of ekString:
          s.vtype = ast.tString()
        of ekBool:
          s.vtype = ast.tBool()
        else:
          discard  # Will be caught by type checker
  of skTupleUnpack:
    var x = s.tupInit
    foldExpression(prog, x)
    s.tupInit = x
  of skObjectUnpack:
    var x = s.objInit
    foldExpression(prog, x)
    s.objInit = x
  of skAssign:
    var x = s.aval; foldExpression(prog, x)
    s.aval = x
  of skCompoundAssign:
    var x = s.crhs; foldExpression(prog, x)
    s.crhs = x
  of skFieldAssign:
    var target = s.faTarget; foldExpression(prog, target)
    s.faTarget = target
    var value = s.faValue; foldExpression(prog, value)
    s.faValue = value
  of skDiscard:
    # Fold all discard expressions
    for i in 0..<s.dexprs.len:
      var expr = s.dexprs[i]
      foldExpression(prog, expr)
      s.dexprs[i] = expr
  of skIf:
    foldExpression(prog, s.cond)
    for i in 0..<s.thenBody.len: foldStatement(prog, s.thenBody[i])
    for i in 0..<s.elseBody.len: foldStatement(prog, s.elseBody[i])
  of skWhile:
    foldExpression(prog, s.wcond)
    for i in 0..<s.wbody.len: foldStatement(prog, s.wbody[i])
  of skFor:
    if s.farray.isSome():
      var x = s.farray.get(); foldExpression(prog, x)
      s.farray = some(x)
    else:
      var start = s.fstart.get()
      foldExpression(prog, start)
      s.fstart = some(start)
      var endVal = s.fend.get()
      foldExpression(prog, endVal)
      s.fend = some(endVal)
    for i in 0..<s.fbody.len: foldStatement(prog, s.fbody[i])
  of skExpression:
    var x = s.sexpr; foldExpression(prog, x)
    s.sexpr = x
  of skBreak:
    discard
  of skReturn:
    if s.re.isSome:
      var x = s.re.get; foldExpression(prog, x)
      s.re = some(x)
  of skComptime:
    for i in 0..<s.cbody.len:
      foldStatement(prog, s.cbody[i])

    # Execute the comptime block using the VM
    var comptimeInjections: Table[string, V]
    try:
      # Create a temporary function containing the comptime block
      # Name it "main" so the VM will execute it as the entry point
      let comptimeFunc = FunctionDeclaration(
        name: "main",
        typarams: @[],
        params: @[],
        ret: tVoid(),
        hasExplicitReturnType: true,
        body: s.cbody,
        isExported: false,
        isCFFI: false,
        isHost: false
      )

      # Create a temporary program with just this function
      var tempProg = Program(
        funs: initTable[string, seq[FunctionDeclaration]](),
        funInstances: initTable[string, FunctionDeclaration](),
        globals: @[],
        types: initTable[string, EtchType](),  # Don't share types to avoid pollution
        lambdaCounter: 0
      )
      tempProg.funInstances["main"] = comptimeFunc

      # Make all function instances available for comptime execution
      # But create copies to avoid modifying the original
      for name, funcDecl in prog.funInstances:
        if name != "main":
          tempProg.funInstances[name] = funcDecl

      # Compile to bytecode
      let bytecode = compileProgram(tempProg, optimizeLevel = 0, verbose = false, debug = false)

      # Execute the comptime block and get the injections
      let (_, injections) = runProgram(bytecode, false)
      comptimeInjections = injections
    except Exception as e:
      echo "Warning: Failed to execute comptime block: ", e.msg
      echo "Exception: ", e.getStackTrace()
      comptimeInjections = initTable[string, V]()

    # Now extract injected variables from the VM execution
    var injectedVars: seq[Statement] = @[]
    var injectCalls: seq[InjectCallInfo] = @[]
    for stmt in s.cbody:
      collectInjectCallsInStatement(stmt, injectCalls)

    var lastOccurrence = initTable[string, int]()
    for idx, info in injectCalls:
      lastOccurrence[info.name] = idx

    for idx, info in injectCalls:
      if lastOccurrence[info.name] != idx:
        continue
      if not comptimeInjections.hasKey(info.name):
        continue

      let injectedValue = comptimeInjections[info.name]
      let varType = resolveInjectedType(info.typeStr)

      var valueExpression: Expression
      if injectedValue.isInt():
        valueExpression = Expression(kind: ekInt, ival: injectedValue.ival, pos: info.pos)
      elif injectedValue.isFloat():
        valueExpression = Expression(kind: ekFloat, fval: injectedValue.fval, pos: info.pos)
      elif injectedValue.isString():
        valueExpression = Expression(kind: ekString, sval: injectedValue.sval, pos: info.pos)
      elif injectedValue.isBool():
        valueExpression = Expression(kind: ekBool, bval: injectedValue.bval, pos: info.pos)
      else:
        valueExpression = Expression(kind: ekInt, ival: 0, pos: info.pos)

      let varDecl = Statement(
        kind: skVar,
        vname: info.name,
        vtype: varType,
        vinit: some(valueExpression),
        pos: info.pos
      )
      injectedVars.add(varDecl)

    s.cbody = injectedVars
  of skDefer:
    # Fold statements in defer body
    for i in 0..<s.deferBody.len:
      foldStatement(prog, s.deferBody[i])
  of skBlock:
    # Fold statements in unnamed scope block
    for i in 0..<s.blockBody.len:
      foldStatement(prog, s.blockBody[i])
  of skTypeDecl:
    discard
  of skImport:
    discard


proc foldComptime*(prog: Program, root: var Program) =
  for i in 0..<root.globals.len:
    var g = root.globals[i]; foldStatement(prog, g); root.globals[i] = g

  for fname, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStatement(prog, s); f.body[i] = s


# Helper to only process ekCompiles expressions (skip comptime blocks)
proc foldCompilesInExpression(prog: Program, e: var Expression) =
  case e.kind
  of ekCompiles:
    # Process this if environment is populated
    if e.compilesEnv.len > 0:
      var compiles = true
      try:
        var isolatedScope = tc_types.Scope(
          types: e.compilesEnv,
          flags: initTable[string, VarFlag](),
          userTypes: initTable[string, EtchType](),
          prog: prog
        )
        var dummyFd = FunctionDeclaration(
          name: "__compiles_check__",
          typarams: @[],
          params: @[],
          ret: tVoid(),
          hasExplicitReturnType: true,
          body: e.compilesBlock,
          isExported: false,
          isCFFI: false,
          isHost: false
        )
        var subst = initTable[string, EtchType]()
        for stmt in e.compilesBlock:
          typecheckStatement(prog, dummyFd, isolatedScope, stmt, subst)
      except Exception:
        compiles = false
      e = Expression(kind: ekBool, bval: compiles, typ: tBool(), pos: e.pos)
  of ekBin:
    foldCompilesInExpression(prog, e.lhs)
    foldCompilesInExpression(prog, e.rhs)
  of ekUn:
    foldCompilesInExpression(prog, e.ue)
  of ekIf:
    foldCompilesInExpression(prog, e.ifCond)
  else:
    discard  # Don't recurse further for other expression types


proc foldCompilesInStatement(prog: Program, s: var Statement) =
  case s.kind
  of skVar:
    if s.vinit.isSome:
      var x = s.vinit.get
      foldCompilesInExpression(prog, x)
      s.vinit = some(x)
  of skAssign:
    foldCompilesInExpression(prog, s.aval)
  of skCompoundAssign:
    foldCompilesInExpression(prog, s.crhs)
  of skExpression:
    foldCompilesInExpression(prog, s.sexpr)
  of skIf:
    foldCompilesInExpression(prog, s.cond)
    for i in 0..<s.thenBody.len:
      foldCompilesInStatement(prog, s.thenBody[i])
    for i in 0..<s.elseBody.len:
      foldCompilesInStatement(prog, s.elseBody[i])
  of skWhile:
    foldCompilesInExpression(prog, s.wcond)
    for i in 0..<s.wbody.len:
      foldCompilesInStatement(prog, s.wbody[i])
  # Skip skComptime - don't reprocess comptime blocks!
  else:
    discard


# Second pass specifically for compiles{...} expressions after typechecking
# This is needed because compiles needs the type environment which is only available after typechecking
proc foldCompilesExpressions*(prog: Program, root: var Program) =
  for i in 0..<root.globals.len:
    foldCompilesInStatement(prog, root.globals[i])

  for fname, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      foldCompilesInStatement(prog, f.body[i])
