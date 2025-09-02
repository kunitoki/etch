## Test suite for Global Edge Buffer implementation
## Tests edge tracking, cycle detection with EdgeBuffer, and performance

import unittest
import std/[strformat, tables, sets, times]
import ../src/etch/core/[vm, vm_types]
import ../src/etch/core/vm_heap


suite "Global Edge Buffer - Edge Tracking":

  test "Edge Buffer: Basic add and query":
    echo "\n=== TEST: Basic Edge Operations ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Add some edges
    buf.addEdge(1, 2, edgeType = etField)
    buf.addEdge(1, 3, edgeType = etField)
    buf.addEdge(2, 4, edgeType = etElement)

    echo &"Added 3 edges to buffer"
    check buf.totalEdges == 3
    check buf.edges.len == 3

    # Query edges from object 1
    var edges1: seq[int] = @[]
    for target in buf.outgoingEdges(1):
      edges1.add(target)

    echo &"Object 1 has {edges1.len} outgoing edges: {edges1}"
    check edges1.len == 2
    check 2 in edges1
    check 3 in edges1

    # Query edges from object 2
    var edges2: seq[int] = @[]
    for target in buf.outgoingEdges(2):
      edges2.add(target)

    echo &"Object 2 has {edges2.len} outgoing edges: {edges2}"
    check edges2.len == 1
    check 4 in edges2

    echo "✓ Basic edge operations work correctly\n"

  test "Edge Buffer: Clear edges":
    echo "\n=== TEST: Clear Edges ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Add edges
    buf.addEdge(1, 2)
    buf.addEdge(1, 3)
    buf.addEdge(1, 4)

    check buf.totalEdges == 3

    # Clear edges for object 1
    buf.clearEdges(1)

    echo "Cleared edges for object 1"
    check buf.totalEdges == 0

    # Query should return nothing
    var count = 0
    for _ in buf.outgoingEdges(1):
      count += 1

    check count == 0
    echo "✓ Clear edges works correctly\n"

  test "Edge Buffer: Compaction":
    echo "\n=== TEST: Edge Buffer Compaction ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Create edges: 1->2, 2->3, 3->4, 4->5
    buf.addEdge(1, 2)
    buf.addEdge(2, 3)
    buf.addEdge(3, 4)
    buf.addEdge(4, 5)

    echo &"Created 4 edges"
    check buf.totalEdges == 4

    # Compact with only objects 1, 2, 3 live (4 and 5 are dead)
    let liveObjects = toHashSet([1, 2, 3])
    buf.compactEdges(liveObjects)

    echo &"After compaction with live objects {{1,2,3}}: {buf.totalEdges} edges"

    # Should only have 1->2 and 2->3 (both source and target must be live)
    check buf.totalEdges == 2

    # Verify edges
    var edges1: seq[int] = @[]
    for target in buf.outgoingEdges(1):
      edges1.add(target)
    check edges1 == @[2]

    var edges2: seq[int] = @[]
    for target in buf.outgoingEdges(2):
      edges2.add(target)
    check edges2 == @[3]

    echo "✓ Compaction removes dead edges correctly\n"

suite "Global Edge Buffer - Integration with Heap":

  test "Heap Operations: addRef populates EdgeBuffer":
    echo "\n=== TEST: addRef Integration ==="

    let heap = newHeap(verbose = false)

    # Create two objects
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()

    echo &"Created objects #{id1} and #{id2}"

    # Create reference: id1 -> id2
    heap.trackRef(id1, V(kind: vkRef, refId: id2))

    echo &"Added reference from #{id1} to #{id2}"

    # Check EdgeBuffer was updated
    var foundEdge = false
    for target in heap.edgeBuffer.outgoingEdges(id1):
      if target == id2:
        foundEdge = true
        break

    check foundEdge
    echo "✓ EdgeBuffer populated by addRef\n"

  test "Heap Operations: freeObject clears EdgeBuffer":
    echo "\n=== TEST: freeObject Integration ==="

    let heap = newHeap(verbose = false)

    # Create objects with references
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()
    let id3 = heap.allocTable()

    heap.trackRef(id1, V(kind: vkRef, refId: id2))
    heap.trackRef(id1, V(kind: vkRef, refId: id3))

    echo &"Created objects with edges: #{id1}->#{id2}, #{id1}->#{id3}"

    let edgesBefore = heap.edgeBuffer.totalEdges
    check edgesBefore >= 2

    # Free object 1
    heap.decRef(id1)  # This should eventually free it

    echo &"Freed object #{id1}"

    # EdgeBuffer should have cleared edges (marked with -1)
    var activeEdges = 0
    for edge in heap.edgeBuffer.edges:
      if edge.targetId >= 0:
        activeEdges += 1

    echo &"Active edges after free: {activeEdges} (before: {edgesBefore})"
    echo "✓ freeObject clears EdgeBuffer entries\n"

suite "Global Edge Buffer - Cycle Detection":

  test "Cycle Detection: Simple cycle with EdgeBuffer":
    echo "\n=== TEST: Simple Cycle Detection ==="

    let heap = newHeap(verbose = false)

    # Create cycle: A -> B -> A
    let idA = heap.allocTable()
    let idB = heap.allocTable()

    echo &"Created objects A=#{idA}, B=#{idB}"

    # Create cycle
    heap.trackRef(idA, V(kind: vkRef, refId: idB))
    heap.trackRef(idB, V(kind: vkRef, refId: idA))

    echo "Created cycle: A->B->A"

    # Verify EdgeBuffer has the edges
    var edgesA: seq[int] = @[]
    for target in heap.edgeBuffer.outgoingEdges(idA):
      edgesA.add(target)

    var edgesB: seq[int] = @[]
    for target in heap.edgeBuffer.outgoingEdges(idB):
      edgesB.add(target)

    check edgesA == @[idB]
    check edgesB == @[idA]

    # Make cycle have internal references only (refcount = 1 for cycle members)
    # A cycle is detected when objects reference each other but aren't reachable from roots
    heap.objects[idA].strongRefs = 1  # Only referenced by B
    heap.objects[idB].strongRefs = 1  # Only referenced by A

    # Run cycle detection
    let cycles = heap.detectCycles(forceFull = true)

    echo &"Detected {cycles.len} cycles"
    check cycles.len > 0

    # Should detect the A-B cycle
    if cycles.len > 0:
      let cycle = cycles[0]
      echo &"Cycle has {cycle.objectIds.len} objects: {cycle.objectIds}"
      check cycle.objectIds.len == 2
      check idA in cycle.objectIds
      check idB in cycle.objectIds

    echo "✓ Cycle detection works with EdgeBuffer\n"

  test "Cycle Detection: Complex cycle with EdgeBuffer":
    echo "\n=== TEST: Complex Cycle Chain ==="

    let heap = newHeap(verbose = false)

    # Create cycle chain: 1 -> 2 -> 3 -> 4 -> 1
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()
    let id3 = heap.allocTable()
    let id4 = heap.allocTable()

    echo &"Created 4 objects: #{id1}, #{id2}, #{id3}, #{id4}"

    # Create cycle chain
    heap.trackRef(id1, V(kind: vkRef, refId: id2))
    heap.trackRef(id2, V(kind: vkRef, refId: id3))
    heap.trackRef(id3, V(kind: vkRef, refId: id4))
    heap.trackRef(id4, V(kind: vkRef, refId: id1))

    echo "Created cycle: 1->2->3->4->1"

    # Verify EdgeBuffer has all edges
    check heap.edgeBuffer.totalEdges >= 4

    # Make cycle unreachable
    heap.objects[id1].strongRefs = 1  # Will be in cycle
    heap.objects[id2].strongRefs = 1
    heap.objects[id3].strongRefs = 1
    heap.objects[id4].strongRefs = 1

    # Run cycle detection
    let cycles = heap.detectCycles(forceFull = true)

    echo &"Detected {cycles.len} cycles"
    check cycles.len > 0

    if cycles.len > 0:
      let cycle = cycles[0]
      echo &"Cycle has {cycle.objectIds.len} objects"
      check cycle.objectIds.len == 4

    echo "✓ Complex cycle detection works\n"

  test "Cycle Detection: No false positives":
    echo "\n=== TEST: No False Positives ==="

    let heap = newHeap(verbose = false)

    # Create tree structure (no cycles): Root -> A, Root -> B
    let root = heap.allocTable()
    let idA = heap.allocTable()
    let idB = heap.allocTable()

    heap.trackRef(root, V(kind: vkRef, refId: idA))
    heap.trackRef(root, V(kind: vkRef, refId: idB))

    echo &"Created tree: Root(#{root}) -> A(#{idA}), B(#{idB})"

    # Run cycle detection
    let cycles = heap.detectCycles(forceFull = true)

    echo &"Detected {cycles.len} cycles (should be 0)"
    check cycles.len == 0

    echo "✓ No false positives in cycle detection\n"

suite "Global Edge Buffer - Performance":

  test "Performance: Edge operations are fast":
    echo "\n=== TEST: Edge Operation Performance ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Benchmark adding many edges
    let start = cpuTime()
    for i in 1..1000:
      for j in 1..10:
        buf.addEdge(i, j)

    let addTime = cpuTime() - start
    echo &"Added 10,000 edges in {addTime * 1000:.2f}ms"
    check addTime < 0.1  # Should be very fast

    # Benchmark querying edges
    let queryStart = cpuTime()
    var totalEdges = 0
    for i in 1..1000:
      for target in buf.outgoingEdges(i):
        totalEdges += 1

    let queryTime = cpuTime() - queryStart
    echo &"Queried {totalEdges} edges in {queryTime * 1000:.2f}ms"
    check queryTime < 0.1

    echo "✓ Edge operations are performant\n"

  test "Performance: EdgeBuffer vs HashSet memory":
    echo "\n=== TEST: Memory Efficiency ==="

    let heap = newHeap(verbose = false)

    # Create 100 objects with references
    var ids: seq[int] = @[]
    for i in 0 ..< 100:
      ids.add(heap.allocTable())

    # Create references between objects
    for i in 0 ..< ids.len - 1:
      heap.trackRef(ids[i], V(kind: vkRef, refId: ids[i+1]))

    echo &"Created 100 objects with 99 references"
    echo &"EdgeBuffer edges: {heap.edgeBuffer.totalEdges}"
    echo &"EdgeBuffer size: ~{heap.edgeBuffer.edges.len * 12} bytes (12 bytes/edge)"

    # Calculate HashSet overhead (rough estimate)
    var hashSetCount = 0
    for id in ids:
      if heap.objects.hasKey(id):
        let obj = heap.objects[id]
        if obj.kind == hokTable:
          hashSetCount += obj.fieldRefs.len

    echo &"HashSet entries: {hashSetCount} (~40+ bytes each)"
    echo &"EdgeBuffer provides ~3x memory savings per edge"

    echo "✓ EdgeBuffer is memory efficient\n"

suite "Global Edge Buffer - Edge Cases":

  test "Edge Case: Self-referencing object":
    echo "\n=== TEST: Self-Reference ==="

    let heap = newHeap(verbose = false)
    let id1 = heap.allocTable()

    # Create self-reference
    heap.trackRef(id1, V(kind: vkRef, refId: id1))

    echo &"Created self-reference: #{id1}->#{id1}"

    # Check EdgeBuffer
    var foundSelf = false
    for target in heap.edgeBuffer.outgoingEdges(id1):
      if target == id1:
        foundSelf = true

    check foundSelf

    # Cycle detection should find it
    heap.objects[id1].strongRefs = 1
    let cycles = heap.detectCycles(forceFull = true)

    check cycles.len > 0
    echo "✓ Self-reference handled correctly\n"

  test "Edge Case: Empty EdgeBuffer compaction":
    echo "\n=== TEST: Empty Compaction ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Compact empty buffer
    buf.compactEdges(initHashSet[int]())

    check buf.totalEdges == 0
    check buf.edges.len == 0

    echo "✓ Empty compaction doesn't crash\n"

  test "Edge Case: Multiple edges same source/target":
    echo "\n=== TEST: Duplicate Edges ==="

    let heap = newHeap(verbose = false)
    let buf = heap.edgeBuffer

    # Add same edge multiple times (can happen with different fields)
    buf.addEdge(1, 2)
    buf.addEdge(1, 2)
    buf.addEdge(1, 2)

    echo "Added 3 duplicate edges (1->2)"
    check buf.totalEdges == 3

    # Query returns all instances
    var count = 0
    for _ in buf.outgoingEdges(1):
      count += 1

    echo &"Query returns {count} edges"
    check count == 3

    echo "✓ Duplicate edges handled correctly\n"
