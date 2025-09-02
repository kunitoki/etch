# arg_queue.nim
# Helpers for managing pending call argument buffers

import ../[vm, vm_types]

proc takePendingCallArgs*(vm: VirtualMachine, expected: uint8, verbose: bool): seq[V] {.inline.} =
  ## Consume the most recently queued arguments for the next call, padding if needed.
  ## Returns a sequence of exactly `expected` arguments (filled with nil when missing).
  let need = int(expected)
  if need == 0:
    return @[]

  let have = vm.pendingCallArgs.len

  let startIdx = max(0, have - need)
  if vm.argScratch.len < need:
    vm.argScratch.setLen(need)
  var srcIdx = startIdx
  var dstIdx = 0
  while srcIdx < have and dstIdx < need:
    vm.argScratch[dstIdx] = vm.pendingCallArgs[srcIdx]
    inc srcIdx
    inc dstIdx
  while dstIdx < need:
    vm.argScratch[dstIdx] = makeNil()
    inc dstIdx
  result = vm.argScratch[0 ..< need]

  vm.pendingCallArgs.setLen(startIdx)
