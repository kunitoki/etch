# cli_bench.nim
# Benchmark command implementation

import ../options

when defined(release):
  import ../../../tooling/benchmark


proc benchCommand*(options: CliOptions): int =
  when not defined(release):
    let message = "Benchmarks should be run in release mode for accurate results, use release mode ('nim c -d:release ...')."
    raise newException(ValueError, message)
  else:
    let perfDir = if options.modeArg != "": options.modeArg else: "performance"
    return runPerformanceBenchmarks(perfDir)
