# cleanup.nim
# AST-level cleanup pass to remove redundant operations

import tables, strformat, options
import base
import ../frontend/ast


proc isRedundantAssignment(stmt: Statement, prevStatement: Statement): bool =
  ## Check if an assignment is redundant (assigning a variable to itself)
  if stmt.kind != skAssign or prevStatement.kind != skAssign:
    return false

  # Check if we're assigning var to itself (a = a)
  if stmt.aval.kind == ekVar and stmt.aval.vname == stmt.aname:
    return true

  # Check if previous statement assigns to same variable
  # and current statement just moves it again
  if prevStatement.aname == stmt.aname:
    # a = expr; a = a -> keep only first
    if stmt.aval.kind == ekVar and stmt.aval.vname == stmt.aname:
      return true

  return false


proc usesVariable(expr: Expression, varName: string): bool =
  ## Check if an expression uses a specific variable
  case expr.kind
  of ekVar:
    expr.vname == varName
  of ekBin:
    usesVariable(expr.lhs, varName) or usesVariable(expr.rhs, varName)
  of ekUn:
    usesVariable(expr.ue, varName)
  of ekFieldAccess:
    usesVariable(expr.objectExpression, varName)
  of ekIndex:
    usesVariable(expr.arrayExpression, varName) or usesVariable(expr.indexExpression, varName)
  of ekArrayLen:
    usesVariable(expr.lenExpression, varName)
  of ekCast:
    usesVariable(expr.castExpression, varName)
  of ekCall:
    for arg in expr.args:
      if usesVariable(arg, varName):
        return true
    false
  of ekArray:
    for elem in expr.elements:
      if usesVariable(elem, varName):
        return true
    false
  of ekTuple:
    for elem in expr.tupleElements:
      if usesVariable(elem, varName):
        return true
    false
  else:
    # For complex expressions (if, match, etc.) or literals, conservatively assume no usage
    # This is safe because we only use this to detect dead stores - false negatives are okay
    false


proc hasNoSideEffects(expr: Expression): bool =
  ## Check if an expression has no side effects
  ## (safe to eliminate if result is unused)
  case expr.kind
  of ekInt, ekFloat, ekString, ekChar, ekBool, ekVar, ekNil:
    true
  of ekBin:
    hasNoSideEffects(expr.lhs) and hasNoSideEffects(expr.rhs)
  of ekUn:
    hasNoSideEffects(expr.ue)
  of ekFieldAccess:
    hasNoSideEffects(expr.objectExpression)
  of ekIndex:
    hasNoSideEffects(expr.arrayExpression) and hasNoSideEffects(expr.indexExpression)
  of ekArrayLen:
    hasNoSideEffects(expr.lenExpression)
  of ekCast:
    hasNoSideEffects(expr.castExpression)
  else:
    # Calls, allocations, etc. have side effects
    false


proc isDeadStore(stmt: Statement, nextStatement: Statement): bool =
  ## Check if this is a dead store (variable assigned but immediately reassigned)
  ## IMPORTANT: Only eliminates if:
  ## 1. The first assignment has no side effects
  ## 2. The next assignment does NOT use the variable's current value
  if stmt.kind != skAssign and stmt.kind != skVar:
    return false

  if nextStatement.kind != skAssign:
    return false

  let varName = if stmt.kind == skAssign: stmt.aname else: stmt.vname

  # If next statement assigns to the same variable, this store MIGHT be dead
  if nextStatement.aname == varName:
    # Check if the initial value has side effects
    let initExpression = if stmt.kind == skAssign: stmt.aval else:
                   if stmt.vinit.isSome: stmt.vinit.get else: return false

    # Don't eliminate if initialization has side effects
    if not hasNoSideEffects(initExpression):
      return false

    # CRITICAL: Check if the next assignment uses the variable's current value
    # Example: acc = 10; acc = acc + 5  -> NOT a dead store (acc is read)
    # Example: acc = 10; acc = 20       -> IS a dead store (acc not read)
    if usesVariable(nextStatement.aval, varName):
      return false

    return true

  return false


proc isUnusedExpression(stmt: Statement): bool =
  ## Check if this is an expression statement with no side effects
  if stmt.kind != skExpression:
    return false

  return hasNoSideEffects(stmt.sexpr)


proc cleanupStatements(stmts: seq[Statement], ctx: PassContext): seq[Statement] =
  ## Clean up a sequence of statements
  result = @[]

  var i = 0
  while i < stmts.len:
    let stmt = stmts[i]
    var shouldKeep = true
    var transformedStatement = stmt

    # Check for redundant assignments
    if i > 0 and isRedundantAssignment(stmt, stmts[i-1]):
      logPass(ctx, &"  Removing redundant assignment")
      ctx.stats.deadCodeEliminated += 1
      shouldKeep = false

    # Check for dead stores
    elif i < stmts.len - 1 and isDeadStore(stmt, stmts[i+1]):
      # For variable declarations, transform to remove initialization
      # For assignments, remove entirely
      if stmt.kind == skVar:
        logPass(ctx, &"  Removing dead initialization from variable declaration")
        ctx.stats.deadCodeEliminated += 1
        # Keep the declaration but remove the initialization
        transformedStatement = Statement(
          kind: skVar,
          vname: stmt.vname,
          vtype: stmt.vtype,
          vinit: none(Expression),  # Remove initialization
          pos: stmt.pos,
          isExported: stmt.isExported
        )
      else:
        logPass(ctx, &"  Removing dead store")
        ctx.stats.deadCodeEliminated += 1
        shouldKeep = false

    # Check for unused pure expressions
    elif isUnusedExpression(stmt):
      logPass(ctx, &"  Removing unused pure expression")
      ctx.stats.deadCodeEliminated += 1
      shouldKeep = false

    if shouldKeep:
      # Recursively clean up nested statements
      case transformedStatement.kind
      of skIf:
        var cleanedElif: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
        for (cond, body) in transformedStatement.elifChain:
          cleanedElif.add((cond, cleanupStatements(body, ctx)))

        result.add(Statement(
          kind: skIf,
          cond: transformedStatement.cond,
          thenBody: cleanupStatements(transformedStatement.thenBody, ctx),
          elifChain: cleanedElif,
          elseBody: cleanupStatements(transformedStatement.elseBody, ctx),
          pos: transformedStatement.pos,
          isExported: transformedStatement.isExported
        ))

      of skWhile:
        result.add(Statement(
          kind: skWhile,
          wcond: transformedStatement.wcond,
          wbody: cleanupStatements(transformedStatement.wbody, ctx),
          pos: transformedStatement.pos,
          isExported: transformedStatement.isExported
        ))

      of skFor:
        result.add(Statement(
          kind: skFor,
          fvar: transformedStatement.fvar,
          fstart: transformedStatement.fstart,
          fend: transformedStatement.fend,
          farray: transformedStatement.farray,
          finclusive: transformedStatement.finclusive,
          fbody: cleanupStatements(transformedStatement.fbody, ctx),
          pos: transformedStatement.pos,
          isExported: transformedStatement.isExported
        ))

      of skBlock:
        result.add(Statement(
          kind: skBlock,
          blockBody: cleanupStatements(transformedStatement.blockBody, ctx),
          blockHoistedVars: transformedStatement.blockHoistedVars,
          pos: transformedStatement.pos,
          isExported: transformedStatement.isExported
        ))

      of skDefer:
        result.add(Statement(
          kind: skDefer,
          deferBody: cleanupStatements(transformedStatement.deferBody, ctx),
          pos: transformedStatement.pos,
          isExported: transformedStatement.isExported
        ))

      else:
        result.add(transformedStatement)

    i += 1


proc cleanupPass*(program: Program, ctx: PassContext): bool =
  ## Cleanup pass to remove redundant operations
  ## Removes:
  ## - Redundant assignments (a = a)
  ## - Dead stores (a = x; a = y -> a = y)
  ## - Unused pure expressions
  var modified = false

  for name, fun in program.funInstances.mpairs:
    let originalLen = fun.body.len
    fun.body = cleanupStatements(fun.body, ctx)

    if fun.body.len < originalLen:
      modified = true
      logPass(ctx, &"  Cleaned up function {name} ({originalLen - fun.body.len} statements removed)")

  return modified
