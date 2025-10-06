# library_resolver.nim
# Shared library resolution logic for FFI imports

import std/[os, strutils]

proc resolveLibraryPath*(libName: string, fromDir: string = ""): tuple[normalizedName: string, actualPath: string] =
  ## Resolve a library name to its actual system path
  ## Returns (normalizedName, actualPath) where normalizedName is used for registration
  ## and actualPath is the full path to the library file

  var normalizedName = libName
  var actualPath = ""

  # Check if this is a path (contains /)
  if "/" in libName:
    # This is a relative path like "clib/mathlib"
    # Build the library filename based on platform
    let libFileName = when defined(macosx):
      "lib" & libName.split("/")[^1] & ".dylib"
    elif defined(windows):
      libName.split("/")[^1] & ".dll"
    else:
      "lib" & libName.split("/")[^1] & ".so"

    # Build the full path to the library
    let pathParts = libName.split("/")
    let dirPath = if pathParts.len > 1:
      pathParts[0..^2].join($DirSep)
    else:
      ""

    actualPath = if dirPath.len > 0:
      fromDir / dirPath / libFileName
    else:
      fromDir / libFileName

    # Simplify the libName for registration (just the last part)
    normalizedName = libName.split("/")[^1]
  else:
    # Map library aliases to actual libraries - ensure cross-platform compatibility
    case libName
    of "c", "libc":
      # Standard C library functions
      actualPath = when defined(macosx):
        "/usr/lib/libSystem.dylib"
      elif defined(windows):
        "msvcrt.dll"
      else:
        "libc.so.6"
      normalizedName = "c"  # Normalize to "c"

    of "cmath", "math", "m":
      # Math library functions
      actualPath = when defined(macosx):
        "/usr/lib/libSystem.dylib"  # Math is in libSystem on macOS
      elif defined(windows):
        "msvcrt.dll"  # Math is in msvcrt on Windows
      else:
        "libm.so.6"  # Separate libm on Linux
      normalizedName = "cmath"  # Normalize to "cmath"

    of "pthread", "threads":
      # Threading library
      actualPath = when defined(macosx):
        "/usr/lib/libSystem.dylib"  # pthreads is in libSystem on macOS
      elif defined(windows):
        "kernel32.dll"  # Windows threads
      else:
        "libpthread.so.0"  # Separate pthread on Linux
      normalizedName = "pthread"  # Normalize

    of "dl", "dlfcn":
      # Dynamic loading library
      actualPath = when defined(macosx):
        "/usr/lib/libSystem.dylib"  # dl functions in libSystem on macOS
      elif defined(windows):
        "kernel32.dll"  # Windows dynamic loading
      else:
        "libdl.so.2"  # Separate libdl on Linux
      normalizedName = "dl"  # Normalize

    else:
      # Custom library - determine path based on platform
      actualPath = when defined(windows):
        libName & ".dll"
      elif defined(macosx):
        "lib" & libName & ".dylib"
      else:
        "lib" & libName & ".so"
      normalizedName = libName

  return (normalizedName, actualPath)

proc findLibraryInSearchPaths*(actualPath: string, searchPaths: seq[string] = @[]): string =
  ## Try to find a library in standard search paths
  ## Returns the full path if found, empty string otherwise

  let defaultSearchPaths = @[".", "lib", "/usr/local/lib", "/usr/lib", "/lib/x86_64-linux-gnu"]
  let allPaths = if searchPaths.len > 0: searchPaths else: defaultSearchPaths

  for searchPath in allPaths:
    let fullPath = searchPath / actualPath
    if fileExists(fullPath):
      return fullPath

  return ""