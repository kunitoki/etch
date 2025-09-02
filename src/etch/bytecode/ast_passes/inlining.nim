# inlining.nim
# AST-level function inlining optimization pass

import std/[tables, options, strformat, strutils, sets]
import base
import ../frontend/ast
import ../../common/types



const
  MAX_INLINE_SIZE = 20          # Maximum function body size (in statements) to inline
  MAX_INLINES_PER_FUNCTION = 5  # Maximum number of functions to inline into a single function


proc cloneStatement(stmt: Statement): Statement
proc substituteInStatement(stmt: Statement, paramName: string, argExpression: Expression): Statement
proc setOriginalFunctionInStatement(stmt: Statement, funcName: string)


proc isInlinableFunction(fun: FunctionDeclaration, maxSize: int): bool =
  ## Check if a function is suitable for inlining
  ## Criteria:
  ## - Small (< maxSize statements)
  ## - No yields (not a coroutine)
  ## - No complex control flow (simple functions only)
  ## - No defer statements (they have complex scope semantics)
  ## - Not a host/ffi function (host functions must be called via C/FFI API)

  if fun.isAsync or fun.isCFFI or fun.isHost:
    return false

  # Don't inline functions that take coroutine parameters
  # (coroutines have complex control flow semantics)
  for param in fun.params:
    if param.typ != nil and param.typ.kind == tkCoroutine:
      return false

  # Count statements (simple metric)
  if fun.body.len > maxSize:
    return false

  # Check for complex control flow and defer statements
  var hasComplexControl = false
  var hasDefer = false
  var returnCount = 0
  var hasResultPropagation = false

  proc checkExpression(expr: Expression) =
    case expr.kind
    of ekNew:
      if expr.initExpression.isSome:
        checkExpression(expr.initExpression.get())
    of ekBin:
      checkExpression(expr.lhs)
      checkExpression(expr.rhs)
    of ekUn:
      checkExpression(expr.ue)
    of ekCall:
      for arg in expr.args:
        checkExpression(arg)
    of ekResultPropagate:
      hasResultPropagation = true
      checkExpression(expr.propagateExpression)
    else:
      discard

  proc checkStatement(stmt: Statement) =
    case stmt.kind
    of skReturn:
      returnCount += 1
      if stmt.re.isSome:
        checkExpression(stmt.re.get)
    of skWhile, skFor:
      hasComplexControl = true
    of skDefer:
      # Defer statements have complex semantics - don't inline
      hasDefer = true
    of skVar:
      if stmt.vinit.isSome:
        checkExpression(stmt.vinit.get)
    of skExpression:
      checkExpression(stmt.sexpr)
    of skAssign:
      checkExpression(stmt.aval)
    of skCompoundAssign:
      checkExpression(stmt.crhs)
    of skIf:
      # Simple if statements are OK, but check bodies
      checkExpression(stmt.cond)
      for s in stmt.thenBody:
        checkStatement(s)
      for (c, body) in stmt.elifChain:
        checkExpression(c)
        for s in body:
          checkStatement(s)
      for s in stmt.elseBody:
        checkStatement(s)
    of skBlock:
      # Check block body
      for s in stmt.blockBody:
        checkStatement(s)
    else:
      discard

  for stmt in fun.body:
    checkStatement(stmt)

  # Allow at most one return statement at the end
  if returnCount > 1 or hasComplexControl or hasDefer or hasResultPropagation:
    return false

  return true


proc cloneExpression(expr: Expression): Expression =
  ## Deep clone an expression
  case expr.kind
  of ekBool:
    Expression(kind: ekBool, bval: expr.bval, typ: expr.typ, pos: expr.pos)
  of ekChar:
    Expression(kind: ekChar, cval: expr.cval, typ: expr.typ, pos: expr.pos)
  of ekInt:
    Expression(kind: ekInt, ival: expr.ival, typ: expr.typ, pos: expr.pos)
  of ekFloat:
    Expression(kind: ekFloat, fval: expr.fval, typ: expr.typ, pos: expr.pos)
  of ekString:
    Expression(kind: ekString, sval: expr.sval, typ: expr.typ, pos: expr.pos)
  of ekVar:
    Expression(kind: ekVar, vname: expr.vname, typ: expr.typ, pos: expr.pos)
  of ekBin:
    Expression(kind: ekBin, bop: expr.bop, lhs: cloneExpression(expr.lhs), rhs: cloneExpression(expr.rhs), typ: expr.typ, pos: expr.pos)
  of ekUn:
    Expression(kind: ekUn, uop: expr.uop, ue: cloneExpression(expr.ue), typ: expr.typ, pos: expr.pos)
  of ekCall:
    var clonedArgs: seq[Expression] = @[]
    for arg in expr.args:
      clonedArgs.add(cloneExpression(arg))
    let clonedTarget = if expr.callTarget != nil: cloneExpression(expr.callTarget) else: nil
    Expression(kind: ekCall, fname: expr.fname, args: clonedArgs, instTypes: expr.instTypes, callTarget: clonedTarget, callIsValue: expr.callIsValue, typ: expr.typ, pos: expr.pos)
  of ekIndex:
    Expression(kind: ekIndex, arrayExpression: cloneExpression(expr.arrayExpression), indexExpression: cloneExpression(expr.indexExpression), typ: expr.typ, pos: expr.pos)
  of ekFieldAccess:
    Expression(kind: ekFieldAccess, objectExpression: cloneExpression(expr.objectExpression), fieldName: expr.fieldName, typ: expr.typ, pos: expr.pos)
  of ekArrayLen:
    Expression(kind: ekArrayLen, lenExpression: cloneExpression(expr.lenExpression), typ: expr.typ, pos: expr.pos)
  of ekCast:
    Expression(kind: ekCast, castType: expr.castType, castExpression: cloneExpression(expr.castExpression), typ: expr.typ, pos: expr.pos)
  of ekArray:
    var clonedElements: seq[Expression] = @[]
    for elem in expr.elements:
      clonedElements.add(cloneExpression(elem))
    Expression(kind: ekArray, elements: clonedElements, typ: expr.typ, pos: expr.pos)
  of ekNew:
    Expression(kind: ekNew, newType: expr.newType, initExpression: if expr.initExpression.isSome: some(cloneExpression(expr.initExpression.get())) else: none(Expression), typ: expr.typ, pos: expr.pos)
  of ekObjectLiteral:
    var clonedFields: seq[tuple[name: string, value: Expression]] = @[]
    for (name, value) in expr.fieldInits:
      clonedFields.add((name, cloneExpression(value)))
    Expression(kind: ekObjectLiteral, objectType: expr.objectType, fieldInits: clonedFields, typ: expr.typ, pos: expr.pos)
  of ekDeref:
    Expression(kind: ekDeref, refExpression: cloneExpression(expr.refExpression), typ: expr.typ, pos: expr.pos)
  of ekNewRef:
    Expression(kind: ekNewRef, init: cloneExpression(expr.init), refInner: expr.refInner, typ: expr.typ, pos: expr.pos)
  of ekOptionSome:
    Expression(kind: ekOptionSome, someExpression: cloneExpression(expr.someExpression), typ: expr.typ, pos: expr.pos)
  of ekResultOk:
    Expression(kind: ekResultOk, okExpression: cloneExpression(expr.okExpression), typ: expr.typ, pos: expr.pos)
  of ekResultErr:
    Expression(kind: ekResultErr, errExpression: cloneExpression(expr.errExpression), typ: expr.typ, pos: expr.pos)
  of ekResultPropagate:
    Expression(kind: ekResultPropagate, propagateExpression: cloneExpression(expr.propagateExpression), typ: expr.typ, pos: expr.pos)
  of ekTuple:
    var clonedElements: seq[Expression] = @[]
    for elem in expr.tupleElements:
      clonedElements.add(cloneExpression(elem))
    Expression(kind: ekTuple, tupleElements: clonedElements, typ: expr.typ, pos: expr.pos)
  of ekMatch:
    var clonedCases: seq[MatchCase] = @[]
    for c in expr.cases:
      var clonedBody: seq[Statement] = @[]
      for stmt in c.body:
        clonedBody.add(cloneStatement(stmt))
      clonedCases.add(MatchCase(pattern: c.pattern, body: clonedBody))
    Expression(
      kind: ekMatch,
      matchExpression: cloneExpression(expr.matchExpression),
      cases: clonedCases,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekLambda:
    var clonedParams: seq[Param] = @[]
    for param in expr.lambdaParams:
      clonedParams.add(Param(
        name: param.name,
        typ: param.typ,
        defaultValue: if param.defaultValue.isSome: some(cloneExpression(param.defaultValue.get())) else: none(Expression)
      ))

    var clonedBody: seq[Statement] = @[]
    for stmt in expr.lambdaBody:
      clonedBody.add(cloneStatement(stmt))

    var clonedCaptures: seq[string] = @[]
    for cap in expr.lambdaCaptures:
      clonedCaptures.add(cap)

    var clonedCaptureTypes: seq[EtchType] = @[]
    for capType in expr.lambdaCaptureTypes:
      clonedCaptureTypes.add(capType)

    Expression(
      kind: ekLambda,
      lambdaCaptures: clonedCaptures,
      lambdaParams: clonedParams,
      lambdaReturnType: expr.lambdaReturnType,
      lambdaBody: clonedBody,
      lambdaCaptureTypes: clonedCaptureTypes,
      lambdaFunctionName: expr.lambdaFunctionName,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekNil:
    Expression(kind: ekNil, typ: expr.typ, pos: expr.pos)
  of ekOptionNone:
    Expression(kind: ekOptionNone, typ: expr.typ, pos: expr.pos)
  else:
    # For complex expressions, return as-is for now
    expr


proc cloneStatement(stmt: Statement): Statement =
  ## Deep clone a statement
  case stmt.kind
  of skVar:
    Statement(
      kind: skVar,
      vflag: stmt.vflag,
      vname: stmt.vname,
      vtype: stmt.vtype,
      vinit: if stmt.vinit.isSome: some(cloneExpression(stmt.vinit.get())) else: none(Expression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skAssign:
    Statement(
      kind: skAssign,
      aname: stmt.aname,
      aval: cloneExpression(stmt.aval),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skCompoundAssign:
    Statement(
      kind: skCompoundAssign,
      caname: stmt.caname,
      cop: stmt.cop,
      crhs: cloneExpression(stmt.crhs),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skFieldAssign:
    Statement(
      kind: skFieldAssign,
      faTarget: cloneExpression(stmt.faTarget),
      faValue: cloneExpression(stmt.faValue),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skExpression:
    Statement(
      kind: skExpression,
      sexpr: cloneExpression(stmt.sexpr),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skReturn:
    Statement(
      kind: skReturn,
      re: if stmt.re.isSome: some(cloneExpression(stmt.re.get())) else: none(Expression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skIf:
    var clonedElif: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
    for (cond, body) in stmt.elifChain:
      var clonedBody: seq[Statement] = @[]
      for s in body:
        clonedBody.add(cloneStatement(s))
      clonedElif.add((cloneExpression(cond), clonedBody))

    var clonedThen: seq[Statement] = @[]
    for s in stmt.thenBody:
      clonedThen.add(cloneStatement(s))

    var clonedElse: seq[Statement] = @[]
    for s in stmt.elseBody:
      clonedElse.add(cloneStatement(s))

    Statement(
      kind: skIf,
      cond: cloneExpression(stmt.cond),
      thenBody: clonedThen,
      elifChain: clonedElif,
      elseBody: clonedElse,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skDiscard:
    var clonedExpressions: seq[Expression] = @[]
    for expr in stmt.dexprs:
      clonedExpressions.add(cloneExpression(expr))
    Statement(
      kind: skDiscard,
      dexprs: clonedExpressions,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  else:
    # For other statement types, return as-is for now
    stmt


proc substituteVariable(expr: Expression, paramName: string, argExpression: Expression): Expression =
  ## Substitute all occurrences of paramName with argExpression in expr
  ## IMPORTANT: Preserves the original position from expr, not argExpression
  case expr.kind
  of ekVar:
    if expr.vname == paramName:
      # Clone the argument but preserve the ORIGINAL position
      # This ensures error messages point to the original function code
      let cloned = cloneExpression(argExpression)
      cloned.pos = expr.pos  # Keep the position where the variable was used
      cloned
    else:
      expr
  of ekBin:
    Expression(
      kind: ekBin,
      bop: expr.bop,
      lhs: substituteVariable(expr.lhs, paramName, argExpression),
      rhs: substituteVariable(expr.rhs, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekUn:
    Expression(
      kind: ekUn,
      uop: expr.uop,
      ue: substituteVariable(expr.ue, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekCall:
    var substArgs: seq[Expression] = @[]
    for arg in expr.args:
      substArgs.add(substituteVariable(arg, paramName, argExpression))
    let substTarget = if expr.callTarget != nil: substituteVariable(expr.callTarget, paramName, argExpression) else: nil
    Expression(
      kind: ekCall,
      fname: expr.fname,
      args: substArgs,
      instTypes: expr.instTypes,
      callTarget: substTarget,
      callIsValue: expr.callIsValue,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekIndex:
    Expression(
      kind: ekIndex,
      arrayExpression: substituteVariable(expr.arrayExpression, paramName, argExpression),
      indexExpression: substituteVariable(expr.indexExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekFieldAccess:
    Expression(
      kind: ekFieldAccess,
      objectExpression: substituteVariable(expr.objectExpression, paramName, argExpression),
      fieldName: expr.fieldName,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekArrayLen:
    Expression(
      kind: ekArrayLen,
      lenExpression: substituteVariable(expr.lenExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekCast:
    Expression(
      kind: ekCast,
      castType: expr.castType,
      castExpression: substituteVariable(expr.castExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekArray:
    var substElements: seq[Expression] = @[]
    for elem in expr.elements:
      substElements.add(substituteVariable(elem, paramName, argExpression))
    Expression(
      kind: ekArray,
      elements: substElements,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekNew:
    Expression(
      kind: ekNew,
      newType: expr.newType,
      initExpression: if expr.initExpression.isSome: some(substituteVariable(expr.initExpression.get(), paramName, argExpression)) else: none(Expression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekObjectLiteral:
    var substFields: seq[tuple[name: string, value: Expression]] = @[]
    for (name, value) in expr.fieldInits:
      substFields.add((name, substituteVariable(value, paramName, argExpression)))
    Expression(
      kind: ekObjectLiteral,
      objectType: expr.objectType,
      fieldInits: substFields,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekDeref:
    Expression(
      kind: ekDeref,
      refExpression: substituteVariable(expr.refExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekNewRef:
    Expression(
      kind: ekNewRef,
      init: substituteVariable(expr.init, paramName, argExpression),
      refInner: expr.refInner,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekOptionSome:
    Expression(
      kind: ekOptionSome,
      someExpression: substituteVariable(expr.someExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekResultOk:
    Expression(
      kind: ekResultOk,
      okExpression: substituteVariable(expr.okExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekResultErr:
    Expression(
      kind: ekResultErr,
      errExpression: substituteVariable(expr.errExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekResultPropagate:
    Expression(
      kind: ekResultPropagate,
      propagateExpression: substituteVariable(expr.propagateExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekTuple:
    var substElements: seq[Expression] = @[]
    for elem in expr.tupleElements:
      substElements.add(substituteVariable(elem, paramName, argExpression))
    Expression(
      kind: ekTuple,
      tupleElements: substElements,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekMatch:
    var substCases: seq[MatchCase] = @[]
    for c in expr.cases:
      var substBody: seq[Statement] = @[]
      for stmt in c.body:
        substBody.add(substituteInStatement(stmt, paramName, argExpression))
      substCases.add(MatchCase(pattern: c.pattern, body: substBody))
    Expression(
      kind: ekMatch,
      matchExpression: substituteVariable(expr.matchExpression, paramName, argExpression),
      cases: substCases,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekIf:
    var substThen: seq[Statement] = @[]
    for stmt in expr.ifThen:
      substThen.add(substituteInStatement(stmt, paramName, argExpression))

    var substElif: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
    for (cond, body) in expr.ifElifChain:
      var substBody: seq[Statement] = @[]
      for stmt in body:
        substBody.add(substituteInStatement(stmt, paramName, argExpression))
      substElif.add((substituteVariable(cond, paramName, argExpression), substBody))

    var substElse: seq[Statement] = @[]
    for stmt in expr.ifElse:
      substElse.add(substituteInStatement(stmt, paramName, argExpression))

    Expression(
      kind: ekIf,
      ifCond: substituteVariable(expr.ifCond, paramName, argExpression),
      ifThen: substThen,
      ifElifChain: substElif,
      ifElse: substElse,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekComptime:
    Expression(
      kind: ekComptime,
      comptimeExpression: substituteVariable(expr.comptimeExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekCompiles:
    var substBody: seq[Statement] = @[]
    for stmt in expr.compilesBlock:
      substBody.add(substituteInStatement(stmt, paramName, argExpression))
    Expression(
      kind: ekCompiles,
      compilesBlock: substBody,
      compilesEnv: expr.compilesEnv,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekYield:
    Expression(
      kind: ekYield,
      yieldValue: if expr.yieldValue.isSome: some(substituteVariable(expr.yieldValue.get(), paramName, argExpression)) else: none(Expression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekResume:
    Expression(
      kind: ekResume,
      resumeValue: substituteVariable(expr.resumeValue, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekSpawn:
    Expression(
      kind: ekSpawn,
      spawnExpression: substituteVariable(expr.spawnExpression, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekSpawnBlock:
    var substBody: seq[Statement] = @[]
    for stmt in expr.spawnBody:
      substBody.add(substituteInStatement(stmt, paramName, argExpression))
    Expression(
      kind: ekSpawnBlock,
      spawnBody: substBody,
      typ: expr.typ,
      pos: expr.pos
    )
  of ekChannelNew:
    Expression(
      kind: ekChannelNew,
      channelType: expr.channelType,
      channelCapacity: if expr.channelCapacity.isSome: some(substituteVariable(expr.channelCapacity.get(), paramName, argExpression)) else: none(Expression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekChannelSend:
    Expression(
      kind: ekChannelSend,
      sendChannel: substituteVariable(expr.sendChannel, paramName, argExpression),
      sendValue: substituteVariable(expr.sendValue, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekChannelRecv:
    Expression(
      kind: ekChannelRecv,
      recvChannel: substituteVariable(expr.recvChannel, paramName, argExpression),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekLambda:
    # Captured variables are handled explicitly via closure bindings, so skip substitution inside lambdas
    expr
  else:
    expr


proc substituteInStatement(stmt: Statement, paramName: string, argExpression: Expression): Statement =
  ## Substitute parameter with argument in a statement
  case stmt.kind
  of skAssign:
    Statement(
      kind: skAssign,
      aname: stmt.aname,
      aval: substituteVariable(stmt.aval, paramName, argExpression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skCompoundAssign:
    Statement(
      kind: skCompoundAssign,
      caname: stmt.caname,
      cop: stmt.cop,
      crhs: substituteVariable(stmt.crhs, paramName, argExpression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skFieldAssign:
    Statement(
      kind: skFieldAssign,
      faTarget: substituteVariable(stmt.faTarget, paramName, argExpression),
      faValue: substituteVariable(stmt.faValue, paramName, argExpression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skExpression:
    Statement(
      kind: skExpression,
      sexpr: substituteVariable(stmt.sexpr, paramName, argExpression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skReturn:
    Statement(
      kind: skReturn,
      re: if stmt.re.isSome: some(substituteVariable(stmt.re.get(), paramName, argExpression)) else: none(Expression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skVar:
    Statement(
      kind: skVar,
      vflag: stmt.vflag,
      vname: stmt.vname,
      vtype: stmt.vtype,
      vinit: if stmt.vinit.isSome: some(substituteVariable(stmt.vinit.get(), paramName, argExpression)) else: none(Expression),
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skIf:
    # Substitute in condition and all branches
    var substElif: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
    for (cond, body) in stmt.elifChain:
      var substBody: seq[Statement] = @[]
      for s in body:
        substBody.add(substituteInStatement(s, paramName, argExpression))
      substElif.add((substituteVariable(cond, paramName, argExpression), substBody))

    var substThen: seq[Statement] = @[]
    for s in stmt.thenBody:
      substThen.add(substituteInStatement(s, paramName, argExpression))

    var substElse: seq[Statement] = @[]
    for s in stmt.elseBody:
      substElse.add(substituteInStatement(s, paramName, argExpression))

    Statement(
      kind: skIf,
      cond: substituteVariable(stmt.cond, paramName, argExpression),
      thenBody: substThen,
      elifChain: substElif,
      elseBody: substElse,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skWhile:
    var substBody: seq[Statement] = @[]
    for s in stmt.wbody:
      substBody.add(substituteInStatement(s, paramName, argExpression))
    Statement(
      kind: skWhile,
      wcond: substituteVariable(stmt.wcond, paramName, argExpression),
      wbody: substBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skFor:
    var substBody: seq[Statement] = @[]
    for s in stmt.fbody:
      substBody.add(substituteInStatement(s, paramName, argExpression))
    Statement(
      kind: skFor,
      fvar: stmt.fvar,
      fstart: if stmt.fstart.isSome: some(substituteVariable(stmt.fstart.get(), paramName, argExpression)) else: none(Expression),
      fend: if stmt.fend.isSome: some(substituteVariable(stmt.fend.get(), paramName, argExpression)) else: none(Expression),
      farray: if stmt.farray.isSome: some(substituteVariable(stmt.farray.get(), paramName, argExpression)) else: none(Expression),
      finclusive: stmt.finclusive,
      fbody: substBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skBlock:
    var substBody: seq[Statement] = @[]
    for s in stmt.blockBody:
      substBody.add(substituteInStatement(s, paramName, argExpression))
    Statement(
      kind: skBlock,
      blockBody: substBody,
      blockHoistedVars: stmt.blockHoistedVars,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skDefer:
    var substBody: seq[Statement] = @[]
    for s in stmt.deferBody:
      substBody.add(substituteInStatement(s, paramName, argExpression))
    Statement(
      kind: skDefer,
      deferBody: substBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  of skDiscard:
    # Substitute parameters in all discarded expressions
    var substExpressions: seq[Expression] = @[]
    for expr in stmt.dexprs:
      substExpressions.add(substituteVariable(expr, paramName, argExpression))
    Statement(
      kind: skDiscard,
      dexprs: substExpressions,
      pos: stmt.pos,
      isExported: stmt.isExported
    )
  else:
    stmt


proc setOriginalFunctionInExpression(expr: Expression, funcName: string) =
  ## Recursively set originalFunction in all positions in an expression tree
  if expr.pos.originalFunction == "":
    expr.pos.originalFunction = funcName

  case expr.kind
  of ekBin:
    setOriginalFunctionInExpression(expr.lhs, funcName)
    setOriginalFunctionInExpression(expr.rhs, funcName)
  of ekUn:
    setOriginalFunctionInExpression(expr.ue, funcName)
  of ekCall:
    for arg in expr.args:
      setOriginalFunctionInExpression(arg, funcName)
  of ekIndex:
    setOriginalFunctionInExpression(expr.arrayExpression, funcName)
    setOriginalFunctionInExpression(expr.indexExpression, funcName)
  of ekFieldAccess:
    setOriginalFunctionInExpression(expr.objectExpression, funcName)
  of ekArrayLen:
    setOriginalFunctionInExpression(expr.lenExpression, funcName)
  of ekCast:
    setOriginalFunctionInExpression(expr.castExpression, funcName)
  of ekArray:
    for elem in expr.elements:
      setOriginalFunctionInExpression(elem, funcName)
  of ekNew:
    if expr.initExpression.isSome:
      setOriginalFunctionInExpression(expr.initExpression.get(), funcName)
  of ekObjectLiteral:
    for (_, value) in expr.fieldInits:
      setOriginalFunctionInExpression(value, funcName)
  of ekDeref:
    setOriginalFunctionInExpression(expr.refExpression, funcName)
  of ekNewRef:
    setOriginalFunctionInExpression(expr.init, funcName)
  of ekOptionSome:
    setOriginalFunctionInExpression(expr.someExpression, funcName)
  of ekResultOk:
    setOriginalFunctionInExpression(expr.okExpression, funcName)
  of ekResultErr:
    setOriginalFunctionInExpression(expr.errExpression, funcName)
  of ekResultPropagate:
    setOriginalFunctionInExpression(expr.propagateExpression, funcName)
  of ekTuple:
    for elem in expr.tupleElements:
      setOriginalFunctionInExpression(elem, funcName)
  of ekMatch:
    setOriginalFunctionInExpression(expr.matchExpression, funcName)
    for c in expr.cases:
      for stmt in c.body:
        setOriginalFunctionInStatement(stmt, funcName)
  else:
    discard


proc setOriginalFunctionInStatement(stmt: Statement, funcName: string) =
  ## Recursively set originalFunction in all positions in a statement tree
  if stmt.pos.originalFunction == "":
    stmt.pos.originalFunction = funcName

  case stmt.kind
  of skVar:
    if stmt.vinit.isSome:
      setOriginalFunctionInExpression(stmt.vinit.get(), funcName)
  of skAssign:
    setOriginalFunctionInExpression(stmt.aval, funcName)
  of skCompoundAssign:
    setOriginalFunctionInExpression(stmt.crhs, funcName)
  of skFieldAssign:
    setOriginalFunctionInExpression(stmt.faTarget, funcName)
    setOriginalFunctionInExpression(stmt.faValue, funcName)
  of skExpression:
    setOriginalFunctionInExpression(stmt.sexpr, funcName)
  of skReturn:
    if stmt.re.isSome:
      setOriginalFunctionInExpression(stmt.re.get(), funcName)
  of skIf:
    setOriginalFunctionInExpression(stmt.cond, funcName)
    for s in stmt.thenBody:
      setOriginalFunctionInStatement(s, funcName)
    for (cond, body) in stmt.elifChain:
      setOriginalFunctionInExpression(cond, funcName)
      for s in body:
        setOriginalFunctionInStatement(s, funcName)
    for s in stmt.elseBody:
      setOriginalFunctionInStatement(s, funcName)
  of skWhile:
    setOriginalFunctionInExpression(stmt.wcond, funcName)
    for s in stmt.wbody:
      setOriginalFunctionInStatement(s, funcName)
  of skFor:
    if stmt.fstart.isSome:
      setOriginalFunctionInExpression(stmt.fstart.get(), funcName)
    if stmt.fend.isSome:
      setOriginalFunctionInExpression(stmt.fend.get(), funcName)
    if stmt.farray.isSome:
      setOriginalFunctionInExpression(stmt.farray.get(), funcName)
    for s in stmt.fbody:
      setOriginalFunctionInStatement(s, funcName)
  of skBlock:
    for s in stmt.blockBody:
      setOriginalFunctionInStatement(s, funcName)
  of skDefer:
    for s in stmt.deferBody:
      setOriginalFunctionInStatement(s, funcName)
  else:
    discard


proc collectLambdaCapturedParams(fun: FunctionDeclaration): HashSet[string] =
  ## Collect function parameter names that appear in lambda capture lists
  if fun.isNil or fun.params.len == 0:
    return initHashSet[string]()

  var captured = initHashSet[string]()

  var paramNames = initHashSet[string]()
  for param in fun.params:
    paramNames.incl(param.name)

  proc visitStatement(stmt: Statement)
  proc visitExpression(expr: Expression)

  proc visitExpression(expr: Expression) =
    if expr.isNil:
      return

    case expr.kind
    of ekLambda:
      for cap in expr.lambdaCaptures:
        if paramNames.contains(cap):
          captured.incl(cap)
      for bodyStmt in expr.lambdaBody:
        visitStatement(bodyStmt)
    of ekBin:
      visitExpression(expr.lhs)
      visitExpression(expr.rhs)
    of ekUn:
      visitExpression(expr.ue)
    of ekCall:
      for arg in expr.args:
        visitExpression(arg)
      if expr.callTarget != nil:
        visitExpression(expr.callTarget)
    of ekIndex:
      visitExpression(expr.arrayExpression)
      visitExpression(expr.indexExpression)
    of ekFieldAccess:
      visitExpression(expr.objectExpression)
    of ekArrayLen:
      visitExpression(expr.lenExpression)
    of ekCast:
      visitExpression(expr.castExpression)
    of ekArray:
      for elem in expr.elements:
        visitExpression(elem)
    of ekNew:
      if expr.initExpression.isSome:
        visitExpression(expr.initExpression.get())
    of ekObjectLiteral:
      for (_, value) in expr.fieldInits:
        visitExpression(value)
    of ekDeref:
      visitExpression(expr.refExpression)
    of ekNewRef:
      visitExpression(expr.init)
    of ekOptionSome:
      visitExpression(expr.someExpression)
    of ekResultOk:
      visitExpression(expr.okExpression)
    of ekResultErr:
      visitExpression(expr.errExpression)
    of ekResultPropagate:
      visitExpression(expr.propagateExpression)
    of ekTuple:
      for elem in expr.tupleElements:
        visitExpression(elem)
    of ekMatch:
      visitExpression(expr.matchExpression)
      for caseStmt in expr.cases:
        for bodyStmt in caseStmt.body:
          visitStatement(bodyStmt)
    of ekIf:
      visitExpression(expr.ifCond)
      for stmt in expr.ifThen:
        visitStatement(stmt)
      for (condExpr, body) in expr.ifElifChain:
        visitExpression(condExpr)
        for stmt in body:
          visitStatement(stmt)
      for stmt in expr.ifElse:
        visitStatement(stmt)
    of ekComptime:
      visitExpression(expr.comptimeExpression)
    of ekCompiles:
      for stmt in expr.compilesBlock:
        visitStatement(stmt)
    of ekYield:
      if expr.yieldValue.isSome:
        visitExpression(expr.yieldValue.get())
    of ekResume:
      visitExpression(expr.resumeValue)
    of ekSpawn:
      visitExpression(expr.spawnExpression)
    of ekSpawnBlock:
      for stmt in expr.spawnBody:
        visitStatement(stmt)
    of ekChannelNew:
      if expr.channelCapacity.isSome:
        visitExpression(expr.channelCapacity.get())
    of ekChannelSend:
      visitExpression(expr.sendChannel)
      visitExpression(expr.sendValue)
    of ekChannelRecv:
      visitExpression(expr.recvChannel)
    else:
      discard

  proc visitStatement(stmt: Statement) =
    if stmt.isNil:
      return

    case stmt.kind
    of skVar:
      if stmt.vinit.isSome:
        visitExpression(stmt.vinit.get())
    of skAssign:
      visitExpression(stmt.aval)
    of skCompoundAssign:
      visitExpression(stmt.crhs)
    of skFieldAssign:
      visitExpression(stmt.faTarget)
      visitExpression(stmt.faValue)
    of skExpression:
      visitExpression(stmt.sexpr)
    of skReturn:
      if stmt.re.isSome:
        visitExpression(stmt.re.get())
    of skIf:
      visitExpression(stmt.cond)
      for bodyStmt in stmt.thenBody:
        visitStatement(bodyStmt)
      for (condExpr, body) in stmt.elifChain:
        visitExpression(condExpr)
        for bodyStmt in body:
          visitStatement(bodyStmt)
      for bodyStmt in stmt.elseBody:
        visitStatement(bodyStmt)
    of skWhile:
      visitExpression(stmt.wcond)
      for bodyStmt in stmt.wbody:
        visitStatement(bodyStmt)
    of skFor:
      if stmt.fstart.isSome:
        visitExpression(stmt.fstart.get())
      if stmt.fend.isSome:
        visitExpression(stmt.fend.get())
      if stmt.farray.isSome:
        visitExpression(stmt.farray.get())
      for bodyStmt in stmt.fbody:
        visitStatement(bodyStmt)
    of skComptime:
      for bodyStmt in stmt.cbody:
        visitStatement(bodyStmt)
    of skDefer:
      for bodyStmt in stmt.deferBody:
        visitStatement(bodyStmt)
    of skBlock:
      for bodyStmt in stmt.blockBody:
        visitStatement(bodyStmt)
    of skDiscard:
      for expr in stmt.dexprs:
        visitExpression(expr)
    of skTupleUnpack:
      visitExpression(stmt.tupInit)
    of skObjectUnpack:
      visitExpression(stmt.objInit)
    else:
      discard

  for stmt in fun.body:
    visitStatement(stmt)

  return captured


proc tryInlineCall(callExpression: Expression, program: Program, ctx: PassContext): Option[seq[Statement]] =
  ## Try to inline a function call
  ## Returns the inlined statements if successful
  if callExpression.kind != ekCall:
    return none(seq[Statement])

  let funcName = callExpression.fname

  # Look up the function
  if not program.funInstances.hasKey(funcName):
    return none(seq[Statement])

  let fun = program.funInstances[funcName]

  # Conservative safety: do not inline compiler-generated lambdas by default.
  # Lambdas are lowered to functions named like "__lambda_<n>" and may
  # rely on capture semantics / closure lowering. Inlining them can change
  # semantics or confuse subsequent passes (captures, name/pos info), so
  # skip them unless we implement a more precise safety analysis.
  if funcName.startsWith("__lambda_"):
    logPass(ctx, &"  Skipping inlining of lambda {funcName}")
    return none(seq[Statement])

  # Check if function is inlinable
  if not isInlinableFunction(fun, MAX_INLINE_SIZE):
    logPass(ctx, &"  Function {funcName} not inlinable (too large or complex)")
    return none(seq[Statement])

  # Check argument count matches
  if callExpression.args.len != fun.params.len:
    return none(seq[Statement])

  logPass(ctx, &"  Inlining function {funcName} (size: {fun.body.len} statements)")

  # Clone function body and substitute parameters
  var inlinedBody: seq[Statement] = @[]
  let lambdaCapturedParams = collectLambdaCapturedParams(fun)

  # Parameters captured by lambdas must stay addressable so the captures
  # keep pointing at a concrete variable after inlining.
  for i in 0 ..< callExpression.args.len:
    let param = fun.params[i]
    if lambdaCapturedParams.contains(param.name):
      let binding = Statement(
        kind: skVar,
        vflag: vfLet,
        vname: param.name,
        vtype: param.typ,
        vinit: some(cloneExpression(callExpression.args[i])),
        pos: callExpression.args[i].pos,
        isExported: false
      )
      inlinedBody.add(binding)

  # For each argument that is a variable, add a dummy statement at the beginning
  # to ensure the variable is marked as "used" by the prover,
  # even if the inlined function body doesn't actually use the parameter
  for i in 0 ..< callExpression.args.len:
    let arg = callExpression.args[i]
    if arg.kind == ekVar and not lambdaCapturedParams.contains(fun.params[i].name):
      # Create a dummy expression statement that references the variable
      let dummyStatement = Statement(
        kind: skExpression,
        sexpr: arg,
        pos: arg.pos,
        isExported: false
      )
      inlinedBody.add(dummyStatement)

  for stmt in fun.body:
    var cloned = cloneStatement(stmt)

    # Substitute each parameter with its argument
    for i in 0 ..< fun.params.len:
      let paramName = fun.params[i].name
      if lambdaCapturedParams.contains(paramName):
        continue
      let argExpression = callExpression.args[i]
      cloned = substituteInStatement(cloned, paramName, argExpression)

    # Mark all positions in the inlined code with the original function name
    # Use functionNameFromSignature to convert "divide::ii:i" to "divide"
    let readableName = &"function {functionNameFromSignature(funcName)}"
    setOriginalFunctionInStatement(cloned, readableName)

    inlinedBody.add(cloned)

  ctx.stats.functionsInlined += 1

  return some(inlinedBody)


proc wrapInlineBody(body: seq[Statement], blockPos: Pos, hoistedVars: seq[string] = @[]): seq[Statement] =
  ## Wrap inlined statements inside their own block to preserve original scopes
  if body.len == 0:
    return @[]

  return @[Statement(
    kind: skBlock,
    blockBody: body,
    blockHoistedVars: hoistedVars,
    pos: blockPos,
    isExported: false
  )]


proc transformExpressionForInlining(expr: Expression, program: Program, ctx: PassContext): Expression =
  ## Recursively transform an expression, looking for inlining opportunities
  case expr.kind
  of ekBin:
    Expression(
      kind: ekBin,
      bop: expr.bop,
      lhs: transformExpressionForInlining(expr.lhs, program, ctx),
      rhs: transformExpressionForInlining(expr.rhs, program, ctx),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekUn:
    Expression(
      kind: ekUn,
      uop: expr.uop,
      ue: transformExpressionForInlining(expr.ue, program, ctx),
      typ: expr.typ,
      pos: expr.pos
    )
  of ekCall:
    # Note: For now we can't inline calls that are part of expressions
    # because we'd need to introduce temporary variables
    # This is a simplification - we only inline statement-level calls
    var transformedArgs: seq[Expression] = @[]
    for arg in expr.args:
      transformedArgs.add(transformExpressionForInlining(arg, program, ctx))
    let transformedTarget = if expr.callTarget != nil: transformExpressionForInlining(expr.callTarget, program, ctx) else: nil
    Expression(
      kind: ekCall,
      fname: expr.fname,
      args: transformedArgs,
      instTypes: expr.instTypes,
      callTarget: transformedTarget,
      callIsValue: expr.callIsValue,
      typ: expr.typ,
      pos: expr.pos
    )
  else:
    expr


proc transformStatementForInlining(stmt: Statement, program: Program, ctx: PassContext): seq[Statement] =
  ## Transform a statement, potentially inlining function calls
  case stmt.kind
  of skExpression:
    # Check if this is a call expression we can inline
    if stmt.sexpr.kind == ekCall:
      let inlined = tryInlineCall(stmt.sexpr, program, ctx)
      if inlined.isSome:
        return wrapInlineBody(inlined.get(), stmt.pos)

    # Otherwise, recursively transform the expression
    return @[Statement(
      kind: skExpression,
      sexpr: transformExpressionForInlining(stmt.sexpr, program, ctx),
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skAssign:
    # Check if we're assigning from a call
    if stmt.aval.kind == ekCall:
      let inlined = tryInlineCall(stmt.aval, program, ctx)
      if inlined.isSome:
        # We need to replace the last return with an assignment
        var body = inlined.get()
        if body.len > 0 and body[^1].kind == skReturn and body[^1].re.isSome:
          body[^1] = Statement(
            kind: skAssign,
            aname: stmt.aname,
            aval: body[^1].re.get(),
            pos: stmt.pos,
            isExported: stmt.isExported
          )
          return wrapInlineBody(body, stmt.pos, @[stmt.aname])

    return @[Statement(
      kind: skAssign,
      aname: stmt.aname,
      aval: transformExpressionForInlining(stmt.aval, program, ctx),
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skCompoundAssign:
    return @[Statement(
      kind: skCompoundAssign,
      caname: stmt.caname,
      cop: stmt.cop,
      crhs: transformExpressionForInlining(stmt.crhs, program, ctx),
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skVar:
    # Check if we're initializing from a call
    if stmt.vinit.isSome and stmt.vinit.get().kind == ekCall:
      let inlined = tryInlineCall(stmt.vinit.get(), program, ctx)
      if inlined.isSome:
        var body = inlined.get()
        if body.len > 0 and body[^1].kind == skReturn and body[^1].re.isSome:
          logPass(ctx, &"    Hoisting declaration {stmt.vname} out of inline block")
          body[^1] = Statement(
            kind: skVar,
            vflag: stmt.vflag,
            vname: stmt.vname,
            vtype: stmt.vtype,
            vinit: some(body[^1].re.get()),
            pos: stmt.pos,
            isExported: stmt.isExported
          )
          return wrapInlineBody(body, stmt.pos, @[stmt.vname])

    return @[stmt]

  of skFor:
    # Recursively transform loop body so we can inline inner statements
    var transformedBody: seq[Statement] = @[]
    for bodyStmt in stmt.fbody:
      transformedBody.add(transformStatementForInlining(bodyStmt, program, ctx))

    let startExpr =
      if stmt.fstart.isSome:
        some(transformExpressionForInlining(stmt.fstart.get(), program, ctx))
      else:
        none(Expression)
    let endExpr =
      if stmt.fend.isSome:
        some(transformExpressionForInlining(stmt.fend.get(), program, ctx))
      else:
        none(Expression)
    let arrayExpr =
      if stmt.farray.isSome:
        some(transformExpressionForInlining(stmt.farray.get(), program, ctx))
      else:
        none(Expression)

    return @[Statement(
      kind: skFor,
      fvar: stmt.fvar,
      fstart: startExpr,
      fend: endExpr,
      farray: arrayExpr,
      finclusive: stmt.finclusive,
      fbody: transformedBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skWhile:
    var transformedBody: seq[Statement] = @[]
    for bodyStmt in stmt.wbody:
      transformedBody.add(transformStatementForInlining(bodyStmt, program, ctx))

    return @[Statement(
      kind: skWhile,
      wcond: transformExpressionForInlining(stmt.wcond, program, ctx),
      wbody: transformedBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skBlock:
    var transformedBody: seq[Statement] = @[]
    for bodyStmt in stmt.blockBody:
      transformedBody.add(transformStatementForInlining(bodyStmt, program, ctx))

    return @[Statement(
      kind: skBlock,
      blockBody: transformedBody,
      blockHoistedVars: stmt.blockHoistedVars,
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skDefer:
    var transformedBody: seq[Statement] = @[]
    for bodyStmt in stmt.deferBody:
      transformedBody.add(transformStatementForInlining(bodyStmt, program, ctx))

    return @[Statement(
      kind: skDefer,
      deferBody: transformedBody,
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skIf:
    # Recursively transform if branches
    var transformedThen: seq[Statement] = @[]
    for s in stmt.thenBody:
      transformedThen.add(transformStatementForInlining(s, program, ctx))

    var transformedElif: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
    for (cond, body) in stmt.elifChain:
      var transformedBody: seq[Statement] = @[]
      for s in body:
        transformedBody.add(transformStatementForInlining(s, program, ctx))
      transformedElif.add((cond, transformedBody))

    var transformedElse: seq[Statement] = @[]
    for s in stmt.elseBody:
      transformedElse.add(transformStatementForInlining(s, program, ctx))

    return @[Statement(
      kind: skIf,
      cond: stmt.cond,
      thenBody: transformedThen,
      elifChain: transformedElif,
      elseBody: transformedElse,
      pos: stmt.pos,
      isExported: stmt.isExported
    )]

  of skReturn:
    if stmt.re.isSome:
      return @[Statement(
        kind: skReturn,
        re: some(transformExpressionForInlining(stmt.re.get(), program, ctx)),
        pos: stmt.pos,
        isExported: stmt.isExported
      )]
    return @[stmt]

  else:
    return @[stmt]


proc inliningPass*(program: Program, ctx: PassContext): bool =
  ## Function inlining pass
  ## Inlines small, simple functions
  ## Limits inlining per function to avoid register overflow
  var modified = false

  for name, fun in program.funInstances.mpairs:
    logPass(ctx, &"Analyzing function {name} for inlining opportunities")

    var inlineCount = 0  # Track how many functions we've inlined
    var newBody: seq[Statement] = @[]

    for stmt in fun.body:
      # Check if we've hit the inline limit
      if inlineCount >= MAX_INLINES_PER_FUNCTION:
        # Stop inlining, just add remaining statements as-is
        newBody.add(stmt)
        continue

      let transformed = transformStatementForInlining(stmt, program, ctx)

      # Count how many functions were inlined in this transformation
      if transformed.len != 1 or transformed[0] != stmt:
        modified = true
        inlineCount += 1  # Increment for each call that was inlined

      newBody.add(transformed)

    if newBody != fun.body:
      fun.body = newBody
      logPass(ctx, &"  Inlined {inlineCount} calls in function {name}")

  return modified
