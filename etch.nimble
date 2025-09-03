# Package
version       = "0.1.0"
author        = "kunitoki"
description   = "Define once, Etch forever."
license       = "MIT"
srcDir        = "src"
bin           = @["etch"]

# Dependencies
requires "nim >= 2.2.4"

task examples, "try all examples suite":
  exec "nim r src/etch.nim --test examples/"
