 # cli_options.nim
# Shared CLI options and argument parsing for Etch

import std/[os, strutils, strformat, options]
import ../../common/[constants, types]


type
  CliOptions* = object
    # Global options
    verbose*: bool
    verboseCompiler*: bool
    verboseVM*: bool
    verboseOptimizer*: bool
    debug*: bool
    profile*: bool
    perfetto*: bool
    perfettoOutput*: string
    force*: bool
    gcCycleInterval*: Option[int]

    # Command-specific options
    command*: CliCommand
    files*: seq[string]
    modeArg*: string
    backend*: string
    runBackend*: string
    recordFile*: string
    stepArg*: string

  CliCommand* = enum
    cmdRun = "run"
    cmdTest = "test"
    cmdTestC = "test-c"
    cmdPerf = "perf"
    cmdDebug = "debug-server"
    cmdDump = "dump"
    cmdReplay = "replay"
    cmdGen = "gen"


proc validateFile*(path: string) =
  if not fileExists(path):
    stderr.writeLine(&"Error: cannot open: {path}")
    quit 1


proc usage*() =
  stderr.writeLine("Etch - minimal language toolchain")
  stderr.writeLine("Usage:")
  stderr.writeLine("  etch [--gen BACKEND] [--run [BACKEND]] [--record FILE] [--verbose [COMPONENT]] [--release] [--profile] [--perfetto [OUTPUT]] [--force] [--gc-interval N] file.etch")
  stderr.writeLine("  etch --replay FILE [--step N[,N..]]")
  stderr.writeLine("  etch --test [DIR|FILE]")
  stderr.writeLine("  etch --test-c [DIR|FILE]")
  stderr.writeLine("  etch --perf [DIR]")
  stderr.writeLine("Options:")
  stderr.writeLine("  --gen BACKEND        Generate code for specified backend (vm, c)")
  stderr.writeLine("  --run [BACKEND]      Execute the program (default: bytecode VM, optional: c)")
  stderr.writeLine("  --dump               Dump bytecode instructions with debug info")
  stderr.writeLine("  --release            Optimize and skip debug information in bytecode")
  stderr.writeLine("  --profile            Enable VM profiling (reports instruction timing and hotspots)")
  stderr.writeLine("  --perfetto [OUTPUT]  Enable Perfetto tracing (optional output file, default: perfetto_trace)")
  stderr.writeLine("  --verbose [COMPONENT] Enable verbose debug output (c=compiler, v=vm, o=optimizer, default=all)")
  stderr.writeLine("  --force              Force recompilation, bypassing bytecode cache")
  stderr.writeLine("  --gc-interval N      GC cycle detection interval in operations (default: 1000)")
  stderr.writeLine("  --debug-server       Start debug server for VSCode integration")
  stderr.writeLine("  --record FILE        Record execution to FILE.replay (use with --run)")
  stderr.writeLine("  --replay FILE        Load and replay recorded execution from FILE.replay")
  stderr.writeLine("  --step N[,N..]       Step through specific statements (use with --replay)")
  stderr.writeLine("                       Special values: S=start, E=end (e.g., --step S,10,E,10,S)")
  stderr.writeLine("  --test [DIR|FILE]    Run tests in directory (default: tests/) with bytecode VM")
  stderr.writeLine("  --test-c [DIR|FILE]  Run tests in directory (default: tests/) with C backend")
  stderr.writeLine("                       Tests need .pass (expected output) or .fail (expected failure)")
  stderr.writeLine("  --perf [DIR]         Run performance benchmarks (default: performance/) and generate report")
  stderr.writeLine("  --help               Show this help message")
  quit 1


proc makeCompilerOptions*(sourceFile: string, runVirtualMachine: bool, options: CliOptions): CompilerOptions =
  CompilerOptions(
    sourceFile: sourceFile,
    runVirtualMachine: runVirtualMachine,
    verbose: options.verboseCompiler,
    debug: options.debug,
    profile: options.profile,
    perfetto: options.perfetto,
    perfettoOutput: options.perfettoOutput,
    force: options.force,
    gcCycleInterval: options.gcCycleInterval
  )


proc parseCliArguments*(): CliOptions =
  result = CliOptions(
    verbose: false,
    verboseCompiler: false,
    verboseVM: false,
    verboseOptimizer: false,
    debug: true,
    profile: false,
    perfetto: false,
    perfettoOutput: "",
    force: false,
    command: cmdGen,
    files: @[],
    modeArg: "",
    backend: "",
    runBackend: "",
    recordFile: "",
    stepArg: ""
  )

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)

    if a == "--verbose":
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        let compStr = paramStr(i + 1)
        for comp in compStr:
          case comp
          of 'c': result.verboseCompiler = true
          of 'v': result.verboseVM = true
          of 'o': result.verboseOptimizer = true
          else:
            stderr.writeLine("Error: unknown verbose component: " & $comp)
            quit 1
        inc i
      else:
        result.verboseCompiler = true
        result.verboseVM = true
        result.verboseOptimizer = true

    elif a == "--release":
      result.debug = false

    elif a == "--profile":
      result.profile = true

    elif a == "--perfetto":
      result.perfetto = true
      # Check if there's an optional output file argument
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        result.perfettoOutput = paramStr(i + 1)
        inc i
      else:
        result.perfettoOutput = "perfetto_trace"

    elif a == "--force":
      result.force = true

    elif a == "--gc-interval":
      if i + 1 <= paramCount():
        try:
          result.gcCycleInterval = some(parseInt(paramStr(i + 1)))
          inc i
        except ValueError:
          stderr.writeLine("Error: --gc-interval requires a valid integer")
          quit 1
      else:
        stderr.writeLine("Error: --gc-interval requires an argument")
        quit 1

    elif a == "--run":
      result.command = cmdRun
      # Check if there's an optional backend argument (not a file path)
      if i + 1 <= paramCount():
        let nextArg = paramStr(i + 1)
        if not nextArg.startsWith("--") and not nextArg.endsWith(SOURCE_FILE_EXTENSION) and not ('/' in nextArg or '\\' in nextArg):
          result.runBackend = nextArg
          inc i

    elif a == "--gen":
      result.command = cmdGen
      if i + 1 <= paramCount():
        result.backend = paramStr(i + 1)
        inc i
      else:
        stderr.writeLine("Error: --gen requires a backend argument (e.g., 'vm' or 'c')")
        quit 1

    elif a == "--test":
      result.command = cmdTest
      # Collect all test files/patterns until next option
      while i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        result.files.add(paramStr(i + 1))
        inc i

    elif a == "--test-c":
      result.command = cmdTestC
      # Collect all test files/patterns until next option
      while i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        result.files.add(paramStr(i + 1))
        inc i

    elif a == "--perf":
      result.command = cmdPerf
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        result.modeArg = paramStr(i + 1)
        inc i

    elif a == "--debug-server":
      result.command = cmdDebug
      if i + 1 <= paramCount():
        result.modeArg = paramStr(i + 1)
        result.files.add(paramStr(i + 1))  # Add to files for validation
        inc i

    elif a == "--dump":
      result.command = cmdDump
      result.force = true # Always force recompilation for dump
      if i + 1 <= paramCount():
        result.modeArg = paramStr(i + 1)
        result.files.add(paramStr(i + 1))  # Add to files for validation
        inc i

    elif a == "--record":
      if i + 1 <= paramCount():
        result.recordFile = paramStr(i + 1)
        inc i
      else:
        stderr.writeLine("Error: --record requires a file argument")
        quit 1

    elif a == "--replay":
      result.command = cmdReplay
      if i + 1 <= paramCount():
        result.modeArg = paramStr(i + 1)
        result.files.add(paramStr(i + 1))  # Add to files for validation
        inc i

    elif a == "--step":
      if i + 1 <= paramCount():
        result.stepArg = paramStr(i + 1)
        inc i

    elif a == "--help":
      usage()
      break

    elif not a.startsWith("--"):
      result.files.add a

    else:
      stderr.writeLine(&"Error: unknown option: {a}")
      usage()
      break

    inc i
