# test_utils.nim
# Common utilities for Etch tests

import std/[os, osproc, strutils, streams, times]

proc getTimeoutCommand*(): string =
  ## Get the appropriate timeout command for the current platform
  ## Returns the command to use for timing out processes
  when defined(windows):
    # Windows doesn't have a built-in timeout command for shell
    # We'll need to handle this differently or skip timeout
    return ""
  elif defined(macosx):
    # On macOS, check if gtimeout is available (from GNU coreutils)
    let (output, exitCode) = execCmdEx("which gtimeout")
    if exitCode == 0 and output.strip().len > 0:
      return "gtimeout"
    # Fall back to checking for timeout
    let (output2, exitCode2) = execCmdEx("which timeout")
    if exitCode2 == 0 and output2.strip().len > 0:
      return "timeout"
    # No timeout available - return empty
    return ""
  else:
    # Linux and others typically have timeout by default
    return "timeout"

proc wrapWithTimeout*(cmd: string, seconds: int): string =
  ## Wrap a command with timeout if available
  let timeoutCmd = getTimeoutCommand()
  if timeoutCmd.len > 0:
    return timeoutCmd & " " & $seconds & " " & cmd
  else:
    # No timeout available, just return the command as-is
    return cmd

proc findEtchExecutable*(): string =
  ## Find the etch executable, trying multiple locations
  ## This works whether tests are run from project root or tests directory

  when defined(windows):
    # Windows uses .exe extension
    if fileExists("./etch.exe"):
      return "./etch.exe"
    if fileExists("../etch.exe"):
      return "../etch.exe"
    if fileExists("etch.exe"):
      return "etch.exe"
  else:
    # Unix-like systems
    if fileExists("./etch"):
      return "./etch"
    if fileExists("../etch"):
      return "../etch"

  # Try using nim to run directly (fallback)
  if fileExists("src/etch.nim"):
    return "nim r src/etch.nim"
  elif fileExists("../src/etch.nim"):
    return "nim r ../src/etch.nim"

  # Last resort: assume it's in PATH or current dir
  when defined(windows):
    return "etch.exe"
  else:
    return "./etch"

proc getTestTempDir*(): string =
  ## Get a temporary directory for test files
  ## Uses a subdirectory to avoid /tmp issues mentioned in CLAUDE.md
  when defined(posix):
    # Use /private/tmp on macOS, regular temp on Linux
    let baseTemp = when defined(macosx): "/private/tmp" else: getTempDir()
    result = baseTemp / "__etch__"
  else:
    result = getTempDir() / "__etch__"

  # Create the directory if it doesn't exist
  if not dirExists(result):
    createDir(result)

proc cleanupTestTempDir*() =
  ## Clean up the test temporary directory
  let tempDir = getTestTempDir()
  if dirExists(tempDir):
    try:
      removeDir(tempDir)
    except:
      discard # Ignore errors during cleanup

proc ensureEtchBinary*(): bool =
  ## Ensure the etch binary is built and available
  ## Returns true if binary is available, false otherwise

  # First check if binary already exists (platform-specific)
  when defined(windows):
    if fileExists("./etch.exe") or fileExists("../etch.exe") or fileExists("etch.exe"):
      return true
  else:
    if fileExists("./etch") or fileExists("../etch"):
      return true

  # Try to build it
  echo "Building etch binary for tests..."

  when defined(windows):
    let buildCmd = if fileExists("src/etch.nim"):
      "nim c -d:danger -o:etch.exe src/etch.nim"
    elif fileExists("../src/etch.nim"):
      "cd .. && nim c -d:danger -o:etch.exe src/etch.nim"
    else:
      return false
  else:
    let buildCmd = if fileExists("src/etch.nim"):
      "nim c -d:danger -o:etch src/etch.nim"
    elif fileExists("../src/etch.nim"):
      "cd .. && nim c -d:danger -o:etch src/etch.nim"
    else:
      return false

  let (output, exitCode) = execCmdEx(buildCmd)
  if exitCode != 0:
    echo "Failed to build etch binary:"
    echo output
    return false

  return true

proc runDebugServerWithInput*(etchExe: string, testProg: string, inputCommands: string, timeoutSecs: int = 5): tuple[output: string, exitCode: int] =
  ## Run the debug server with input commands using proper process piping
  ## This works reliably across all platforms including Windows
  var args: seq[string] = @["--debug-server", testProg]

  # Start the process with piped stdin/stdout/stderr
  let process = startProcess(
    etchExe,
    args = args,
    options = {poUsePath, poStdErrToStdOut}  # Merge stderr into stdout
  )

  try:
    # Write input commands to stdin
    let inputStream = process.inputStream
    inputStream.write(inputCommands)
    inputStream.close()

    # Read output with timeout
    var output = ""
    let startTime = cpuTime()
    let outputStream = process.outputStream

    while process.running:
      if cpuTime() - startTime > float(timeoutSecs):
        # Timeout reached
        process.kill()
        break

      # Try to read available data without blocking indefinitely
      try:
        if not outputStream.atEnd:
          let line = outputStream.readLine()
          output.add(line & "\n")
        else:
          # No data available right now, sleep briefly
          sleep(10)
      except IOError:
        # Stream closed or error reading, break out
        break

    # Wait for process to finish (with remaining timeout)
    let remainingTime = max(0, int((float(timeoutSecs) - (cpuTime() - startTime)) * 1000))
    if remainingTime > 0 and process.running:
      discard process.waitForExit(timeout = remainingTime)

    # Read any remaining output after process finishes
    try:
      while not outputStream.atEnd:
        let line = outputStream.readLine()
        output.add(line & "\n")
    except IOError:
      discard  # Stream closed, that's ok

    let exitCode = if process.running: -1 else: process.peekExitCode()
    process.close()

    return (output, exitCode)

  except Exception:
    try:
      if process.running:
        process.kill()
    except:
      discard
    process.close()
    raise
