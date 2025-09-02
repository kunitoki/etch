# logging.nim
# Centralized logging utilities for the Etch language implementation

import std/[macros]
import constants


# Convenience templates for each module
# Note: All diagnostic output goes to stderr to avoid interfering with program stdout
macro logCompiler*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_COMPILER, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logProver*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_PROVER, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logOptimizer*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_OPTIMIZER, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logVM*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_VM, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logHeap*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_HEAP, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logCLI*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_CLI, "] ", $`msg`
  else:
    result = quote do:
      discard

macro logTypecheck*(verbose: untyped, msg: untyped): untyped =
  when not defined(deploy):
    result = quote do:
      if `verbose`:
        stderr.writeLine "[", MODULE_TYPECHECKER, "] ", $`msg`
  else:
    result = quote do:
      discard
