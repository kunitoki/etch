# prover/core.nim
# Main prover coordination and public interface


import std/[tables]
import ../frontend/ast, ../errors, ../interpreter/serialize
import types, expression_analysis


const MAIN_FN_NAME = "main"


proc verboseProverLog*(flags: CompilerFlags, msg: string) =
  ## Print verbose debug message if verbose flag is enabled
  if flags.verbose:
    echo "[PROVER] ", msg


proc prove*(prog: Program, filename: string = "<unknown>", flags: CompilerFlags = CompilerFlags()) =
  verboseProverLog(flags, "Starting safety proof analysis for " & filename)
  errors.loadSourceLines(filename)
  var env = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expr]())

  verboseProverLog(flags, "Initializing environment with " & $prog.globals.len & " global variables")

  # First pass: add all global variable declarations to environment (forward references)
  for g in prog.globals:
    if g.kind == skVar:
      verboseProverLog(flags, "Adding global variable to environment: " & g.vname)
      # Add variable as uninitialized first to allow forward references
      env.vals[g.vname] = infoUninitialized()
      env.nils[g.vname] = true

  # Second pass: analyze global variable initializations with full environment
  verboseProverLog(flags, "Analyzing global variable initializations")
  let globalCtx = newProverContext("", flags, prog)
  for g in prog.globals:
    if g.kind == skVar:
      verboseProverLog(flags, "Proving global variable: " & g.vname)
    proveStmt(g, env, globalCtx)

  # Analyze main function directly (it's the entry point)
  if prog.funInstances.hasKey(MAIN_FN_NAME):
    verboseProverLog(flags, "Analyzing main function")
    let mainFn = prog.funInstances[MAIN_FN_NAME]
    var mainEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs) # copy global environment
    verboseProverLog(flags, "Main function has " & $mainFn.body.len & " statements")
    let mainCtx = newProverContext(MAIN_FN_NAME, flags, prog)
    for i, stmt in mainFn.body:
      verboseProverLog(flags, "Proving main statement " & $(i + 1) & "/" & $mainFn.body.len)
      proveStmt(stmt, mainEnv, mainCtx)
  else:
    verboseProverLog(flags, "No main function found to analyze")

  verboseProverLog(flags, "Safety proof analysis complete")
