# test_utils.nim
# Common utilities for Etch tests

import std/[os, osproc, strutils]

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
