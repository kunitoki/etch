# visitor.nim
# Generic AST visitor pattern for traversing and querying the AST

import std/options
import ./ast


## Generic AST visitor - walks the AST and calls predicate on each expr/stmt
## Returns true if predicate returns true for any node (short-circuits)
type
  ASTVisitorContext* = object
    skipLambdas*: bool       # Don't traverse into lambda bodies
    skipComptime*: bool      # Don't traverse into comptime blocks


proc visitExpression*(expr: Expression, predicate: proc(e: Expression): bool, ctx: ASTVisitorContext): bool
proc visitStatement*(stmt: Statement, predicate: proc(e: Expression): bool, ctx: ASTVisitorContext): bool


proc visitExpression*(expr: Expression, predicate: proc(e: Expression): bool, ctx: ASTVisitorContext): bool =
  # Check current node
  if predicate(expr):
    return true

  # Recursively visit children
  case expr.kind
  of ekBool, ekChar, ekInt, ekFloat, ekString, ekVar, ekNil, ekOptionNone:
    return false

  of ekBin:
    return visitExpression(expr.lhs, predicate, ctx) or visitExpression(expr.rhs, predicate, ctx)

  of ekUn:
    return visitExpression(expr.ue, predicate, ctx)

  of ekCall:
    if expr.callTarget != nil and visitExpression(expr.callTarget, predicate, ctx):
      return true
    for arg in expr.args:
      if visitExpression(arg, predicate, ctx):
        return true
    return false

  of ekIndex:
    return visitExpression(expr.arrayExpression, predicate, ctx) or visitExpression(expr.indexExpression, predicate, ctx)

  of ekSlice:
    if visitExpression(expr.sliceExpression, predicate, ctx):
      return true
    if expr.startExpression.isSome and visitExpression(expr.startExpression.get, predicate, ctx):
      return true
    if expr.endExpression.isSome and visitExpression(expr.endExpression.get, predicate, ctx):
      return true
    return false

  of ekArrayLen:
    return visitExpression(expr.lenExpression, predicate, ctx)

  of ekFieldAccess:
    return visitExpression(expr.objectExpression, predicate, ctx)

  of ekArray:
    for elem in expr.elements:
      if visitExpression(elem, predicate, ctx):
        return true
    return false

  of ekTuple:
    for elem in expr.tupleElements:
      if visitExpression(elem, predicate, ctx):
        return true
    return false

  of ekObjectLiteral:
    for fieldInit in expr.fieldInits:
      if visitExpression(fieldInit.value, predicate, ctx):
        return true
    return false

  of ekNew:
    if expr.initExpression.isSome:
      return visitExpression(expr.initExpression.get, predicate, ctx)
    return false

  of ekNewRef:
    return visitExpression(expr.init, predicate, ctx)

  of ekDeref:
    return visitExpression(expr.refExpression, predicate, ctx)

  of ekCast:
    return visitExpression(expr.castExpression, predicate, ctx)

  of ekOptionSome:
    return visitExpression(expr.someExpression, predicate, ctx)

  of ekResultOk:
    return visitExpression(expr.okExpression, predicate, ctx)

  of ekResultErr:
    return visitExpression(expr.errExpression, predicate, ctx)

  of ekResultPropagate:
    return visitExpression(expr.propagateExpression, predicate, ctx)

  of ekIf:
    if visitExpression(expr.ifCond, predicate, ctx):
      return true
    for stmt in expr.ifThen:
      if visitStatement(stmt, predicate, ctx):
        return true
    for branch in expr.ifElifChain:
      if visitExpression(branch.cond, predicate, ctx):
        return true
      for stmt in branch.body:
        if visitStatement(stmt, predicate, ctx):
          return true
    for stmt in expr.ifElse:
      if visitStatement(stmt, predicate, ctx):
        return true
    return false

  of ekMatch:
    if visitExpression(expr.matchExpression, predicate, ctx):
      return true
    for matchCase in expr.cases:
      for stmt in matchCase.body:
        if visitStatement(stmt, predicate, ctx):
          return true
    return false

  of ekComptime:
    if ctx.skipComptime:
      return false
    return visitExpression(expr.comptimeExpression, predicate, ctx)

  of ekCompiles:
    return false  # Don't traverse compiles blocks

  of ekSpawn:
    return visitExpression(expr.spawnExpression, predicate, ctx)

  of ekSpawnBlock:
    for stmt in expr.spawnBody:
      if visitStatement(stmt, predicate, ctx):
        return true
    return false

  of ekChannelNew:
    if expr.channelCapacity.isSome:
      return visitExpression(expr.channelCapacity.get, predicate, ctx)
    return false

  of ekChannelSend:
    return visitExpression(expr.sendChannel, predicate, ctx) or visitExpression(expr.sendValue, predicate, ctx)

  of ekChannelRecv:
    return visitExpression(expr.recvChannel, predicate, ctx)

  of ekTypeof:
    return visitExpression(expr.typeofExpression, predicate, ctx)

  of ekYield:
    return false  # Handled by predicate above

  of ekResume:
    return visitExpression(expr.resumeValue, predicate, ctx)

  of ekLambda:
    if ctx.skipLambdas:
      return false
    # Visit lambda body statements
    for stmt in expr.lambdaBody:
      if visitStatement(stmt, predicate, ctx):
        return true
    return false


proc visitStatement*(stmt: Statement, predicate: proc(e: Expression): bool, ctx: ASTVisitorContext): bool =
  case stmt.kind
  of skVar:
    if stmt.vinit.isSome:
      return visitExpression(stmt.vinit.get, predicate, ctx)
    return false

  of skAssign:
    return visitExpression(stmt.aval, predicate, ctx)

  of skCompoundAssign:
    return visitExpression(stmt.crhs, predicate, ctx)

  of skFieldAssign:
    return visitExpression(stmt.faTarget, predicate, ctx) or visitExpression(stmt.faValue, predicate, ctx)

  of skExpression:
    return visitExpression(stmt.sexpr, predicate, ctx)

  of skReturn:
    if stmt.re.isSome:
      return visitExpression(stmt.re.get, predicate, ctx)
    return false

  of skIf:
    if visitExpression(stmt.cond, predicate, ctx):
      return true
    for s in stmt.thenBody:
      if visitStatement(s, predicate, ctx):
        return true
    for branch in stmt.elifChain:
      if visitExpression(branch.cond, predicate, ctx):
        return true
      for s in branch.body:
        if visitStatement(s, predicate, ctx):
          return true
    for s in stmt.elseBody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skWhile:
    if visitExpression(stmt.wcond, predicate, ctx):
      return true
    for s in stmt.wbody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skFor:
    if stmt.fstart.isSome and visitExpression(stmt.fstart.get, predicate, ctx):
      return true
    if stmt.fend.isSome and visitExpression(stmt.fend.get, predicate, ctx):
      return true
    if stmt.farray.isSome and visitExpression(stmt.farray.get, predicate, ctx):
      return true
    for s in stmt.fbody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skBlock:
    for s in stmt.blockBody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skDefer:
    for s in stmt.deferBody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skComptime:
    if ctx.skipComptime:
      return false
    for s in stmt.cbody:
      if visitStatement(s, predicate, ctx):
        return true
    return false

  of skTupleUnpack:
    return visitExpression(stmt.tupInit, predicate, ctx)

  of skObjectUnpack:
    return visitExpression(stmt.objInit, predicate, ctx)

  of skDiscard:
    for expr in stmt.dexprs:
      if visitExpression(expr, predicate, ctx):
        return true
    return false

  of skBreak, skTypeDecl, skImport:
    return false
