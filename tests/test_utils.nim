# test_utils.nim
# Common utilities for Etch tests

import std/[os, osproc, strutils, streams, times]
import ../src/etch/common/constants

proc getTimeoutCommand*(): string =
  ## Get the appropriate timeout command for the current platform
  ## Returns the command to use for timing out processes
  when defined(windows):
    return ""
  elif defined(macosx):
    let (output, exitCode) = execCmdEx("which gtimeout")
    if exitCode == 0 and output.strip().len > 0:
      return "gtimeout"
    let (output2, exitCode2) = execCmdEx("which timeout")
    if exitCode2 == 0 and output2.strip().len > 0:
      return "timeout"
    return ""
  else:
    return "timeout"

proc wrapWithTimeout*(cmd: string, seconds: int): string =
  ## Wrap a command with timeout if available
  let timeoutCmd = getTimeoutCommand()
  if timeoutCmd.len > 0:
    return timeoutCmd & " " & $seconds & " " & cmd
  else:
    return cmd

proc findEtchExecutable*(): string =
  ## Find the etch executable in bin/ directory
  ## Works whether tests are run from project root or tests directory

  when defined(windows):
    const binaryName = "bin/etch.exe"
  else:
    const binaryName = "bin/etch"

  if fileExists(binaryName):
    return binaryName
  elif fileExists("../" & binaryName):
    return "../" & binaryName
  else:
    let errorMessage = "ERROR: etch binary not found at " & binaryName & ", please run 'nimble test' from project root to build it"
    raise newException(ValueError, errorMessage)

proc getTestTempDir*(): string =
  ## Get a temporary directory for test files
  when defined(posix):
    let baseTemp = when defined(macosx): "/tmp" else: getTempDir()
    result = baseTemp / BYTECODE_CACHE_DIR
  else:
    result = getTempDir() / BYTECODE_CACHE_DIR
  if not dirExists(result):
    createDir(result)

proc cleanupTestTempDir*() =
  ## Clean up the test temporary directory
  let tempDir = getTestTempDir()
  if dirExists(tempDir):
    try:
      removeDir(tempDir)
    except:
      discard

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
