# base.nim
# Base infrastructure for AST optimization passes

import strformat
import ../frontend/ast
import ../../common/logging

type
  PassContext* = ref object
    ## Context shared across all AST passes
    program*: Program              # The program being optimized
    verbose*: bool                 # Verbose logging enabled
    stats*: PassStatistics         # Statistics about pass execution

  PassStatistics* = object
    ## Statistics collected during pass execution
    functionsInlined*: int
    fusedOperations*: int
    deadCodeEliminated*: int

  PassFunction* = proc(program: Program, ctx: PassContext): bool
    ## A pass function that transforms a program
    ## Returns true if the program was modified


proc newPassContext*(program: Program, verbose: bool): PassContext =
  ## Create a new pass context
  PassContext(
    program: program,
    verbose: verbose,
    stats: PassStatistics()
  )


proc logPass*(ctx: PassContext, msg: string) =
  ## Log a message from a pass
  logOptimizer(ctx.verbose, msg)


proc runPassesOnProgram*(passes: seq[tuple[name: string, pass: PassFunction]], program: Program, verbose: bool): PassStatistics =
  ## Run all passes on a program
  ## Returns statistics about the optimization
  let ctx = newPassContext(program, verbose)

  logOptimizer(verbose, "Running AST optimization passes...")

  # Run passes
  for (name, pass) in passes:
    logOptimizer(verbose, &"Running pass: {name}")

    if pass(program, ctx):
      logOptimizer(verbose, &"  Pass {name} modified the program")

  # Log final statistics
  if ctx.stats.functionsInlined > 0:
    logOptimizer(verbose, &"  Functions inlined: {ctx.stats.functionsInlined}")
  if ctx.stats.fusedOperations > 0:
    logOptimizer(verbose, &"  Fused operations: {ctx.stats.fusedOperations}")
  if ctx.stats.deadCodeEliminated > 0:
    logOptimizer(verbose, &"  Dead code eliminated: {ctx.stats.deadCodeEliminated}")

  result = ctx.stats
