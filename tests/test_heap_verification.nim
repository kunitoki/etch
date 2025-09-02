## Test suite for heap verification and corruption recovery
## Demonstrates detection and recovery from various corruption scenarios

import unittest
import std/[strformat, tables, sets]
import ../src/etch/core/[vm, vm_types]
import ../src/etch/core/vm_heap
import ../src/etch/core/vm_heap_verify


suite "Heap Verification - Corruption Detection and Recovery":

  test "Scenario 1: Dirty Inconsistency - 100% Fixable":
    ## Test: Object marked dirty but not in dirtyObjects set
    ## Recovery: Add to dirtyObjects set OR clear dirty flag

    echo "\n=== TEST: Dirty Inconsistency ==="

    # Create heap
    let heap = newHeap(verbose = false)

    # Allocate an object (starts with dirty=true and in dirtyObjects)
    let id1 = heap.allocTable()
    echo &"Created object #{id1}"

    # INTRODUCE CORRUPTION: Remove from dirtyObjects but leave dirty=true
    heap.dirtyObjects.excl(id1)
    # Now: object has dirty=true but is not in dirtyObjects set

    echo "Corruption introduced: object dirty=true but not in dirtyObjects set"

    # Verify - should detect the issue
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"
    echo &"  Warnings: {report.warnings.len}"
    echo &"  Health score: {report.heapHealthScore * 100.0:.2f}%"

    check report.warnings.len > 0  # Should have warnings

    var foundDirtyError = false
    for warning in report.warnings:
      if warning.kind == vekDirtyInconsistency:
        foundDirtyError = true
        echo &"  ✓ Detected: {warning.message}"

    check foundDirtyError

    # Attempt recovery
    let fixed = heap.attemptRecovery(report)
    echo &"\nRecovery: Fixed {fixed} issues"
    check fixed > 0

    # Verify again - should be clean now
    let report2 = heap.verifyHeap(verbose = false)
    echo &"After recovery:"
    echo &"  Errors: {report2.errors.len}"
    echo &"  Warnings: {report2.warnings.len}"
    echo &"  Health score: {report2.heapHealthScore * 100.0:.2f}%"

    check report2.warnings.len == 0
    check report2.heapHealthScore > 0.99

    echo "✓ Dirty inconsistency: DETECTED and RECOVERED\n"

  test "Scenario 2: Field Ref Mismatch - 100% Fixable":
    ## Test: fieldRefs doesn't match actual field contents
    ## Recovery: Rebuild fieldRefs from actual fields

    echo "\n=== TEST: Field Ref Mismatch ==="

    let heap = newHeap(verbose = false)

    # Create two objects with a reference
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()

    # Set a field that references id2
    let obj1 = heap.objects[id1]
    obj1.fields["child"] = V(kind: vkRef, refId: id2)

    echo &"Created objects #{id1} and #{id2}"
    echo &"Object #{id1} has field 'child' -> #{id2}"

    # INTRODUCE CORRUPTION: Clear fieldRefs but leave actual field
    obj1.fieldRefs.clear()
    echo "Corruption introduced: fieldRefs cleared but field still references object"

    # Verify - should detect mismatch
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"
    echo &"  Warnings: {report.warnings.len}"

    var foundFieldRefError = false
    for warning in report.warnings:
      if warning.kind == vekFieldRefMismatch:
        foundFieldRefError = true
        echo &"  ✓ Detected: {warning.message}"

    check foundFieldRefError

    # Attempt recovery
    let fixed = heap.attemptRecovery(report)
    echo &"\nRecovery: Fixed {fixed} issues"
    check fixed > 0

    # Verify fieldRefs rebuilt correctly
    check heap.objects[id1].fieldRefs.contains(id2)

    # Verify again - should be clean
    let report2 = heap.verifyHeap(verbose = false)
    echo &"After recovery:"
    echo &"  Health score: {report2.heapHealthScore * 100.0:.2f}%"

    check report2.warnings.len == 0
    check report2.heapHealthScore > 0.99

    echo "✓ Field ref mismatch: DETECTED and RECOVERED\n"

  test "Scenario 3: Double-Free - 100% Fixable":
    ## Test: Object in free list but still in objects table
    ## Recovery: Remove from free list

    echo "\n=== TEST: Double-Free Scenario ==="

    let heap = newHeap(verbose = false)

    # Allocate object
    let id1 = heap.allocTable()
    echo &"Created object #{id1}"

    # INTRODUCE CORRUPTION: Add to free list without removing from objects
    heap.freeList.add(id1)
    echo &"Corruption introduced: object #{id1} added to free list but still live"

    # Verify - should detect double-free
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"

    var foundDoubleFree = false
    for error in report.errors:
      if error.kind == vekDoubleFreed:
        foundDoubleFree = true
        echo &"  ✓ Detected: {error.message}"
        check error.severity == seCritical

    check foundDoubleFree

    # Attempt recovery
    let fixed = heap.attemptRecovery(report)
    echo &"\nRecovery: Fixed {fixed} issues"
    check fixed > 0

    # Verify free list no longer contains live object
    check id1 notin heap.freeList
    check heap.objects.hasKey(id1)

    # Verify again - should be clean
    let report2 = heap.verifyHeap(verbose = false)
    echo &"After recovery:"
    echo &"  Errors: {report2.errors.len}"
    echo &"  Health score: {report2.heapHealthScore * 100.0:.2f}%"

    check report2.errors.len == 0
    check report2.heapHealthScore > 0.99

    echo "✓ Double-free: DETECTED and RECOVERED\n"

  test "Scenario 4: Dangling Reference - Detection Only":
    ## Test: Reference to non-existent object
    ## Recovery: NOT auto-fixable (would require finding all refs and nullifying)

    echo "\n=== TEST: Dangling Reference ==="

    let heap = newHeap(verbose = false)

    # Create two objects
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()

    # Create reference from id1 to id2
    let obj1 = heap.objects[id1]
    obj1.fields["dangling"] = V(kind: vkRef, refId: id2)
    obj1.fieldRefs.incl(id2)

    echo &"Created objects #{id1} and #{id2}"
    echo &"Object #{id1} has field 'dangling' -> #{id2}"

    # INTRODUCE CORRUPTION: Delete id2 but leave reference in id1
    heap.objects.del(id2)
    echo &"Corruption introduced: deleted object #{id2} but reference from #{id1} remains"

    # Verify - should detect dangling reference
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"

    var foundDangling = false
    var foundCritical = false
    for error in report.errors:
      if error.kind == vekDanglingReference:
        foundDangling = true
        echo &"  ✓ Detected: {error.message}"
        if error.severity == seCritical:
          foundCritical = true

    check foundDangling
    check foundCritical  # At least one should be critical
    check report.errors.len > 0

    # Attempt recovery - dangling refs are NOT auto-fixable
    let fixedBefore = report.errors.len
    let fixed = heap.attemptRecovery(report)
    echo &"\nRecovery: Fixed {fixed} issues (dangling refs not auto-fixable)"

    # Verify again - dangling reference still present
    let report2 = heap.verifyHeap(verbose = false)
    echo &"After recovery attempt:"
    echo &"  Errors: {report2.errors.len} (should still have dangling ref)"

    # Dangling references should still be detected
    check report2.errors.len > 0

    echo "✓ Dangling reference: DETECTED (not auto-fixable, requires manual intervention)\n"

  test "Scenario 5: Negative Reference Count - Critical Detection":
    ## Test: Object with negative refcount
    ## Recovery: Not auto-fixable (indicates serious memory corruption)

    echo "\n=== TEST: Negative Reference Count ==="

    let heap = newHeap(verbose = false)

    # Create object
    let id1 = heap.allocTable()
    echo &"Created object #{id1} with refcount: {heap.objects[id1].strongRefs}"

    # INTRODUCE CORRUPTION: Set negative refcount
    heap.objects[id1].strongRefs = -5
    echo "Corruption introduced: negative refcount = -5"

    # Verify - should detect critical issue
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"

    var foundNegative = false
    for error in report.errors:
      if error.kind == vekNegativeRefCount:
        foundNegative = true
        echo &"  ✓ Detected: {error.message}"
        check error.severity == seCritical

    check foundNegative
    check report.heapHealthScore < 0.5  # Very unhealthy

    echo "✓ Negative refcount: DETECTED (critical corruption)\n"

  test "Scenario 6: Weak Reference Corruption":
    ## Test: Weak ref points to freed object but targetId not set to -1
    ## Recovery: Can detect but complex to fix

    echo "\n=== TEST: Weak Reference Corruption ==="

    let heap = newHeap(verbose = false)

    # Create target object
    let targetId = heap.allocTable()

    # Create weak reference to it
    let weakId = heap.allocWeak(targetId, "TestTable")

    echo &"Created weak ref #{weakId} -> #{targetId}"
    check heap.objects[weakId].kind == hokWeak

    # INTRODUCE CORRUPTION: Delete target but leave weak ref pointing to it
    heap.objects.del(targetId)
    # weakId.targetId still points to freed targetId (should be -1)

    echo &"Corruption introduced: target #{targetId} deleted but weak ref still points to it"

    # Verify - should detect weak ref corruption
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"

    var foundWeakCorruption = false
    for error in report.errors:
      if error.kind == vekWeakRefCorruption:
        foundWeakCorruption = true
        echo &"  ✓ Detected: {error.message}"

    check foundWeakCorruption

    echo "✓ Weak ref corruption: DETECTED\n"

  test "Scenario 7: Comprehensive Health Check":
    ## Test: Multiple issues at once

    echo "\n=== TEST: Multiple Corruption Issues ==="

    let heap = newHeap(verbose = false)

    # Create several objects
    let id1 = heap.allocTable()
    let id2 = heap.allocTable()
    let id3 = heap.allocTable()

    echo &"Created objects #{id1}, #{id2}, #{id3}"

    # Introduce multiple corruptions

    # 1. Dirty inconsistency - remove from dirtyObjects but leave dirty=true
    heap.dirtyObjects.excl(id1)

    # 2. Field ref mismatch
    heap.objects[id2].fields["ref"] = V(kind: vkRef, refId: id3)
    heap.objects[id2].fieldRefs.clear()

    # 3. Double-free
    heap.freeList.add(id3)

    echo "Multiple corruptions introduced:"
    echo &"  - Dirty inconsistency on #{id1}"
    echo &"  - Field ref mismatch on #{id2}"
    echo &"  - Double-free on #{id3}"

    # Verify - should detect all issues
    let report = heap.verifyHeap(verbose = true)

    echo &"\nVerification results:"
    echo &"  Errors: {report.errors.len}"
    echo &"  Warnings: {report.warnings.len}"
    echo &"  Health score: {report.heapHealthScore * 100.0:.2f}%"

    # Should have multiple issues
    check (report.errors.len + report.warnings.len) >= 3
    check report.heapHealthScore < 0.9

    # Show detected issues
    echo "\nDetected issues:"
    for error in report.errors:
      echo &"  ERROR: {error.kind} - {error.message}"
    for warning in report.warnings:
      echo &"  WARN: {warning.kind} - {warning.message}"

    # Attempt recovery
    let fixed = heap.attemptRecovery(report)
    echo &"\nRecovery: Fixed {fixed} issues"
    check fixed >= 3

    # Verify again
    let report2 = heap.verifyHeap(verbose = false)
    echo &"\nAfter recovery:"
    echo &"  Errors: {report2.errors.len}"
    echo &"  Warnings: {report2.warnings.len}"
    echo &"  Health score: {report2.heapHealthScore * 100.0:.2f}%"

    check report2.heapHealthScore > 0.99

    echo "✓ Multiple corruptions: All DETECTED and RECOVERED\n"

  test "Scenario 8: Quick Health Check Performance":
    ## Test: Quick health check is fast

    echo "\n=== TEST: Quick Health Check Performance ==="

    let heap = newHeap(verbose = false)

    # Create many objects
    var ids: seq[int] = @[]
    for i in 0 ..< 100:
      ids.add(heap.allocTable())

    echo &"Created {ids.len} objects"

    # Quick health check should pass
    let healthy = heap.quickHealthCheck()
    check healthy
    echo "✓ Quick health check: PASSED (heap is healthy)"

    # Introduce corruption
    heap.objects[ids[50]].strongRefs = -1

    # Quick health check should fail
    let corrupted = heap.quickHealthCheck()
    check not corrupted
    echo "✓ Quick health check: FAILED (detected corruption)"

    echo "Quick health check is fast and effective for production\n"
