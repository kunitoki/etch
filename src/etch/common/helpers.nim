import std/[os, strutils, hashes]

proc compileFileCached*(cc, flags, source, target_filename, target_folder: string) {.compiletime.} =
  let targetPath = target_folder / target_filename & ".o"
  let hashPath = targetPath & ".hash"

  let sourceContent = staticRead(source)
  let hash = $sourceContent.hash()

  var needsCompile = true
  if fileExists(targetPath):
    if fileExists(hashPath):
      let storedHash = readFile(hashPath).strip()
      if storedHash == hash:
        needsCompile = false

  if needsCompile:
    let compileResult = staticExec(cc & " " & flags & " -c " & source & " -o " & targetPath)
    if compileResult.len > 0:
      echo compileResult

    writeFile(hashPath, hash)
