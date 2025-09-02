# Etch GC Optimization Plan: Revised for Game Engines

## Executive Summary

This document outlines the **remaining optimizations** needed for Etch's reference counting and cycle detection system to meet game engine requirements.

**Status**: Heap implementation has already received significant optimization (see `HEAP_OPTIMIZATIONS.md`). This plan focuses on the remaining game-engine-specific enhancements.

**Key Achievement**: Already 20-50% faster with all 352 tests passing ✅

**Remaining Work**: 2-3 weeks for game engine frame budgeting and edge tracking optimization

---

## ✅ Already Completed (from HEAP_OPTIMIZATIONS.md)

### Performance Improvements Achieved
- ✅ **+30% allocation rate** (1000 → 1300 ops/sec)
- ✅ **-70% cycle detection overhead** (50ms → 15ms per check)
- ✅ **-33% incRef/decRef latency** (15ns → 10ns per operation)
- ✅ **-25% memory per object** (128 → 96 bytes)
- ✅ **-37% cache miss rate** (35% → 22%)

### Features Implemented
1. **Critical Path Optimization**
   - Inlined incRef/decRef (15-20% faster)
   - Field lookup caching (5-10% improvement)
   - Optimized memory layout (hot fields in first cache line)

2. **Cycle Detection Tuning**
   - Adaptive interval adjustment (30-50% overhead reduction)
   - Incremental SCC - only scans dirty objects (40-60% faster)
   - Early termination optimizations (20-30% overhead reduction)

3. **Production Reliability**
   - Comprehensive heap verification system
   - Periodic health checks (debug mode)
   - Automatic corruption recovery

---

## 🎯 Remaining Priorities for Game Engines

### Priority Matrix

| Feature | Priority | Impact | Effort | Blocking |
|---------|----------|--------|--------|----------|
| Frame Budget API | HIGH | Deterministic timing | 3 days | No |
| Global Edge Buffer | HIGH | 5-10x edge tracking | 4 days | No |
| Weak Ref Fix | MEDIUM | Correctness | 1 day | No |
| Time-Sliced GC | LOW | Very large heaps | 3 days | Frame Budget API |
| Bump Allocator | LOW | Temp allocations | 2 days | No |
| Visual Debugging | LOW | Developer tools | 1 day | No |

---

## Revised Implementation Plan

### Phase 1: Frame Budget Integration (Week 1 - 4 days)

#### 1.1 Frame-Budgeted Collection API ⭐ HIGHEST PRIORITY
**Goal**: Allow game engines to control GC time budget per frame

**Files**:
- `src/etch/interpreter/regvm_heap.nim`
- `src/etch/interpreter/regvm.nim`
- `src/etch/capi.nim`

**Implementation**:

```nim
# New heap fields
type Heap = ref object
  # ... existing fields ...
  frameBudgetUs*: int64          # Time budget for this frame
  frameStartTime*: MonoTime      # When frame started
  gcWorkThisFrame*: int64        # Microseconds spent on GC this frame

# VM API (Nim)
proc beginFrame*(vm: RegisterVM, budgetUs: int64) =
  if vm.heap != nil:
    let heap = cast[Heap](vm.heap)
    heap.frameBudgetUs = budgetUs
    heap.frameStartTime = getMonoTime()
    heap.gcWorkThisFrame = 0

proc maybeCheckCyclesWithBudget*(heap: Heap): seq[CycleInfo] =
  # Check if we have budget left this frame
  let elapsed = inMicroseconds(getMonoTime() - heap.frameStartTime)
  let remaining = heap.frameBudgetUs - elapsed - heap.gcWorkThisFrame

  if remaining < 500:  # Need at least 500us
    return @[]  # Skip GC this frame

  let beforeGC = getMonoTime()
  let cycles = heap.detectCycles()
  let gcTime = inMicroseconds(getMonoTime() - beforeGC)
  heap.gcWorkThisFrame += gcTime

  return cycles

proc needsGCFrame*(vm: RegisterVM): bool =
  # Returns true if GC is backed up and needs a full frame
  if vm.heap != nil:
    let heap = cast[Heap](vm.heap)
    return heap.dirtyObjects.len > 1000  # Heuristic
  return false

# C API (for game engines)
proc etch_vm_begin_frame*(vm: VM, budgetUs: int64) {.exportc, cdecl.} =
  let regVm = cast[RegisterVM](vm)
  regVm.beginFrame(budgetUs)

proc etch_vm_needs_gc_frame*(vm: VM): bool {.exportc, cdecl.} =
  let regVm = cast[RegisterVM](vm)
  return regVm.needsGCFrame()

proc etch_vm_get_gc_stats*(vm: VM): GCFrameStats {.exportc, cdecl.} =
  let regVm = cast[RegisterVM](vm)
  if regVm.heap != nil:
    let heap = cast[Heap](regVm.heap)
    return GCFrameStats(
      gcTimeThisFrameUs: heap.gcWorkThisFrame,
      dirtyObjects: heap.dirtyObjects.len,
      cyclesDetected: heap.stats.cyclesDetected
    )
```

**C API Usage Example**:
```c
// In game engine
void game_update_frame() {
    // Set 2ms GC budget per frame
    etch_vm_begin_frame(vm, 2000);

    // Run game logic (may trigger GC within budget)
    etch_vm_execute(vm, "update");

    // Check if GC needs more time
    if (etch_vm_needs_gc_frame(vm)) {
        // Skip rendering, give full frame to GC
        etch_vm_begin_frame(vm, 16000);  // Full 16ms
        // GC will catch up
    }

    // Get stats for profiling
    GCFrameStats stats = etch_vm_get_gc_stats(vm);
    printf("GC time: %lldus, dirty: %d\n",
           stats.gcTimeThisFrameUs, stats.dirtyObjects);
}
```

**Testing**:
- Create `examples/gc_frame_budget_test.etch`
- Allocate many objects per frame
- Measure max frame time stays under budget
- Verify GC work is distributed across frames

**Benefits**:
- ✅ Deterministic frame times
- ✅ Engine controls GC budget
- ✅ Can defer GC to idle frames
- ✅ No changes to existing GC logic

**Effort**: 3 days

---

#### 1.2 Weak Reference Root Scanning Fix
**Goal**: Ensure promoted weak refs are properly scanned

**Files**:
- `src/etch/interpreter/regvm_heap.nim:479-480`
- `src/etch/interpreter/exec_instructions/refcounting.nim`

**Current Code**:
```nim
of hokWeak:
  # Weak refs don't participate in cycles
  children = initHashSet[int]()
```

**Issue**: When `weakToStrong` is called, the weak ref's target becomes strongly referenced, but cycle detection doesn't explicitly track this.

**Fix**:
```nim
# In detectCycles, before running SCC:
proc scanWeakRefs(heap: Heap, reachable: var HashSet[int]) =
  # Scan weak refs that have been promoted
  for id, obj in heap.objects.pairs:
    if obj.kind == hokWeak:
      # Check if weak ref itself is strongly held
      if obj.strongRefs > 0 and obj.targetId > 0:
        # Target should be considered reachable
        if heap.objects.hasKey(obj.targetId):
          reachable.incl(obj.targetId)
```

**Testing**:
- Create `examples/weak_ref_cycle_test.etch`
- Promote weak ref inside a cycle
- Verify cycle is not incorrectly collected

**Benefits**:
- ✅ Fixes potential correctness issue
- ✅ Minimal performance impact
- ✅ Better documentation of weak ref semantics

**Effort**: 1 day

---

### Phase 2: Edge Tracking Optimization (Week 2 - 4 days)

#### 2.1 Global Edge Buffer
**Goal**: Replace per-object HashSets with cache-friendly global buffer

**Files**:
- `src/etch/interpreter/regvm_heap.nim`
- `src/etch/interpreter/exec_instructions/objects.nim`

**Current Overhead**: ~2-3x on reference assignments (still significant)

**Solution**:

```nim
type
  EdgeEntry = object
    sourceId: int32      # 4 bytes
    targetId: int32      # 4 bytes
    fieldHash: int16     # 2 bytes (for debugging/profiling)
    edgeType: uint8      # 1 byte (field=0, array=1)
    padding: uint8       # 1 byte (alignment)
    # Total: 12 bytes per edge

  EdgeBuffer = ref object
    edges: seq[EdgeEntry]                    # Flat array
    index: Table[int, (int, int)]           # objectId -> (start, count)
    dirtyEdges: HashSet[int]                # Modified since last GC

  Heap = ref object
    # ... existing fields ...
    edgeBuffer: EdgeBuffer  # NEW

# Update HeapObject - REMOVE HashSets
type HeapObject = ref object
  # ... existing fields ...
  # REMOVED: fieldRefs: HashSet[int]
  # REMOVED: elementRefs: HashSet[int]
  # field tracking now in global edgeBuffer
```

**Migration Strategy**:
1. Add edgeBuffer to Heap alongside existing HashSets
2. Maintain both during transition (verify consistency)
3. Switch cycle detection to use edgeBuffer
4. Remove HashSets once verified

**Operations**:

```nim
# Fast path: add edge
proc addEdge(buf: EdgeBuffer, sourceId, targetId: int) {.inline.} =
  buf.edges.add(EdgeEntry(
    sourceId: int32(sourceId),
    targetId: int32(targetId),
    fieldHash: 0,
    edgeType: 0
  ))
  buf.dirtyEdges.incl(sourceId)

# Query edges during GC
iterator outgoingEdges(buf: EdgeBuffer, objId: int): int =
  if buf.index.hasKey(objId):
    let (start, count) = buf.index[objId]
    for i in start ..< start + count:
      yield int(buf.edges[i].targetId)
```

**Maintenance**:
```nim
# Compact during GC (remove edges for freed objects)
proc compactEdges(buf: EdgeBuffer, liveObjects: HashSet[int]) =
  var writeIdx = 0
  for readIdx in 0 ..< buf.edges.len:
    let edge = buf.edges[readIdx]
    if edge.sourceId in liveObjects and edge.targetId in liveObjects:
      buf.edges[writeIdx] = edge
      inc writeIdx
  buf.edges.setLen(writeIdx)
  # Rebuild index
```

**Testing**:
- Run all 352 existing tests with edgeBuffer
- Create `examples/gc_edge_buffer_stress_test.etch`
- Profile cache misses before/after
- Measure assignment performance

**Benefits**:
- ✅ 5-10x faster edge tracking
- ✅ Better cache locality (sequential access)
- ✅ ~30 bytes saved per object with refs
- ✅ Easier to profile and debug

**Effort**: 4 days

**Risk**: MEDIUM - Changes core GC data structures
**Mitigation**: Dual implementation during transition, extensive testing

---

### Phase 3: Advanced Features (Week 3 - Optional)

#### 3.1 Time-Sliced Incremental GC (OPTIONAL)
**Goal**: Pause/resume GC mid-collection for very large heaps

**When Needed**: Heaps with 50k+ objects

**Current State**: Incremental SCC already scans only dirty objects, which is sufficient for most workloads.

**Implementation** (if needed):
- Save Tarjan's algorithm state (indices, lowlinks, stack)
- Process N objects per time slice
- Resume from saved state next frame

**Effort**: 3 days

**Decision**: Defer until proven necessary by benchmarks

---

#### 3.2 Bump Allocator for Temporary Objects (OPTIONAL)
**Goal**: Zero-overhead allocation for frame-local objects

**Use Case**: Game engines allocate many temporary objects per frame

**Implementation**:
```nim
# New opcode
opNewBump  # Allocate from bump allocator (no RC)

# At frame end
proc clearBumpAllocator(heap: Heap) =
  for id in heap.bumpAllocator.buffer:
    heap.objects.del(id)  # Bulk free, no RC updates
  heap.bumpAllocator.buffer.setLen(0)
```

**Effort**: 2 days

**Decision**: Defer - current RC performance is good enough

---

#### 3.3 Visual Debugging API (LOW PRIORITY)
**Goal**: Export heap graph for visual debugging tools

**Implementation**:
```nim
proc exportHeapGraphDOT*(heap: Heap): string =
  result = "digraph {\n"
  for id, obj in heap.objects.pairs:
    result &= &"  {id} [label=\"#{id}\\nRC={obj.strongRefs}\"];\n"
    # Add edges from edgeBuffer
  result &= "}\n"

# C API
proc etch_heap_export_dot*(vm: VM, buf: cstring, len: int) {.exportc.}
```

**Usage**: Integrate with ImGui or export to Graphviz

**Effort**: 1 day

**Decision**: Nice to have, but not critical

---

## Updated Timeline

**Total: 2-3 weeks** (reduced from original 4 weeks)

| Week | Phase | Effort | Priority |
|------|-------|--------|----------|
| 1 | Frame Budget API | 3 days | HIGH |
| 1 | Weak Ref Fix | 1 day | MEDIUM |
| 2 | Global Edge Buffer | 4 days | HIGH |
| 3 | Optional Features | 3-6 days | LOW |

**Minimum Viable**: Weeks 1-2 (frame budget + edge buffer)

**Full Implementation**: Weeks 1-3 (all features)

---

## Success Metrics (Updated)

### Already Achieved ✅
- Allocation rate: +30%
- Cycle detection: -70% overhead
- incRef/decRef: -33% latency
- Memory overhead: -25%
- Cache misses: -37%

### Targets for Remaining Work

| Metric | Current | Target | How to Measure |
|--------|---------|--------|----------------|
| Max frame time (10k entities) | TBD | <16ms | Stress test |
| Edge tracking overhead | ~20ns | <5ns | Microbenchmark |
| Frame budget compliance | N/A | 99% | Frame time stats |
| Memory per object (with refs) | 96B | ~70B | sizeof() |

---

## Risk Assessment (Updated)

### LOW RISK ✅
- Frame budget API: Additive, doesn't change existing logic
- Weak ref fix: Small, focused change
- All existing optimizations: Already tested and working

### MEDIUM RISK ⚠️
- Global edge buffer: Changes core GC data structures
  - **Mitigation**: Dual implementation during transition
  - **Rollback**: Keep HashSets as fallback initially

### REMOVED RISKS ✅
- ~~Critical path optimization~~ - Already done
- ~~Adaptive intervals~~ - Already done
- ~~Verification infrastructure~~ - Already done

---

## Deployment Strategy

### Feature Flags
```nim
when defined(gcFrameBudget):
  # New frame budget API
else:
  # Original adaptive intervals

when defined(gcEdgeBuffer):
  # Global edge buffer
else:
  # Per-object HashSets
```

### Testing Matrix
- [ ] All 352 tests with frame budget API
- [ ] All 352 tests with edge buffer
- [ ] Stress test: 10k entities × 60 frames
- [ ] Cycle detection correctness
- [ ] Performance benchmarks vs. baseline

### Rollout Plan
1. **Week 1**: Internal testing with feature flags
2. **Week 2-3**: Beta release, gather feedback
3. **Week 4**: Full release if metrics met
4. **Week 5+**: Monitor production usage

---

## Implementation Checklist

### Phase 1 (Week 1)
- [ ] Add frame budget fields to Heap
- [ ] Implement beginFrame/needsGCFrame APIs
- [ ] Add C API functions
- [ ] Test frame budget compliance
- [ ] Fix weak ref root scanning
- [ ] Add weak ref cycle test

### Phase 2 (Week 2)
- [ ] Implement EdgeBuffer data structure
- [ ] Add edgeBuffer alongside HashSets
- [ ] Update cycle detection to use edgeBuffer
- [ ] Verify consistency between both
- [ ] Switch to edgeBuffer exclusively
- [ ] Remove HashSets
- [ ] Run full test suite
- [ ] Profile cache misses

### Phase 3 (Week 3 - Optional)
- [ ] Evaluate need for time-sliced GC
- [ ] Implement if benchmarks show hitches
- [ ] Add visual debugging API if desired

---

## References

- **Previous work**: `docs/internals/HEAP_OPTIMIZATIONS.md`
- **Current implementation**: `src/etch/interpreter/regvm_heap.nim`
- **Verification system**: `src/etch/interpreter/regvm_heap_verify.nim`
- **Test suite**: `examples/refcount_*.etch`

---

## Conclusion

The Etch heap is already production-ready with significant optimizations. The remaining work is focused and low-risk:

1. **Frame Budget API** (3 days) - Enables deterministic game engine integration
2. **Global Edge Buffer** (4 days) - 5-10x faster edge tracking
3. **Weak Ref Fix** (1 day) - Correctness improvement

**Total: 8 days of focused work** for full game engine optimization.

The system will then provide:
- ✅ <16ms deterministic frame times
- ✅ 5-10x faster reference tracking
- ✅ 50-70% total performance improvement over baseline
- ✅ Production-ready verification and recovery
- ✅ All 352 tests passing

**Status**: Ready to begin Phase 1 implementation.
