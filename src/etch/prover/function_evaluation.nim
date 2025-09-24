# prover/function_evaluation.nim
# Function evaluation and constant folding for the safety prover

import std/[tables, options]
import ../frontend/ast
import types


const MAX_ITERATIONS = 1000


proc tryEvaluateComplexFunction*(body: seq[Stmt], paramEnv: Table[string, int64]): Option[int64] =
  ## Try to evaluate a function body with loops and local variables
  var localVars = paramEnv  # Start with parameters

  proc evalExprLocal(expr: Expr): Option[int64] =
    case expr.kind
    of ekInt:
      return some(expr.ival)
    of ekVar:
      if localVars.hasKey(expr.vname):
        return some(localVars[expr.vname])
      return none(int64)
    of ekBin:
      let lhs = evalExprLocal(expr.lhs)
      let rhs = evalExprLocal(expr.rhs)
      if lhs.isSome and rhs.isSome:
        case expr.bop
        of boAdd: return some(lhs.get + rhs.get)
        of boSub: return some(lhs.get - rhs.get)
        of boMul: return some(lhs.get * rhs.get)
        of boDiv:
          if rhs.get != 0: return some(lhs.get div rhs.get)
          else: return none(int64)
        of boMod:
          if rhs.get != 0: return some(lhs.get mod rhs.get)
          else: return none(int64)
        of boLt: return some(if lhs.get < rhs.get: 1'i64 else: 0'i64)
        of boLe: return some(if lhs.get <= rhs.get: 1'i64 else: 0'i64)
        of boGt: return some(if lhs.get > rhs.get: 1'i64 else: 0'i64)
        of boGe: return some(if lhs.get >= rhs.get: 1'i64 else: 0'i64)
        of boEq: return some(if lhs.get == rhs.get: 1'i64 else: 0'i64)
        of boNe: return some(if lhs.get != rhs.get: 1'i64 else: 0'i64)
        else: return none(int64)
      return none(int64)
    else:
      return none(int64)

  # Process statements in order
  for stmt in body:
    case stmt.kind
    of skVar:
      if stmt.vinit.isSome:
        let val = evalExprLocal(stmt.vinit.get)
        if val.isSome:
          localVars[stmt.vname] = val.get
        else:
          return none(int64)  # Cannot evaluate initializer
      else:
        localVars[stmt.vname] = 0'i64  # Default initialization
    of skAssign:
      let val = evalExprLocal(stmt.aval)
      if val.isSome:
        localVars[stmt.aname] = val.get
      else:
        return none(int64)  # Cannot evaluate assignment
    of skWhile:
      # Simple loop evaluation with maximum iterations to prevent infinite loops
      var iterations = 0
      while iterations < MAX_ITERATIONS:
        let condVal = evalExprLocal(stmt.wcond)
        if not condVal.isSome:
          return none(int64)  # Cannot evaluate condition
        if condVal.get == 0:
          break  # Condition is false, exit loop

        # Execute loop body
        for bodyStmt in stmt.wbody:
          case bodyStmt.kind
          of skAssign:
            let val = evalExprLocal(bodyStmt.aval)
            if val.isSome:
              localVars[bodyStmt.aname] = val.get
            else:
              return none(int64)
          else:
            return none(int64)  # Unsupported statement in loop body

        iterations += 1

      if iterations >= MAX_ITERATIONS:
        return none(int64)  # Potential infinite loop
    of skReturn:
      if stmt.re.isSome:
        return evalExprLocal(stmt.re.get)
      return some(0'i64)  # void return
    else:
      return none(int64)  # Unsupported statement type

  # If we reach here without a return, assume void return
  return some(0'i64)


proc tryEvaluatePureFunction*(call: Expr, argInfos: seq[Info], fn: FunDecl, prog: Program): Option[int64] =
  ## Try to evaluate a pure function with constant arguments
  ## Returns the result if successful, None if the function cannot be evaluated

  # Create parameter environment with constant argument values
  var paramEnv: Table[string, int64] = initTable[string, int64]()
  for i, arg in argInfos:
    if i < fn.params.len and arg.known:
      paramEnv[fn.params[i].name] = arg.cval
    else:
      return none(int64)  # Cannot evaluate if not all params are constants

  # Forward declaration for mutual recursion
  proc evalStmt(stmt: Stmt): Option[int64]

  # Simple recursive expression evaluator
  proc evalExpr(expr: Expr): Option[int64] =
    case expr.kind
    of ekInt:
      return some(expr.ival)
    of ekVar:
      if paramEnv.hasKey(expr.vname):
        return some(paramEnv[expr.vname])
      return none(int64)
    of ekBin:
      let lhs = evalExpr(expr.lhs)
      let rhs = evalExpr(expr.rhs)
      if lhs.isSome and rhs.isSome:
        case expr.bop
        of boAdd: return some(lhs.get + rhs.get)
        of boSub: return some(lhs.get - rhs.get)
        of boMul: return some(lhs.get * rhs.get)
        of boDiv:
          if rhs.get != 0: return some(lhs.get div rhs.get)
          else: return none(int64)
        of boMod:
          if rhs.get != 0: return some(lhs.get mod rhs.get)
          else: return none(int64)
        of boEq: return some(if lhs.get == rhs.get: 1'i64 else: 0'i64)
        of boNe: return some(if lhs.get != rhs.get: 1'i64 else: 0'i64)
        of boLt: return some(if lhs.get < rhs.get: 1'i64 else: 0'i64)
        of boLe: return some(if lhs.get <= rhs.get: 1'i64 else: 0'i64)
        of boGt: return some(if lhs.get > rhs.get: 1'i64 else: 0'i64)
        of boGe: return some(if lhs.get >= rhs.get: 1'i64 else: 0'i64)
        else: return none(int64)
      return none(int64)
    of ekCall:
      # Support recursive function calls
      if prog != nil and expr.fname == fn.name:
        # Recursive call to the same function - evaluate arguments and call recursively
        var recursiveArgs: seq[int64] = @[]
        for arg in expr.args:
          let argResult = evalExpr(arg)
          if argResult.isSome:
            recursiveArgs.add(argResult.get)
          else:
            return none(int64)

        # Create new parameter environment for recursive call
        var newParamEnv: Table[string, int64] = initTable[string, int64]()
        for i, arg in recursiveArgs:
          if i < fn.params.len:
            newParamEnv[fn.params[i].name] = arg

        # Temporarily swap parameter environments
        let oldParamEnv = paramEnv
        paramEnv = newParamEnv

        # Evaluate the function body with new parameters
        for stmt in fn.body:
          let res = evalStmt(stmt)
          if res.isSome:
            paramEnv = oldParamEnv  # Restore environment
            return res

        paramEnv = oldParamEnv  # Restore environment
        return none(int64)
      else:
        # For now, don't support calls to other functions
        return none(int64)
    else:
      return none(int64)

  # Simple statement evaluator for function body
  proc evalStmt(stmt: Stmt): Option[int64] =
    case stmt.kind
    of skReturn:
      if stmt.re.isSome:
        return evalExpr(stmt.re.get)
      return some(0'i64)  # void return
    of skIf:
      # Handle if-else statements
      let condResult = evalExpr(stmt.cond)
      if condResult.isSome:
        if condResult.get != 0:
          # Condition is true - execute then branch
          for thenStmt in stmt.thenBody:
            let res = evalStmt(thenStmt)
            if res.isSome:
              return res
        else:
          # Condition is false - execute else branch
          for elseStmt in stmt.elseBody:
            let res = evalStmt(elseStmt)
            if res.isSome:
              return res
      return none(int64)
    else:
      return none(int64)  # Unsupported statement type

  # Try to evaluate the function body
  if fn.body.len == 1 and (fn.body[0].kind == skReturn or fn.body[0].kind == skIf):
    # Simple case: single return statement or single if statement
    return evalStmt(fn.body[0])
  else:
    # Try to handle more complex function bodies with loops and variables
    return tryEvaluateComplexFunction(fn.body, paramEnv)
