# prover/function_evaluation.nim
# Function evaluation and constant folding for the safety prover

import std/[tables, options]
import ../frontend/ast
import ../../common/constants
import types


proc evalBinaryOp(bop: BinOp, a: int64, b: int64): Option[int64] =
  ## Evaluate a binary operation on two int64 values with overflow checking
  case bop
  of boAdd:
    if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b):
      return none(int64)
    return some(a + b)
  of boSub:
    if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b):
      return none(int64)
    return some(a - b)
  of boMul:
    if a != 0 and b != 0:
      let absA = if a == low(int64): high(int64) else: (if a < 0: -a else: a)
      let absB = if b == low(int64): high(int64) else: (if b < 0: -b else: b)
      if absB > 0 and absA > high(int64) div absB:
        return none(int64)
    return some(a * b)
  of boDiv:
    if b != 0: return some(a div b)
    else: return none(int64)
  of boMod:
    if b != 0: return some(a mod b)
    else: return none(int64)
  of boLt: return some(if a < b: 1'i64 else: 0'i64)
  of boLe: return some(if a <= b: 1'i64 else: 0'i64)
  of boGt: return some(if a > b: 1'i64 else: 0'i64)
  of boGe: return some(if a >= b: 1'i64 else: 0'i64)
  of boEq: return some(if a == b: 1'i64 else: 0'i64)
  of boNe: return some(if a != b: 1'i64 else: 0'i64)
  else: return none(int64)


proc tryEvaluateComplexFunction*(body: seq[Statement], paramEnv: Table[string, int64]): Option[int64] =
  ## Try to evaluate a function body with loops and local variables
  var localVars = paramEnv  # Start with parameters
  var uninitializedVars: seq[string] = @[]  # Track uninitialized variables

  proc evalExpressionLocal(expr: Expression): Option[int64] =
    case expr.kind
    of ekInt:
      return some(expr.ival)
    of ekVar:
      # Check if variable is uninitialized
      if expr.vname in uninitializedVars:
        return none(int64)  # Cannot evaluate - variable is uninitialized
      if localVars.hasKey(expr.vname):
        return some(localVars[expr.vname])
      return none(int64)
    of ekBin:
      let lhs = evalExpressionLocal(expr.lhs)
      let rhs = evalExpressionLocal(expr.rhs)
      if lhs.isSome and rhs.isSome:
        return evalBinaryOp(expr.bop, lhs.get, rhs.get)
      return none(int64)
    else:
      return none(int64)

  # Process statements in order
  for stmt in body:
    case stmt.kind
    of skVar:
      if stmt.vinit.isSome:
        let val = evalExpressionLocal(stmt.vinit.get)
        if val.isSome:
          localVars[stmt.vname] = val.get
          # Remove from uninitialized list if it was there
          let idx = uninitializedVars.find(stmt.vname)
          if idx >= 0:
            uninitializedVars.delete(idx)
        else:
          return none(int64)  # Cannot evaluate initializer
      else:
        # Variable declared without initializer - mark as uninitialized
        uninitializedVars.add(stmt.vname)
    of skAssign:
      let val = evalExpressionLocal(stmt.aval)
      if val.isSome:
        localVars[stmt.aname] = val.get
        # Assignment initializes the variable
        let idx = uninitializedVars.find(stmt.aname)
        if idx >= 0:
          uninitializedVars.delete(idx)
      else:
        return none(int64)  # Cannot evaluate assignment
    of skCompoundAssign:
      let desugared = desugarCompoundAssign(stmt)
      let val = evalExpressionLocal(desugared.aval)
      if val.isSome:
        localVars[desugared.aname] = val.get
        let idx = uninitializedVars.find(desugared.aname)
        if idx >= 0:
          uninitializedVars.delete(idx)
      else:
        return none(int64)
    of skWhile:
      # Simple loop evaluation with maximum iterations to prevent infinite loops
      var iterations = 0
      while iterations < MAX_LOOP_ITERATIONS:
        let condVal = evalExpressionLocal(stmt.wcond)
        if not condVal.isSome:
          return none(int64)  # Cannot evaluate condition
        if condVal.get == 0:
          break  # Condition is false, exit loop

        # Execute loop body
        for bodyStatement in stmt.wbody:
          case bodyStatement.kind
          of skVar:
            if bodyStatement.vinit.isSome:
              let val = evalExpressionLocal(bodyStatement.vinit.get)
              if val.isSome:
                localVars[bodyStatement.vname] = val.get
                let idx = uninitializedVars.find(bodyStatement.vname)
                if idx >= 0:
                  uninitializedVars.delete(idx)
              else:
                return none(int64)
            else:
              uninitializedVars.add(bodyStatement.vname)
          of skAssign:
            let val = evalExpressionLocal(bodyStatement.aval)
            if val.isSome:
              localVars[bodyStatement.aname] = val.get
              # Assignment initializes the variable
              let idx = uninitializedVars.find(bodyStatement.aname)
              if idx >= 0:
                uninitializedVars.delete(idx)
            else:
              return none(int64)
          of skCompoundAssign:
            let desugared = desugarCompoundAssign(bodyStatement)
            let val = evalExpressionLocal(desugared.aval)
            if val.isSome:
              localVars[desugared.aname] = val.get
              let idx = uninitializedVars.find(desugared.aname)
              if idx >= 0:
                uninitializedVars.delete(idx)
            else:
              return none(int64)
          else:
            return none(int64)  # Unsupported statement in loop body

        iterations += 1

      if iterations >= MAX_LOOP_ITERATIONS:
        return none(int64)  # Potential infinite loop
    of skReturn:
      if stmt.re.isSome:
        return evalExpressionLocal(stmt.re.get)
      return some(0'i64)  # void return
    else:
      return none(int64)  # Unsupported statement type

  # If we reach here without a return, assume void return
  return some(0'i64)


proc tryEvaluatePureFunction*(call: Expression, argInfos: seq[Info], fn: FunctionDeclaration, prog: Program): Option[int64] =
  ## Try to evaluate a pure function with constant arguments
  ## Returns the result if successful, none if the function cannot be evaluated

  # Coroutines cannot be evaluated at compile-time
  if fn.isAsync:
    return none(int64)

  # Create parameter environment with constant argument values
  var paramEnv: Table[string, int64] = initTable[string, int64]()
  var uninitializedVars: seq[string] = @[]  # Track uninitialized variables
  var recursionDepth = 0  # Track recursion depth to prevent infinite evaluation
  var executedReturn = false  # Track whether a return statement was executed

  for i, arg in argInfos:
    if i < fn.params.len and arg.known and not arg.cval.isFloat:
      paramEnv[fn.params[i].name] = arg.cval.toInt
    else:
      return none(int64)  # Cannot evaluate if not all params are constant ints

  # Forward declaration for mutual recursion
  proc evalStatement(stmt: Statement): Option[int64]
  proc evalExpression(expr: Expression): Option[int64]

  proc evalVarExpression(expr: Expression): Option[int64] =
    if expr.vname in uninitializedVars:
      return none(int64)
    if paramEnv.hasKey(expr.vname):
      return some(paramEnv[expr.vname])
    return none(int64)

  proc evalBinExpression(expr: Expression): Option[int64] =
    let lhs = evalExpression(expr.lhs)
    let rhs = evalExpression(expr.rhs)
    if lhs.isSome and rhs.isSome:
      return evalBinaryOp(expr.bop, lhs.get, rhs.get)
    return none(int64)

  proc evalCallExpression(expr: Expression): Option[int64] =
    if prog != nil and expr.fname == fn.name:
      # Check recursion depth to prevent infinite evaluation
      recursionDepth += 1
      if recursionDepth > MAX_RECURSION_DEPTH:
        recursionDepth -= 1
        return none(int64)  # Too deep, cannot evaluate

      var recursiveArgs: seq[int64] = @[]
      for arg in expr.args:
        let argResult = evalExpression(arg)
        if argResult.isSome:
          recursiveArgs.add(argResult.get)
        else:
          recursionDepth -= 1
          return none(int64)

      var newParamEnv: Table[string, int64] = initTable[string, int64]()
      for i, arg in recursiveArgs:
        if i < fn.params.len:
          newParamEnv[fn.params[i].name] = arg

      let oldParamEnv = paramEnv
      let oldExecutedReturn = executedReturn
      paramEnv = newParamEnv
      executedReturn = false

      for stmt in fn.body:
        let res = evalStatement(stmt)
        if executedReturn:
          paramEnv = oldParamEnv
          executedReturn = oldExecutedReturn
          recursionDepth -= 1
          return res
        elif not res.isSome:
          paramEnv = oldParamEnv
          executedReturn = oldExecutedReturn
          recursionDepth -= 1
          return none(int64)

      paramEnv = oldParamEnv
      executedReturn = oldExecutedReturn
      recursionDepth -= 1
      return none(int64)
    else:
      return none(int64)

  proc evalExpression(expr: Expression): Option[int64] =
    case expr.kind
    of ekInt: return some(expr.ival)
    of ekVar: return evalVarExpression(expr)
    of ekBin: return evalBinExpression(expr)
    of ekCall: return evalCallExpression(expr)
    else: return none(int64)

  proc evalVarStatement(stmt: Statement): Option[int64] =
    if stmt.vinit.isSome:
      let val = evalExpression(stmt.vinit.get)
      if val.isSome:
        paramEnv[stmt.vname] = val.get
        let idx = uninitializedVars.find(stmt.vname)
        if idx >= 0:
          uninitializedVars.delete(idx)
      else:
        return none(int64)
    else:
      uninitializedVars.add(stmt.vname)
    return some(0'i64)

  proc evalAssignStatement(stmt: Statement): Option[int64] =
    let val = evalExpression(stmt.aval)
    if val.isSome:
      paramEnv[stmt.aname] = val.get
      let idx = uninitializedVars.find(stmt.aname)
      if idx >= 0:
        uninitializedVars.delete(idx)
    else:
      return none(int64)
    return some(0'i64)

  proc evalCompoundAssignStatement(stmt: Statement): Option[int64] =
    let desugared = desugarCompoundAssign(stmt)
    evalAssignStatement(desugared)

  proc evalReturnStatement(stmt: Statement): Option[int64] =
    executedReturn = true
    if stmt.re.isSome:
      return evalExpression(stmt.re.get)
    return some(0'i64)

  proc evalIfStatement(stmt: Statement): Option[int64] =
    let condResult = evalExpression(stmt.cond)
    if not condResult.isSome:
      return none(int64)
    if condResult.get != 0:
      for thenStatement in stmt.thenBody:
        let res = evalStatement(thenStatement)
        if thenStatement.kind == skReturn and res.isSome:
          return res
        elif not res.isSome:
          return none(int64)
    else:
      for elseStatement in stmt.elseBody:
        let res = evalStatement(elseStatement)
        if elseStatement.kind == skReturn and res.isSome:
          return res
        elif not res.isSome:
          return none(int64)
    return some(0'i64)

  proc evalStatement(stmt: Statement): Option[int64] =
    case stmt.kind
    of skVar: return evalVarStatement(stmt)
    of skAssign: return evalAssignStatement(stmt)
    of skCompoundAssign: return evalCompoundAssignStatement(stmt)
    of skReturn: return evalReturnStatement(stmt)
    of skIf: return evalIfStatement(stmt)
    else: return none(int64)

  # Try to evaluate the function body
  if fn.body.len == 1 and (fn.body[0].kind == skReturn or fn.body[0].kind == skIf):
    # Simple case: single return statement or single if statement
    let res = evalStatement(fn.body[0])
    if fn.body[0].kind == skReturn:
      return res
    elif res.isSome and res.get == 0:
      return some(0'i64)
    else:
      return res
  elif fn.body.len > 1:
    # Process multiple statements in sequence
    for stmt in fn.body:
      let res = evalStatement(stmt)
      if executedReturn:
        # A return statement was executed (either explicitly or inside control flow)
        return res
      elif not res.isSome:
        # Statement failed to evaluate - give up
        return none(int64)
      # Otherwise: statement succeeded but didn't return - continue to next statement
    # Try to handle more complex function bodies with loops and variables
    return tryEvaluateComplexFunction(fn.body, paramEnv)
  else:
    return none(int64)
