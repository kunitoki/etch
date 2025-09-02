# builtins.nim
# Tiny helpers to fold comptime calls via the VM during compilation

import std/[tables, options]
import ast, vm


proc foldComptime*(prog: Program; root: var Program) =
  # Walk all instantiated functions and replace ekComptime with literals by VM evaluation.
  var v = VM(heap: @[], funs: initTable[string, FunDecl](), injectedStmts: @[])
  # Add both generic templates and instantiated functions to VM for comptime evaluation
  for k, f in pairs(prog.funs): v.funs[k] = f
  for k, f in pairs(prog.funInstances): v.funs[k] = f

  proc foldExpr(e: var Expr) =
    case e.kind
    of ekComptime:
      # eval inner in empty frame
      let fr = Frame(vars: initTable[string, V]())
      let val = v.evalExpr(fr, e.inner)
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
      # Execute comptime block at compile time using existing VM logic
      var fr = Frame(vars: initTable[string, V]())
      # Add globals to comptime frame (assuming they're compile-time constants)
      for g in prog.globals:
        if g.kind == skVar and g.vinit.isSome:
          let globalVal = v.evalExpr(fr, g.vinit.get)
          fr.vars[g.vname] = globalVal

      # Execute comptime block by creating a temporary function and running it in VM
      # This reuses all the VM's existing statement execution logic
      let comptimeFn = FunDecl(
        name: "__comptime_block__",
        typarams: @[],
        params: @[],
        ret: tVoid(),
        body: s.cbody
      )

      # Temporarily add the comptime function to VM
      v.funs[comptimeFn.name] = comptimeFn

      # Execute the comptime block by calling the temporary function
      try:
        let callExpr = Expr(
          kind: ekCall,
          fname: comptimeFn.name,
          args: @[],
          pos: Pos(line: 0, col: 0, filename: "")
        )
        discard v.evalExpr(fr, callExpr)
      finally:
        # Remove the temporary function
        v.funs.del(comptimeFn.name)

      # Get any injected statements from VM and replace comptime block with them
      s.cbody = v.injectedStmts
      v.injectedStmts = @[]  # Clear for next comptime block

  for _, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStmt(s); f.body[i] = s
