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


proc typecheckStmt*(prog: Program; fd: FunDecl; sc: Scope; s: Stmt; subst: var TySubst) =
  case s.kind
  of skVar: typecheckVar(prog, fd, sc, s, subst)
  of skAssign: typecheckAssign(prog, fd, sc, s, subst)
  of skIf: typecheckIf(prog, fd, sc, s, subst)
  of skWhile: typecheckWhile(prog, fd, sc, s, subst)
  of skExpr: discard inferExprTypes(prog, fd, sc, s.sexpr, subst)
  of skReturn: typecheckReturn(prog, fd, sc, s, subst)
  of skComptime: typecheckComptime(prog, fd, sc, s, subst)
