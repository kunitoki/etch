# vm_heap_verify.nim
# Heap verification and corruption detection for production reliability
# Provides comprehensive consistency checks and diagnostics


import std/[tables, sets, strformat, sequtils]
import vm
import vm_heap
import vm_types


type
  VerificationError* = object
    kind*: VerificationErrorKind
    objectId*: int
    message*: string
    severity*: ErrorSeverity

  VerificationErrorKind* = enum
    vekRefCountMismatch      # Reference count doesn't match actual references
    vekDanglingReference     # Reference to non-existent object
    vekOrphanedObject        # Object with no incoming references but refcount > 0
    vekDirtyInconsistency    # Dirty flag inconsistent with dirtyObjects set
    vekFieldRefMismatch      # fieldRefs/elementRefs don't match actual fields
    vekWeakRefCorruption     # Weak reference integrity violation
    vekMemoryLeak            # Object that should be freed but isn't
    vekDoubleFreed           # ID in free list but still in objects table
    vekNegativeRefCount      # Reference count < 0

  ErrorSeverity* = enum
    seWarning,    # Suspicious but might be ok
    seError,      # Definite problem, heap corrupted
    seCritical    # Severe corruption, immediate action needed

  VerificationReport* = object
    errors*: seq[VerificationError]
    warnings*: seq[VerificationError]
    totalObjects*: int
    totalReferences*: int
    heapHealthScore*: float  # 0.0-1.0, 1.0 = perfect
    timestamp*: int64


# Count actual references to an object from all sources
proc countActualReferences(heap: Heap, targetId: int): tuple[strong: int, weak: int] =
  result.strong = 0
  result.weak = 0

  # Count references from all heap objects
  for obj in heap.objects:
    if obj == nil: continue
    case obj.kind
    of hokScalar:
      # Scalars don't have references
      discard
    of hokTable:
      for fieldVal in obj.fields.values:
        if fieldVal.isHeapObject and fieldVal.heapObjectId == targetId:
          inc result.strong
    of hokArray:
      for elem in obj.elements:
        if elem.isHeapObject and elem.heapObjectId == targetId:
          inc result.strong
    of hokWeak:
      if obj.targetId == targetId:
        inc result.weak
    of hokClosure:
      for capture in obj.captures:
        if capture.isHeapObject and capture.heapObjectId == targetId:
          inc result.strong
    of hokRef:
      if obj.refTargetId == targetId:
        inc result.strong


# Verify reference counts match actual references
proc verifyRefCounts*(heap: Heap): seq[VerificationError] =
  result = @[]

  for id in 0 ..< heap.objects.len:
    let obj = heap.objects[id]
    if obj == nil: continue

    # Check for negative ref counts
    if obj.strongRefs < 0:
      result.add(VerificationError(
        kind: vekNegativeRefCount,
        objectId: id,
        message: &"Object #{id} has negative refcount: {obj.strongRefs}",
        severity: seCritical
      ))
      continue

    if obj.weakRefs < 0:
      result.add(VerificationError(
        kind: vekNegativeRefCount,
        objectId: id,
        message: &"Object #{id} has negative weak refcount: {obj.weakRefs}",
        severity: seCritical
      ))

    # Count actual references
    let (actualStrong, actualWeak) = heap.countActualReferences(id)

    # Strong reference count verification
    # Note: We can't easily count references from VM registers, so we only
    # check that declared refcount >= actual references in heap
    if actualStrong > obj.strongRefs:
      result.add(VerificationError(
        kind: vekRefCountMismatch,
        objectId: id,
        message: &"Object #{id} has {actualStrong} actual references but refcount is {obj.strongRefs}",
        severity: seError
      ))

    # Weak reference count verification
    if actualWeak != obj.weakRefs:
      result.add(VerificationError(
        kind: vekWeakRefCorruption,
        objectId: id,
        message: &"Object #{id} has {actualWeak} actual weak refs but count is {obj.weakRefs}",
        severity: seError
      ))


# Verify no dangling references
proc verifyNoDanglingRefs*(heap: Heap): seq[VerificationError] =
  result = @[]

  for id in 0 ..< heap.objects.len:
    let obj = heap.objects[id]
    if obj == nil: continue

    case obj.kind
    of hokScalar:
      discard
    of hokTable:
      # Check field values
      for fieldName, fieldVal in obj.fields.pairs:
        if fieldVal.isHeapObject:
          let childId = fieldVal.heapObjectId
          if childId != 0 and (childId >= heap.objects.len or heap.objects[childId] == nil):
            result.add(VerificationError(
              kind: vekDanglingReference,
              objectId: id,
              message: &"Object #{id} field '{fieldName}' references non-existent object #{childId}",
              severity: seCritical
            ))

      # Check fieldRefs consistency
      for refId in obj.fieldRefs:
        if refId != 0 and (refId >= heap.objects.len or heap.objects[refId] == nil):
          result.add(VerificationError(
            kind: vekDanglingReference,
            objectId: id,
            message: &"Object #{id} fieldRefs contains non-existent object #{refId}",
            severity: seError
          ))

    of hokArray:
      # Check array elements
      for i, elem in obj.elements.pairs:
        if elem.isHeapObject:
          let childId = elem.heapObjectId
          if childId != 0 and (childId >= heap.objects.len or heap.objects[childId] == nil):
            result.add(VerificationError(
              kind: vekDanglingReference,
              objectId: id,
              message: &"Object #{id} array[{i}] references non-existent object #{childId}",
              severity: seCritical
            ))

      # Check elementRefs consistency
      for refId in obj.elementRefs:
        if refId != 0 and (refId >= heap.objects.len or heap.objects[refId] == nil):
          result.add(VerificationError(
            kind: vekDanglingReference,
            objectId: id,
            message: &"Object #{id} elementRefs contains non-existent object #{refId}",
            severity: seError
          ))

    of hokWeak:
      # Weak refs to freed objects should have targetId = -1
      if obj.targetId > 0 and (obj.targetId >= heap.objects.len or heap.objects[obj.targetId] == nil):
        result.add(VerificationError(
          kind: vekWeakRefCorruption,
          objectId: id,
          message: &"Weak ref #{id} points to non-existent object #{obj.targetId}",
          severity: seError
        ))
    of hokClosure:
      for idx, capture in obj.captures.pairs:
        if capture.isHeapObject:
          let childId = capture.heapObjectId
          if childId != 0 and (childId >= heap.objects.len or heap.objects[childId] == nil):
            result.add(VerificationError(
              kind: vekDanglingReference,
              objectId: id,
              message: &"Closure #{id} capture[{idx}] references non-existent object #{childId}",
              severity: seCritical
            ))

      for refId in obj.captureRefs:
        if refId != 0 and (refId >= heap.objects.len or heap.objects[refId] == nil):
          result.add(VerificationError(
            kind: vekDanglingReference,
            objectId: id,
            message: &"Closure #{id} captureRefs contains non-existent object #{refId}",
            severity: seError
          ))

    of hokRef:
      if obj.refTargetId != 0 and (obj.refTargetId >= heap.objects.len or heap.objects[obj.refTargetId] == nil):
        result.add(VerificationError(
          kind: vekDanglingReference,
          objectId: id,
          message: &"Object #{id} references non-existent object #{obj.refTargetId}",
          severity: seCritical
        ))


# Verify fieldRefs/elementRefs match actual field contents
proc verifyFieldRefsConsistency*(heap: Heap): seq[VerificationError] =
  result = @[]

  for id in 0 ..< heap.objects.len:
    let obj = heap.objects[id]
    if obj == nil: continue

    case obj.kind
    of hokScalar, hokWeak, hokRef:
      discard
    of hokTable:
      # Collect actual refs from fields
      var actualRefs = initHashSet[int]()
      for fieldVal in obj.fields.values:
        if fieldVal.isHeapObject:
          let childId = fieldVal.heapObjectId
          if childId != 0:
            actualRefs.incl(childId)

      # Check for missing refs in fieldRefs
      for refId in actualRefs:
        if refId notin obj.fieldRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Object #{id} has field reference to #{refId} but it's not in fieldRefs",
            severity: seWarning
          ))

      # Check for extra refs in fieldRefs
      for refId in obj.fieldRefs:
        if refId notin actualRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Object #{id} fieldRefs contains #{refId} but no field references it",
            severity: seWarning
          ))

    of hokArray:
      # Collect actual refs from elements
      var actualRefs = initHashSet[int]()
      for elem in obj.elements:
        if elem.isHeapObject:
          let childId = elem.heapObjectId
          if childId != 0:
            actualRefs.incl(childId)

      # Check for missing refs in elementRefs
      for refId in actualRefs:
        if refId notin obj.elementRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Object #{id} has element reference to #{refId} but it's not in elementRefs",
            severity: seWarning
          ))

      # Check for extra refs in elementRefs
      for refId in obj.elementRefs:
        if refId notin actualRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Object #{id} elementRefs contains #{refId} but no element references it",
            severity: seWarning
          ))
    of hokClosure:
      var actualRefs = initHashSet[int]()
      for capture in obj.captures:
        if capture.isHeapObject:
          let childId = capture.heapObjectId
          if childId != 0:
            actualRefs.incl(childId)

      for refId in actualRefs:
        if refId notin obj.captureRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Closure #{id} references #{refId} in captures but it's missing from captureRefs",
            severity: seWarning
          ))

      for refId in obj.captureRefs:
        if refId notin actualRefs:
          result.add(VerificationError(
            kind: vekFieldRefMismatch,
            objectId: id,
            message: &"Closure #{id} captureRefs contains #{refId} but no capture references it",
            severity: seWarning
          ))


# Verify dirty object tracking consistency
proc verifyDirtyObjects*(heap: Heap): seq[VerificationError] =
  result = @[]

  # Check that all dirty objects are in the dirty set
  for id in 0 ..< heap.objects.len:
    let obj = heap.objects[id]
    if obj == nil: continue

    if obj.dirty and not heap.dirtyObjects.contains(id):
      result.add(VerificationError(
        kind: vekDirtyInconsistency,
        objectId: id,
        message: &"Object #{id} is marked dirty but not in dirtyObjects set",
        severity: seError
      ))

    if not obj.dirty and heap.dirtyObjects.contains(id):
      result.add(VerificationError(
        kind: vekDirtyInconsistency,
        objectId: id,
        message: &"Object #{id} is in dirtyObjects set but not marked dirty",
        severity: seError
      ))

  # Check that all objects in dirty set exist
  for id in heap.dirtyObjects:
    if id >= heap.objects.len or heap.objects[id] == nil:
      result.add(VerificationError(
        kind: vekDirtyInconsistency,
        objectId: id,
        message: &"Dirty set contains non-existent object #{id}",
        severity: seError
      ))


# Verify free list doesn't contain live objects
proc verifyFreeList*(heap: Heap): seq[VerificationError] =
  result = @[]

  for id in heap.freeList:
    if id < heap.objects.len and heap.objects[id] != nil:
      result.add(VerificationError(
        kind: vekDoubleFreed,
        objectId: id,
        message: &"Object #{id} is in free list but still exists in objects table",
        severity: seCritical
      ))


# Comprehensive heap verification
proc verifyHeap*(heap: Heap, verbose: bool = false): VerificationReport =
  result.timestamp = 0  # Would use epochTime() in real impl

  var count = 0
  for obj in heap.objects:
    if obj != nil: inc count
  result.totalObjects = count

  result.totalReferences = 0

  # Run all verification checks
  var allErrors: seq[VerificationError] = @[]

  if verbose:
    echo "[VERIFY] Running heap verification..."
    echo &"[VERIFY] Total objects: {result.totalObjects}"

  # 1. Verify reference counts
  if verbose:
    echo "[VERIFY] Checking reference counts..."
  allErrors.add(heap.verifyRefCounts())

  # 2. Verify no dangling references
  if verbose:
    echo "[VERIFY] Checking for dangling references..."
  allErrors.add(heap.verifyNoDanglingRefs())

  # 3. Verify field refs consistency
  if verbose:
    echo "[VERIFY] Checking fieldRefs consistency..."
  allErrors.add(heap.verifyFieldRefsConsistency())

  # 4. Verify dirty tracking
  if verbose:
    echo "[VERIFY] Checking dirty tracking..."
  allErrors.add(heap.verifyDirtyObjects())

  # 5. Verify free list
  if verbose:
    echo "[VERIFY] Checking free list..."
  allErrors.add(heap.verifyFreeList())

  # Categorize by severity
  for error in allErrors:
    case error.severity
    of seWarning:
      result.warnings.add(error)
    of seError, seCritical:
      result.errors.add(error)

  # Calculate heap health score
  let totalIssues = result.errors.len + result.warnings.len
  if totalIssues == 0:
    result.heapHealthScore = 1.0
  else:
    # Errors weigh more than warnings
    let errorWeight = result.errors.len * 10
    let warningWeight = result.warnings.len * 1
    let totalWeight = errorWeight + warningWeight
    result.heapHealthScore = max(0.0, 1.0 - (float(totalWeight) / float(max(result.totalObjects * 5, 10))))

  if verbose:
    echo &"[VERIFY] Heap health score: {result.heapHealthScore:.2f}"
    echo &"[VERIFY] Errors: {result.errors.len}, Warnings: {result.warnings.len}"


# Format verification report for display
proc formatReport*(report: VerificationReport): string =
  result = "\n=== Heap Verification Report ===\n"
  result &= &"Total Objects: {report.totalObjects}\n"
  result &= &"Health Score: {report.heapHealthScore * 100.0:.2f}%\n"
  result &= &"Errors: {report.errors.len}\n"
  result &= &"Warnings: {report.warnings.len}\n"

  if report.errors.len > 0:
    result &= "\n--- ERRORS ---\n"
    for err in report.errors:
      let severityStr = case err.severity
        of seWarning: "WARN"
        of seError: "ERROR"
        of seCritical: "CRITICAL"
      result &= &"[{severityStr}] {err.message}\n"

  if report.warnings.len > 0:
    result &= "\n--- WARNINGS ---\n"
    for warn in report.warnings:
      result &= &"[WARN] {warn.message}\n"

  if report.errors.len == 0 and report.warnings.len == 0:
    result &= "\n✓ Heap is healthy - no issues detected\n"

  result &= "================================\n"


# Quick sanity check (fast version for production)
proc quickHealthCheck*(heap: Heap): bool =
  # Fast check for critical issues
  for i, obj in heap.objects:
    if obj == nil: continue

    # Check 1: Ref count sanity
    if obj.refCount < 0:
      return false

    # Check 2: Type sanity
    if obj.kind == objNone:
      return false

    # Check 3: Field refs sanity
    for fieldRef in obj.fieldRefs:
      if fieldRef < 0 or fieldRef >= heap.objects.len or heap.objects[fieldRef] == nil:
        return false

  return true


# Recover from detected corruption (best effort)
proc attemptRecovery*(heap: Heap, report: VerificationReport): int =
  ## Attempt to recover from corruption by fixing fixable issues
  ## Returns number of issues fixed
  result = 0

  # Process both errors and warnings (many fixable issues are warnings)
  for error in report.errors & report.warnings:
    case error.kind
    of vekDirtyInconsistency:
      # Fix dirty tracking inconsistencies
      if heap.objects.hasKey(error.objectId):
        if error.objectId in heap.dirtyObjects and not heap.objects[error.objectId].dirty:
          heap.objects[error.objectId].dirty = true
          inc result
        elif error.objectId notin heap.dirtyObjects and heap.objects[error.objectId].dirty:
          heap.dirtyObjects.incl(error.objectId)
          inc result
      else:
        heap.dirtyObjects.excl(error.objectId)
        inc result

    of vekDoubleFreed:
      # Remove from free list if still in objects
      if heap.objects.hasKey(error.objectId):
        heap.freeList = heap.freeList.filterIt(it != error.objectId)
        inc result

    of vekFieldRefMismatch:
      # Rebuild fieldRefs/elementRefs from actual contents
      if heap.objects.hasKey(error.objectId):
        let obj = heap.objects[error.objectId]
        case obj.kind
        of hokTable:
          obj.fieldRefs.clear()
          for fieldVal in obj.fields.values:
            if fieldVal.isHeapObject:
              let childId = fieldVal.heapObjectId
              if childId != 0:
                obj.fieldRefs.incl(childId)
          inc result
        of hokArray:
          obj.elementRefs.clear()
          for elem in obj.elements:
            if elem.isHeapObject:
              let childId = elem.heapObjectId
              if childId != 0:
                obj.elementRefs.incl(childId)
          inc result
        of hokClosure:
          obj.captureRefs.clear()
          for capture in obj.captures:
            if capture.isHeapObject:
              let childId = capture.heapObjectId
              if childId != 0:
                obj.captureRefs.incl(childId)
          inc result
        else:
          discard

    else:
      # Other errors are not auto-fixable
      discard
