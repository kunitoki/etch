# regvm_heap.nim
# Explicit heap management with reference counting and cycle detection

import std/[tables, sets, strformat]
import regvm

# We need to call invokeDestructor from regvm_exec.nim, but can't import it directly
# due to circular dependencies. We'll work around this by having freeObject
# dynamically call through the vm pointer which knows about RegisterVM

type
  HeapObjectKind* = enum
    hokScalar,   # Scalar value (int, float, bool, string, char)
    hokTable,    # Object/table
    hokArray,    # Array
    hokWeak      # Weak reference wrapper

  HeapObject* = ref object
    id*: int                           # Unique object ID
    strongRefs*: int                   # Strong reference count
    weakRefs*: int                     # Weak reference count
    marked*: bool                      # For cycle detection mark phase
    destructorFuncIdx*: int            # Function index for destructor (-1 if none)
    beingDestroyed*: bool              # Re-entrancy protection flag
    case kind*: HeapObjectKind
    of hokScalar:
      value*: V                        # Scalar value
    of hokTable:
      fields*: Table[string, V]        # Object fields
      fieldRefs*: HashSet[int]         # IDs of objects referenced by fields
    of hokArray:
      elements*: seq[V]                # Array elements
      elementRefs*: HashSet[int]       # IDs of objects referenced by elements
    of hokWeak:
      targetId*: int                   # ID of target object (-1 if freed)
      targetType*: string              # Type name for debugging

  # Destructor callback type - called when an object with a destructor is freed
  DestructorCallback* = proc(vm: pointer, funcIdx: int, objId: int) {.closure.}

  Heap* = ref object
    objects*: Table[int, HeapObject]   # ID -> object mapping
    nextId*: int                       # Next available object ID
    freeList*: seq[int]                # Recycled IDs
    cycleDetectionInterval*: int       # Cycles between cycle checks
    operationCount*: int               # Operations since last cycle check
    verbose*: bool                     # Enable verbose logging
    vm*: pointer                       # VM reference for destructor calls
    callDestructor*: DestructorCallback  # Callback to invoke destructor

    # Statistics
    allocCount*: int
    freeCount*: int
    cyclesDetected*: int
    cycleCheckCount*: int

  CycleInfo* = object
    objectIds*: seq[int]
    objectKinds*: seq[HeapObjectKind]
    totalSize*: int

# Create a new heap
proc newHeap*(verbose: bool = false, cycleInterval: int = 1000): Heap =
  result = Heap(
    objects: initTable[int, HeapObject](),
    nextId: 1,  # Start from 1, 0 reserved for nil
    freeList: @[],
    cycleDetectionInterval: cycleInterval,
    operationCount: 0,
    verbose: verbose,
    vm: nil,  # Will be set during VM initialization
    callDestructor: nil,  # Will be set during VM initialization
    allocCount: 0,
    freeCount: 0,
    cyclesDetected: 0,
    cycleCheckCount: 0
  )

# Allocate a new object ID
proc allocId*(heap: Heap): int =
  if heap.freeList.len > 0:
    result = heap.freeList.pop()
  else:
    result = heap.nextId
    inc heap.nextId

# Allocate a new table object
proc allocTable*(heap: Heap, destructorFuncIdx: int = -1): int =
  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokTable,
    strongRefs: 1,  # Start with 1 reference
    weakRefs: 0,
    marked: false,
    destructorFuncIdx: destructorFuncIdx,
    beingDestroyed: false,
    fields: initTable[string, V](),
    fieldRefs: initHashSet[int]()
  )
  inc heap.allocCount
  if heap.verbose:
    let dtorInfo = if destructorFuncIdx >= 0: &" destructor=func#{destructorFuncIdx}" else: ""
    echo &"[HEAP] Allocated table object #{id} (strong refs: 1{dtorInfo})"
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
    destructorFuncIdx: -1,  # Arrays don't have destructors
    beingDestroyed: false,
    elements: newSeq[V](size),
    elementRefs: initHashSet[int]()
  )
  inc heap.allocCount
  if heap.verbose:
    echo &"[HEAP] Allocated array object #{id} size={size} (strong refs: 1)"
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
    destructorFuncIdx: -1,  # Scalars don't have destructors
    beingDestroyed: false,
    value: val
  )
  inc heap.allocCount
  if heap.verbose:
    echo &"[HEAP] Allocated scalar object #{id} (strong refs: 1)"
  return id

# Allocate a weak reference
proc allocWeak*(heap: Heap, targetId: int, targetType: string): int =
  if targetId == 0:
    # Weak reference to nil
    return 0

  if not heap.objects.hasKey(targetId):
    if heap.verbose:
      echo &"[HEAP] Warning: Creating weak ref to non-existent object #{targetId}"
    return 0

  let id = heap.allocId()
  heap.objects[id] = HeapObject(
    id: id,
    kind: hokWeak,
    strongRefs: 1,  # Weak ref itself has strong refs
    weakRefs: 0,
    marked: false,
    destructorFuncIdx: -1,  # Weak refs don't have destructors
    beingDestroyed: false,
    targetId: targetId,
    targetType: targetType
  )

  # Increment weak count on target
  inc heap.objects[targetId].weakRefs

  inc heap.allocCount
  if heap.verbose:
    echo &"[HEAP] Allocated weak ref #{id} -> #{targetId} (target weak refs: {heap.objects[targetId].weakRefs})"
  return id

# Get object by ID
proc getObject*(heap: Heap, id: int): HeapObject =
  if id == 0 or not heap.objects.hasKey(id):
    return nil
  return heap.objects[id]

# Increment strong reference count
proc incRef*(heap: Heap, id: int) =
  if id == 0:  # nil reference
    return

  if not heap.objects.hasKey(id):
    if heap.verbose:
      echo &"[HEAP] Warning: Attempting to incRef non-existent object #{id}"
    return

  inc heap.objects[id].strongRefs
  if heap.verbose:
    echo &"[HEAP] IncRef #{id} (strong refs: {heap.objects[id].strongRefs})"

# Track reference from parent to child (for cycle detection)
proc trackRef*(heap: Heap, parentId: int, childValue: V) =
  if parentId == 0:
    return

  # Only track references to heap objects
  if childValue.kind != vkRef:
    return

  let childId = childValue.refId

  if not heap.objects.hasKey(parentId):
    return

  let parent = heap.objects[parentId]
  case parent.kind
  of hokScalar:
    # Scalars don't have references to other objects
    discard
  of hokTable:
    parent.fieldRefs.incl(childId)
    if heap.verbose:
      echo &"[HEAP] Tracking reference: object #{parentId} -> object #{childId}"
  of hokArray:
    parent.elementRefs.incl(childId)
  of hokWeak:
    discard

# Nullify all weak references to an object
proc nullifyWeakRefs*(heap: Heap, targetId: int) =
  # Find all weak references pointing to this target
  for weakId, obj in heap.objects.pairs:
    if obj.kind == hokWeak and obj.targetId == targetId:
      obj.targetId = -1  # Mark as freed
      if heap.verbose:
        echo &"[HEAP] Nullified weak ref #{weakId} (was pointing to #{targetId})"

# Forward declaration for mutual recursion
proc decRef*(heap: Heap, id: int)

# Free an object (called when strong refs reach 0)
proc freeObject*(heap: Heap, id: int) =
  if id == 0 or not heap.objects.hasKey(id):
    return

  let obj = heap.objects[id]
  if heap.verbose:
    echo &"[HEAP] Freeing object #{id} kind={obj.kind} (weak refs: {obj.weakRefs})"

  # Call destructor BEFORE freeing children (if object has one and not already being destroyed)
  if obj.destructorFuncIdx >= 0 and not obj.beingDestroyed:
    if heap.callDestructor != nil and heap.vm != nil:
      # Set flag to prevent re-entrancy
      obj.beingDestroyed = true
      if heap.verbose:
        echo &"[HEAP] Calling destructor for object #{id} (funcIdx={obj.destructorFuncIdx})"
      # Call destructor through callback
      heap.callDestructor(heap.vm, obj.destructorFuncIdx, id)
      if heap.verbose:
        echo &"[HEAP] Destructor completed for object #{id}"

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
      if fieldVal.kind == vkRef:
        # Recursively decrement ref count for child refs
        heap.decRef(fieldVal.refId)
        if heap.verbose:
          echo &"[HEAP] Recursively decRef'd child ref #{fieldVal.refId} from freed object #{id}"
  of hokArray:
    for elem in obj.elements:
      if elem.kind == vkRef:
        # Recursively decrement ref count for child refs
        heap.decRef(elem.refId)
        if heap.verbose:
          echo &"[HEAP] Recursively decRef'd child ref #{elem.refId} from freed object #{id}"
  of hokWeak:
    # Decrement weak count on target if still alive
    if obj.targetId > 0 and heap.objects.hasKey(obj.targetId):
      dec heap.objects[obj.targetId].weakRefs

  # Remove from objects table
  heap.objects.del(id)
  heap.freeList.add(id)
  inc heap.freeCount

# Decrement strong reference count
proc decRef*(heap: Heap, id: int) =
  if id == 0:  # nil reference
    return

  if not heap.objects.hasKey(id):
    if heap.verbose:
      echo &"[HEAP] Warning: Attempting to decRef non-existent object #{id}"
    return

  var obj = heap.objects[id]
  dec obj.strongRefs

  if heap.verbose:
    echo &"[HEAP] DecRef #{id} (strong refs: {obj.strongRefs})"

  if obj.strongRefs <= 0:
    # Free the object
    heap.freeObject(id)

# Promote weak reference to strong reference (returns 0 if target freed)
proc weakToStrong*(heap: Heap, weakId: int): int =
  if weakId == 0:
    return 0

  if not heap.objects.hasKey(weakId):
    return 0

  let weakObj = heap.objects[weakId]
  if weakObj.kind != hokWeak:
    if heap.verbose:
      echo &"[HEAP] Warning: weakToStrong called on non-weak object #{weakId}"
    return 0

  if weakObj.targetId <= 0 or not heap.objects.hasKey(weakObj.targetId):
    # Target was freed
    return 0

  # Target still alive, increment its strong ref count
  heap.incRef(weakObj.targetId)
  return weakObj.targetId

# Cycle detection using DFS-based strongly connected components
proc detectCycles*(heap: Heap): seq[CycleInfo] =
  result = @[]
  inc heap.cycleCheckCount

  if heap.verbose:
    echo &"[HEAP] Running cycle detection (check #{heap.cycleCheckCount})"

  # Reset marks
  for obj in heap.objects.mvalues:
    obj.marked = false

  # Tarjan's algorithm for strongly connected components
  var
    index = 0
    stack: seq[int] = @[]
    indices = initTable[int, int]()
    lowlinks = initTable[int, int]()
    onStack = initHashSet[int]()
    cycles: seq[CycleInfo] = @[]

  proc strongConnect(v: int, cyclesOut: var seq[CycleInfo]) =
    indices[v] = index
    lowlinks[v] = index
    inc index
    stack.add(v)
    onStack.incl(v)

    if not heap.objects.hasKey(v):
      return

    let obj = heap.objects[v]
    var children: HashSet[int]

    case obj.kind
    of hokScalar:
      # Scalars don't have references
      children = initHashSet[int]()
    of hokTable:
      children = obj.fieldRefs
    of hokArray:
      children = obj.elementRefs
    of hokWeak:
      # Weak refs don't participate in cycles
      children = initHashSet[int]()

    for w in children:
      if not indices.hasKey(w):
        strongConnect(w, cyclesOut)
        lowlinks[v] = min(lowlinks[v], lowlinks[w])
      elif w in onStack:
        lowlinks[v] = min(lowlinks[v], indices[w])

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
      if component.len > 1 or (component.len == 1 and v in children):
        var cycleInfo = CycleInfo(
          objectIds: component,
          objectKinds: @[],
          totalSize: component.len
        )
        for id in component:
          if heap.objects.hasKey(id):
            cycleInfo.objectKinds.add(heap.objects[id].kind)
        cyclesOut.add(cycleInfo)
        inc heap.cyclesDetected

  # Run SCC detection on all objects
  for id in heap.objects.keys:
    if not indices.hasKey(id):
      strongConnect(id, cycles)

  result = cycles

# Check for cycles if enough operations have passed
proc maybeCheckCycles*(heap: Heap): seq[CycleInfo] =
  inc heap.operationCount

  if heap.operationCount >= heap.cycleDetectionInterval:
    heap.operationCount = 0
    return heap.detectCycles()

  return @[]

# Get heap statistics
proc getStats*(heap: Heap): string =
  let liveObjects = heap.objects.len
  let totalAllocs = heap.allocCount
  let totalFrees = heap.freeCount

  result = &"""
Heap Statistics:
  Live objects: {liveObjects}
  Total allocations: {totalAllocs}
  Total frees: {totalFrees}
  Cycles detected: {heap.cyclesDetected}
  Cycle checks: {heap.cycleCheckCount}
  Next ID: {heap.nextId}
  Free list size: {heap.freeList.len}
"""

# Format cycle information for reporting
proc formatCycle*(cycle: CycleInfo): string =
  result = &"Cycle detected with {cycle.totalSize} objects:\n"
  for i in 0 ..< cycle.objectIds.len:
    let id = cycle.objectIds[i]
    let kind = if i < cycle.objectKinds.len: $cycle.objectKinds[i] else: "unknown"
    result &= &"  - Object #{id} ({kind})\n"
