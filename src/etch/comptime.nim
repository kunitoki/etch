# comptime.nim
# Compile-time evaluation and injection helpers for Etch

import std/[tables, options]
import common/[types]
import prover/[function_evaluation, types]
import frontend/ast


proc hasImpureExpr(e: Expr): bool


proc hasImpureCalls(s: Stmt): bool =
  case s.kind
  of skExpr:
    return hasImpureExpr(s.sexpr)
  of skVar:
    if s.vinit.isSome:
      return hasImpureExpr(s.vinit.get)
  of skAssign:
    return hasImpureExpr(s.aval)
  of skIf:
    if hasImpureExpr(s.cond): return true
    for stmt in s.thenBody:
      if hasImpureCalls(stmt): return true
    for stmt in s.elseBody:
      if hasImpureCalls(stmt): return true
  of skWhile:
    if hasImpureExpr(s.wcond): return true
    for stmt in s.wbody:
      if hasImpureCalls(stmt): return true
  of skFor:
    if s.farray.isSome and hasImpureExpr(s.farray.get): return true
    if s.fstart.isSome and hasImpureExpr(s.fstart.get): return true
    if s.fend.isSome and hasImpureExpr(s.fend.get): return true
    for stmt in s.fbody:
      if hasImpureCalls(stmt): return true
  of skReturn:
    if s.re.isSome:
      return hasImpureExpr(s.re.get)
  else:
    discard
  return false


proc hasImpureExpr(e: Expr): bool =
  case e.kind
  of ekCall:
    if e.fname in ["print", "seed", "rand", "readFile"]:
      return true
    for arg in e.args:
      if hasImpureExpr(arg): return true
  of ekBin:
    return hasImpureExpr(e.lhs) or hasImpureExpr(e.rhs)
  of ekUn:
    return hasImpureExpr(e.ue)
  of ekArray:
    for elem in e.elements:
      if hasImpureExpr(elem): return true
  of ekIndex:
    return hasImpureExpr(e.arrayExpr) or hasImpureExpr(e.indexExpr)
  of ekSlice:
    if hasImpureExpr(e.sliceExpr): return true
    if e.startExpr.isSome and hasImpureExpr(e.startExpr.get): return true
    if e.endExpr.isSome and hasImpureExpr(e.endExpr.get): return true
  of ekNewRef:
    return hasImpureExpr(e.init)
  of ekDeref:
    return hasImpureExpr(e.refExpr)
  of ekCast:
    return hasImpureExpr(e.castExpr)
  else:
    discard
  return false


proc isPureFunction(fn: FunDecl): bool =
  for stmt in fn.body:
    if hasImpureCalls(stmt):
      return false
  return true


proc foldExpr(prog: Program, e: var Expr) =
  case e.kind
  of ekBin:
    foldExpr(prog, e.lhs); foldExpr(prog, e.rhs)
  of ekUn:
    foldExpr(prog, e.ue)
  of ekCall:
    for i in 0..<e.args.len: foldExpr(prog, e.args[i])

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
            e = Expr(kind: ekInt, ival: evalResult.get, pos: e.pos)
  of ekNewRef:
    foldExpr(prog, e.init)
  of ekDeref:
    foldExpr(prog, e.refExpr)
  of ekCast:
    foldExpr(prog, e.castExpr)
  of ekArray:
    for i in 0..<e.elements.len: foldExpr(prog, e.elements[i])
  of ekIndex:
    foldExpr(prog, e.arrayExpr)
    foldExpr(prog, e.indexExpr)
  of ekSlice:
    foldExpr(prog, e.sliceExpr)
    if e.startExpr.isSome: foldExpr(prog, e.startExpr.get)
    if e.endExpr.isSome: foldExpr(prog, e.endExpr.get)
  else: discard


proc foldStmt(prog: Program, s: var Stmt) =
  case s.kind
  of skVar:
    if s.vinit.isSome:
      var x = s.vinit.get
      foldExpr(prog, x)
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
  of skAssign:
    var x = s.aval; foldExpr(prog, x)
    s.aval = x
  of skFieldAssign:
    var target = s.faTarget; foldExpr(prog, target)
    s.faTarget = target
    var value = s.faValue; foldExpr(prog, value)
    s.faValue = value
  of skIf:
    foldExpr(prog, s.cond)
    for i in 0..<s.thenBody.len: foldStmt(prog, s.thenBody[i])
    for i in 0..<s.elseBody.len: foldStmt(prog, s.elseBody[i])
  of skWhile:
    foldExpr(prog, s.wcond)
    for i in 0..<s.wbody.len: foldStmt(prog, s.wbody[i])
  of skFor:
    if s.farray.isSome():
      var x = s.farray.get(); foldExpr(prog, x)
      s.farray = some(x)
    else:
      var start = s.fstart.get()
      foldExpr(prog, start)
      s.fstart = some(start)
      var endVal = s.fend.get()
      foldExpr(prog, endVal)
      s.fend = some(endVal)
    for i in 0..<s.fbody.len: foldStmt(prog, s.fbody[i])
  of skExpr:
    var x = s.sexpr; foldExpr(prog, x)
    s.sexpr = x
  of skBreak:
    discard
  of skReturn:
    if s.re.isSome:
      var x = s.re.get; foldExpr(prog, x)
      s.re = some(x)
  of skComptime:
    for i in 0..<s.cbody.len:
      foldStmt(prog, s.cbody[i])

    var injectedVars: seq[Stmt] = @[]
    var comptimeScope: Table[string, Expr] = initTable[string, Expr]()

    for stmt in s.cbody:
      if stmt.kind == skVar and stmt.vinit.isSome:
        comptimeScope[stmt.vname] = stmt.vinit.get()
      elif stmt.kind == skExpr and stmt.sexpr.kind == ekCall and stmt.sexpr.fname == "inject":
        if stmt.sexpr.args.len == 3:
          let nameExpr = stmt.sexpr.args[0]
          let typeExpr = stmt.sexpr.args[1]
          var valueExpr = stmt.sexpr.args[2]

          if nameExpr.kind == ekString and typeExpr.kind == ekString:
            let varName = nameExpr.sval
            let typeStr = typeExpr.sval

            var varType: EtchType
            case typeStr:
              of "string": varType = tString()
              of "int": varType = tInt()
              of "bool": varType = tBool()
              of "float": varType = tFloat()
              else: varType = tString() # default to string

            if valueExpr.kind == ekVar and comptimeScope.hasKey(valueExpr.vname):
              valueExpr = comptimeScope[valueExpr.vname]

            foldExpr(prog, valueExpr)

            let varDecl = Stmt(
              kind: skVar,
              vname: varName,
              vtype: varType,
              vinit: some(valueExpr),
              pos: stmt.pos
            )
            injectedVars.add(varDecl)

    s.cbody = injectedVars
  of skTypeDecl:
    discard
  of skImport:
    discard


proc foldComptime*(prog: Program, root: var Program) =
  for i in 0..<root.globals.len:
    var g = root.globals[i]; foldStmt(prog, g); root.globals[i] = g

  for _, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStmt(prog, s); f.body[i] = s
