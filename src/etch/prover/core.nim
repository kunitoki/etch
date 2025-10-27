# prover/core.nim
# Main prover coordination and public interface


import std/[tables]
import ../frontend/ast
import ../common/[constants, logging, types]
import types, expression_analysis


proc prove*(prog: Program, filename: string = "<unknown>", options: CompilerOptions) =
  logProver(options.verbose, "Starting safety proof analysis for " & filename)
  # Source lines will be lazily loaded on error in formatError() (file is on disk)
  var env = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expr](), declPos: initTable[string, Pos]())

  logProver(options.verbose, "Initializing environment with " & $prog.globals.len & " global variables")

  # First pass: add all global variable declarations to environment (forward references)
  for g in prog.globals:
    if g.kind == skVar:
      logProver(options.verbose, "Adding global variable to environment: " & g.vname)
      # Add variable as uninitialized first to allow forward references
      env.vals[g.vname] = infoUninitialized()
      env.nils[g.vname] = true

  # Second pass: analyze global variable initializations with full environment
  logProver(options.verbose, "Analyzing global variable initializations")
  let globalCtx = newProverContext("", options, prog)
  for g in prog.globals:
    if g.kind == skVar:
      logProver(options.verbose, "Proving global variable: " & g.vname)
    proveStmt(g, env, globalCtx)

  # Third pass: analyze main function directly
  if prog.funInstances.hasKey(MAIN_FUNCTION_NAME):
    logProver(options.verbose, "Analyzing main function")
    let mainFn = prog.funInstances[MAIN_FUNCTION_NAME]
    var mainEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs, declPos: env.declPos) # copy global environment
    logProver(options.verbose, "Main function has " & $mainFn.body.len & " statements")
    let mainCtx = newProverContext(MAIN_FUNCTION_NAME, options, prog)
    for i, stmt in mainFn.body:
      logProver(options.verbose, "Proving main statement " & $(i + 1) & "/" & $mainFn.body.len)
      proveStmt(stmt, mainEnv, mainCtx)

    # Check for unused local variables in main function (exclude globals)
    checkUnusedVariables(mainEnv, mainCtx, "main function", excludeGlobals = true)

    # Scan all function bodies for global variable usage
    # This marks globals as "used" if they appear in any function body
    markGlobalsUsedInFunctions(mainEnv, globalCtx)

    # Now check for unused global variables (after scanning all functions)
    checkUnusedGlobalVariables(mainEnv, globalCtx)
  else:
    logProver(options.verbose, "No main function found to analyze")

  logProver(options.verbose, "Safety proof analysis complete")
