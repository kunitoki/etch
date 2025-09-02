# core.nim
# Main type checker core functions and unified type inference

import std/[tables]
import ../frontend/ast
import ../../common/builtins
import types, statements



proc typecheck*(prog: Program) =
  var subst: TySubst

  # First pass: collect all variable declarations for forward references
  var gscope = Scope(
    types: initTable[string, EtchType](),
    flags: initTable[string, VarFlag](),
    userTypes: initTable[string, EtchType](),
    prog: prog
  )

  # Second pass: add all user-defined types to scope
  for typeName, typeDecl in prog.types:
    gscope.userTypes[typeName] = typeDecl

  # Third pass: add all global variable types to scope (without checking initializers)
  for g in prog.globals:
    if g.kind == skVar:
      gscope.types[g.vname] = g.vtype
      gscope.flags[g.vname] = g.vflag

  # Register top-level functions as callable values in the global scope when unambiguous
  # This allows references like `fnName` to be used as a function value (fn pointer)
  for fname, overloads in prog.funs:
    if isBuiltin(fname): continue
    # Try to build a single function type if overloads are identical or there's a single overload
    if overloads.len == 1:
      let f = overloads[0]
      var ptypes: seq[EtchType] = @[]
      for p in f.params:
        ptypes.add(resolveNestedUserTypes(gscope, p.typ, f.pos))
      let rett = if f.ret == nil: tVoid() else: resolveNestedUserTypes(gscope, f.ret, f.pos)
      gscope.types[fname] = tFunction(ptypes, rett)
      gscope.flags[fname] = vfLet
    else:
      # If multiple overloads, see if they all share the same signature
      var firstSig: EtchType = nil
      var allSame = true
      for f in overloads:
        var ptypes: seq[EtchType] = @[]
        for p in f.params:
          ptypes.add(resolveNestedUserTypes(gscope, p.typ, f.pos))
        let rett = if f.ret == nil: tVoid() else: resolveNestedUserTypes(gscope, f.ret, f.pos)
        let sig = tFunction(ptypes, rett)
        if firstSig.isNil:
          firstSig = sig
        else:
          if not typeEq(firstSig, sig):
            allSame = false
            break
      if allSame and not firstSig.isNil:
        gscope.types[fname] = firstSig
        gscope.flags[fname] = vfLet

  # Fourth pass: typecheck all global statements with complete scope
  for g in prog.globals:
    typecheckStatement(prog, nil, gscope, g, subst)
