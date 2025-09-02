# vm_heap.nim
# Explicit heap management with reference counting and cycle detection

import std/[tables, sets, strformat, monotimes, times]
import ../common/logging
import vm_types
import vm


proc incRef*(heap: Heap, id: int) {.inline.}
proc decRef*(heap: Heap, id: int) {.inline.}
proc trackRef*(heap: Heap, parentId: int, childValue: V)
proc freeObjectImpl*(heap: Heap, id: int)


# Create a new heap with optimized defaults
proc newHeap*(verbose: bool = false, cycleInterval: int = 1000, enableVerification: bool = false): Heap =
  result = Heap(
    objects: @[nil], # Index 0 is reserved
    nextId: 1,  # Start from 1, 0 reserved for nil
    freeList: @[],
    dirtyObjects: initHashSet[int](),
    weakRefObjects: initHashSet[int](),
    cycleDetectionInterval: cycleInterval,
    minCycleInterval: max(100, cycleInterval div 10),
    maxCycleInterval: cycleInterval * 10,
    operationCount: 0,
    verbose: verbose,
    vm: nil,  # Will be set during VM initialization
    callDestructor: nil,  # Will be set during VM initialization
    stats: HeapStats(
      allocCount: 0,
      freeCount: 0,
      cyclesDetected: 0,
      cycleCheckCount: 0,
      totalGCTime: 0,
      avgAllocRate: 0.0,
      lastCheckAllocs: 0
    ),
    enableVerification: enableVerification,
    verificationInterval: 10000,  # Check every 10k operations in debug mode
    lastVerificationOp: 0,
    # Frame budget fields (disabled by default)
    frameBudgetUs: 0,
    frameStartTime: getMonoTime(),
    gcWorkThisFrame: 0,
    dirtyCheckedThisFrame: 0,
    # Edge buffer (NEW)
    edgeBuffer: EdgeBuffer(
      edges: @[],
      index: @[-1'i32], # Index 0 reserved
      dirtyEdges: initHashSet[int](),
      totalEdges: 0,
      maxEdges: 0
    ),
    # Time-sliced GC state (initialized as not in progress)
    gcState: GCState(
      inProgress: false,
      reachableFromDirty: initHashSet[int](),
      pendingObjects: @[],
      tarjanIndex: 0,
      tarjanStack: @[],
      tarjanIndices: @[],
      tarjanLowlinks: @[],
      tarjanOnStack: initHashSet[int](),
      cycles: @[],
      objectsProcessedThisSlice: 0,
      maxObjectsPerSlice: 100  # Process 100 objects per slice by default
    ),
    # Bump allocator (disabled by default, opt-in for performance-critical code)
    bumpAllocator: BumpAllocator(
      buffer: @[],
      enabled: false,
      maxPerFrame: 10000  # Safety limit: max 10k temp objects per frame
    )
  )


# Allocate a new object ID
proc allocId*(heap: Heap): int =
  if heap.freeList.len > 0:
    result = heap.freeList.pop()
  else:
    result = heap.objects.len
    heap.objects.add(nil)
    # Ensure edge buffer index grows with objects
    if heap.edgeBuffer.index.len <= result:
      heap.edgeBuffer.index.setLen(result + 1)
      heap.edgeBuffer.index[result] = -1'i32
    heap.nextId = result + 1


# ============================================================================
# EdgeBuffer Operations
# ============================================================================

proc addEdge*(buf: EdgeBuffer, sourceId: int, targetId: int, fieldHash: int16 = 0, edgeType: EdgeType = etField) {.inline.} =
  ## Add an edge from source to target object
  ## This is the hot path - must be fast

  # Get current head of the list for this source
  let nextEdge = if sourceId < buf.index.len: buf.index[sourceId] else: -1'i32

  buf.edges.add(EdgeEntry(
    sourceId: int32(sourceId),
    targetId: int32(targetId),
    nextEdge: nextEdge,
    fieldHash: fieldHash,
    edgeType: edgeType,
    padding: 0
  ))
  buf.dirtyEdges.incl(sourceId)
  inc buf.totalEdges
  buf.maxEdges = max(buf.maxEdges, buf.totalEdges)

  # Update index (new head)
  if sourceId < buf.index.len:
    buf.index[sourceId] = int32(buf.edges.len - 1)


iterator outgoingEdges*(buf: EdgeBuffer, objectId: int): int =
  ## Iterate over all outgoing edges from an object
  ## Yields target object IDs
  if objectId < buf.index.len:
    var currIdx = buf.index[objectId]
    while currIdx != -1:
      if currIdx < buf.edges.len:
        let edge = buf.edges[currIdx]
        if edge.targetId != -1: # Skip dead edges
          yield int(edge.targetId)
        currIdx = edge.nextEdge
      else:
        break # Should not happen


proc clearEdges*(buf: EdgeBuffer, objectId: int) =
  ## Clear all edges from an object (when it's being freed or modified)
  if objectId >= buf.index.len:
    return

  # Just detach the list from the object
  # The edges remain in the buffer but are unreachable from the object
  # They will be cleaned up during compaction
  buf.index[objectId] = -1'i32
  buf.dirtyEdges.excl(objectId)


proc compactEdges*(buf: EdgeBuffer, liveObjects: HashSet[int]) =
  ## Compact the edge buffer by removing dead edges
  ## Called during GC to reclaim space

  var newEdges = newSeqOfCap[EdgeEntry](buf.edges.len)
  var oldIndex = buf.index # Copy old index to traverse old lists

  # Reset index
  for i in 0 ..< buf.index.len:
    buf.index[i] = -1'i32

  # Iterate all live objects
  for objId in liveObjects:
    if objId >= oldIndex.len: continue

    # Traverse old list
    var currIdx = oldIndex[objId]
    var prevNewIdx = -1'i32
    var firstNewIdx = -1'i32

    while currIdx != -1 and currIdx < buf.edges.len:
      let edge = buf.edges[currIdx]

      # Keep edge if target is alive
      if edge.targetId != -1 and int(edge.targetId) in liveObjects:
        # Add to new edges
        let newIdx = int32(newEdges.len)
        newEdges.add(edge)
        newEdges[newIdx].nextEdge = -1'i32 # Will be linked

        if firstNewIdx == -1:
          firstNewIdx = newIdx
          buf.index[objId] = newIdx # Set head
        else:
          newEdges[prevNewIdx].nextEdge = newIdx

        prevNewIdx = newIdx

      currIdx = edge.nextEdge

  buf.edges = newEdges
  buf.totalEdges = buf.edges.len
  buf.dirtyEdges.clear()


# Forward declaration for adaptive cycle detection
proc maybeCheckCycles*(heap: Heap): seq[CycleInfo]


# Allocate a new table object
proc allocTable*(heap: Heap, destructorFuncIdx: int = -1): int =
  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokTable,
    strongRefs: 1,  # Start with 1 reference
    weakRefs: 0,
    marked: false,
    dirty: true,  # New objects are dirty
    destructorFuncIdx: destructorFuncIdx,
    beingDestroyed: false,
    fields: initTable[string, V](),
    fieldRefs: initHashSet[int](),
    fieldCache: initTable[string, V]()
  )
  inc heap.stats.allocCount
  heap.dirtyObjects.incl(id)
  if heap.verbose:
    let dtorInfo = if destructorFuncIdx >= 0: &" destructor=func#{destructorFuncIdx}" else: ""
    logHeap(heap.verbose, &"Allocated table object #{id} (strong refs: 1{dtorInfo})")

  # Check for cycles adaptively (respects frame budget if set)
  discard heap.maybeCheckCycles()

  return id


# Allocate a new array object
proc allocArray*(heap: Heap, size: int = 0): int =
  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokArray,
    strongRefs: 1,  # Start with 1 reference
    weakRefs: 0,
    marked: false,
    dirty: true,  # New objects are dirty
    destructorFuncIdx: -1,  # Arrays don't have destructors
    beingDestroyed: false,
    elements: newSeq[V](size),
    elementRefs: initHashSet[int]()
  )
  inc heap.stats.allocCount
  heap.dirtyObjects.incl(id)
  logHeap(heap.verbose, &"Allocated array object #{id} size={size} (strong refs: 1)")

  # Check for cycles adaptively (respects frame budget if set)
  discard heap.maybeCheckCycles()

  return id


# Retain/release helpers used by heap containers
proc retainHeapValue*(heap: Heap, val: V) {.inline.} =
  if val.kind == vkNil:
    return

  if val.isHeapObject:
    heap.incRef(val.heapObjectId)
  elif val.kind == vkCoroutine and heap.vm != nil:
    let vm = cast[VirtualMachine](heap.vm)
    vm.retainCoroutineRef(val.coroId)


proc releaseHeapValue*(heap: Heap, val: V) {.inline.} =
  if val.kind == vkNil:
    return

  if val.isHeapObject:
    heap.decRef(val.heapObjectId)
  elif val.kind == vkCoroutine and heap.vm != nil:
    let vm = cast[VirtualMachine](heap.vm)
    vm.releaseCoroutineRef(val.coroId)


# Allocate a new closure object
proc allocClosure*(heap: Heap, funcIdx: int, captures: openArray[V]): int =
  let id = heap.allocId()
  var copiedCaptures = @captures
  var captureRefs = initHashSet[int]()
  for val in copiedCaptures:
    case val.kind
    of vkRef:
      captureRefs.incl(val.refId)
    of vkClosure:
      captureRefs.incl(val.closureId)
    else:
      discard
    heap.retainHeapValue(val)

  heap.objects[id] = HeapObject(
    id: id,
    kind: hokClosure,
    strongRefs: 1,
    weakRefs: 0,
    marked: false,
    dirty: true,
    destructorFuncIdx: -1,
    beingDestroyed: false,
    funcIdx: funcIdx,
    captures: copiedCaptures,
    captureRefs: captureRefs
  )
  inc heap.stats.allocCount
  heap.dirtyObjects.incl(id)
  for val in copiedCaptures:
    heap.trackRef(id, val)
  logHeap(heap.verbose, &"Allocated closure object #{id} (funcIdx={funcIdx}, captures={captures.len})")
  discard heap.maybeCheckCycles()
  return id


# Allocate a new scalar object
proc allocScalar*(heap: Heap, val: V): int =
  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokScalar,
    strongRefs: 1,  # Start with 1 reference
    weakRefs: 0,
    marked: false,
    dirty: false,  # Scalars don't participate in cycles
    destructorFuncIdx: -1,  # Scalars don't have destructors
    beingDestroyed: false,
    value: val
  )
  inc heap.stats.allocCount
  logHeap(heap.verbose, &"Allocated scalar object #{id} (strong refs: 1)")
  return id


proc setScalarValue*(heap: Heap, id: int, val: V) =
  ## Replace the scalar value stored in heap object `id`, retaining/releasing refs safely
  if id <= 0 or id >= heap.objects.len:
    return
  let obj = heap.objects[id]
  if obj == nil or obj.kind != hokScalar:
    when not defined(release):
      logHeap(heap.verbose, &"setScalarValue called on non-scalar object #{id}")
    return

  heap.retainHeapValue(val)
  let oldVal = obj.value
  obj.value = val
  heap.releaseHeapValue(oldVal)
  logHeap(heap.verbose, &"Updated scalar object #{id} value")


# Allocate a weak reference
proc allocWeak*(heap: Heap, targetId: int, targetType: string): int =
  if targetId == 0:
    # Weak reference to nil
    return 0

  if targetId >= heap.objects.len or heap.objects[targetId] == nil:
    logHeap(heap.verbose, &"Warning: Creating weak ref to non-existent object #{targetId}")
    return 0

  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokWeak,
    strongRefs: 1,  # Weak ref itself has strong refs
    weakRefs: 0,
    marked: false,
    dirty: false,  # Weak refs don't participate in cycles
    destructorFuncIdx: -1,  # Weak refs don't have destructors
    beingDestroyed: false,
    targetId: targetId,
    targetType: targetType
  )

  # Increment weak count on target
  inc heap.objects[targetId].weakRefs

  # Track weak ref object for fast nullification
  heap.weakRefObjects.incl(id)

  inc heap.stats.allocCount
  logHeap(heap.verbose, &"Allocated weak ref #{id} -> #{targetId} (target weak refs: {heap.objects[targetId].weakRefs})")
  return id


# Get object by ID
proc getObject*(heap: Heap, id: int): HeapObject =
  if id == 0 or id >= heap.objects.len or heap.objects[id] == nil:
    return nil
  return heap.objects[id]


# CRITICAL PATH: Increment strong reference count (inlined proc)
# This is called very frequently, so we inline it for maximum performance
proc incRef*(heap: Heap, id: int) {.inline.} =
  # Fast path: early return for nil
  if id == 0:
    return

  when not defined(release):
    if id >= heap.objects.len or heap.objects[id] == nil:
      logHeap(heap.verbose, &"Warning: Attempting to incRef non-existent object #{id}")
      return

  inc heap.objects[id].strongRefs
  when not defined(release):
    logHeap(heap.verbose, &"IncRef #{id} (strong refs: {heap.objects[id].strongRefs})")


# Track reference from parent to child (for cycle detection)
proc trackRef*(heap: Heap, parentId: int, childValue: V) =
  if parentId == 0:
    return

  # Fast path for scalar values - avoid expensive heap checks
  case childValue.kind:
  of vkInt, vkFloat, vkBool, vkChar, vkString, vkEnum, vkNil:
    return  # Scalars don't create reference cycles
  else:
    discard  # Continue with heap object tracking

  # Only track references to heap or closure objects
  if not childValue.isHeapObject:
    return

  let childId = childValue.heapObjectId

  if parentId >= heap.objects.len or heap.objects[parentId] == nil:
    return

  let parent = heap.objects[parentId]

  # Mark parent as dirty since its reference set changed
  parent.dirty = true
  heap.dirtyObjects.incl(parentId)

  case parent.kind
  of hokScalar:
    # Scalars don't have references to other objects
    discard
  of hokTable:
    # Lazy update: we don't update EdgeBuffer here.
    # It will be rebuilt in detectCycles for dirty objects.
    discard
  of hokArray:
    discard
  of hokClosure:
    discard
  of hokRef:
    parent.refTargetId = childId
  of hokWeak:
    discard


# Nullify all weak references to an object
proc nullifyWeakRefs*(heap: Heap, targetId: int) =
  # Find all weak references pointing to this target
  # Optimized: only check known weak ref objects
  for weakId in heap.weakRefObjects:
    if weakId < heap.objects.len and heap.objects[weakId] != nil:
      let obj = heap.objects[weakId]
      if obj.targetId == targetId:
        obj.targetId = -1  # Mark as freed
        logHeap(heap.verbose, &"Nullified weak ref #{weakId} (was pointing to #{targetId})")


# CRITICAL PATH: Decrement strong reference count (inlined proc)
# This is called very frequently, so we inline it for maximum performance
proc decRef*(heap: Heap, id: int) {.inline.} =
  # Fast path: early return for nil
  if id == 0:
    return

  # Always check if object exists (even in release mode) to avoid crashes
  if id >= heap.objects.len or heap.objects[id] == nil:
    when not defined(release):
      logHeap(heap.verbose, &"Warning: Attempting to decRef non-existent object #{id}")
    return

  dec heap.objects[id].strongRefs

  when not defined(release):
    logHeap(heap.verbose, &"DecRef #{id} (strong refs: {heap.objects[id].strongRefs})")

  if heap.objects[id].strongRefs <= 0:
    # Free the object (may recursively call decRef on children)
    heap.freeObjectImpl(id)


# Implementation of freeObject (called when strong refs reach 0)
# This is the actual implementation that does the work
proc freeObjectImpl*(heap: Heap, id: int) =
  if id == 0 or id >= heap.objects.len or heap.objects[id] == nil:
    return

  let obj = heap.objects[id]
  logHeap(heap.verbose, &"Freeing object #{id} kind={obj.kind} (weak refs: {obj.weakRefs})")

  if obj.kind == hokWeak:
    heap.weakRefObjects.excl(id)

  # Call destructor BEFORE freeing children (if object has one and not already being destroyed)
  if obj.destructorFuncIdx >= 0 and not obj.beingDestroyed:
    if heap.callDestructor != nil and heap.vm != nil:
      # Set flag to prevent re-entrancy
      obj.beingDestroyed = true
      logHeap(heap.verbose, &"Calling destructor for object #{id} (funcIdx={obj.destructorFuncIdx})")
      # Call destructor through callback
      heap.callDestructor(heap.vm, obj.destructorFuncIdx, id)
      logHeap(heap.verbose, &"Destructor completed for object #{id}")

  # Nullify any weak references pointing to this object
  if obj.weakRefs > 0:
    heap.nullifyWeakRefs(id)

  # Decrement refs for children
  case obj.kind
  of hokScalar:
    # Scalars don't have child references
    discard
  of hokTable:
    for fieldVal in obj.fields.values:
      heap.releaseHeapValue(fieldVal)
  of hokArray:
    for elem in obj.elements:
      heap.releaseHeapValue(elem)
  of hokWeak:
    # Decrement weak count on target if still alive
    if obj.targetId > 0 and obj.targetId < heap.objects.len and heap.objects[obj.targetId] != nil:
      dec heap.objects[obj.targetId].weakRefs
  of hokClosure:
    for cap in obj.captures:
      heap.releaseHeapValue(cap)
  of hokRef:
    heap.releaseHeapValue(obj.refValue)

  # Clear edges from EdgeBuffer (NEW)
  heap.edgeBuffer.clearEdges(id)

  # Remove from objects table
  heap.objects[id] = nil
  heap.freeList.add(id)
  heap.dirtyObjects.excl(id)  # No longer dirty since it's freed
  inc heap.stats.freeCount


# Keep freeObject as an alias for backward compatibility
proc freeObject*(heap: Heap, id: int) {.inline.} =
  heap.freeObjectImpl(id)


# Promote weak reference to strong reference (returns 0 if target freed)
proc weakToStrong*(heap: Heap, weakId: int): int =
  if weakId == 0:
    return 0

  if weakId >= heap.objects.len or heap.objects[weakId] == nil:
    return 0

  let weakObj = heap.objects[weakId]
  if weakObj.kind != hokWeak:
    logHeap(heap.verbose, &"Warning: weakToStrong called on non-weak object #{weakId}")
    return 0

  if weakObj.targetId <= 0 or weakObj.targetId >= heap.objects.len or heap.objects[weakObj.targetId] == nil:
    # Target was freed
    return 0

  # Target still alive, increment its strong ref count
  heap.incRef(weakObj.targetId)
  return weakObj.targetId


# Optimized cycle detection using incremental DFS-based strongly connected components
# Only checks dirty objects and their reachable subgraph for better performance
# Set forceFull=true to check all objects (used at program exit)
proc detectCycles*(heap: Heap, forceFull: bool = false): seq[CycleInfo] =
  let startTime = getMonoTime()
  defer:
    heap.stats.totalGCTime += (getMonoTime() - startTime).inNanoseconds

  result = @[]
  inc heap.stats.cycleCheckCount

  logHeap(heap.verbose, &"Running cycle detection (check #{heap.stats.cycleCheckCount}, dirty: {heap.dirtyObjects.len}, forceFull: {forceFull})")

  # Early exit if no dirty objects (unless forcing full check)
  if not forceFull and heap.dirtyObjects.len == 0:
    return @[]

  # Rebuild edges for dirty objects to ensure graph is up to date
  # This allows trackRef to be O(1) without maintaining edges incrementally
  for id in heap.dirtyObjects:
    if id < heap.objects.len and heap.objects[id] != nil:
      let obj = heap.objects[id]
      heap.edgeBuffer.clearEdges(id)

      case obj.kind
      of hokTable:
        for val in obj.fields.values:
          if val.isHeapObject:
            heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etField)
      of hokArray:
        for val in obj.elements:
          if val.isHeapObject:
            heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etElement)
      of hokClosure:
        for val in obj.captures:
          if val.isHeapObject:
            heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etCapture)
      of hokRef:
        if obj.refTargetId > 0:
          heap.edgeBuffer.addEdge(id, obj.refTargetId, edgeType = etRef)
      else:
        discard

  # Reset marks
  for obj in heap.objects:
    if obj != nil:
      obj.marked = false

  # Build reachable set from dirty objects (incremental SCC) or all objects (full check)
  var reachableFromDirty = initHashSet[int]()

  if forceFull:
    # Full check: include all live objects
    for id in 0 ..< heap.objects.len:
      let obj = heap.objects[id]
      if obj != nil and obj.strongRefs > 0:
        reachableFromDirty.incl(id)
    logHeap(heap.verbose, &"Full SCC: checking {reachableFromDirty.len} objects")
  else:
    # Incremental check: only objects reachable from dirty objects
    proc markReachable(id: int) =
      if id in reachableFromDirty or id >= heap.objects.len or heap.objects[id] == nil:
        return
      reachableFromDirty.incl(id)
      let obj = heap.objects[id]

      # Skip objects with no outgoing edges
      case obj.kind
      of hokScalar, hokWeak:
        return  # No children to traverse
      of hokTable, hokArray, hokClosure, hokRef:
        # Use EdgeBuffer to get children
        for childId in heap.edgeBuffer.outgoingEdges(id):
          markReachable(childId)

    # Mark all objects reachable from dirty objects
    for dirtyId in heap.dirtyObjects:
      markReachable(dirtyId)

    if heap.verbose:
      logHeap(heap.verbose, &"Incremental SCC: checking {reachableFromDirty.len} reachable objects (from {heap.dirtyObjects.len} dirty)")
      # Debug: print what dirty objects actually are
      var kindCounts = initTable[HeapObjectKind, int]()
      var refCounts = initTable[int, int]()  # refcount -> count
      for dirtyId in heap.dirtyObjects:
        if dirtyId < heap.objects.len and heap.objects[dirtyId] != nil:
          let obj = heap.objects[dirtyId]
          kindCounts[obj.kind] = kindCounts.getOrDefault(obj.kind, 0) + 1
          refCounts[obj.strongRefs] = refCounts.getOrDefault(obj.strongRefs, 0) + 1
      logHeap(heap.verbose, &"  Dirty object breakdown:")
      for kind, count in kindCounts.pairs:
        logHeap(heap.verbose, &"    {kind}: {count}")
      logHeap(heap.verbose, &"  Reference count distribution:")
      for refs, count in refCounts.pairs:
        logHeap(heap.verbose, &"    refs={refs}: {count} objects")

  # Scan weak references for promoted targets
  # Weak refs that have been promoted via weakToStrong should have their targets
  # treated as reachable roots to prevent premature collection
  for id, obj in heap.objects:
    if obj == nil: continue
    if obj.kind == hokWeak:
      # Check if weak ref itself is strongly held (stored in registers/globals)
      if obj.strongRefs > 0 and obj.targetId > 0:
        # Target should be considered reachable if it still exists
        if obj.targetId < heap.objects.len and heap.objects[obj.targetId] != nil:
          reachableFromDirty.incl(obj.targetId)
          logHeap(heap.verbose, &"Weak ref #{id} keeps target #{obj.targetId} reachable")

  # Tarjan's algorithm for strongly connected components (only on reachable subset)
  var
    index = 0
    stack: seq[int] = @[]
    indices = newSeq[int](heap.objects.len)
    lowlinks = newSeq[int](heap.objects.len)
    onStack = initHashSet[int]()
    cycles: seq[CycleInfo] = @[]

  # Initialize with -1 (0 is valid index)
  for i in 0 ..< indices.len:
    indices[i] = -1
    lowlinks[i] = -1

  proc strongConnect(v: int, cyclesOut: var seq[CycleInfo]) =
    # Early exit if object doesn't exist
    if v >= heap.objects.len or heap.objects[v] == nil:
      return

    # Early skip for trivial cases: objects with refcount==1 and no outgoing edges can't be in cycles
    # But we must check if they actually have outgoing edges first
    if heap.objects[v].strongRefs == 1:
      let obj = heap.objects[v]
      var hasOutgoingEdges = false
      case obj.kind
      of hokTable, hokArray, hokClosure, hokRef:
        # Check if this object has any outgoing edges via EdgeBuffer
        for childId in heap.edgeBuffer.outgoingEdges(v):
          hasOutgoingEdges = true
          break
      of hokScalar, hokWeak:
        # Scalars and weak references have no outgoing edges
        discard

      if not hasOutgoingEdges:
        return  # No outgoing edges = can't be in a cycle

    indices[v] = index
    lowlinks[v] = index
    inc index
    stack.add(v)
    onStack.incl(v)

    let obj = heap.objects[v]
    var hasChildren = false

    # Use EdgeBuffer for iteration
    case obj.kind
    of hokScalar, hokWeak:
      return
    of hokTable, hokArray, hokClosure, hokRef:
      for w in heap.edgeBuffer.outgoingEdges(v):
        hasChildren = true
        if w notin reachableFromDirty:
          continue
        if indices[w] == -1:
          strongConnect(w, cyclesOut)
          # Only update lowlinks if w was successfully processed
          if lowlinks[w] != -1:
            lowlinks[v] = min(lowlinks[v], lowlinks[w])
        elif w in onStack:
          # Only update if w is still tracked
          if indices[w] != -1:
            lowlinks[v] = min(lowlinks[v], indices[w])

    # Early skip: no children means no cycles
    if not hasChildren:
      return

    # Root of SCC
    if lowlinks[v] == indices[v]:
      var component: seq[int] = @[]
      var w: int
      while true:
        w = stack.pop()
        onStack.excl(w)
        component.add(w)
        if w == v:
          break

      # Only report if it's a real cycle (size > 1 or self-referencing)
      # Check for self-reference by looking in EdgeBuffer
      var hasSelfRef = false
      if component.len == 1:
        for w in heap.edgeBuffer.outgoingEdges(v):
          if w == v:
            hasSelfRef = true
            break

      if component.len > 1 or hasSelfRef:
        var cycleInfo = CycleInfo(
          objectIds: component,
          objectKinds: @[],
          totalSize: component.len
        )
        for id in component:
          if id < heap.objects.len and heap.objects[id] != nil:
            cycleInfo.objectKinds.add(heap.objects[id].kind)
        cyclesOut.add(cycleInfo)
        inc heap.stats.cyclesDetected

  # Run SCC detection only on reachable objects (incremental)
  for id in reachableFromDirty:
    if indices[id] == -1:
      strongConnect(id, cycles)

  # Clear dirty flags for objects we just checked
  # Note: Some objects may have been freed during strongConnect (e.g., by destructors),
  # so we must check hasKey before accessing each object
  for id in reachableFromDirty:
    if id < heap.objects.len and heap.objects[id] != nil:
      heap.objects[id].dirty = false
  heap.dirtyObjects.clear()

  result = cycles


# Time-Sliced Incremental GC: Can pause/resume for very large heaps (50k+ objects)
proc detectCyclesSliced*(heap: Heap, maxObjectsThisSlice: int = 100): tuple[completed: bool, cycles: seq[CycleInfo]] =
  ## Time-sliced cycle detection: process up to maxObjectsThisSlice objects
  ## Returns (completed, cycles): completed=true when GC finishes, cycles=detected cycles
  ## Call repeatedly until completed=true
  ##
  ## For heaps with 50k+ objects, this allows spreading GC work across multiple frames

  let state = heap.gcState

  # Start new GC cycle if not in progress
  if not state.inProgress:
    inc heap.stats.cycleCheckCount

    logHeap(heap.verbose, &"Starting time-sliced cycle detection (check #{heap.stats.cycleCheckCount}, dirty: {heap.dirtyObjects.len})")

    # Early exit if no dirty objects
    if heap.dirtyObjects.len == 0:
      return (true, @[])

    # Rebuild edges for dirty objects (Lazy update strategy)
    for id in heap.dirtyObjects:
      if id < heap.objects.len and heap.objects[id] != nil:
        let obj = heap.objects[id]
        heap.edgeBuffer.clearEdges(id)

        case obj.kind
        of hokTable:
          for val in obj.fields.values:
            if val.isHeapObject:
              heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etField)
        of hokArray:
          for val in obj.elements:
            if val.isHeapObject:
              heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etElement)
        of hokClosure:
          for val in obj.captures:
            if val.isHeapObject:
              heap.edgeBuffer.addEdge(id, val.heapObjectId, edgeType = etCapture)
        of hokRef:
          if obj.refTargetId > 0:
            heap.edgeBuffer.addEdge(id, obj.refTargetId, edgeType = etRef)
        else:
          discard

    # Reset marks
    for obj in heap.objects.mitems:
      if obj != nil:
        obj.marked = false

    # Build reachable set from dirty objects
    state.reachableFromDirty = initHashSet[int]()

    proc markReachable(id: int) =
      if id in state.reachableFromDirty or id >= heap.objects.len or heap.objects[id] == nil:
        return
      state.reachableFromDirty.incl(id)
      let obj = heap.objects[id]

      case obj.kind
      of hokScalar, hokWeak:
        return
      of hokTable, hokArray, hokClosure, hokRef:
        for childId in heap.edgeBuffer.outgoingEdges(id):
          markReachable(childId)

    for dirtyId in heap.dirtyObjects:
      markReachable(dirtyId)

    # Initialize Tarjan state
    state.tarjanIndex = 0
    state.tarjanStack = @[]
    state.tarjanIndices = newSeq[int](heap.objects.len)
    state.tarjanLowlinks = newSeq[int](heap.objects.len)
    for i in 0 ..< state.tarjanIndices.len:
      state.tarjanIndices[i] = -1
      state.tarjanLowlinks[i] = -1
    state.tarjanOnStack = initHashSet[int]()
    state.cycles = @[]
    state.objectsProcessedThisSlice = 0

    # Queue all reachable objects for processing
    state.pendingObjects = @[]
    for id in state.reachableFromDirty:
      state.pendingObjects.add(id)

    state.inProgress = true

    logHeap(heap.verbose, &"Time-sliced GC: {state.pendingObjects.len} objects to process")

  # Process up to maxObjectsThisSlice objects this time slice
  state.objectsProcessedThisSlice = 0

  proc strongConnectSliced(v: int): bool =
    ## Returns true if we should continue, false if slice budget exhausted
    inc state.objectsProcessedThisSlice
    if state.objectsProcessedThisSlice >= maxObjectsThisSlice:
      return false  # Budget exhausted, pause

    # Skip if already visited
    if state.tarjanIndices[v] != -1:
      return true

    # Early skip for trivial cases: objects with refcount==1 and no outgoing edges can't be in cycles
    if v < heap.objects.len and heap.objects[v] != nil and heap.objects[v].strongRefs == 1:
      let obj = heap.objects[v]
      var hasOutgoingEdges = false
      case obj.kind
      of hokTable, hokArray, hokClosure, hokRef:
        for childId in heap.edgeBuffer.outgoingEdges(v):
          hasOutgoingEdges = true
          break
      of hokScalar, hokWeak:
        discard

      if not hasOutgoingEdges:
        return true  # No outgoing edges = can't be in a cycle

    state.tarjanIndices[v] = state.tarjanIndex
    state.tarjanLowlinks[v] = state.tarjanIndex
    inc state.tarjanIndex
    state.tarjanStack.add(v)
    state.tarjanOnStack.incl(v)

    if v >= heap.objects.len or heap.objects[v] == nil:
      return true

    let obj = heap.objects[v]
    var hasChildren = false

    case obj.kind
    of hokScalar, hokWeak:
      return true
    of hokTable, hokArray, hokClosure, hokRef:
      for w in heap.edgeBuffer.outgoingEdges(v):
        hasChildren = true
        if w notin state.reachableFromDirty:
          continue

        if state.tarjanIndices[w] == -1:
          if not strongConnectSliced(w):
            return false  # Propagate budget exhaustion
          state.tarjanLowlinks[v] = min(state.tarjanLowlinks[v], state.tarjanLowlinks[w])
        elif w in state.tarjanOnStack:
          state.tarjanLowlinks[v] = min(state.tarjanLowlinks[v], state.tarjanIndices[w])

    if not hasChildren:
      return true

    # Root of SCC
    if state.tarjanLowlinks[v] == state.tarjanIndices[v]:
      var component: seq[int] = @[]
      var w: int
      while true:
        w = state.tarjanStack.pop()
        state.tarjanOnStack.excl(w)
        component.add(w)
        if w == v:
          break

      # Check if it's a real cycle
      var hasSelfRef = false
      if component.len == 1:
        for targetId in heap.edgeBuffer.outgoingEdges(v):
          if targetId == v:
            hasSelfRef = true
            break

      if component.len > 1 or hasSelfRef:
        var cycleInfo = CycleInfo(
          objectIds: component,
          objectKinds: @[],
          totalSize: component.len
        )
        for id in component:
          if id < heap.objects.len and heap.objects[id] != nil:
            cycleInfo.objectKinds.add(heap.objects[id].kind)
        state.cycles.add(cycleInfo)
        inc heap.stats.cyclesDetected

    return true

  # Process pending objects until budget exhausted or all done
  while state.pendingObjects.len > 0:
    let id = state.pendingObjects.pop()

    if state.tarjanIndices[id] == -1:
      if not strongConnectSliced(id):
        # Budget exhausted, save state and return
        logHeap(heap.verbose, &"Time-sliced GC: paused ({state.objectsProcessedThisSlice} objects processed, {state.pendingObjects.len} remaining)")
        return (false, state.cycles)

  # All objects processed, GC complete
  logHeap(heap.verbose, &"Time-sliced GC: completed ({state.objectsProcessedThisSlice} objects processed, {state.cycles.len} cycles found)")

  # Clear dirty flags
  for id in state.reachableFromDirty:
    if id < heap.objects.len and heap.objects[id] != nil:
      heap.objects[id].dirty = false
  heap.dirtyObjects.clear()

  # Reset state
  state.inProgress = false

  result = (true, state.cycles)


# Frame Budget API for Game Engine Integration
proc beginHeapFrame*(heap: Heap, budgetUs: int64) =
  ## Start a new frame with a GC time budget
  ## budgetUs: Microseconds available for GC work this frame
  ## Set to 0 to disable frame budgeting (use adaptive intervals)
  heap.frameBudgetUs = budgetUs
  heap.frameStartTime = getMonoTime()
  heap.gcWorkThisFrame = 0
  heap.dirtyCheckedThisFrame = 0

  if budgetUs > 0:
    logHeap(heap.verbose, &"Frame started with {budgetUs}us GC budget")


proc hasFrameBudgetRemaining*(heap: Heap, minRequired: int64 = 500): bool =
  ## Check if there's enough frame budget remaining for GC work
  ## Returns false if frame budget is disabled (0) or insufficient budget remains
  if heap.frameBudgetUs == 0:
    return true  # Budget disabled, always allow GC

  let elapsed = inMicroseconds(getMonoTime() - heap.frameStartTime)
  let remaining = heap.frameBudgetUs - heap.gcWorkThisFrame

  if remaining < minRequired:
    logHeap(heap.verbose, &"Insufficient frame budget: {remaining}us < {minRequired}us (elapsed: {elapsed}us)")

  return remaining >= minRequired


proc getFrameGCStats*(heap: Heap): tuple[usedUs: int64, budgetUs: int64, dirtyCount: int] =
  ## Get GC statistics for the current frame
  return (
    usedUs: heap.gcWorkThisFrame,
    budgetUs: heap.frameBudgetUs,
    dirtyCount: heap.dirtyCheckedThisFrame
  )


# Bump Allocator API for Zero-Overhead Temporary Objects
proc enableBumpAllocator*(heap: Heap, enabled: bool = true) =
  ## Enable/disable bump allocator for temporary frame-local objects
  ## When enabled, objects allocated with allocBump() have zero RC overhead
  ## and are bulk-freed at frame end with clearBumpAllocator()
  heap.bumpAllocator.enabled = enabled
  if enabled:
    logHeap(heap.verbose, "Bump allocator enabled (zero-overhead temp objects)")
  else:
    logHeap(heap.verbose, "Bump allocator disabled")


proc isBumpObject*(heap: Heap, id: int): bool =
  ## Check if an object was allocated via bump allocator
  id in heap.bumpAllocator.buffer


proc clearBumpAllocator*(heap: Heap) =
  ## Bulk-free all bump-allocated objects from this frame
  ## Call this at frame end to clear temporary objects
  ## This is much faster than decRef() for each object
  if not heap.bumpAllocator.enabled:
    return

  let count = heap.bumpAllocator.buffer.len
  if count > 0:
    logHeap(heap.verbose, &"Clearing {count} bump-allocated objects")

  # Bulk free without RC updates
  for id in heap.bumpAllocator.buffer:
    if id < heap.objects.len and heap.objects[id] != nil:
      # Clear edges from EdgeBuffer
      heap.edgeBuffer.clearEdges(id)

      # Free the object
      heap.objects[id] = nil
      heap.freeList.add(id)
      inc heap.stats.freeCount

  heap.bumpAllocator.buffer.setLen(0)


proc allocBump*(heap: Heap, kind: HeapObjectKind): int =
  ## Allocate a temporary object using bump allocator (zero RC overhead)
  ## Must call clearBumpAllocator() at frame end to free these objects
  ## Returns object ID
  ##
  ## WARNING: Bump objects should NOT:
  ## - Be stored in globals or long-lived structures
  ## - Be referenced after frame end
  ## - Hold references to non-bump objects (will leak)
  if not heap.bumpAllocator.enabled:
    raise newException(ValueError, "Bump allocator not enabled")

  if heap.bumpAllocator.buffer.len >= heap.bumpAllocator.maxPerFrame:
    raise newException(ValueError, &"Bump allocator limit exceeded: {heap.bumpAllocator.maxPerFrame} objects per frame")

  let id = heap.allocId()

  # Create object with refcount=0 (no RC overhead)
  # Note: Bump-allocated objects should typically be Tables or Arrays
  # Scalars don't need heap allocation
  var obj: HeapObject
  case kind
  of hokScalar:
    obj = HeapObject(
      id: id,
      kind: kind,
      strongRefs: 0,
      marked: false,
      dirty: false,
      weakRefs: 0,
      destructorFuncIdx: -1,
      beingDestroyed: false
    )
  of hokTable:
    obj = HeapObject(
      id: id,
      kind: kind,
      strongRefs: 0,
      marked: false,
      dirty: false,
      weakRefs: 0,
      destructorFuncIdx: -1,
      beingDestroyed: false,
      fields: initTable[string, V](),
      fieldRefs: initHashSet[int](),
      fieldCache: initTable[string, V]()
    )
  of hokArray:
    obj = HeapObject(
      id: id,
      kind: kind,
      strongRefs: 0,
      marked: false,
      dirty: false,
      weakRefs: 0,
      destructorFuncIdx: -1,
      beingDestroyed: false,
      elements: @[],
      elementRefs: initHashSet[int]()
    )
  of hokRef:
    obj = HeapObject(
      id: id,
      kind: kind,
      strongRefs: 0,
      marked: false,
      dirty: false,
      weakRefs: 0,
      destructorFuncIdx: -1,
      beingDestroyed: false,
      refValue: makeNil(),
      refTargetId: 0
    )
  of hokClosure:
    raise newException(ValueError, "Bump allocator cannot allocate closures")
  of hokWeak:
    obj = HeapObject(
      id: id,
      kind: kind,
      strongRefs: 0,
      marked: false,
      dirty: false,
      weakRefs: 0,
      destructorFuncIdx: -1,
      beingDestroyed: false,
      targetId: 0
    )

  heap.objects[id] = obj
  heap.bumpAllocator.buffer.add(id)
  inc heap.stats.allocCount

  logHeap(heap.verbose, &"Bump allocated #{id} ({kind}) [{heap.bumpAllocator.buffer.len}/{heap.bumpAllocator.maxPerFrame}]")

  return id


# Frame budget-aware cycle detection
# Checks for cycles only if frame budget allows
proc maybeCheckCyclesWithBudget*(heap: Heap): seq[CycleInfo] =
  ## Check for cycles if frame budget allows
  ## Returns empty seq if budget is insufficient or no cycles found
  ## Automatically tracks time spent and updates gcWorkThisFrame

  # Check if we have budget (need at least 500us for cycle detection)
  if not heap.hasFrameBudgetRemaining(500):
    logHeap(heap.verbose, &"Skipping cycle check due to frame budget")
    return @[]

  # Capture dirty count before detection clears it
  heap.dirtyCheckedThisFrame += heap.dirtyObjects.len

  # Run cycle detection and measure time
  let beforeGC = getMonoTime()
  let cycles = heap.detectCycles()
  let gcTime = inMicroseconds(getMonoTime() - beforeGC)

  # Update frame budget tracking
  heap.gcWorkThisFrame += gcTime

  if cycles.len > 0:
    logHeap(heap.verbose, &"Cycle detection took {gcTime}us (total this frame: {heap.gcWorkThisFrame}us)")

  return cycles


# Adaptive cycle detection with profile-guided interval adjustment
# Adjusts check frequency based on allocation rate and cycle detection success
proc maybeCheckCycles*(heap: Heap): seq[CycleInfo] =
  inc heap.operationCount

  if heap.operationCount >= heap.cycleDetectionInterval:
    heap.operationCount = 0

    # Update allocation rate statistics
    let allocsSinceLastCheck = heap.stats.allocCount - heap.stats.lastCheckAllocs
    heap.stats.lastCheckAllocs = heap.stats.allocCount

    # Exponential moving average for allocation rate
    let alpha = 0.3  # Smoothing factor
    heap.stats.avgAllocRate = alpha * float(allocsSinceLastCheck) + (1.0 - alpha) * heap.stats.avgAllocRate

    # Run cycle detection (respects frame budget if set)
    let cyclesBefore = heap.stats.cyclesDetected

    # Capture dirty count before it gets cleared
    if heap.frameBudgetUs == 0:
      heap.dirtyCheckedThisFrame += heap.dirtyObjects.len

    let cycles = if heap.frameBudgetUs > 0: heap.maybeCheckCyclesWithBudget() else: heap.detectCycles()
    let cyclesFound = heap.stats.cyclesDetected - cyclesBefore

    # Adaptive interval adjustment based on results
    if cyclesFound > 0:
      # Found cycles: increase check frequency (decrease interval)
      heap.cycleDetectionInterval = max(heap.minCycleInterval, int(float(heap.cycleDetectionInterval) * 0.8))
      logHeap(heap.verbose, &"Found {cyclesFound} cycle(s), increasing check frequency (interval: {heap.cycleDetectionInterval})")
    else:
      # No cycles found: decrease check frequency (increase interval)
      # But only if dirty set was non-trivial
      if heap.dirtyObjects.len > 5:
        heap.cycleDetectionInterval = min(heap.maxCycleInterval, int(float(heap.cycleDetectionInterval) * 1.2))
        logHeap(heap.verbose, &"No cycles found, decreasing check frequency (interval: {heap.cycleDetectionInterval})")

    # Further adjust based on allocation rate
    if heap.stats.avgAllocRate > 100.0:
      # High allocation rate: check more frequently
      heap.cycleDetectionInterval = max(heap.minCycleInterval,
                                        int(float(heap.cycleDetectionInterval) * 0.9))

    return cycles

  return @[]


# Helper proc to run final cycle detection
proc runFinalCycleDetection*(vm: VirtualMachine) =
  let cycles = vm.heap.detectCycles(forceFull = true)  # Force full check at program exit
  if vm.heap.verbose and cycles.len > 0:
    for cycle in cycles:
      var info = ""
      for i in 0 ..< cycle.objectIds.len:
        if i > 0: info &= ", "
        info &= "#" & $cycle.objectIds[i] & " (" & $cycle.objectKinds[i] & ")"
      # TODO: Stderr ?
      echo "[HEAP] Cycle detected with ", cycle.totalSize, " objects: ", info


# Get heap statistics
proc getStats*(heap: Heap): string =
  let liveObjects = heap.objects.len

  result = &"""
Heap Statistics:
  Live objects: {liveObjects}
  Total allocations: {heap.stats.allocCount}
  Total frees: {heap.stats.freeCount}
  Cycles detected: {heap.stats.cyclesDetected}
  Cycle checks: {heap.stats.cycleCheckCount}
  Avg alloc rate: {heap.stats.avgAllocRate:.2f}
  Current cycle interval: {heap.cycleDetectionInterval}
  Dirty objects: {heap.dirtyObjects.len}
  Next ID: {heap.nextId}
  Free list size: {heap.freeList.len}
"""


# Periodic verification check (if enabled)
# Call this from critical operations to catch corruption early
proc maybeVerifyHeap*(heap: Heap) =
  if not heap.enableVerification:
    return

  # Check if enough operations have passed
  let opsSinceLastCheck = heap.stats.allocCount + heap.stats.freeCount - heap.lastVerificationOp
  if opsSinceLastCheck < heap.verificationInterval:
    return

  heap.lastVerificationOp = heap.stats.allocCount + heap.stats.freeCount

  # Run quick health check (fast)
  when not defined(release):
    # In debug mode, do quick check
    var criticalIssues = 0

    # Check 1: No negative ref counts
    for obj in heap.objects:
      if obj == nil: continue
      if obj.strongRefs < 0 or obj.weakRefs < 0:
        # TODO: Stderr ?
        echo &"[HEAP CORRUPTION] Object #{obj.id} has negative refcount!"
        inc criticalIssues

    # Check 2: Free list doesn't overlap
    for id in heap.freeList:
      if id < heap.objects.len and heap.objects[id] != nil:
        # TODO: Stderr ?
        echo &"[HEAP CORRUPTION] Object #{id} in free list but still live!"
        inc criticalIssues

    # Check 3: dirtyObjects all exist
    for id in heap.dirtyObjects:
      if id >= heap.objects.len or heap.objects[id] == nil:
        # TODO: Stderr ?
        echo &"[HEAP CORRUPTION] dirtyObjects references non-existent #{id}!"
        inc criticalIssues

    if criticalIssues > 0:
      # TODO: Stderr ?
      echo &"[HEAP CORRUPTION] Found {criticalIssues} critical issues!"
      echo "[HEAP] Heap state:"
      echo heap.getStats()
      # In severe cases, could call a panic or dump more diagnostics


# Format cycle information for reporting
proc formatCycle*(cycle: CycleInfo): string =
  result = &"Cycle detected with {cycle.totalSize} objects:\n"
  for i in 0 ..< cycle.objectIds.len:
    let id = cycle.objectIds[i]
    let kind = if i < cycle.objectKinds.len: $cycle.objectKinds[i] else: "unknown"
    result &= &"  - Object #{id} ({kind})\n"


# Mark objects reachable from a root value
proc markFromValue(heap: Heap, val: V, visited: var HashSet[int]) =
  if not val.isHeapObject:
    return

  let id = val.heapObjectId
  if id == 0 or id in visited:
    return

  if id >= heap.objects.len or heap.objects[id] == nil:
    return

  visited.incl(id)
  heap.objects[id].marked = true

  # Recursively mark children
  let obj = heap.objects[id]
  case obj.kind
  of hokScalar:
    discard
  of hokTable:
    for fieldVal in obj.fields.values:
      heap.markFromValue(fieldVal, visited)
  of hokArray:
    for elem in obj.elements:
      heap.markFromValue(elem, visited)
  of hokWeak:
    discard  # Weak refs don't keep objects alive
  of hokRef:
    heap.markFromValue(obj.refValue, visited)
  of hokClosure:
    for cap in obj.captures:
      heap.markFromValue(cap, visited)


# Collect and free unreachable cyclic objects
# This uses mark-and-sweep: mark reachable objects, then sweep unreachable ones in cycles
proc collectCycles*(heap: Heap, cycles: seq[CycleInfo], rootsCallback: proc(): seq[V]) =
  if cycles.len == 0:
    return

  logHeap(heap.verbose, &"Starting cycle collection for {cycles.len} detected cycle(s)")

  # Reset all marks
  for obj in heap.objects:
    if obj != nil:
      obj.marked = false

  # Mark phase: mark all objects reachable from roots
  var visited = initHashSet[int]()
  let roots = rootsCallback()

  logHeap(heap.verbose, &"Marking from {roots.len} root values")

  for rootVal in roots:
    heap.markFromValue(rootVal, visited)

  # Sweep phase: free unmarked objects that are in cycles
  var freedCount = 0
  var cycleIds = initHashSet[int]()

  # Collect all IDs in cycles
  for cycle in cycles:
    for id in cycle.objectIds:
      cycleIds.incl(id)

  # Free unmarked objects in cycles
  # Need to collect IDs first to avoid modifying table during iteration
  var toFree: seq[int] = @[]
  for id in cycleIds:
    if id < heap.objects.len and heap.objects[id] != nil and not heap.objects[id].marked:
      toFree.add(id)

  logHeap(heap.verbose, &"Found {toFree.len} unreachable objects in cycles to collect")

  # Free the unreachable cyclic objects
  # Important: Set their ref counts to 0 first to prevent cascading decrements
  for id in toFree:
    if id < heap.objects.len and heap.objects[id] != nil:
      heap.objects[id].strongRefs = 0

  for id in toFree:
    if id < heap.objects.len and heap.objects[id] != nil:
      heap.freeObject(id)
      inc freedCount

  logHeap(heap.verbose, &"Cycle collection freed {freedCount} objects")

  # Compact EdgeBuffer after freeing objects (NEW)
  if freedCount > 0:
    var liveObjects = initHashSet[int]()
    for id in 0 ..< heap.objects.len:
      if heap.objects[id] != nil:
        liveObjects.incl(id)
    heap.edgeBuffer.compactEdges(liveObjects)
    logHeap(heap.verbose, &"EdgeBuffer compacted: {heap.edgeBuffer.totalEdges} edges remaining")
