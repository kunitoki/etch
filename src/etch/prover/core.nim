# prover/core.nim
# Main prover coordination and public interface

import std/[tables]
import ../frontend/ast, ../errors, ../interpreter/vm
import types, expression_analysis, statement_analysis

proc prove*(prog: Program, filename: string = "<unknown>") =
  errors.loadSourceLines(filename)
  var env = Env(vals: initTable[string, Info](), nils: initTable[string, bool](), exprs: initTable[string, Expr]())

  # First pass: add all global variable declarations to environment (forward references)
  for g in prog.globals:
    if g.kind == skVar:
      # Add variable as uninitialized first to allow forward references
      env.vals[g.vname] = infoUninitialized()
      env.nils[g.vname] = true

  # Second pass: analyze global variable initializations with full environment
  for g in prog.globals: proveStmt(g, env, prog)
  # Analyze main function directly (it's the entry point)
  if prog.funInstances.hasKey("main"):
    let mainFn = prog.funInstances["main"]
    var mainEnv = Env(vals: env.vals, nils: env.nils, exprs: env.exprs) # copy global environment
    for stmt in mainFn.body:
      proveStmt(stmt, mainEnv, prog)

  # Other function bodies are analyzed at call-sites for more precise analysis