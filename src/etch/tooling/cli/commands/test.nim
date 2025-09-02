# cli_test.nim
# Test command implementation

import std/[algorithm, os, strformat, sequtils]
import ../options
import ../../../common/[constants]
import ../../[tester]


proc expandGlobPattern*(pattern: string): seq[string] =
  ## Expand a glob pattern to matching files
  result = @[]

  # Check if pattern contains glob characters
  if '*' in pattern or '?' in pattern:
    # Extract directory and pattern
    let (dir, name, ext) = pattern.splitFile
    let searchDir = if dir == "": "." else: dir
    let searchPattern = name & ext

    if dirExists(searchDir):
      for file in walkFiles(searchDir / searchPattern):
        result.addUnique(file)
      result.sort()
  else:
    # Not a glob pattern, check if file exists
    if fileExists(pattern):
      result.addUnique(pattern)


proc findTestFiles(directory: string): seq[string] =
  ## Find all .etch files in directory that have corresponding .result or .error files
  result = @[]

  if not dirExists(directory):
    echo &"Test directory '{directory}' does not exist"
    return

  for file in walkFiles(directory / ("*" & SOURCE_FILE_EXTENSION)):
    let baseName = file.splitFile.name
    let resultFile = directory / baseName & ".pass"
    let errorFile = directory / baseName & ".fail"
    if fileExists(resultFile) or fileExists(errorFile):
      result.addUnique(file)


proc testCommand*(options: CliOptions): int =
  # If multiple files specified, run each one
  var testFiles: seq[string] = @[]

  for f in options.files:
    let path = if f != "": f else: "examples"

    if '*' in path or '?' in path:
      # Glob pattern
      testFiles &= expandGlobPattern(path)
      if testFiles.len == 0:
        echo &"No files match pattern: {path}"
        return 1

    elif fileExists(path):
      # Single file
      testFiles.addUnique(path)

    elif dirExists(path):
      # Directory - find all test files
      testFiles &= findTestFiles(path)
      if testFiles.len == 0:
        echo "No test files found (looking for .etch files with corresponding .pass or .fail files)"
        return 1

    else:
      echo &"Error: Path '{path}' does not exist"
      return 1

  testFiles.sort()
  testFiles = deduplicate(testFiles, isSorted = true)

  let backend = if options.command == cmdTestC: "c" else: "vm"
  return runTests(testFiles, options.verbose, not options.debug, backend)
