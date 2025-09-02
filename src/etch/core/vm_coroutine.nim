# vm_coroutine.nim
# Coroutine and channel runtime support for VirtualMachine

import std/[deques, options]
import vm_types
import vm_heap


type
  ## Coroutine state enumeration
  CoroutineState* = enum
    csSuspended   # Created or yielded, can be resumed
    csRunning     # Currently executing
    csCompleted   # Returned, cannot resume
    csDead        # Collected/cleaned up (internal-only)

  ## Coroutine runtime object
  Coroutine* = ref object
    id*: int                      # Unique coroutine ID
    state*: CoroutineState        # Current state
    savedFrame*: RegisterFrame    # Saved register state
    resumePC*: int                # PC to resume from
    yieldValue*: V                # Last yielded value
    returnValue*: V               # Final return value (when completed)
    funcIdx*: int                 # Function index being executed
    parentCoroId*: int            # Parent coroutine (-1 for main)

  ## Channel state
  ChannelState* = enum
    chOpen        # Channel is open
    chClosed      # Channel is closed

  ## Channel runtime object
  Channel* = ref object
    id*: int                        # Unique channel ID
    state*: ChannelState            # Open or closed
    buffer*: Deque[V]               # Buffered values
    capacity*: int                  # Max buffer size (0 = unbuffered)
    sendQueue*: Deque[int]          # Waiting senders (coroutine IDs)
    recvQueue*: Deque[int]          # Waiting receivers (coroutine IDs)
    blockedSenders*: seq[tuple[coroId: int, value: V]]  # Blocked with values
    blockedReceivers*: seq[int]     # Blocked receiver coroutine IDs


## Create a new coroutine
proc newCoroutine*(id: int, funcIdx: int, savedFrame: RegisterFrame, parentCoroId: int): Coroutine =
  Coroutine(
    id: id,
    state: csSuspended,
    savedFrame: savedFrame,
    resumePC: savedFrame.pc,
    yieldValue: V(kind: vkNil),
    returnValue: V(kind: vkNil),
    funcIdx: funcIdx,
    parentCoroId: parentCoroId
  )


## Create a new channel
proc newChannel*(id: int, capacity: int): Channel =
  Channel(
    id: id,
    state: chOpen,
    buffer: initDeque[V](),
    capacity: capacity,
    sendQueue: initDeque[int](),
    recvQueue: initDeque[int](),
    blockedSenders: @[],
    blockedReceivers: @[]
  )


## Check if a channel can receive (has data or is unbuffered with sender)
proc canReceive*(ch: Channel): bool =
  ch.buffer.len > 0 or (ch.capacity == 0 and ch.sendQueue.len > 0)


## Check if a channel can send (has buffer space or is unbuffered with receiver)
proc canSend*(ch: Channel): bool =
  ch.state == chOpen and (ch.buffer.len < ch.capacity or (ch.capacity == 0 and ch.recvQueue.len > 0))


## Try to send a value to a channel (non-blocking)
proc trySend*(ch: Channel, value: V): bool =
  if ch.state == chClosed:
    return false

  # Unbuffered channel with waiting receiver
  if ch.capacity == 0 and ch.recvQueue.len > 0:
    # Direct handoff
    ch.buffer.addLast(value)
    return true

  # Buffered channel with space
  if ch.buffer.len < ch.capacity:
    ch.buffer.addLast(value)
    return true

  return false


## Try to receive a value from a channel (non-blocking)
proc tryRecv*(ch: Channel): Option[V] =
  if ch.buffer.len > 0:
    return some(ch.buffer.popFirst())

  return none(V)


## Close a channel
proc closeChannel*(ch: Channel) =
  ch.state = chClosed
  # Wake up all blocked senders and receivers
  ch.sendQueue.clear()
  ch.recvQueue.clear()
  ch.blockedSenders = @[]
  ch.blockedReceivers = @[]


## Cleanup a coroutine when it's destroyed
## This function MUST be called when a coroutine is garbage collected or goes out of scope
proc cleanupCoroutine*(coro: Coroutine, vm: VirtualMachine) =
  ## Clean up a coroutine that is being destroyed
  ## This decrements refcounts for all values in the coroutine's registers
  ## and executes deferred cleanup blocks

  if coro.state == csDead:
    return  # Already cleaned up

  # Execute deferred cleanup blocks first (before decrementing refcounts)
  # This is a forward declaration - the actual implementation is in vm_execution.nim
  # to avoid circular dependencies
  # executeCoroutineDefers(vm, coro)  # Will be called from refcounting.nim instead

  # Decrement refcounts for all values in the coroutine's saved registers
  for i, val in coro.savedFrame.regs:
    if val.isHeapObject:
      vm.heap.decRef(val.heapObjectId)

  # Mark as dead
  coro.state = csDead

  # Release GC reference
  GC_unref(coro)
