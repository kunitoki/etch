# perfetto.nim - Perfetto tracing integration for Etch

import std/[paths]
import ../core/vm_types
import ../common/helpers

when defined(perfetto):
  when defined(gcc):
    const cc = "gcc++"
  elif defined(clang):
    const cc = "clang++"

  static:
    let thisFile = currentSourcePath().Path
    var etchFolder = thisFile.parentDir.parentDir / Path("capabilities") / Path("perfetto")
    var cacheFolder = thisFile.parentDir.parentDir.parentDir.parentDir / Path(".nimcache")

    var flags = "-std=c++17 -Wno-everything -fPIC -DETCH_ENABLE_PERFETTO=1 -Isrc/etch/capabilities/perfetto"
    when defined(macosx):
      let sdkPath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
      flags &= " -isysroot " & sdkPath & " -I" & sdkPath & "/usr/include -F" & sdkPath & "/System/Library/Frameworks"

    compileFileCached(cc, flags, $(etchFolder / Path("etch_perfetto.cpp")), "etch_perfetto", $cacheFolder)
    compileFileCached(cc, flags, $(etchFolder / Path("perfetto.cc")), "perfetto", $cacheFolder)

  when defined(macosx):
    {.passL: "-lc++ -lc++abi".}

  {.passL: ".nimcache/perfetto.o".}
  {.passL: ".nimcache/etch_perfetto.o".}

  # FFI bindings for Perfetto
  proc etch_perfetto_init(process_name: cstring, output_file: cstring): bool {.importc, cdecl.}
  proc etch_perfetto_shutdown() {.importc, cdecl.}
  proc etch_perfetto_is_enabled(): bool {.importc, cdecl.}
  proc etch_perfetto_begin_event(category: cstring, name: cstring, id: uint64) {.importc, cdecl.}
  proc etch_perfetto_end_event(category: cstring, name: cstring, id: uint64) {.importc, cdecl.}
  proc etch_perfetto_instant_event(category: cstring, name: cstring, scope: cstring) {.importc, cdecl.}
  proc etch_perfetto_counter(category: cstring, name: cstring, value: int64, unit: cstring) {.importc, cdecl.}
  proc etch_perfetto_flush() {.importc, cdecl.}

  type
    PerfettoTracer* = ref object
      enabled*: bool
      processName*: string
      outputFile*: string

  proc newPerfettoTracer*(processName: string = "etch", outputFile: string = ""): PerfettoTracer =
    result = PerfettoTracer(
      enabled: false,
      processName: processName,
      outputFile: outputFile
    )

  proc startTracing*(tracer: PerfettoTracer): bool =
    let outputFile = if tracer.outputFile.len > 0: tracer.outputFile.cstring else: nil
    if etch_perfetto_init(tracer.processName.cstring, outputFile):
      tracer.enabled = true
      return true
    return false

  proc stopTracing*(tracer: PerfettoTracer) =
    if tracer.enabled:
      etch_perfetto_shutdown()
      tracer.enabled = false

  proc isTracingEnabled*(tracer: PerfettoTracer): bool =
    return tracer.enabled and etch_perfetto_is_enabled()

  proc beginEvent*(tracer: PerfettoTracer, category: string, name: string, id: uint64 = 0) =
    if tracer.enabled:
      etch_perfetto_begin_event(category.cstring, name.cstring, id)

  proc endEvent*(tracer: PerfettoTracer, category: string, name: string, id: uint64 = 0) =
    if tracer.enabled:
      etch_perfetto_end_event(category.cstring, name.cstring, id)

  proc instantEvent*(tracer: PerfettoTracer, category: string, name: string, scope: string = "thread") =
    if tracer.enabled:
      etch_perfetto_instant_event(category.cstring, name.cstring, scope.cstring)

  proc recordCounter*(tracer: PerfettoTracer, category: string, name: string, value: int64, unit: string = "count") =
    if tracer.enabled:
      etch_perfetto_counter(category.cstring, name.cstring, value, unit.cstring)

  proc flush*(tracer: PerfettoTracer) =
    if tracer.enabled:
      etch_perfetto_flush()
