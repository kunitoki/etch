# inference.nim
# Return type inference for functions

import std/[strformat, options]
import ../frontend/ast, ../common/errors
import types, expressions


proc collectReturnTypes*(prog: Program, fd: FunDecl, sc: Scope, statements: seq[Stmt], subst: var TySubst): seq[EtchType] =
  ## Collect all return types from statements, recursively looking into control flow
  result = @[]
  for stmt in statements:
    case stmt.kind:
    of skReturn:
      if stmt.re.isSome():
        let returnType = inferExprTypes(prog, fd, sc, stmt.re.get(), subst)
        result.add(returnType)
      else:
        result.add(tVoid())
    of skIf:
      # Collect from if branch
      if stmt.thenBody.len > 0:
        result.add(collectReturnTypes(prog, fd, sc, stmt.thenBody, subst))
      # Collect from elif branches
      for elifBranch in stmt.elifChain:
        if elifBranch.body.len > 0:
          result.add(collectReturnTypes(prog, fd, sc, elifBranch.body, subst))
      # Collect from else branch
      if stmt.elseBody.len > 0:
        result.add(collectReturnTypes(prog, fd, sc, stmt.elseBody, subst))
    of skWhile:
      if stmt.wbody.len > 0:
        result.add(collectReturnTypes(prog, fd, sc, stmt.wbody, subst))
    of skComptime:
      if stmt.cbody.len > 0:
        result.add(collectReturnTypes(prog, fd, sc, stmt.cbody, subst))
    else:
      discard # Other statements don't contain returns


proc inferReturnType*(returnTypes: seq[EtchType]): EtchType =
  ## Infer a single return type from collected return types, or return void if no returns
  if returnTypes.len == 0:
    return tVoid()

  # Check that all return types are the same
  let firstType = returnTypes[0]
  for i in 1..<returnTypes.len:
    if not typeEq(firstType, returnTypes[i]):
      raise newEtchError(&"conflicting return types: {firstType} and {returnTypes[i]}")

  return firstType
