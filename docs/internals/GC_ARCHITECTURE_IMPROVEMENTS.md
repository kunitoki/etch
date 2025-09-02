# GC Architecture Improvements: Technical Design

## Overview

This document provides detailed technical designs for the proposed GC optimizations, including data structures, algorithms, and implementation strategies.

## 1. Global Edge Buffer Architecture

### Problem Statement

Current per-object HashSets create excessive overhead:
- Memory: 40+ bytes per HashSet (even if empty)
- CPU: Hash computation on every insert/delete
- Cache: Scattered allocations destroy spatial locality

### Solution: Structure of Arrays (SoA) Pattern

```nim
type
  EdgeType* = enum
    etField    # Object field reference
    etElement  # Array element reference

  EdgeEntry* = object
    sourceId*: int32     # Parent object ID
    targetId*: int32     # Child object ID
    fieldHash*: int16    # Hash of field name (for debugging)
    edgeType*: EdgeType  # Field vs array element
    padding: uint8       # Alignment padding
    # Total: 12 bytes per edge (vs 40+ bytes for HashSet entry)

  EdgeBuffer* = ref object
    # Primary storage: flat array of all edges in heap
    edges*: seq[EdgeEntry]

    # Sparse index: objectId -> range in edges array
    # Only allocated for objects that have outgoing references
    index*: Table[int, tuple[start: int, count: int]]

    # Dirty tracking: which objects had edge changes
    dirtyEdges*: HashSet[int]  # Object IDs with edge changes

    # Stats
    totalEdges*: int
    maxEdges*: int

  Heap* = ref object
    # ... existing fields ...
    edgeBuffer*: EdgeBuffer  # NEW: Global edge storage
```

### Operations

#### Add Edge (Hot Path)
```nim
proc addEdge*(buf: EdgeBuffer, parentId: int, childId: int, fieldHash: int16 = 0) {.inline.} =
  # Fast path: just append to edges array
  buf.edges.add(EdgeEntry(
    sourceId: int32(parentId),
    targetId: int32(childId),
    fieldHash: fieldHash,
    edgeType: etField
  ))
  buf.dirtyEdges.incl(parentId)
  inc buf.totalEdges

  # Update index (lazy, batched during GC)
  if buf.index.hasKey(parentId):
    var entry = buf.index[parentId]
    entry.count += 1
    buf.index[parentId] = entry
  else:
    # First edge for this object
    buf.index[parentId] = (start: buf.edges.len - 1, count: 1)
```

#### Query Edges (GC Path)
```nim
iterator outgoingEdges*(buf: EdgeBuffer, objectId: int): int =
  # Yields target IDs of all outgoing edges from objectId
  if buf.index.hasKey(objectId):
    let entry = buf.index[objectId]
    for i in entry.start ..< entry.start + entry.count:
      if i < buf.edges.len:
        yield int(buf.edges[i].targetId)
```

#### Compact Buffer (GC Maintenance)
```nim
proc compactEdges*(buf: EdgeBuffer, liveObjects: HashSet[int]) =
  # Remove edges from freed objects
  var writeIdx = 0
  var newIndex = initTable[int, tuple[start: int, count: int]]()

  for readIdx in 0 ..< buf.edges.len:
    let edge = buf.edges[readIdx]

    # Keep edge if both source and target are live
    if edge.sourceId in liveObjects and edge.targetId in liveObjects:
      buf.edges[writeIdx] = edge
      inc writeIdx

      # Update index
      if not newIndex.hasKey(edge.sourceId):
        newIndex[edge.sourceId] = (start: writeIdx - 1, count: 1)
      else:
        var entry = newIndex[edge.sourceId]
        entry.count += 1
        newIndex[edge.sourceId] = entry

  # Shrink edges array
  buf.edges.setLen(writeIdx)
  buf.index = newIndex
  buf.totalEdges = writeIdx
```

### Performance Analysis

| Operation | Old (HashSet) | New (EdgeBuffer) | Speedup |
|-----------|---------------|------------------|---------|
| Add edge | ~100ns | ~10ns | 10x |
| Query edges | ~50ns/edge | ~5ns/edge | 10x |
| Memory overhead | 40+ bytes/edge | 12 bytes/edge | 3.3x |
| Cache misses | High (scattered) | Low (sequential) | ~5x |

## 2. Write Barrier Design

### Tri-Color Marking Abstraction

```nim
type
  ObjectColor* = enum
    ocWhite   # Not yet scanned
    ocGray    # Scanned but children not processed
    ocBlack   # Fully processed

  WriteBarrierMode* = enum
    wbmDisabled  # Normal execution (fast path)
    wbmEnabled   # During incremental GC (slow path)

  Heap* = ref object
    # ... existing fields ...
    writeBarrierMode*: WriteBarrierMode
    rememberedSet*: HashSet[int]  # Objects mutated during GC
    objectColors*: Table[int, ObjectColor]
```

### Write Barrier Implementation

```nim
proc writeBarrier*(heap: Heap, parentId: int, oldChildId: int, newChildId: int) {.inline.} =
  # Fast path: barrier disabled during normal execution
  if heap.writeBarrierMode == wbmDisabled:
    return

  # Slow path: barrier enabled during incremental GC
  # This is Dijkstra's write barrier (conservative but simple)
  if heap.objectColors.getOrDefault(parentId, ocWhite) == ocBlack:
    if heap.objectColors.getOrDefault(newChildId, ocWhite) == ocWhite:
      # Black object gained white child - need to rescan parent
      heap.rememberedSet.incl(parentId)
      heap.objectColors[parentId] = ocGray  # Demote to gray
```

### Integration with Reference Assignment

Current code (regvm_heap.nim:238):
```nim
proc trackRef*(heap: Heap, parentId: int, childValue: V) =
  # ... existing code ...
  parent.fieldRefs.incl(childId)  # OLD: per-object HashSet
```

New code:
```nim
proc trackRef*(heap: Heap, parentId: int, oldChild: V, newChild: V) =
  # Extract IDs
  let oldId = if oldChild.kind == vkRef: oldChild.refId else: 0
  let newId = if newChild.kind == vkRef: newChild.refId else: 0

  # Write barrier (fast path: single branch + return)
  heap.writeBarrier(parentId, oldId, newId)

  # Update edge buffer (always, but cheaper than HashSet)
  if newId != 0:
    heap.edgeBuffer.addEdge(parentId, newId)
```

## 3. Incremental Cycle Detection

### Problem with Tarjan's Algorithm

Tarjan's SCC is difficult to incrementalize because:
- Requires complete DFS traversal
- State (indices, lowlinks, stack) is global
- Cannot pause mid-traversal safely

### Solution: Incremental DFS with Cycle Suspects

```nim
type
  IncrementalGCState* = object
    phase*: GCPhase
    workQueue*: seq[int]       # Objects to process
    processedIndex*: int       # Current position in queue
    suspects*: seq[int]        # Cycle suspect objects
    cyclesFound*: int

  GCPhase* = enum
    gcIdle        # Not running
    gcSuspect     # Finding cycle suspects
    gcVerify      # Verifying suspects are cycles
    gcCollect     # Collecting unreachable cycles

proc findCycleSuspects*(heap: Heap, maxObjects: int): seq[int] =
  # A "suspect" is an object where outgoing ref count > strong refs
  # This indicates the object might be in a cycle
  result = @[]
  var checked = 0

  for id, obj in heap.objects.pairs:
    if checked >= maxObjects:
      break

    # Count outgoing references
    var outgoingCount = 0
    for _ in heap.edgeBuffer.outgoingEdges(id):
      inc outgoingCount

    # Suspect if outgoing > strong refs
    if outgoingCount > 0 and obj.strongRefs > 0:
      let suspicion = float(outgoingCount) / float(obj.strongRefs)
      if suspicion >= 0.8:  # Heuristic threshold
        result.add(id)

    inc checked

proc incrementalGCStep*(heap: Heap, budgetUs: int64): bool =
  let startTime = getMonoTime()
  var workDone = false

  while inMicroseconds(getMonoTime() - startTime) < budgetUs:
    case heap.incrementalState.phase
    of gcIdle:
      if heap.dirtyObjects.len > 10:
        heap.incrementalState.phase = gcSuspect
        heap.incrementalState.workQueue = @[]
        heap.incrementalState.processedIndex = 0
      else:
        return false

    of gcSuspect:
      # Find cycle suspects incrementally
      let batch = heap.findCycleSuspects(maxObjects = 100)
      heap.incrementalState.suspects.add(batch)
      heap.incrementalState.phase = gcVerify
      workDone = true

    of gcVerify:
      # Verify suspects using simple DFS (not Tarjan's)
      # This is O(cycle_size) not O(heap_size)
      if heap.incrementalState.processedIndex < heap.incrementalState.suspects.len:
        let suspectId = heap.incrementalState.suspects[heap.incrementalState.processedIndex]
        if heap.verifyCycle(suspectId):
          # Found a cycle, collect it
          heap.trialDeleteCycle(suspectId)
        inc heap.incrementalState.processedIndex
        workDone = true
      else:
        heap.incrementalState.phase = gcCollect

    of gcCollect:
      # Finalize collection
      heap.dirtyObjects.clear()
      heap.incrementalState.phase = gcIdle
      return true  # Collection cycle complete

  return workDone
```

### Trial Deletion Algorithm

```nim
proc trialDeleteCycle*(heap: Heap, suspectId: int): bool =
  # Try to delete suspect and see if cycle is isolated
  # Returns true if cycle was successfully collected

  var cycle: seq[int] = @[]
  var visited = initHashSet[int]()

  proc findCycleMembers(id: int) =
    if id in visited or not heap.objects.hasKey(id):
      return
    visited.incl(id)
    cycle.add(id)

    # Follow outgoing edges
    for childId in heap.edgeBuffer.outgoingEdges(id):
      findCycleMembers(childId)

  # Find all members of the cycle
  findCycleMembers(suspectId)

  # Check if cycle is isolated (no external refs)
  var externalRefs = 0
  for id in cycle:
    let obj = heap.objects[id]
    # Count refs from outside the cycle
    for parentId, parentObj in heap.objects.pairs:
      if parentId notin cycle:
        for childId in heap.edgeBuffer.outgoingEdges(parentId):
          if childId == id:
            inc externalRefs

  if externalRefs == 0:
    # Isolated cycle - safe to collect
    for id in cycle:
      heap.freeObject(id)
    return true

  return false
```

## 4. Ref-Specific Store Opcodes

### Problem Statement

Current store operations (opSetField, opSetIndex) don't properly handle RC atomicity:
```nim
# Current (UNSAFE for refs)
opSetField:
  obj.field = newValue  # What about old value's DecRef?
```

### Solution: Atomic Store Opcodes

```nim
type
  RegOpCode = enum
    # ... existing opcodes ...

    # NEW: Atomic store operations for references
    opStoreFieldRef,    # R[A].field = R[B] (atomic: DecRef old, IncRef new, assign)
    opStoreArrayRef,    # R[A][C] = R[B] (atomic: DecRef old, IncRef new, assign)
    opStoreFieldImm,    # R[A].field = imm (no RC, for value types)
    opStoreArrayImm,    # R[A][C] = imm (no RC, for value types)

proc execStoreFieldRef*(vm: RegisterVM, instr: RegInstruction, verbose: bool) =
  # Atomic reference field assignment
  let objVal = getReg(vm, instr.a)
  let newVal = getReg(vm, instr.b)
  let fieldName = vm.constants[instr.c].sval  # Field name from constant pool

  if objVal.kind != vkRef:
    runtimeError("StoreFieldRef: not a reference")

  if vm.heap == nil:
    runtimeError("StoreFieldRef: heap not initialized")

  let heap = cast[Heap](vm.heap)
  let obj = heap.getObject(objVal.refId)

  if obj.kind != hokTable:
    runtimeError("StoreFieldRef: not a table object")

  # Get old value
  let oldVal = obj.fields.getOrDefault(fieldName, makeNil())

  # ATOMIC OPERATION:
  # 1. DecRef old value (if ref)
  if oldVal.kind == vkRef:
    heap.decRef(oldVal.refId)

  # 2. IncRef new value (if ref)
  if newVal.kind == vkRef:
    heap.incRef(newVal.refId)

  # 3. Update field
  obj.fields[fieldName] = newVal

  # 4. Track reference (for cycle detection)
  heap.trackRef(objVal.refId, oldVal, newVal)
```

### Compiler Integration

Update the compiler to emit specialized opcodes:

```nim
# In compile_statement/assign_statement.nim
proc compileFieldAssignment(ctx: CompilerContext, target: AstNode, value: AstNode) =
  # ... compile target and value ...

  # Choose opcode based on value type
  if ctx.typeOf(value).isReference():
    emit(opStoreFieldRef, targetReg, valueReg, fieldNameConst)
  else:
    emit(opStoreFieldImm, targetReg, valueReg, fieldNameConst)
```

## 5. Frame Budget API Integration

### Engine Integration Pattern

```nim
# Example C integration
#include "etch.h"

void game_frame() {
    // Frame start: set GC budget
    etch_vm_begin_frame(vm, 2000);  // 2ms budget

    // Run game logic (may trigger incremental GC)
    etch_vm_execute(vm, "update_frame");

    // Check if next frame should be skipped for GC
    if (etch_vm_needs_gc_frame(vm)) {
        // Skip rendering, let GC catch up
        etch_vm_execute_gc(vm, 16000);  // Full frame for GC
    }

    // Frame end: get GC stats
    int cycles_collected = etch_heap_get_cycles_collected(vm);
    printf("Cycles collected this frame: %d\n", cycles_collected);
}
```

### Nim VM API

```nim
proc beginFrame*(vm: RegisterVM, budgetUs: int64) =
  if vm.heap != nil:
    let heap = cast[Heap](vm.heap)
    heap.cycleDetectionBudgetUs = budgetUs
    heap.frameStartTime = getMonoTime()

proc executeWithGCBudget*(vm: RegisterVM) =
  while not vm.halted:
    # Execute a few instructions
    for i in 0..<100:
      vm.step()

    # Check GC budget
    if vm.heap != nil:
      let heap = cast[Heap](vm.heap)
      let elapsed = inMicroseconds(getMonoTime() - heap.frameStartTime)
      let remaining = heap.cycleDetectionBudgetUs - elapsed

      if remaining > 0:
        # Run incremental GC
        discard heap.incrementalGCStep(remaining)
      else:
        # Budget exhausted, continue next frame
        break

proc needsGCFrame*(vm: RegisterVM): bool =
  if vm.heap != nil:
    let heap = cast[Heap](vm.heap)
    # Heuristic: need full GC if many dirty objects
    return heap.dirtyObjects.len > 1000 or heap.incrementalState.phase != gcIdle
  return false
```

## 6. Memory Layout Optimization

### Cache Line Analysis

Current layout wastes space:
```nim
# Current: ~150 bytes per object
HeapObject = ref object
  id: int                      # 8 bytes
  strongRefs: int              # 8 bytes
  weakRefs: int                # 8 bytes
  kind: HeapObjectKind         # 4 bytes (enum)
  marked: bool                 # 1 byte
  dirty: bool                  # 1 byte
  beingDestroyed: bool         # 1 byte
  destructorFuncIdx: int       # 8 bytes
  # Padding to 40 bytes (first cache line)
  # But then adds:
  fieldRefs: HashSet[int]      # 40+ bytes
  elementRefs: HashSet[int]    # 40+ bytes
  # Total: ~150 bytes
```

Optimized layout:
```nim
# New: ~64 bytes per object (without refs)
HeapObject = ref object
  # First cache line (64 bytes) - HOT fields
  id: int32                    # 4 bytes
  strongRefs: int32            # 4 bytes
  weakRefs: int32              # 4 bytes
  kind: HeapObjectKind         # 1 byte
  marked: bool                 # 1 byte
  dirty: bool                  # 1 byte
  beingDestroyed: bool         # 1 byte
  destructorFuncIdx: int16     # 2 bytes
  # 18 bytes used, 46 bytes padding = 64 byte cache line

  # Second cache line - COLD fields
  case kindDiscriminator: HeapObjectKind
  of hokTable:
    fields: Table[string, V]
  of hokArray:
    elements: seq[V]
  of hokScalar:
    value: V
  of hokWeak:
    targetId: int32
    targetType: string
```

Benefits:
- Hot fields fit in single cache line
- No HashSets for objects without refs (use global EdgeBuffer)
- 2.5x memory reduction per object

## 7. Testing Infrastructure

### Heap Verification

```nim
proc verifyHeapIntegrity*(heap: Heap): seq[string] =
  result = @[]

  # Check 1: No negative ref counts
  for id, obj in heap.objects.pairs:
    if obj.strongRefs < 0:
      result.add(&"Object #{id} has negative strongRefs: {obj.strongRefs}")
    if obj.weakRefs < 0:
      result.add(&"Object #{id} has negative weakRefs: {obj.weakRefs}")

  # Check 2: Edge buffer consistency
  for edge in heap.edgeBuffer.edges:
    if not heap.objects.hasKey(edge.sourceId):
      result.add(&"Edge source #{edge.sourceId} doesn't exist")
    if not heap.objects.hasKey(edge.targetId):
      result.add(&"Edge target #{edge.targetId} doesn't exist")

  # Check 3: Ref count consistency
  var actualRefCounts = initTable[int, int]()
  for edge in heap.edgeBuffer.edges:
    actualRefCounts[edge.targetId] = actualRefCounts.getOrDefault(edge.targetId, 0) + 1

  for id, count in actualRefCounts.pairs:
    if heap.objects.hasKey(id):
      let obj = heap.objects[id]
      # Note: strongRefs includes stack/global refs, so might be > edge count
      if count > obj.strongRefs:
        result.add(&"Object #{id} has more incoming edges ({count}) than strongRefs ({obj.strongRefs})")

  # Check 4: No cycles with external refs
  # (cycles should only exist if isolated)
```

### Performance Profiling

```nim
type
  GCProfileData* = object
    frameNumber*: int
    dirtyObjects*: int
    edgeBufferSize*: int
    cyclesDetected*: int
    gcTimeUs*: int64
    totalFrameTimeUs*: int64

proc profileGCFrame*(heap: Heap): GCProfileData =
  result.dirtyObjects = heap.dirtyObjects.len
  result.edgeBufferSize = heap.edgeBuffer.totalEdges
  result.cyclesDetected = heap.stats.cyclesDetected
  # ... gather more stats ...

proc dumpGCProfile*(profiles: seq[GCProfileData]) =
  echo "Frame,Dirty,Edges,Cycles,GC Time (us),Frame Time (us)"
  for p in profiles:
    echo &"{p.frameNumber},{p.dirtyObjects},{p.edgeBufferSize},{p.cyclesDetected},{p.gcTimeUs},{p.totalFrameTimeUs}"
```

## Implementation Checklist

- [ ] Implement EdgeBuffer data structure
- [ ] Replace HashSet edge tracking with EdgeBuffer
- [ ] Add write barrier infrastructure
- [ ] Implement incremental GC state machine
- [ ] Add ref-specific store opcodes
- [ ] Integrate frame budget API
- [ ] Optimize HeapObject memory layout
- [ ] Add heap verification checks
- [ ] Create GC stress tests
- [ ] Benchmark and profile
- [ ] Document performance characteristics

## References

1. **Dijkstra's Write Barrier**: "On-the-Fly Garbage Collection: An Exercise in Cooperation" (1978)
2. **Incremental GC**: Lua's incremental collector design
3. **Cache-Friendly Data Structures**: "Data-Oriented Design" by Richard Fabian
4. **Game Engine GC**: "Real-Time Garbage Collection for C++" (Bartlett)

---

**Document Version**: 1.0
**Last Updated**: 2025-11-08
**Status**: Technical Design - Ready for Implementation
