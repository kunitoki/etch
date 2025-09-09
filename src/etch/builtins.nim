# builtins.nim
# Tiny helpers to fold comptime calls via the VM during compilation

import std/[tables, options]
import ast, vm


proc foldComptime*(prog: Program; root: var Program) =
  # Walk all instantiated functions and replace ekComptime with literals by bytecode evaluation.
  
  proc foldExpr(e: var Expr) =
    case e.kind
    of ekComptime:
      # eval inner using bytecode
      let val = evalExprWithBytecode(prog, e.inner)
      case val.kind
      of tkInt:
        e = Expr(kind: ekInt, ival: val.ival, typ: e.typ, pos: e.pos)
      of tkFloat:
        e = Expr(kind: ekFloat, fval: val.fval, typ: e.typ, pos: e.pos)
      of tkBool:
        e = Expr(kind: ekBool, bval: val.bval, typ: e.typ, pos: e.pos)
      of tkString:
        e = Expr(kind: ekString, sval: val.sval, typ: e.typ, pos: e.pos)
      else:
        discard
    of ekBin:
      foldExpr(e.lhs); foldExpr(e.rhs)
    of ekUn:
      foldExpr(e.ue)
    of ekCall:
      for i in 0..<e.args.len: foldExpr(e.args[i])
    of ekNewRef:
      foldExpr(e.init)
    of ekDeref:
      foldExpr(e.refExpr)
    of ekCast:
      foldExpr(e.castExpr)
    of ekArray:
      for i in 0..<e.elements.len: foldExpr(e.elements[i])
    of ekIndex:
      foldExpr(e.arrayExpr); foldExpr(e.indexExpr)
    of ekSlice:
      foldExpr(e.sliceExpr)
      if e.startExpr.isSome: foldExpr(e.startExpr.get)
      if e.endExpr.isSome: foldExpr(e.endExpr.get)
    else: discard

  proc foldStmt(s: var Stmt) =
    case s.kind
    of skVar:
      if s.vinit.isSome:
        var x = s.vinit.get
        foldExpr(x)
        s.vinit = some(x)
        # If this variable had a comptime type inference placeholder, resolve it now
        if s.vtype.kind == tkGeneric and s.vtype.name == "__comptime_infer__":
          # After folding, the expression should be a literal with a determinable type
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
            # If it's still not a literal after folding, this is an error
            discard  # Will be caught by type checker
    of skAssign:
      var x = s.aval; foldExpr(x); s.aval = x
    of skIf:
      foldExpr(s.cond)
      for i in 0..<s.thenBody.len: foldStmt(s.thenBody[i])
      for i in 0..<s.elseBody.len: foldStmt(s.elseBody[i])
    of skWhile:
      foldExpr(s.wcond)
      for i in 0..<s.wbody.len: foldStmt(s.wbody[i])
    of skExpr:
      var x = s.sexpr; foldExpr(x); s.sexpr = x
    of skReturn:
      if s.re.isSome:
        var x = s.re.get; foldExpr(x); s.re = some(x)
    of skComptime:
      # Execute comptime block at compile time using bytecode
      # For now, we'll keep the existing comptime block as-is
      # TODO: Implement comptime block execution via bytecode
      for i in 0..<s.cbody.len: foldStmt(s.cbody[i])

  for _, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStmt(s); f.body[i] = s
