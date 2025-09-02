# benchmark.nim
# Performance benchmarking system for Etch

import std/[os, osproc, strformat, strutils, times, sequtils, json]
import ../common/constants
import ./tester


type
  BenchmarkResult* = object
    name*: string
    cTime*: float  # milliseconds (0 if not available)
    vmTime*: float  # milliseconds
    pyTime*: float  # milliseconds
    cVsPython*: float  # speedup ratio (< 1 means slower)
    vmVsPython*: float  # speedup ratio
    luaTime*: float  # milliseconds
    luaVsPython*: float  # speedup ratio
    vmVsLua*: float  # speedup ratio
    cVsLua*: float  # speedup ratio


proc commandAvailable*(cmd: string): bool =
  try:
    let res = execCmdEx(&"{cmd} -v")
    res.exitCode == 0
  except:
    false


proc parseHyperfineResults(jsonContent: string, hasCBackend: bool, hasLua: bool): BenchmarkResult =
  ## Parse hyperfine JSON output and extract times
  try:
    let data = parseJson(jsonContent)
    let results = data["results"]
    var index = 0

    if hasCBackend and index < results.len:
      result.cTime = results[index]["mean"].getFloat() * 1000.0
      index.inc
    else:
      result.cTime = 0.0

    if index < results.len:
      result.vmTime = results[index]["mean"].getFloat() * 1000.0
      index.inc

    if index < results.len:
      result.pyTime = results[index]["mean"].getFloat() * 1000.0
      index.inc

    if hasLua and index < results.len:
      result.luaTime = results[index]["mean"].getFloat() * 1000.0
      index.inc
    else:
      result.luaTime = 0.0

    if result.pyTime > 0.0:
      if result.vmTime > 0.0:
        result.vmVsPython = result.pyTime / result.vmTime
      if result.luaTime > 0.0:
        result.luaVsPython = result.pyTime / result.luaTime
      if result.cTime > 0.0:
        result.cVsPython = result.pyTime / result.cTime
    if result.luaTime > 0.0:
      if result.vmTime > 0.0:
        result.vmVsLua = result.luaTime / result.vmTime
      if result.cTime > 0.0:
        result.cVsLua = result.luaTime / result.cTime
  except:
    echo "Warning: Failed to parse hyperfine JSON output"


proc replaceEmojis(text: string): string =
  result = text.replace("GG", "🟢")
  result = result.replace("YY", "🟡")
  result = result.replace("RR", "🔴")


proc formatTime(ms: float, baseline: float): string =
  ## Format time with color coding based on comparison to baseline
  if ms == 0.0:
    return "N/A"

  &"{ms:.1f}ms"


proc formatSpeedup(ratio: float): string =
  ## Format speedup ratio with color
  if ratio == 0.0:
    return "N/A"

  if ratio > 1.0:
    # Faster than Python
    &"GG {ratio:.2f}×"
  elif ratio > (1.0 / 1.5):
    # Slightly slower
    &"YY {(1.0/ratio):.2f}× slower"
  else:
    # Much slower
    &"RR {(1.0/ratio):.2f}× slower"


proc padRight(text: string, width: int): string =
  ## Left-align text with trailing padding spaces
  if text.len >= width:
    return text
  alignLeft(text, width)


proc buildTable(headers: seq[string], rows: seq[seq[string]]): string =
  ## Render a markdown table with padded columns for improved readability
  if headers.len == 0:
    return ""

  var colWidths = newSeq[int](headers.len)
  for i, header in headers:
    colWidths[i] = header.len

  for row in rows:
    if row.len != headers.len:
      continue
    for i, cell in row:
      if cell.len > colWidths[i]:
        colWidths[i] = cell.len

  proc renderRow(cells: seq[string]): string =
    var line = "|"
    for i, cell in cells:
      line.add(" " & padRight(cell, colWidths[i]) & " |")
    line & "\n"

  result.add(renderRow(headers))

  var dividerCells: seq[string] = @[]
  for width in colWidths:
    dividerCells.add(repeat('-', max(3, width)))
  result.add(renderRow(dividerCells))

  for row in rows:
    result.add(renderRow(row))


proc generateReport(results: seq[BenchmarkResult], perfDir: string): string =
  ## Generate markdown report with clearer baseline sections
  result = "# Etch Performance Benchmarks\n\n"
  result.add(&"**Generated**: {now()}\n\n")
  result.add(&"**Directory**: `{perfDir}`\n\n")
  result.add("Each section compares runtimes against the baseline named in the heading. Colored dots show how alternative targets perform relative to that baseline.\n\n")

  result.add("## Python Baseline\n\n")
  let pyHeaders = @["Benchmark", "Python", "VM", "VM vs Python", "C Backend", "C vs Python"]
  var pyRows: seq[seq[string]] = @[]

  for res in results:
    let pyTimeStr = if res.pyTime > 0.0:
      &"{res.pyTime:.1f}ms"
    else:
      "N/A"
    let vmTimeStr = if res.pyTime > 0.0:
      formatTime(res.vmTime, res.pyTime)
    else:
      "N/A"
    let cTimeStr = if res.cTime > 0.0 and res.pyTime > 0.0:
      formatTime(res.cTime, res.pyTime)
    elif res.cTime > 0.0:
      &"{res.cTime:.1f}ms"
    else:
      "N/A"

    let vmVsPy = formatSpeedup(res.vmVsPython)
    let cVsPy = formatSpeedup(res.cVsPython)

    pyRows.add(@[res.name, pyTimeStr, vmTimeStr, vmVsPy, cTimeStr, cVsPy])

  result.add(buildTable(pyHeaders, pyRows))

  let hasLuaData = results.anyIt(it.luaTime > 0.0)

  if hasLuaData:
    result.add("\n## Lua Baseline\n\n")
    let luaHeaders = @["Benchmark", "Lua", "VM", "VM vs Lua", "C Backend", "C vs Lua"]
    var luaRows: seq[seq[string]] = @[]

    for res in results:
      if res.luaTime <= 0.0:
        continue

      let luaTimeStr = &"{res.luaTime:.1f}ms"
      let vmLuaTime = formatTime(res.vmTime, res.luaTime)
      let cLuaTime = if res.cTime > 0.0:
        formatTime(res.cTime, res.luaTime)
      else:
        "N/A"

      let vmVsLuaStr = formatSpeedup(res.vmVsLua)
      let cVsLuaStr = formatSpeedup(res.cVsLua)
      luaRows.add(@[res.name, luaTimeStr, vmLuaTime, vmVsLuaStr, cLuaTime, cVsLuaStr])

    result.add(buildTable(luaHeaders, luaRows))
  else:
    result.add("\n> Lua baseline skipped (interpreter unavailable or *.lua scripts missing).\n")

  result = result.replaceEmojis()

  result.add("\n")
  result.add("**Legend:**\n")
  result.add("- 🟢 Faster than the section baseline\n")
  result.add("- 🟡 Slightly slower than the section baseline (< 1.5×)\n")
  result.add("- 🔴 Much slower than the section baseline (≥ 1.5×)\n")


proc runPerformanceBenchmarks*(perfPath: string = "performance", resultFile: string = "performance.md"): int =
  echo "===== Running performance benchmarks ====="

  let luaInterpreterAvailable = commandAvailable("lua")
  if not luaInterpreterAvailable:
    echo "⚠️  'lua' interpreter not available; skipping Lua timing"

  var perfDir: string
  var benchmarks: seq[string] = @[]
  var singleFile = false

  # Check if path is a file or directory
  if fileExists(perfPath):
    # Single file mode
    singleFile = true
    let (dir, name, ext) = splitFile(perfPath)
    if ext != SOURCE_FILE_EXTENSION:
      echo &"Error: {perfPath} must be a {SOURCE_FILE_EXTENSION} file"
      return 1
    perfDir = if dir == "": "." else: dir
    benchmarks.add(name)
    echo &"Running single benchmark: {name}"
  elif dirExists(perfPath):
    # Directory mode
    perfDir = perfPath

    # Discover all .etch files that have corresponding .py files
    for file in walkFiles(perfDir / &"*{SOURCE_FILE_EXTENSION}"):
      let (_, name, _) = splitFile(file)
      let pyFile = perfDir / name & ".py"
      if fileExists(pyFile):
        benchmarks.add(name)
  else:
    echo &"Error: {perfPath} not found (not a file or directory)"
    return 1

  echo &"Directory: {perfDir}"
  echo &"Generating markdown report: {resultFile}"
  echo ""

  if benchmarks.len == 0:
    echo "No performance tests found!"
    return 1

  echo &"Found {benchmarks.len} benchmarks:"
  for benchmark in benchmarks:
    echo &"  - {benchmark}"
  echo ""

  var results: seq[BenchmarkResult] = @[]
  var successCount = 0
  var failCount = 0

  for benchmark in benchmarks:
    echo &"----- Benchmarking: {benchmark} -----"

    let etchFile = perfDir / benchmark & SOURCE_FILE_EXTENSION
    let pyFile = perfDir / benchmark & ".py"
    let luaFile = perfDir / benchmark & ".lua"
    let etchDir = perfDir / BYTECODE_CACHE_DIR
    let cExecutable = etchDir / benchmark & "_c"
    let jsonOutput = etchDir / benchmark & "_bench.json"
    let mdOutput = etchDir / benchmark & "_bench.md"

    createDir(etchDir)

    let etchExe = getAppFilename()
    let passFile = perfDir / benchmark & ".pass"
    let hasLuaScript = fileExists(luaFile)
    let hasLuaBenchmark = luaInterpreterAvailable and hasLuaScript
    if not hasLuaScript and luaInterpreterAvailable:
      echo "  ⚠️  Lua benchmark script missing (skipping Lua timing)"

    if not fileExists(passFile):
      echo &"  ✗ Missing expected output file: {passFile}"
      failCount.inc()
      continue

    clearCachedFiles(etchFile)
    let expectedOutput = normalizeOutput(readFile(passFile))

    # Validate VM output
    let vmCmd = &"{quoteShell(etchExe)} --run vm --release --force {quoteShell(etchFile)}"
    let vmExec = executeWithSeparateStreams(vmCmd)
    let vmOutput = smartFilterOutput(vmExec)
    if vmExec.exitCode != 0:
      echo &"  ✗ VM execution failed (exit code {vmExec.exitCode})"
      if vmOutput.len > 0:
        echo "    Output:"
        echo vmOutput
      failCount.inc()
      continue
    let vmComparison = compareOutputs(expectedOutput, vmOutput)
    if not vmComparison.match:
      echo "  ✗ VM output mismatch"
      echo "    Expected:"
      echo expectedOutput
      echo "    Actual:"
      echo vmComparison.normalizedActual
      failCount.inc()
      continue
    echo "  ✓ VM output matches expected .pass"

    # Validate / detect C backend
    var hasCBackend = false
    let cCmd = &"{quoteShell(etchExe)} --run c --release {quoteShell(etchFile)}"
    let cExec = executeWithSeparateStreams(cCmd)
    if cExec.exitCode == 0 and fileExists(cExecutable):
      let cOutput = smartFilterOutput(cExec)
      let cComparison = compareOutputs(expectedOutput, cOutput)
      if cComparison.match:
        hasCBackend = true
        echo "  ✓ C output matches expected .pass"
      else:
        echo "  ✗ C output mismatch"
        echo "    Expected:"
        echo expectedOutput
        echo "    Actual:"
        echo cComparison.normalizedActual
        failCount.inc()
        continue
    else:
      echo "  ⚠️  C backend unavailable (skipping C timing)"

    # Run hyperfine based on whether C backend is available
    var hyperArgs: seq[string] = @["hyperfine",
                                    "--warmup", "3",
                                    "--runs", "5",
                                    "--shell=none",
                                    "--export-json", jsonOutput,
                                    "--export-markdown", mdOutput]

    if hasCBackend:
      let targetDesc = if hasLuaBenchmark:
        "C backend + VM + Python + Lua"
      else:
        "C backend + VM + Python"
      echo &"  Running: {targetDesc}"
      hyperArgs.add(cExecutable)
      hyperArgs.add(&"{etchExe} --run --release {etchFile}")
      hyperArgs.add(&"python3 {pyFile}")
    else:
      let targetDesc = if hasLuaBenchmark:
        "VM + Python + Lua (C backend not available)"
      else:
        "VM + Python (C backend not available)"
      echo &"  Running: {targetDesc}"
      hyperArgs.add(&"{etchExe} --run --release {etchFile}")
      hyperArgs.add(&"python3 {pyFile}")

    if hasLuaBenchmark:
      hyperArgs.add(&"lua {luaFile}")

    let hyperCmd = hyperArgs.map(quoteShell).join(" ")
    echo ""
    discard execCmd(hyperCmd)
    echo ""

    # Parse results from JSON
    if fileExists(jsonOutput):
      let jsonContent = readFile(jsonOutput)
      var res = parseHyperfineResults(jsonContent, hasCBackend, hasLuaBenchmark)
      res.name = benchmark
      results.add(res)

      successCount.inc()
      echo "  ✓ Results added to report"
    else:
      failCount.inc()
      echo "  ✗ Benchmark failed"

  # Generate and write report
  let report = generateReport(results, perfDir)
  writeFile(resultFile, report)

  echo ""
  echo "===== Benchmark complete ====="
  echo &"Success: {successCount}/{benchmarks.len}"
  if failCount > 0:
    echo &"Failed:  {failCount}"
  echo &"Report saved to: {resultFile}"

  return if failCount > 0: 1 else: 0
