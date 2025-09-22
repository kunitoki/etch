# builtins.nim
# Tiny helpers to fold comptime calls via the VM during compilation

import std/[tables, options]
import ast, vm

proc foldComptime*(prog: Program; root: var Program) =
  # Process comptime blocks and handle inject statements
  
  proc foldExpr(e: var Expr) =
    case e.kind
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
      # Execute comptime block at compile time and handle inject calls
      # First fold all statements normally to resolve variables
      for i in 0..<s.cbody.len:
        foldStmt(s.cbody[i])

      # Then process statements to find inject calls and create variable declarations
      var injectedVars: seq[Stmt] = @[]

      # Create a simple evaluation scope for comptime variables
      var comptimeScope: Table[string, Expr] = initTable[string, Expr]()

      for stmt in s.cbody:
        if stmt.kind == skVar and stmt.vinit.isSome:
          # This is a variable declaration in comptime - add to our scope
          comptimeScope[stmt.vname] = stmt.vinit.get()
        elif stmt.kind == skExpr and stmt.sexpr.kind == ekCall and stmt.sexpr.fname == "inject":
          # This is an inject call - convert it to a variable declaration
          if stmt.sexpr.args.len == 3:
            # Extract the arguments: name, type_str, value_expr
            let nameExpr = stmt.sexpr.args[0]
            let typeExpr = stmt.sexpr.args[1]
            var valueExpr = stmt.sexpr.args[2]

            # The name should be a string literal
            if nameExpr.kind == ekString and typeExpr.kind == ekString:
              let varName = nameExpr.sval
              let typeStr = typeExpr.sval

              # Parse the type string and create the appropriate type
              var varType: EtchType
              case typeStr:
                of "string": varType = tString()
                of "int": varType = tInt()
                of "bool": varType = tBool()
                of "float": varType = tFloat()
                else: varType = tString() # default to string

              # If the value is a variable reference, substitute it
              if valueExpr.kind == ekVar and comptimeScope.hasKey(valueExpr.vname):
                valueExpr = comptimeScope[valueExpr.vname]

              # Fold the value expression
              foldExpr(valueExpr)

              # Create a variable declaration
              let varDecl = Stmt(
                kind: skVar,
                vname: varName,
                vtype: varType,
                vinit: some(valueExpr),
                pos: stmt.pos
              )
              injectedVars.add(varDecl)

      # Replace the comptime body with the injected variables
      s.cbody = injectedVars

  # Process global variables first
  for i in 0..<root.globals.len:
    var g = root.globals[i]; foldStmt(g); root.globals[i] = g

  for _, f in pairs(root.funInstances):
    for i in 0..<f.body.len:
      var s = f.body[i]; foldStmt(s); f.body[i] = s
