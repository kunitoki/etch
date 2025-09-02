
when system.fileExists(withDir(thisDir(), "nimble.paths")):
  include "nimble.paths"

when defined(staticlib) or defined(sharedlib):
  switch("threads", "off")
else:
  switch("threads", "on")

switch("panics", "on")
switch("nimcache", ".nimcache")

when defined(macosx):
  let sdkPath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  switch("passC", "-isysroot " & sdkPath)
  switch("passL", "-L " & sdkPath & "/usr/lib -F " & sdkPath & "/System/Library/Frameworks")

  let libffiPath = "/opt/homebrew/opt/libffi"
  switch("passC", "-I" & libffiPath & "/include")
  switch("passL", libffiPath & "/lib/libffi.a")

when defined(release) or defined(deploy):
  switch("define", "danger")
  switch("define", "strip")
  switch("define", "lto")
  switch("checks", "off")

  when defined(macosx):
    switch("passC", "-O2 -fomit-frame-pointer -fvisibility=hidden -fvisibility-inlines-hidden -march=native")
    switch("passL", "-Wl,-dead_strip -Wl,-dead_strip")

when defined(debug):
  switch("panics", "on")
  switch("checks", "on")
  switch("lineDir", "on")
  switch("debugger", "native")
  switch("debuginfo")

  when defined(macosx):
    discard
    #switch("passC", "-O0 -g -fsanitize=address")
    #switch("passL", "-fsanitize=address")
    #switch("passC", "-O0 -g -fsanitize=threads")
    #switch("passL", "-fsanitize=threads")
