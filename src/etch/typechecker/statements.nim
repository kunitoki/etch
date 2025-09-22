# statements.nim
# Statement type checking

import std/[strformat, options, tables, strutils]
import ../frontend/ast, ../errors
import types, expressions

proc typecheckStmt*(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst)

proc typecheckVar(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if s.vtype.kind == tkGeneric:
    raise newTypecheckError(s.pos, "generic variable type not allowed at runtime scope")
  if s.vinit.isSome():
    # Two-phase approach: First check type compatibility assuming all variables exist,
    # then check for undeclared variables if type check passes

    # Phase 1: Create temporary scope with self-reference to check type compatibility
    var tempScope = Scope(types: sc.types, flags: sc.flags)
    tempScope.types[s.vname] = s.vtype  # Allow self-reference for type checking

    var tempSubst = subst
    let t0 = try:
      inferExprTypes(prog, fd, tempScope, s.vinit.get(), tempSubst)
    except EtchError as e:
      # If we get an error during type inference, check if it's specifically about
      # the variable being initialized (circular reference) vs other issues
      if e.msg.contains(&"undeclared variable '{s.vname}'"):
        raise newTypecheckError(s.pos, &"circular reference: variable '{s.vname}' cannot be used in its own initialization")
      else:
        # Re-raise the original error (could be other undeclared variable or other issue)
        raise

    # Phase 2: Check type compatibility
    if not typeEq(t0, s.vtype):
      if t0.kind == tkVoid:
        raise newTypecheckError(s.pos, &"cannot assign void function result to variable '{s.vname}' of type {s.vtype}")
      else:
        raise newTypecheckError(s.pos, &"initialization type mismatch: {t0} vs {s.vtype}")

  sc.types[s.vname] = s.vtype
  sc.flags[s.vname] = s.vflag


proc typecheckAssign(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if not sc.types.hasKey(s.aname): raise newTypecheckError(s.pos, "unknown variable '" & s.aname & "'")
  if sc.flags.hasKey(s.aname) and sc.flags[s.aname] == vfLet:
    raise newTypecheckError(s.pos, &"cannot assign to immutable variable '{s.aname}'")
  let t0 = inferExprTypes(prog, fd, sc, s.aval, subst)
  if not typeEq(t0, sc.types[s.aname]):
    if t0.kind == tkVoid:
      raise newTypecheckError(s.pos, &"cannot assign void function result to variable '{s.aname}'")
    else:
      raise newTypecheckError(s.pos, "assignment type mismatch")


proc typecheckIf(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  let ct = inferExprTypes(prog, fd, sc, s.cond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "if condition must be bool")
  var sThen = Scope(types: sc.types, flags: sc.flags) # shallow copy ok
  for st in s.thenBody: typecheckStmt(prog, fd, sThen, st, subst)

  # Typecheck elif chain
  for elifBranch in s.elifChain:
    let elifCondType = inferExprTypes(prog, fd, sc, elifBranch.cond, subst)
    if elifCondType.kind != tkBool: raise newTypecheckError(s.pos, "elif condition must be bool")
    var sElif = Scope(types: sc.types, flags: sc.flags)
    for st in elifBranch.body: typecheckStmt(prog, fd, sElif, st, subst)

  var sElse = Scope(types: sc.types, flags: sc.flags)
  for st in s.elseBody: typecheckStmt(prog, fd, sElse, st, subst)


proc typecheckWhile(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  let ct = inferExprTypes(prog, fd, sc, s.wcond, subst)
  if ct.kind != tkBool: raise newTypecheckError(s.pos, "while condition must be bool")
  var sBody = Scope(types: sc.types, flags: sc.flags)
  for st in s.wbody: typecheckStmt(prog, fd, sBody, st, subst)


proc typecheckReturn(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  if fd == nil: return
  if fd.ret.kind == tkVoid:
    if s.re.isSome(): raise newTypecheckError(s.pos, "void function cannot return a value")
  else:
    if not s.re.isSome(): raise newTypecheckError(s.pos, "non-void function must return a value")
    let rt = inferExprTypes(prog, fd, sc, s.re.get(), subst)
    if not typeEq(rt, fd.ret): raise newTypecheckError(s.pos, &"return type mismatch: expected {fd.ret}, got {rt}")


proc typecheckComptime(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Typecheck comptime block statements and add injected variables to main scope
  var ctScope = Scope(types: sc.types, flags: sc.flags)
  for stmt in s.cbody:
    typecheckStmt(prog, fd, ctScope, stmt, subst)
    # If this is a variable declaration, add it to the main scope (injected variables)
    if stmt.kind == skVar:
      sc.types[stmt.vname] = stmt.vtype


proc typecheckFor(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Create new scope for loop body with loop variable
  var loopScope = Scope(types: sc.types, flags: sc.flags)

  if s.farray.isSome():
    # Array iteration: for x in array
    let arrayType = inferExprTypes(prog, fd, sc, s.farray.get(), subst)

    if arrayType.kind == tkArray:
      # Loop variable has the array element type
      loopScope.types[s.fvar] = arrayType.inner
    elif arrayType.kind == tkString:
      # String iteration - loop variable is char
      loopScope.types[s.fvar] = tChar()
    else:
      raise newTypecheckError(s.farray.get().pos, "for loop can only iterate over arrays or strings, got " & $arrayType)
  else:
    # Range iteration: for x in start..end
    let startType = inferExprTypes(prog, fd, sc, s.fstart.get(), subst)
    let endType = inferExprTypes(prog, fd, sc, s.fend.get(), subst)

    # Both start and end must be integers
    if startType.kind != tkInt:
      raise newTypecheckError(s.fstart.get().pos, "for loop start expression must be int, got " & $startType)
    if endType.kind != tkInt:
      raise newTypecheckError(s.fend.get().pos, "for loop end expression must be int, got " & $endType)

    # Loop variable is int
    loopScope.types[s.fvar] = tInt()

  loopScope.flags[s.fvar] = vfLet  # Loop variable is immutable within loop body

  # Type check loop body
  for stmt in s.fbody:
    typecheckStmt(prog, fd, loopScope, stmt, subst)

proc typecheckBreak(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  # Break statements don't need special type checking, just verify they're valid
  # (validation that break is inside a loop is done at parse time or runtime)
  discard

proc typecheckStmt*(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  case s.kind
  of skVar: typecheckVar(prog, fd, sc, s, subst)
  of skAssign: typecheckAssign(prog, fd, sc, s, subst)
  of skIf: typecheckIf(prog, fd, sc, s, subst)
  of skWhile: typecheckWhile(prog, fd, sc, s, subst)
  of skFor: typecheckFor(prog, fd, sc, s, subst)
  of skBreak: typecheckBreak(prog, fd, sc, s, subst)
  of skExpr: discard inferExprTypes(prog, fd, sc, s.sexpr, subst)
  of skReturn: typecheckReturn(prog, fd, sc, s, subst)
  of skComptime: typecheckComptime(prog, fd, sc, s, subst)
