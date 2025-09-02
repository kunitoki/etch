# Destructor Implementation Design

## Overview

Destructors allow cleanup code to run automatically when ref-counted objects reach zero references. This is critical for resource management (files, sockets, etc.).

## Syntax

```etch
type File = object {
    handle: int;
    path: string;
};

// Destructor syntax: fn ~(obj: TypeName)
fn ~(f: File) -> void {
    print("Closing file: " + f.path);
    // cleanup code here
}
```

## Implementation Plan

### 1. Lexer Changes
- Add `~` as a token (may already exist)
- Handle `~` in function name position

### 2. Parser Changes (frontend/parser.nim)
- Recognize `fn ~(param: Type)` pattern
- Parse as special function with name like `~TypeName`
- Store destructor flag or special naming convention

### 3. Type System Integration (typechecker/)

**During Type Declaration:**
- When `type Foo = object {...}` is parsed, create EtchType with `destructor: none(string)`

**During Destructor Declaration:**
- When `fn ~(obj: Foo)` is parsed:
  1. Validate: exactly 1 parameter of object type
  2. Validate: return type is void
  3. Look up type `Foo` in scope
  4. Set `Foo.destructor = some("~Foo")` (or similar naming)
  5. Register function as `~Foo` in function table

### 4. Heap Management Integration (interpreter/regvm_heap.nim)

**HeapObject Extension:**
```nim
type HeapObject = ref object
  id: int
  strongRefs: int
  weakRefs: int
  destructorFuncId: Option[int]  # NEW: function ID for destructor
  case kind: HeapObjectKind
  of hokTable:
    fields: Table[string, V]
    # ...
```

**When Allocating (allocTable):**
- Look up type from compilation context
- If type has destructor, store destructor function ID in heap object

**When Freeing (freeObject):**
```nim
proc freeObject(heap: Heap, id: int) =
  if id == 0 or not heap.objects.hasKey(id):
    return

  let obj = heap.objects[id]

  # NEW: Call destructor BEFORE freeing children
  if obj.destructorFuncId.isSome:
    let destructorId = obj.destructorFuncId.get
    # Call destructor function with object as argument
    callDestructor(heap, obj, destructorId)

  # Nullify weak refs
  if obj.weakRefs > 0:
    heap.nullifyWeakRefs(id)

  # Recursively decRef children
  case obj.kind
  of hokTable:
    for fieldVal in obj.fields.values:
      if fieldVal.kind == vkRef:
        heap.decRef(fieldVal.refId)
  # ...

  # Remove from objects table
  heap.objects.del(id)
  heap.freeList.add(id)
  inc heap.freeCount
```

### 5. Bytecode Compilation (interpreter/regvm_compiler.nim)

**When compiling `new[Type]` with destructor:**
- Look up type's destructor function
- Pass destructor function ID to `opNewRef` opcode (extend opcode?)
- OR: Store in a global type->destructor mapping

**Option A: Extend opNewRef opcode**
```nim
# A=dest, B=destructor_func_idx (or 0 if none), C=1 for table
c.prog.emitABC(opNewRef, result, destructorIdx, 0)
```

**Option B: Global type->destructor registry**
- Maintain `destructorRegistry: Table[string, int]` in VM
- Heap looks up destructor by type name when allocating

### 6. VM Execution (interpreter/regvm_exec.nim)

**Destructor Invocation:**
```nim
proc callDestructor(vm: RegisterVM, heap: Heap, obj: HeapObject, funcId: int) =
  # Create temporary frame
  # Push object as first argument
  # Call destructor function
  # Pop frame
  # Destructor should not modify refcount of the object being destroyed
```

**Challenges:**
- Destructor runs during `decRef` which might be called during VM execution
- Need to ensure no re-entrancy issues
- Destructor should be able to access object fields but not the object itself as ref

### 7. C Backend Support (backend/c/runtime.h)

**Extend C heap object:**
```c
typedef struct {
  int id;
  int strongRefs;
  int weakRefs;
  int destructorFuncIdx;  // NEW: -1 if none
  HeapObjectKind kind;
  // ...
} HeapObject;
```

**In freeObject:**
```c
void etch_freeObject(EtchHeap* heap, int id) {
  HeapObject* obj = getObject(heap, id);
  if (!obj) return;

  // Call destructor if present
  if (obj->destructorFuncIdx >= 0) {
    etch_callDestructor(heap, obj, obj->destructorFuncIdx);
  }

  // ... rest of cleanup
}
```

## Edge Cases & Considerations

### 1. Destructor Ordering
- Destructor runs BEFORE children are decRef'd
- This allows destructor to access child objects
- Children are then automatically cleaned up

### 2. Cycles with Destructors
- If cycle contains objects with destructors, destructors should still run
- Cycle detection should trigger explicit destruction
- Order of destruction in cycles: undefined but deterministic

### 3. Destructor Exceptions
- Destructors should not throw/error
- If they do, log warning and continue cleanup
- Never abort cleanup process

### 4. Re-entrancy
- Destructor might allocate new objects
- Destructor might decRef other objects
- Need to mark object as "being destroyed" to prevent re-entrant destruction

### 5. Weak References in Destructors
- Weak refs should be nullified AFTER destructor runs
- Destructor might want to notify weak ref holders

## Testing Strategy

### Test 1: Basic Destructor
```etch
type Resource = object {
    id: int;
};

fn ~(r: Resource) -> void {
    print("Destroying resource: ");
    print(r.id);
}

fn main() -> void {
    let r = new[Resource]{ id: 42 };
    // Destructor should run when r goes out of scope
}
```

Expected output:
```
Destroying resource:
42
```

### Test 2: Destructor with Field Access
```etch
type File = object {
    path: string;
    handle: int;
};

fn ~(f: File) -> void {
    print("Closing file: " + f.path);
}

fn main() -> void {
    let file = new[File]{ path: "test.txt", handle: 123 };
}
```

Expected output:
```
Closing file: test.txt
```

### Test 3: Multiple Objects
```etch
type Counter = object {
    value: int;
};

fn ~(c: Counter) -> void {
    print("Counter destroyed: ");
    print(c.value);
}

fn main() -> void {
    let c1 = new[Counter]{ value: 1 };
    let c2 = new[Counter]{ value: 2 };
    let c3 = new[Counter]{ value: 3 };
}
```

Expected output:
```
Counter destroyed: 1
Counter destroyed: 2
Counter destroyed: 3
```

### Test 4: Destructor with Child Objects
```etch
type Child = object {
    id: int;
};

type Parent = object {
    child: ref[Child];
};

fn ~(c: Child) -> void {
    print("Child destroyed: ");
    print(c.id);
}

fn ~(p: Parent) -> void {
    print("Parent destroyed");
}

fn main() -> void {
    let child = new[Child]{ id: 99 };
    let parent = new[Parent]{ child: child };
}
```

Expected output (order may vary):
```
Parent destroyed
Child destroyed: 99
```

## Open Questions

1. **Should destructors be allowed to access `self` as a ref?**
   - Probably NO - object is being destroyed
   - Can access fields but not get a new reference to self

2. **Can destructors allocate new refs?**
   - YES - but those are independent objects

3. **Can types have multiple destructors?**
   - NO - one destructor per type

4. **Can destructors be overloaded?**
   - NO - destructors are not regular functions

5. **What if type has no destructor but fields do?**
   - Field destructors run automatically when fields are freed
   - No special handling needed

## Implementation Order

1. ✅ Add `destructor` field to EtchType
2. Parse `fn ~(obj: Type)` syntax
3. Register destructor during typechecking
4. Extend HeapObject with destructor ID
5. Call destructor in freeObject
6. Write and test bytecode VM support
7. Implement C backend support
8. Write comprehensive tests
9. Document destructor feature

## Performance Considerations

- Destructor call adds overhead to deallocation
- Most objects won't have destructors
- Check `destructorFuncId` is fast (single int comparison)
- Destructor call creates temporary frame - acceptable overhead
- Alternative: inline small destructors (future optimization)
