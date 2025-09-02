# expressions.nim
# Expression type inference for the type checker

import std/[strformat, options, sequtils, tables, strutils]
import ../../common/[constants, builtins, errors, types]
import ../frontend/ast
import ./[types, lambda]


proc inferExpressionTypes*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType {.exportc.}
proc inferMatchExpression(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType {.importc.}
proc typecheckStatementList*(prog: Program; fd: FunctionDeclaration; sc: Scope; stmts: seq[Statement]; subst: var TySubst; blockResultUsed: bool = false; expectedResultType: EtchType = nil): EtchType {.importc.}
proc collectReturnTypesFromTypedAST*(statements: seq[Statement]): seq[ReturnInfo]


proc collectYieldTypesFromTypedAST*(statements: seq[Statement]): seq[EtchType] =
  ## Collect yield types from already type-checked statements
  result = @[]
  for stmt in statements:
    case stmt.kind:
    of skExpression:
      if stmt.sexpr.kind == ekYield:
        result.add(stmt.sexpr.typ)
    of skIf:
      if stmt.thenBody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.thenBody))
      for elifBranch in stmt.elifChain:
        if elifBranch.body.len > 0:
          result.add(collectYieldTypesFromTypedAST(elifBranch.body))
      if stmt.elseBody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.elseBody))
    of skWhile:
      if stmt.wbody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.wbody))
    of skFor:
      if stmt.fbody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.fbody))
    of skBlock:
      if stmt.blockBody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.blockBody))
    of skComptime:
      if stmt.cbody.len > 0:
        result.add(collectYieldTypesFromTypedAST(stmt.cbody))
    else:
      discard


proc collectReturnTypesFromExpression(e: Expression): seq[ReturnInfo] =
  case e.kind
  of ekMatch:
    for matchCase in e.cases:
      if matchCase.body.len > 0:
        result.add(collectReturnTypesFromTypedAST(matchCase.body))
  of ekIf:
    if e.ifThen.len > 0:
      result.add(collectReturnTypesFromTypedAST(e.ifThen))
    for elifCase in e.ifElifChain:
      if elifCase.body.len > 0:
        result.add(collectReturnTypesFromTypedAST(elifCase.body))
    if e.ifElse.len > 0:
      result.add(collectReturnTypesFromTypedAST(e.ifElse))
  of ekSpawnBlock:
    if e.spawnBody.len > 0:
      result.add(collectReturnTypesFromTypedAST(e.spawnBody))
  of ekLambda:
    if e.lambdaBody.len > 0:
      result.add(collectReturnTypesFromTypedAST(e.lambdaBody))
  else:
    discard


proc collectReturnTypesFromTypedAST*(statements: seq[Statement]): seq[ReturnInfo] =
  ## Collect return types from already type-checked statements
  result = @[]
  for stmt in statements:
    case stmt.kind:
    of skReturn:
      let hasValue = stmt.re.isSome()
      let returnType = if hasValue: stmt.re.get().typ else: tVoid()
      result.add(ReturnInfo(typ: returnType, pos: stmt.pos, hasValue: hasValue))
    of skIf:
      if stmt.thenBody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.thenBody))
      for elifBranch in stmt.elifChain:
        if elifBranch.body.len > 0:
          result.add(collectReturnTypesFromTypedAST(elifBranch.body))
      if stmt.elseBody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.elseBody))
    of skWhile:
      if stmt.wbody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.wbody))
    of skFor:
      if stmt.fbody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.fbody))
    of skBlock:
      if stmt.blockBody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.blockBody))
    of skComptime:
      if stmt.cbody.len > 0:
        result.add(collectReturnTypesFromTypedAST(stmt.cbody))
    of skExpression:
      result.add(collectReturnTypesFromExpression(stmt.sexpr))
    else:
      discard


proc collectReturnTypes*(prog: Program, fd: FunctionDeclaration, sc: Scope, statements: seq[Statement], subst: var TySubst): seq[EtchType] =
  ## Collect all return types from statements, recursively looking into control flow
  result = @[]
  for stmt in statements:
    case stmt.kind:
    of skReturn:
      if stmt.re.isSome():
        let returnType = inferExpressionTypes(prog, fd, sc, stmt.re.get(), subst)
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


proc inferReturnType*(returnTypes: seq[EtchType], pos: Pos): EtchType =
  ## Infer a single return type from collected return types, or return void if no returns
  if returnTypes.len == 0:
    return tVoid()

  # Check that all return types are the same
  let firstType = returnTypes[0]
  for i in 1..<returnTypes.len:
    if not typeEq(firstType, returnTypes[i]):
      raise newTypecheckError(pos, &"conflicting return types: {firstType} and {returnTypes[i]}")

  return firstType


include inference/function_expressions
include inference/arithmetic_expressions
include inference/var_expressions
include inference/object_expressions
include inference/if_expressions
include inference/monad_expressions
include inference/propagate_expressions
include inference/cast_expressions
include inference/slice_expressions
include inference/tuple_expressions
include inference/array_expressions
include inference/ref_expressions
include inference/coroutine_expressions
include inference/comptime_expressions
include inference/typeof_expressions


proc inferExpressionTypes*(prog: Program; fd: FunctionDeclaration; sc: Scope; e: Expression; subst: var TySubst; expectedTy: EtchType = nil): EtchType =
  result = case e.kind
  of ekInt, ekFloat, ekString, ekChar, ekBool, ekNil: inferLiteralExpression(prog, fd, sc, e, subst, expectedTy)
  of ekVar: inferVarExpression(prog, fd, sc, e, subst)
  of ekUn: inferUnOp(prog, fd, sc, e, subst)
  of ekBin: inferBinOp(prog, fd, sc, e, subst)
  of ekCall: inferCallExpression(prog, fd, sc, e, subst)
  of ekNewRef: inferNewRefExpression(prog, fd, sc, e, subst)
  of ekDeref: inferDerefExpression(prog, fd, sc, e, subst)
  of ekArray: inferArrayExpression(prog, fd, sc, e, subst, expectedTy)
  of ekIndex: inferIndexExpression(prog, fd, sc, e, subst)
  of ekSlice: inferSliceExpression(prog, fd, sc, e, subst)
  of ekArrayLen: inferArrayLenExpression(prog, fd, sc, e, subst)
  of ekCast: inferCastExpression(prog, fd, sc, e, subst)
  of ekOptionSome: inferOptionSomeExpression(prog, fd, sc, e, subst)
  of ekOptionNone: inferOptionNoneExpression(prog, fd, sc, e, subst, expectedTy)
  of ekResultOk: inferResultOkExpression(prog, fd, sc, e, subst)
  of ekResultErr: inferResultErrExpression(prog, fd, sc, e, subst, expectedTy)
  of ekResultPropagate: inferResultPropagateExpression(prog, fd, sc, e, subst)
  of ekMatch: inferMatchExpression(prog, fd, sc, e, subst, expectedTy)
  of ekObjectLiteral: inferObjectLiteralExpression(prog, fd, sc, e, subst, expectedTy)
  of ekFieldAccess: inferFieldAccessExpression(prog, fd, sc, e, subst)
  of ekTuple: inferTupleExpression(prog, fd, sc, e, subst, expectedTy)
  of ekNew: inferNewExpression(prog, fd, sc, e, subst)
  of ekIf: inferIfExpression(prog, fd, sc, e, subst)
  of ekComptime: inferComptimeExpression(prog, fd, sc, e, subst, expectedTy)
  of ekCompiles: inferCompilesExpression(prog, fd, sc, e, subst)
  of ekYield: inferYieldExpression(prog, fd, sc, e, subst)
  of ekResume: inferResumeExpression(prog, fd, sc, e, subst)
  of ekSpawn: inferSpawnExpression(prog, fd, sc, e, subst)
  of ekSpawnBlock: inferSpawnBlockExpression(prog, fd, sc, e, subst)
  of ekChannelNew: inferChannelNewExpression(prog, fd, sc, e, subst)
  of ekChannelSend: inferChannelSendExpression(prog, fd, sc, e, subst)
  of ekChannelRecv: inferChannelRecvExpression(prog, fd, sc, e, subst)
  of ekLambda: inferLambdaExpression(prog, fd, sc, e, subst, expectedTy)
  of ekTypeof: inferTypeofExpression(prog, fd, sc, e, subst)
