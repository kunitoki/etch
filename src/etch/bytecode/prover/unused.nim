# unused.nim

import std/[strformat, options, tables]
import ../../common/[types, logging, errors]
import ../frontend/ast
import ./types


proc checkUnusedVariables*(env: Env, ctx: ProverContext, scopeName: string = "", excludeGlobals: bool = false, excludeNames: seq[string] = @[]) =
  ## Check for unused variables in the current scope
  logProver(ctx.options.verbose, "Checking for unused variables" & (if scopeName != "": " in " & scopeName else: ""))

  var excluded = initTable[string, bool]()
  for name in excludeNames:
    excluded[name] = true

  for varName, info in env.vals:
    if excluded.hasKey(varName):
      continue
    if info.initialized and not info.used:
      let varType = env.types.getOrDefault(varName, nil)
      if not varType.isNil and typeRequiresUsage(varType):
        if ctx.options.verbose:
          logProver(ctx.options.verbose, &"Skipping unused warning for '{varName}' due to destructor-carrying type")
        continue
      # Skip global variables if excludeGlobals is true
      if excludeGlobals and ctx.prog != nil:
        var isGlobal = false
        for g in ctx.prog.globals:
          if g.kind == skVar and g.vname == varName:
            isGlobal = true
            break
        if isGlobal:
          continue

      # Use the stored declaration position for accurate error reporting
      let pos = if env.declPos.hasKey(varName): env.declPos[varName] else: Pos(line: 1, col: 1)  # fallback position
      raise newProveError(pos, &"unused variable '{varName}'")
    elif ctx.options.verbose:
      logProver(ctx.options.verbose, &"Variable '{varName}' marked as used (initialized={info.initialized})")


proc checkUnusedGlobalVariables*(env: var Env, ctx: ProverContext) =
  ## Scan all function bodies for global variable references and mark them as used
  ## This ensures that globals used in function bodies don't get flagged as unused
  logProver(ctx.options.verbose, "Scanning function bodies for global variable usage")

  if ctx.prog == nil:
    return

  # Forward declarations for mutually recursive helpers
  proc scanExpressionForGlobals(expr: Expression, env: var Env, globals: Table[string, bool])
  proc scanStatementForGlobals(stmt: Statement, env: var Env, globals: Table[string, bool])

  # Helper to recursively scan expressions for identifier references
  proc scanExpressionForGlobals(expr: Expression, env: var Env, globals: Table[string, bool]) =
    case expr.kind
    of ekInt, ekFloat, ekString, ekBool, ekChar, ekNil:
      discard

    of ekVar:
      # Check if this is a global variable and mark it as used
      if globals.hasKey(expr.vname) and env.vals.hasKey(expr.vname):
        var info = env.vals[expr.vname]
        info.used = true
        env.vals[expr.vname] = info
        logProver(ctx.options.verbose, "  Marked global '" & expr.vname & "' as used (found in function)")

    of ekBin:
      scanExpressionForGlobals(expr.lhs, env, globals)
      scanExpressionForGlobals(expr.rhs, env, globals)

    of ekUn:
      scanExpressionForGlobals(expr.ue, env, globals)

    of ekCall:
      for arg in expr.args:
        scanExpressionForGlobals(arg, env, globals)

    of ekIndex:
      scanExpressionForGlobals(expr.arrayExpression, env, globals)
      scanExpressionForGlobals(expr.indexExpression, env, globals)

    of ekFieldAccess:
      scanExpressionForGlobals(expr.objectExpression, env, globals)

    of ekArray:
      for elem in expr.elements:
        scanExpressionForGlobals(elem, env, globals)

    of ekTuple:
      for elem in expr.tupleElements:
        scanExpressionForGlobals(elem, env, globals)

    of ekOptionSome:
      scanExpressionForGlobals(expr.someExpression, env, globals)

    of ekOptionNone:
      discard

    of ekResultOk:
      scanExpressionForGlobals(expr.okExpression, env, globals)

    of ekResultErr:
      scanExpressionForGlobals(expr.errExpression, env, globals)

    of ekResultPropagate:
      scanExpressionForGlobals(expr.propagateExpression, env, globals)

    of ekArrayLen:
      scanExpressionForGlobals(expr.lenExpression, env, globals)

    of ekCast:
      scanExpressionForGlobals(expr.castExpression, env, globals)

    of ekSlice:
      scanExpressionForGlobals(expr.sliceExpression, env, globals)
      if expr.startExpression.isSome:
        scanExpressionForGlobals(expr.startExpression.get, env, globals)
      if expr.endExpression.isSome:
        scanExpressionForGlobals(expr.endExpression.get, env, globals)

    of ekMatch:
      scanExpressionForGlobals(expr.matchExpression, env, globals)
      for matchCase in expr.cases:
        for stmt in matchCase.body:
          scanStatementForGlobals(stmt, env, globals)

    of ekIf:
      scanExpressionForGlobals(expr.ifCond, env, globals)
      for stmt in expr.ifThen:
        scanStatementForGlobals(stmt, env, globals)
      for elifBranch in expr.ifElifChain:
        scanExpressionForGlobals(elifBranch.cond, env, globals)
        for stmt in elifBranch.body:
          scanStatementForGlobals(stmt, env, globals)
      for stmt in expr.ifElse:
        scanStatementForGlobals(stmt, env, globals)

    of ekNewRef:
      if expr.init != nil:
        scanExpressionForGlobals(expr.init, env, globals)

    of ekDeref:
      scanExpressionForGlobals(expr.refExpression, env, globals)

    of ekObjectLiteral:
      for field in expr.fieldInits:
        scanExpressionForGlobals(field.value, env, globals)

    of ekNew:
      if expr.initExpression.isSome:
        scanExpressionForGlobals(expr.initExpression.get, env, globals)

    of ekComptime:
      scanExpressionForGlobals(expr.comptimeExpression, env, globals)

    of ekCompiles:
      for stmt in expr.compilesBlock:
        scanStatementForGlobals(stmt, env, globals)

    of ekYield:
      if expr.yieldValue.isSome:
        scanExpressionForGlobals(expr.yieldValue.get, env, globals)

    of ekResume:
      scanExpressionForGlobals(expr.resumeValue, env, globals)

    of ekSpawn:
      scanExpressionForGlobals(expr.spawnExpression, env, globals)

    of ekSpawnBlock:
      for stmt in expr.spawnBody:
        scanStatementForGlobals(stmt, env, globals)

    of ekChannelNew:
      if expr.channelCapacity.isSome:
        scanExpressionForGlobals(expr.channelCapacity.get, env, globals)

    of ekChannelSend:
      scanExpressionForGlobals(expr.sendChannel, env, globals)
      scanExpressionForGlobals(expr.sendValue, env, globals)

    of ekChannelRecv:
      scanExpressionForGlobals(expr.recvChannel, env, globals)

    of ekTypeof:
      scanExpressionForGlobals(expr.typeofExpression, env, globals)

    of ekLambda:
      # Scan lambda body for global variable references
      for stmt in expr.lambdaBody:
        scanStatementForGlobals(stmt, env, globals)

  # Helper to recursively scan statements for global references
  proc scanStatementForGlobals(stmt: Statement, env: var Env, globals: Table[string, bool]) =
    case stmt.kind
    of skVar:
      if stmt.vinit.isSome:
        scanExpressionForGlobals(stmt.vinit.get, env, globals)

    of skTupleUnpack:
      scanExpressionForGlobals(stmt.tupInit, env, globals)

    of skObjectUnpack:
      scanExpressionForGlobals(stmt.objInit, env, globals)

    of skAssign:
      if globals.hasKey(stmt.aname) and env.vals.hasKey(stmt.aname):
        # Assignment to global
        var info = env.vals[stmt.aname]
        info.used = true
        env.vals[stmt.aname] = info
      scanExpressionForGlobals(stmt.aval, env, globals)
    of skCompoundAssign:
      if globals.hasKey(stmt.caname) and env.vals.hasKey(stmt.caname):
        var info = env.vals[stmt.caname]
        info.used = true
        env.vals[stmt.caname] = info
      scanExpressionForGlobals(compoundAssignExpression(stmt), env, globals)

    of skFieldAssign:
      scanExpressionForGlobals(stmt.faTarget, env, globals)
      scanExpressionForGlobals(stmt.faValue, env, globals)

    of skIf:
      scanExpressionForGlobals(stmt.cond, env, globals)
      for s in stmt.thenBody:
        scanStatementForGlobals(s, env, globals)
      for elifBranch in stmt.elifChain:
        scanExpressionForGlobals(elifBranch.cond, env, globals)
        for s in elifBranch.body:
          scanStatementForGlobals(s, env, globals)
      for s in stmt.elseBody:
        scanStatementForGlobals(s, env, globals)

    of skWhile:
      scanExpressionForGlobals(stmt.wcond, env, globals)
      for s in stmt.wbody:
        scanStatementForGlobals(s, env, globals)

    of skFor:
      if stmt.fstart.isSome:
        scanExpressionForGlobals(stmt.fstart.get, env, globals)
      if stmt.fend.isSome:
        scanExpressionForGlobals(stmt.fend.get, env, globals)
      if stmt.farray.isSome:
        scanExpressionForGlobals(stmt.farray.get, env, globals)
      for s in stmt.fbody:
        scanStatementForGlobals(s, env, globals)

    of skReturn:
      if stmt.re.isSome:
        scanExpressionForGlobals(stmt.re.get, env, globals)

    of skExpression:
      scanExpressionForGlobals(stmt.sexpr, env, globals)

    of skDiscard:
      for e in stmt.dexprs:
        scanExpressionForGlobals(e, env, globals)

    of skComptime:
      for s in stmt.cbody:
        scanStatementForGlobals(s, env, globals)

    of skDefer:
      for s in stmt.deferBody:
        scanStatementForGlobals(s, env, globals)

    of skBlock:
      for s in stmt.blockBody:
        scanStatementForGlobals(s, env, globals)

    of skBreak, skTypeDecl, skImport:
      discard

  # Build a set of global variable names for quick lookup
  var globals = initTable[string, bool]()
  for g in ctx.prog.globals:
    if g.kind == skVar:
      globals[g.vname] = true

  # Scan all functions
  for funcName, funcInstance in ctx.prog.funInstances:
    logProver(ctx.options.verbose, "  Scanning function: " & funcName)
    for stmt in funcInstance.body:
      scanStatementForGlobals(stmt, env, globals)

  ## Check for unused global variables specifically
  logProver(ctx.options.verbose, "Checking for unused global variables")

  for g in ctx.prog.globals:
    if g.kind != skVar or not env.vals.hasKey(g.vname):
      continue

    let info = env.vals[g.vname]
    if info.initialized and not info.used:
      # Use the stored declaration position for accurate error reporting
      let pos = if env.declPos.hasKey(g.vname): env.declPos[g.vname] else: g.pos
      raise newProveError(pos, &"unused variable '{g.vname}'")
