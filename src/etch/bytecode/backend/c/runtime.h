// Etch C Runtime

#ifndef ETCH_RUNTIME_H
#define ETCH_RUNTIME_H

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <errno.h>

// Global constants
#ifndef ETCH_MAX_GLOBALS
#define ETCH_MAX_GLOBALS 256
#endif

#ifndef ETCH_MAX_HEAP_OBJECTS
#define ETCH_MAX_HEAP_OBJECTS 4096
#endif

#ifndef ETCH_MAX_FIELD_REFS
#define ETCH_MAX_FIELD_REFS 64
#endif

#ifndef ETCH_MAX_SCC_STACK
#define ETCH_MAX_SCC_STACK 256
#endif

#ifndef ETCH_MAX_DEFER_STACK
#define ETCH_MAX_DEFER_STACK 32
#endif

#ifndef ETCH_MAX_CALL_ARGS
#define ETCH_MAX_CALL_ARGS 256
#endif

#ifndef ETCH_MAX_DESTRUCTOR_STACK
#define ETCH_MAX_DESTRUCTOR_STACK 64
#endif

#ifndef ETCH_MAX_COROUTINES
#define ETCH_MAX_COROUTINES 256
#endif

#ifndef ETCH_MAX_CORO_REGISTERS
#define ETCH_MAX_CORO_REGISTERS 256
#endif

// Value types
typedef enum {
  ETCH_VK_INT, ETCH_VK_FLOAT, ETCH_VK_BOOL, ETCH_VK_CHAR, ETCH_VK_NIL,
  ETCH_VK_STRING, ETCH_VK_ARRAY, ETCH_VK_TABLE, ETCH_VK_ENUM,
  ETCH_VK_SOME, ETCH_VK_NONE, ETCH_VK_OK, ETCH_VK_ERR,
  ETCH_VK_REF, ETCH_VK_CLOSURE, ETCH_VK_WEAK, ETCH_VK_COROUTINE,
  ETCH_VK_TYPEDESC
} EtchVKind;

// Forward declarations
typedef struct EtchV EtchV;
typedef struct EtchVTableEntry EtchVTableEntry;
typedef struct EtchCoroutine EtchCoroutine;

// Value type (discriminated union) - defined early for use in other types
struct EtchV {
  EtchVKind kind;
  union {
    int64_t ival;
    double fval;
    bool bval;
    char cval;
    char* sval;
    struct {
      EtchV* data;
      size_t len;
      size_t cap;
    } aval;
    struct {
      EtchVTableEntry* entries;
      size_t len;
      size_t cap;
    } tval;
    EtchV* wrapped;  // For some/ok/error
    int refId;       // For ETCH_VK_REF - heap object ID
    int closureId;   // For ETCH_VK_CLOSURE - closure heap ID
    int weakId;      // For ETCH_VK_WEAK - weak reference ID
    int coroId;      // For ETCH_VK_COROUTINE - coroutine ID
    struct {
      int enumTypeId;      // Type ID for the enum
      int64_t enumIntVal;  // Integer value
      char* enumStringVal; // String value
    } enumVal;      // For ETCH_VK_ENUM - enum values
  };
};

// Table entry (defined after EtchV)
struct EtchVTableEntry {
  char* key;
  EtchV value;
};

// Heap object kinds
typedef enum {
  ETCH_HOK_SCALAR,
  ETCH_HOK_TABLE,
  ETCH_HOK_ARRAY,
  ETCH_HOK_WEAK,
  ETCH_HOK_CLOSURE
} EtchHeapObjectKind;

// Set for tracking references (simple implementation)
typedef struct {
  int refs[ETCH_MAX_FIELD_REFS];
  int count;
} RefSet;

// Destructor function pointer type
typedef EtchV (*EtchDestructorFn)(EtchV);

// Heap object
typedef struct {
  int id;
  int strongRefs;
  int weakRefs;
  bool marked;  // For cycle detection
  EtchHeapObjectKind kind;
  EtchDestructorFn destructor;  // Function to call when object is destroyed (can be NULL)
  union {
    EtchV scalarValue;  // For ETCH_HOK_SCALAR
    struct {
      EtchVTableEntry* entries;
      size_t len;
      size_t cap;
      RefSet fieldRefs;  // Track refs to other heap objects
    } table;  // For ETCH_HOK_TABLE
    struct {
      EtchV* elements;
      size_t len;
      RefSet elementRefs;  // Track refs to heap objects in array
    } array;  // For ETCH_HOK_ARRAY
    int targetId;  // For ETCH_HOK_WEAK - target object ID
    struct {
      int funcIdx;
      size_t captureCount;
      EtchV* captures;
      RefSet captureRefs;  // Track refs to captured heap objects
    } closure;  // For ETCH_HOK_CLOSURE
  };
} EtchHeapObject;

// Heap with cycle detection
EtchHeapObject etch_heap[ETCH_MAX_HEAP_OBJECTS];
int etch_next_heap_id = 1;

// Destructor reentrancy protection (per-instance tracking)
int etch_destructor_stack[ETCH_MAX_DESTRUCTOR_STACK];
int etch_destructor_stack_size = 0;

// Cycle detection (Tarjan's SCC algorithm)
typedef struct {
  int stack[ETCH_MAX_SCC_STACK];
  bool onStack[ETCH_MAX_HEAP_OBJECTS];
  int index[ETCH_MAX_HEAP_OBJECTS];
  int lowLink[ETCH_MAX_HEAP_OBJECTS];
  int stackSize;
  int currentIndex;
  int cyclesFound;
} EtchTarjanState;

// Coroutine support
typedef enum {
  CORO_READY,       // Created, not yet started
  CORO_RUNNING,     // Currently executing
  CORO_SUSPENDED,   // Yielded, can be resumed
  CORO_COMPLETED,   // Returned, cannot resume
  CORO_CLEANUP,     // Force executing defers before destruction
  CORO_DEAD         // Error or collected
} EtchCoroState;

struct EtchCoroutine {
  int id;                                    // Coroutine ID
  EtchCoroState state;                       // Current state of the coroutine
  int funcIdx;                               // Function index being executed (-1 for completed)
  int resumePC;                              // Label to resume from
  EtchV registers[ETCH_MAX_CORO_REGISTERS];  // Saved register state
  int numRegisters;                          // Number of registers in use
  EtchV yieldValue;                          // Last yielded value
  EtchV returnValue;                         // Final return value
  int deferStack[ETCH_MAX_DEFER_STACK];      // Saved defer stack
  int deferCount;                            // Number of defers on stack
  int deferReturnPC;                         // Saved defer return PC
};

// Coroutine storage
EtchCoroutine etch_coroutines[ETCH_MAX_COROUTINES];
int etch_next_coro_id = 0;
int etch_active_coro_id = -1;  // Currently executing coroutine (-1 = main)
int etch_coro_refcounts[ETCH_MAX_COROUTINES];

// Global variables table
typedef struct {
  char* name;
  EtchV value;
} EtchGlobalEntry;

EtchGlobalEntry etch_globals_table[ETCH_MAX_GLOBALS];
int etch_globals_count = 0;

// Forward declaration emitted by the generated code
EtchV etch_call_function_by_index(int funcIdx, EtchV* args, int numArgs);

// Forward declarations of helper functions
static inline EtchV etch_make_nil(void);
static inline EtchV etch_make_int(int64_t val);
static inline EtchV etch_make_float(double val);
static inline EtchV etch_make_bool(bool val);
static inline EtchV etch_make_char(char val);
static inline EtchV etch_make_none(void);
static inline EtchV etch_make_string(const char* val);
static inline EtchV etch_make_array(size_t cap);
static inline EtchV etch_make_table(void);
static inline EtchV etch_make_some(EtchV val);
static inline EtchV etch_make_ok(EtchV val);
static inline EtchV etch_make_err(EtchV val);
static inline EtchV etch_make_ref(int id);
static inline EtchV etch_make_weak(int id);
static inline EtchV etch_make_coroutine(int id);
static inline EtchV etch_make_enum(int typeId, int64_t intVal);
static inline EtchV etch_make_typedesc(const char* val);
static EtchV etch_value_retain(EtchV value);
static void etch_value_release(EtchV value);
__attribute__((noreturn)) static inline void etch_panic(const char* msg);

// Destructor stack functions
static inline bool etch_destructor_is_active(int id) {
  for (int i = 0; i < etch_destructor_stack_size; i++) {
    if (etch_destructor_stack[i] == id) {
      return true;
    }
  }
  return false;
}

static inline void etch_destructor_push(int id) {
  if (etch_destructor_stack_size < ETCH_MAX_DESTRUCTOR_STACK) {
    etch_destructor_stack[etch_destructor_stack_size++] = id;
  }
}

static inline void etch_destructor_pop(void) {
  if (etch_destructor_stack_size > 0) {
    etch_destructor_stack_size--;
  }
}

// Heap functions
static int etch_heap_alloc_scalar(EtchV val, EtchDestructorFn destructor);
static int etch_heap_alloc_table(EtchDestructorFn destructor);
static int etch_heap_alloc_array(size_t size);
static EtchV etch_heap_get_array_element(int id, size_t index);
static void etch_heap_set_array_element(int id, size_t index, EtchV value);
static int etch_heap_alloc_weak(int targetId);
static int etch_heap_alloc_closure(int funcIdx, EtchV* captures, size_t captureCount);
static void etch_heap_inc_ref(int id);
static void etch_heap_dec_ref(int id);
static EtchV etch_heap_get_scalar(int id);
static int etch_heap_weak_to_strong(int weakId);
static void etch_heap_track_ref(int parentId, EtchV childValue);
static void etch_heap_detect_cycles(void);
static void etch_heap_free_object(int id);
static EtchV etch_builtin_make_closure(EtchV funcIdxVal, EtchV captureArray);
static EtchV etch_builtin_invoke_closure(EtchV closureVal, EtchV* args, int numArgs);

// Coroutine functions
static int etch_coro_spawn(int funcIdx, EtchV* args, int numArgs);
static EtchV etch_coro_resume(int coroId);
static EtchV etch_coro_dispatch(int coroId);  // Actually call the coroutine function
static void etch_coro_yield(EtchV value);
static inline bool etch_coro_is_active(int coroId);
static void etch_coro_retain(int coroId);
static void etch_coro_release(int coroId);
static void etch_coro_cleanup(int coroId);

// Global variables functions
static bool etch_has_global(const char* name) {
  for (int i = 0; i < etch_globals_count; i++) {
    if (strcmp(etch_globals_table[i].name, name) == 0) {
      return true;
    }
  }
  return false;
}

static EtchV etch_get_global(const char* name) {
  for (int i = 0; i < etch_globals_count; i++) {
    if (strcmp(etch_globals_table[i].name, name) == 0) {
      return etch_globals_table[i].value;
    }
  }
  return etch_make_nil();
}

static void etch_set_global(const char* name, EtchV value) {
  // Check if global already exists
  for (int i = 0; i < etch_globals_count; i++) {
    if (strcmp(etch_globals_table[i].name, name) == 0) {
      etch_value_release(etch_globals_table[i].value);
      etch_globals_table[i].value = etch_value_retain(value);
      return;
    }
  }
  // Add new global
  if (etch_globals_count < ETCH_MAX_GLOBALS) {
    etch_globals_table[etch_globals_count].name = strdup(name);
    etch_globals_table[etch_globals_count].value = etch_value_retain(value);
    etch_globals_count++;
  }
}

// Panic
__attribute__((noreturn)) static inline void etch_panic(const char* msg) {
  fprintf(stderr, "%s\n", msg);
  exit(1);
}

// Value constructors
static inline EtchV etch_make_int(int64_t val) {
  EtchV v = {.kind = ETCH_VK_INT, .ival = val};
  return v;
}

static inline EtchV etch_make_float(double val) {
  EtchV v = {.kind = ETCH_VK_FLOAT, .fval = val};
  return v;
}

static inline EtchV etch_make_bool(bool val) {
  EtchV v = {.kind = ETCH_VK_BOOL, .bval = val};
  return v;
}

static inline EtchV etch_make_char(char val) {
  EtchV v = {.kind = ETCH_VK_CHAR, .cval = val};
  return v;
}

static inline EtchV etch_make_nil(void) {
  EtchV v = {.kind = ETCH_VK_NIL};
  return v;
}

static inline EtchV etch_make_none(void) {
  EtchV v = {.kind = ETCH_VK_NONE};
  return v;
}

static inline EtchV etch_make_string(const char* val) {
  EtchV v = {.kind = ETCH_VK_STRING};
  v.sval = strdup(val);
  return v;
}

static inline EtchV etch_make_array(size_t cap) {
  EtchV v = {.kind = ETCH_VK_ARRAY};
  v.aval.data = malloc(cap * sizeof(EtchV));
  v.aval.len = 0;
  v.aval.cap = cap;
  return v;
}

static inline EtchV etch_make_table(void) {
  EtchV v = {.kind = ETCH_VK_TABLE};
  v.tval.entries = NULL;
  v.tval.len = 0;
  v.tval.cap = 0;
  return v;
}

static inline EtchV etch_make_some(EtchV val) {
  EtchV v = {.kind = ETCH_VK_SOME};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_ok(EtchV val) {
  EtchV v = {.kind = ETCH_VK_OK};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_err(EtchV val) {
  EtchV v = {.kind = ETCH_VK_ERR};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_ref(int id) {
  EtchV v = {.kind = ETCH_VK_REF, .refId = id};
  return v;
}

static inline EtchV etch_make_closure(int id) {
  EtchV v = {.kind = ETCH_VK_CLOSURE, .closureId = id};
  return v;
}

static inline EtchV etch_make_weak(int id) {
  EtchV v = {.kind = ETCH_VK_WEAK, .weakId = id};
  return v;
}

static inline EtchV etch_make_coroutine(int id) {
  EtchV v = {.kind = ETCH_VK_COROUTINE, .coroId = id};
  return v;
}

// Forward declaration for recursive deep copy
static EtchV etch_value_deep_copy(EtchV val);

static EtchV etch_value_deep_copy(EtchV val) {
  switch (val.kind) {
    case ETCH_VK_NIL:
    case ETCH_VK_BOOL:
    case ETCH_VK_CHAR:
    case ETCH_VK_INT:
    case ETCH_VK_FLOAT:
    case ETCH_VK_REF:
    case ETCH_VK_WEAK:
    case ETCH_VK_COROUTINE:
    case ETCH_VK_CLOSURE:
      // These types are either value types or IDs - shallow copy is fine
      return etch_value_retain(val);

    case ETCH_VK_STRING:
      // Strings are ref-counted - retain is sufficient
      return etch_value_retain(val);

    case ETCH_VK_ARRAY: {
      // Deep copy array elements
      EtchV copy = {.kind = ETCH_VK_ARRAY};
      copy.aval.len = val.aval.len;
      copy.aval.cap = val.aval.cap;
      if (val.aval.cap > 0) {
        copy.aval.data = malloc(val.aval.cap * sizeof(EtchV));
        for (size_t i = 0; i < val.aval.len; i++) {
          copy.aval.data[i] = etch_value_deep_copy(val.aval.data[i]);
        }
      } else {
        copy.aval.data = NULL;
      }
      return copy;
    }

    case ETCH_VK_TABLE: {
      // Deep copy table entries
      EtchV copy = {.kind = ETCH_VK_TABLE};
      copy.tval.len = val.tval.len;
      copy.tval.cap = val.tval.cap;
      if (val.tval.cap > 0) {
        copy.tval.entries = malloc(val.tval.cap * sizeof(EtchVTableEntry));
        for (size_t i = 0; i < val.tval.len; i++) {
          copy.tval.entries[i].key = strdup(val.tval.entries[i].key);
          copy.tval.entries[i].value = etch_value_deep_copy(val.tval.entries[i].value);
        }
      } else {
        copy.tval.entries = NULL;
      }
      return copy;
    }

    case ETCH_VK_SOME:
    case ETCH_VK_OK:
    case ETCH_VK_ERR: {
      // Deep copy wrapped value
      EtchV copy = {.kind = val.kind};
      copy.wrapped = malloc(sizeof(EtchV));
      *copy.wrapped = etch_value_deep_copy(*val.wrapped);
      return copy;
    }

    default:
      etch_panic("Unknown value kind in etch_value_deep_copy");
      return etch_make_nil();
  }
}

static inline EtchV etch_make_enum(int typeId, int64_t intVal) {
  EtchV v = {.kind = ETCH_VK_ENUM};
  v.enumVal.enumTypeId = typeId;
  v.enumVal.enumIntVal = intVal;
  // For string value, we'll set it later using strdup
  v.enumVal.enumStringVal = NULL;
  return v;
}

static inline EtchV etch_make_typedesc(const char* val) {
  EtchV v = {.kind = ETCH_VK_TYPEDESC, .sval = (char*)val};
  return v;
}

// Find a free heap slot (reuse freed objects)
static int etch_heap_find_free_slot(void) {
  for (int i = 1; i < etch_next_heap_id; i++) {
    // Don't reuse slots for objects currently having destructors executed
    if (etch_heap[i].strongRefs == 0 && !etch_destructor_is_active(i)) {
      return i;
    }
  }
  return -1;  // No free slot found
}

// Heap management with cycle detection
static int etch_heap_alloc_scalar(EtchV val, EtchDestructorFn destructor) {
  int id;

  // Try to reuse a freed slot first
  id = etch_heap_find_free_slot();
  if (id < 0) {
    // No free slot, allocate new one
    if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
      etch_panic("Heap overflow");
    }
    id = etch_next_heap_id++;
  }

  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = ETCH_HOK_SCALAR;
  etch_heap[id].destructor = destructor;
  etch_heap[id].scalarValue = val;
  return id;
}

static int etch_heap_alloc_table(EtchDestructorFn destructor) {
  int id;

  // Try to reuse a freed slot first
  id = etch_heap_find_free_slot();
  if (id < 0) {
    // No free slot, allocate new one
    if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
      etch_panic("Heap overflow");
    }
    id = etch_next_heap_id++;
  }

  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = ETCH_HOK_TABLE;
  etch_heap[id].destructor = destructor;
  etch_heap[id].table.entries = NULL;
  etch_heap[id].table.len = 0;
  etch_heap[id].table.cap = 0;
  etch_heap[id].table.fieldRefs.count = 0;
  return id;
}

static int etch_heap_alloc_array(size_t size) {
  int id;

  // Try to reuse a freed slot first
  id = etch_heap_find_free_slot();
  if (id < 0) {
    // No free slot, allocate new one
    if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
      etch_panic("Heap overflow");
    }
    id = etch_next_heap_id++;
  }

  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = ETCH_HOK_ARRAY;
  etch_heap[id].destructor = NULL;  // Arrays don't have destructors (elements managed separately)

  // Allocate array elements
  etch_heap[id].array.elements = (EtchV*)calloc(size, sizeof(EtchV));
  if (!etch_heap[id].array.elements && size > 0) {
    etch_panic("Failed to allocate array elements");
  }
  etch_heap[id].array.len = size;
  etch_heap[id].array.elementRefs.count = 0;

  // Initialize all elements to nil
  for (size_t i = 0; i < size; i++) {
    etch_heap[id].array.elements[i] = etch_make_nil();
  }

  return id;
}

static EtchV etch_heap_get_array_element(int id, size_t index) {
  if (id <= 0 || id >= etch_next_heap_id || etch_heap[id].strongRefs == 0) {
    return etch_make_nil();
  }

  if (etch_heap[id].kind != ETCH_HOK_ARRAY) {
    return etch_make_nil();
  }

  if (index >= etch_heap[id].array.len) {
    return etch_make_nil();
  }

  return etch_heap[id].array.elements[index];
}

static void etch_heap_set_array_element(int id, size_t index, EtchV value) {
  if (id <= 0 || id >= etch_next_heap_id || etch_heap[id].strongRefs == 0) {
    return;
  }

  if (etch_heap[id].kind != ETCH_HOK_ARRAY) {
    return;
  }

  if (index >= etch_heap[id].array.len) {
    return;
  }

  // Release old value
  etch_value_release(etch_heap[id].array.elements[index]);

  // Set new value and retain it
  etch_heap[id].array.elements[index] = value;
  etch_value_retain(value);

  // Track reference if it's a heap object
  if (value.kind == ETCH_VK_REF || value.kind == ETCH_VK_WEAK) {
    etch_heap_track_ref(id, value);
  }
}

static int etch_heap_alloc_weak(int targetId) {
  if (targetId == 0) return 0;

  int id;

  // Try to reuse a freed slot first
  id = etch_heap_find_free_slot();
  if (id < 0) {
    // No free slot, allocate new one
    if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
      etch_panic("Heap overflow");
    }
    id = etch_next_heap_id++;
  }

  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = ETCH_HOK_WEAK;
  etch_heap[id].destructor = NULL;  // Weak refs don't have destructors
  etch_heap[id].targetId = targetId;
  if (targetId > 0 && targetId < etch_next_heap_id) {
    etch_heap[targetId].weakRefs++;
  }
  return id;
}

static int etch_heap_alloc_closure(int funcIdx, EtchV* captures, size_t captureCount) {
  int id = etch_heap_find_free_slot();
  if (id < 0) {
    if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
      etch_panic("Heap overflow");
    }
    id = etch_next_heap_id++;
  }

  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = ETCH_HOK_CLOSURE;
  etch_heap[id].destructor = NULL;
  etch_heap[id].closure.funcIdx = funcIdx;
  etch_heap[id].closure.captureCount = captureCount;
  etch_heap[id].closure.captureRefs.count = 0;
  if (captureCount > 0) {
    etch_heap[id].closure.captures = malloc(sizeof(EtchV) * captureCount);
    if (etch_heap[id].closure.captures == NULL) {
      etch_panic("Out of memory while allocating closure captures");
    }
    for (size_t i = 0; i < captureCount; i++) {
      EtchV val = etch_value_retain(captures[i]);
      etch_heap[id].closure.captures[i] = val;
      if (val.kind == ETCH_VK_REF) {
        RefSet* refs = &etch_heap[id].closure.captureRefs;
        if (refs->count < ETCH_MAX_FIELD_REFS) {
          refs->refs[refs->count++] = val.refId;
        }
      } else if (val.kind == ETCH_VK_CLOSURE) {
        RefSet* refs = &etch_heap[id].closure.captureRefs;
        if (refs->count < ETCH_MAX_FIELD_REFS) {
          refs->refs[refs->count++] = val.closureId;
        }
      }
    }
  } else {
    etch_heap[id].closure.captures = NULL;
  }
  return id;
}

static void etch_heap_inc_ref(int id) {
  if (id > 0 && id < etch_next_heap_id) {
    etch_heap[id].strongRefs++;
  }
}

static void etch_heap_free_object(int id) {
  if (id <= 0 || id >= etch_next_heap_id) return;
  EtchHeapObject* obj = &etch_heap[id];

  // Prevent recursive destructor calls on the SAME object (but allow nested destructors for different objects)
  if (etch_destructor_is_active(id)) {
    return;
  }

  // Call destructor if present
  if (obj->destructor != NULL && obj->kind == ETCH_HOK_SCALAR) {
    // Mark that we're in THIS object's destructor
    etch_destructor_push(id);
    // Call destructor with the scalar value
    obj->destructor(obj->scalarValue);
    // Remove this object from the destructor stack
    etch_destructor_pop();
  } else if (obj->destructor != NULL && obj->kind == ETCH_HOK_TABLE) {
    // Mark that we're in THIS object's destructor
    etch_destructor_push(id);
    // Call destructor with a ref to the table
    EtchV tableRef = etch_make_ref(id);
    obj->destructor(tableRef);
    // Remove this object from the destructor stack
    etch_destructor_pop();
  }

  // Free memory based on object kind
  if (obj->kind == ETCH_HOK_TABLE && obj->table.entries != NULL) {
    // Free table entries - decrement refcounts for values first
    for (size_t i = 0; i < obj->table.len; i++) {
      if (obj->table.entries[i].key != NULL) {
        etch_value_release(obj->table.entries[i].value);
        free(obj->table.entries[i].key);
      }
    }
    free(obj->table.entries);
    obj->table.entries = NULL;
    obj->table.len = 0;
    obj->table.cap = 0;
  }
  if (obj->kind == ETCH_HOK_ARRAY && obj->array.elements != NULL) {
    // Free array elements - decrement refcounts first
    for (size_t i = 0; i < obj->array.len; i++) {
      etch_value_release(obj->array.elements[i]);
    }
    free(obj->array.elements);
    obj->array.elements = NULL;
    obj->array.len = 0;
    obj->array.elementRefs.count = 0;
  }
  if (obj->kind == ETCH_HOK_CLOSURE && obj->closure.captures != NULL) {
    for (size_t i = 0; i < obj->closure.captureCount; i++) {
      EtchV cap = obj->closure.captures[i];
      etch_value_release(cap);
    }
    free(obj->closure.captures);
    obj->closure.captures = NULL;
    obj->closure.captureCount = 0;
    obj->closure.captureRefs.count = 0;
  }

  // Decrement weak reference counts on target if this was a weak ref
  if (obj->kind == ETCH_HOK_WEAK) {
    int targetId = obj->targetId;
    if (targetId > 0 && targetId < etch_next_heap_id) {
      etch_heap[targetId].weakRefs--;
    }
  }

  // Mark as freed
  obj->strongRefs = 0;
  obj->destructor = NULL;
}

static void etch_heap_dec_ref(int id) {
  if (id > 0 && id < etch_next_heap_id) {
    etch_heap[id].strongRefs--;
    if (etch_heap[id].strongRefs <= 0) {
      etch_heap_free_object(id);
    }
  }
}

static EtchV etch_value_retain(EtchV value) {
  if (value.kind == ETCH_VK_REF) {
    etch_heap_inc_ref(value.refId);
  } else if (value.kind == ETCH_VK_CLOSURE) {
    etch_heap_inc_ref(value.closureId);
  } else if (value.kind == ETCH_VK_COROUTINE) {
    etch_coro_retain(value.coroId);
  }
  return value;
}

static void etch_value_release(EtchV value) {
  if (value.kind == ETCH_VK_REF) {
    etch_heap_dec_ref(value.refId);
  } else if (value.kind == ETCH_VK_CLOSURE) {
    etch_heap_dec_ref(value.closureId);
  } else if (value.kind == ETCH_VK_COROUTINE) {
    etch_coro_release(value.coroId);
  } else if (value.kind == ETCH_VK_ARRAY) {
    // Release array elements (for arrays containing refs/closures/coroutines)
    for (size_t i = 0; i < value.aval.len; i++) {
      etch_value_release(value.aval.data[i]);
    }
    // Free the array data
    if (value.aval.data != NULL) {
      free(value.aval.data);
    }
  }
}

static EtchV etch_heap_get_scalar(int id) {
  if (id > 0 && id < etch_next_heap_id && etch_heap[id].kind == ETCH_HOK_SCALAR) {
    return etch_heap[id].scalarValue;
  }
  return etch_make_nil();
}

static int etch_heap_weak_to_strong(int weakId) {
  if (weakId > 0 && weakId < etch_next_heap_id && etch_heap[weakId].kind == ETCH_HOK_WEAK) {
    int targetId = etch_heap[weakId].targetId;
    if (targetId > 0 && targetId < etch_next_heap_id && etch_heap[targetId].strongRefs > 0) {
      etch_heap_inc_ref(targetId);
      return targetId;
    }
  }
  return 0;
}

// Track reference from parent to child
static void etch_heap_track_ref(int parentId, EtchV childValue) {
  if (parentId == 0) return;
  int childId = 0;
  if (childValue.kind == ETCH_VK_REF) {
    childId = childValue.refId;
  } else if (childValue.kind == ETCH_VK_CLOSURE) {
    childId = childValue.closureId;
  } else {
    return;
  }
  if (parentId <= 0 || parentId >= etch_next_heap_id) return;

  EtchHeapObject* parent = &etch_heap[parentId];
  if (parent->kind == ETCH_HOK_TABLE) {
    RefSet* refs = &parent->table.fieldRefs;
    // Check if already tracked
    for (int i = 0; i < refs->count; i++) {
      if (refs->refs[i] == childId) return;
    }
    // Add if space available
    if (refs->count < ETCH_MAX_FIELD_REFS) {
      refs->refs[refs->count++] = childId;
    }
  }
}

static EtchV etch_builtin_make_closure(EtchV funcIdxVal, EtchV captureArray) {
  if (funcIdxVal.kind != ETCH_VK_INT) {
    return etch_make_nil();
  }
  if (captureArray.kind != ETCH_VK_ARRAY) {
    return etch_make_nil();
  }

  size_t captureCount = captureArray.aval.len;
  EtchV* captureData = captureCount > 0 ? captureArray.aval.data : NULL;
  int closureId = etch_heap_alloc_closure((int)funcIdxVal.ival, captureData, captureCount);
  return etch_make_closure(closureId);
}

static EtchV etch_builtin_invoke_closure(EtchV closureVal, EtchV* args, int numArgs) {
  if (closureVal.kind != ETCH_VK_CLOSURE) {
    return etch_make_nil();
  }

  int closureId = closureVal.closureId;
  if (closureId <= 0 || closureId >= etch_next_heap_id) {
    return etch_make_nil();
  }

  EtchHeapObject* obj = &etch_heap[closureId];
  if (obj->kind != ETCH_HOK_CLOSURE) {
    return etch_make_nil();
  }

  size_t captureCount = obj->closure.captureCount;
  size_t userArgCount = 0;
  if (numArgs > 0) {
    if (args == NULL) {
      etch_panic("Invalid argument buffer for closure invocation");
    }
    userArgCount = (size_t)numArgs;
  }
  size_t totalArgs = captureCount + userArgCount;
  EtchV* callArgs = NULL;
  if (totalArgs > 0) {
    callArgs = malloc(sizeof(EtchV) * totalArgs);
    if (callArgs == NULL) {
      etch_panic("Out of memory while invoking closure");
    }
  }

  for (size_t i = 0; i < captureCount; i++) {
    callArgs[i] = obj->closure.captures[i];
  }
  for (size_t i = 0; i < userArgCount; i++) {
    callArgs[captureCount + i] = args[i];
  }

  EtchV result = etch_call_function_by_index(
    obj->closure.funcIdx,
    (totalArgs > 0 ? callArgs : NULL),
    (int)totalArgs
  );

  if (callArgs != NULL) {
    free(callArgs);
  }

  return result;
}

// Tarjan's SCC algorithm for cycle detection
static void etch_tarjan_strongconnect(int v, EtchTarjanState* state) {
  state->index[v] = state->currentIndex;
  state->lowLink[v] = state->currentIndex;
  state->currentIndex++;

  if (state->stackSize < ETCH_MAX_SCC_STACK) {
    state->stack[state->stackSize++] = v;
    state->onStack[v] = true;
  }

  // Get successors (children)
  RefSet* refs = NULL;
  if (etch_heap[v].kind == ETCH_HOK_TABLE) {
    refs = &etch_heap[v].table.fieldRefs;
  } else if (etch_heap[v].kind == ETCH_HOK_CLOSURE) {
    refs = &etch_heap[v].closure.captureRefs;
  }
  if (refs != NULL) {
    for (int i = 0; i < refs->count; i++) {
      int w = refs->refs[i];
      if (w <= 0 || w >= etch_next_heap_id) continue;

      if (state->index[w] == -1) {
        etch_tarjan_strongconnect(w, state);
        if (state->lowLink[w] < state->lowLink[v]) {
          state->lowLink[v] = state->lowLink[w];
        }
      } else if (state->onStack[w]) {
        if (state->index[w] < state->lowLink[v]) {
          state->lowLink[v] = state->index[w];
        }
      }
    }
  }

  // If v is a root node, pop the stack and report SCC
  if (state->lowLink[v] == state->index[v]) {
    int sccIds[ETCH_MAX_SCC_STACK];
    int sccSize = 0;
    int w;
    do {
      if (state->stackSize == 0) break;
      w = state->stack[--state->stackSize];
      state->onStack[w] = false;
      sccIds[sccSize++] = w;
    } while (w != v);

    // Report cycle if SCC has more than one node
    if (sccSize > 1) {
      printf("[HEAP] Cycle detected with %d objects: ", sccSize);
      for (int i = sccSize - 1; i >= 0; i--) {
        if (i < sccSize - 1) printf(", ");
        int objId = sccIds[i];
        const char* kindName = "unknown";
        if (objId > 0 && objId < etch_next_heap_id) {
          switch (etch_heap[objId].kind) {
            case ETCH_HOK_SCALAR: kindName = "hokScalar"; break;
            case ETCH_HOK_TABLE: kindName = "hokTable"; break;
            case ETCH_HOK_ARRAY: kindName = "hokArray"; break;
            case ETCH_HOK_WEAK: kindName = "hokWeak"; break;
            case ETCH_HOK_CLOSURE: kindName = "hokClosure"; break;
          }
        }
        printf("#%d (%s)", objId, kindName);
      }
      printf("\n");
      state->cyclesFound++;
    }
  }
}

// Mark an object and its children as reachable
static void etch_mark_object(int id) {
  if (id <= 0 || id >= etch_next_heap_id) return;
  if (etch_heap[id].strongRefs <= 0) return;
  if (etch_heap[id].marked) return;  // Already marked

  etch_heap[id].marked = true;

  // Recursively mark children
  if (etch_heap[id].kind == ETCH_HOK_TABLE) {
    RefSet* refs = &etch_heap[id].table.fieldRefs;
    for (int i = 0; i < refs->count; i++) {
      etch_mark_object(refs->refs[i]);
    }
  } else if (etch_heap[id].kind == ETCH_HOK_CLOSURE) {
    RefSet* refs = &etch_heap[id].closure.captureRefs;
    for (int i = 0; i < refs->count; i++) {
      etch_mark_object(refs->refs[i]);
    }
  }
  // Note: Arrays would also need marking if we tracked their refs
}

// Mark all objects reachable from a value
static void etch_mark_from_value(EtchV val) {
  if (val.kind == ETCH_VK_REF) {
    etch_mark_object(val.refId);
  } else if (val.kind == ETCH_VK_CLOSURE) {
    etch_mark_object(val.closureId);
  }
}

static void etch_heap_detect_cycles(void) {
  EtchTarjanState state;
  state.stackSize = 0;
  state.currentIndex = 0;
  state.cyclesFound = 0;

  // Initialize arrays
  for (int i = 0; i < ETCH_MAX_HEAP_OBJECTS; i++) {
    state.onStack[i] = false;
    state.index[i] = -1;
    state.lowLink[i] = -1;
  }

  // Run Tarjan's algorithm on all unvisited nodes
  for (int v = 1; v < etch_next_heap_id; v++) {
    if (etch_heap[v].strongRefs > 0 && state.index[v] == -1) {
      etch_tarjan_strongconnect(v, &state);
    }
  }
}

// Detect and collect cycles (mark-and-sweep approach)
// This should be called with all live registers to mark roots
static void etch_heap_collect_cycles(EtchV* registers, int numRegisters) {
  // First run cycle detection
  EtchTarjanState state;
  state.stackSize = 0;
  state.currentIndex = 0;
  state.cyclesFound = 0;

  // Initialize arrays
  for (int i = 0; i < ETCH_MAX_HEAP_OBJECTS; i++) {
    state.onStack[i] = false;
    state.index[i] = -1;
    state.lowLink[i] = -1;
    etch_heap[i].marked = false;  // Reset marks
  }

  // Collect cycle members during detection
  int cycleMembers[ETCH_MAX_HEAP_OBJECTS];
  int cycleCount = 0;

  // Run Tarjan's algorithm and collect cycle members
  for (int v = 1; v < etch_next_heap_id; v++) {
    if (etch_heap[v].strongRefs > 0 && state.index[v] == -1) {
      etch_tarjan_strongconnect(v, &state);
    }
  }

  if (state.cyclesFound == 0) {
    return;  // No cycles, nothing to collect
  }

  // Mark phase: mark all objects reachable from roots (registers + globals)
  for (int i = 0; i < numRegisters; i++) {
    etch_mark_from_value(registers[i]);
  }

  // Mark from global variables
  for (int i = 0; i < etch_globals_count; i++) {
    etch_mark_from_value(etch_globals_table[i].value);
  }

  // Sweep phase: free unmarked objects that have strongRefs > 0 (in cycles)
  // Collect IDs to free first (avoid modifying during iteration)
  int toFree[ETCH_MAX_HEAP_OBJECTS];
  int freeCount = 0;

  for (int i = 1; i < etch_next_heap_id; i++) {
    // If object is alive, unmarked, and has strong refs, it's in an unreachable cycle
    if (etch_heap[i].strongRefs > 0 && !etch_heap[i].marked) {
      toFree[freeCount++] = i;
    }
  }

  // Free the unreachable cyclic objects
  if (freeCount > 0) {
    for (int i = 0; i < freeCount; i++) {
      int id = toFree[i];
      if (etch_heap[id].strongRefs > 0) {
        etch_heap[id].strongRefs = 0;  // Prevent cascading decrements
        etch_heap_free_object(id);
      }
    }
  }
}

// Forward declarations for functions used in arithmetic operations
EtchV etch_concat_strings(EtchV a, EtchV b);

// Arithmetic operations
EtchV etch_add(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    return etch_make_int(a.ival + b.ival);
  } else if (a.kind == ETCH_VK_FLOAT || b.kind == ETCH_VK_FLOAT) {
    return etch_make_float(a.fval + b.fval);
  } else if (a.kind == ETCH_VK_STRING && b.kind == ETCH_VK_STRING) {
    return etch_concat_strings(a, b);
  }
  etch_panic("Type error in etch_add");
}

EtchV etch_sub(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    return etch_make_int(a.ival - b.ival);
  } else if (a.kind == ETCH_VK_FLOAT || b.kind == ETCH_VK_FLOAT) {
    return etch_make_float(a.fval - b.fval);
  }
  etch_panic("Type error in etch_sub");
}

EtchV etch_mul(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    return etch_make_int(a.ival * b.ival);
  } else if (a.kind == ETCH_VK_FLOAT || b.kind == ETCH_VK_FLOAT) {
    return etch_make_float(a.fval * b.fval);
  }
  etch_panic("Type error in etch_mul");
}

EtchV etch_div(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    assert(b.ival != 0);
    return etch_make_int(a.ival / b.ival);
  } else if (a.kind == ETCH_VK_FLOAT || b.kind == ETCH_VK_FLOAT) {
    assert(b.fval != 0.0);
    return etch_make_float(a.fval / b.fval);
  }
  etch_panic("Type error in etch_div");
}

EtchV etch_mod(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    assert(b.ival != 0);
    return etch_make_int(a.ival % b.ival);
  } else if (a.kind == ETCH_VK_FLOAT || b.kind == ETCH_VK_FLOAT) {
    assert(b.fval != 0.0);
    return etch_make_float(fmod(a.fval, b.fval));
  }
  etch_panic("Type error in etch_mod");
}

EtchV etch_pow(EtchV a, EtchV b) {
  double av = (a.kind == ETCH_VK_INT) ? (double)a.ival : a.fval;
  double bv = (b.kind == ETCH_VK_INT) ? (double)b.ival : b.fval;
  return etch_make_float(pow(av, bv));
}

EtchV etch_unm(EtchV a) {
  if (a.kind == ETCH_VK_INT) {
    return etch_make_int(-a.ival);
  } else if (a.kind == ETCH_VK_FLOAT) {
    return etch_make_float(-a.fval);
  }
  etch_panic("Type error in etch_unm");
}

// Helper to check if a weak reference is still valid
static inline bool etch_weak_is_valid(int weakId) {
  if (weakId <= 0 || weakId >= etch_next_heap_id) return false;
  if (etch_heap[weakId].kind != ETCH_HOK_WEAK) return false;
  int targetId = etch_heap[weakId].targetId;
  if (targetId <= 0 || targetId >= etch_next_heap_id) return false;
  return etch_heap[targetId].strongRefs > 0;
}

// Comparison operations
bool etch_eq(EtchV a, EtchV b) {
  // Special handling for weak references - compare based on validity
  if (a.kind == ETCH_VK_WEAK && b.kind == ETCH_VK_NIL) {
    return !etch_weak_is_valid(a.weakId);
  }
  if (a.kind == ETCH_VK_NIL && b.kind == ETCH_VK_WEAK) {
    return !etch_weak_is_valid(b.weakId);
  }

  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case ETCH_VK_INT: return a.ival == b.ival;
    case ETCH_VK_FLOAT: return a.fval == b.fval;
    case ETCH_VK_BOOL: return a.bval == b.bval;
    case ETCH_VK_CHAR: return a.cval == b.cval;
    case ETCH_VK_NIL: return true;
    case ETCH_VK_NONE: return true;
    case ETCH_VK_STRING: return strcmp(a.sval, b.sval) == 0;
    case ETCH_VK_ENUM:
      return a.enumVal.enumTypeId == b.enumVal.enumTypeId &&
             a.enumVal.enumIntVal == b.enumVal.enumIntVal;
    case ETCH_VK_TYPEDESC:
      return strcmp(a.sval, b.sval) == 0;
    case ETCH_VK_WEAK:
      // Two weak refs are equal if they point to the same target and both are valid
      return a.weakId == b.weakId;
    case ETCH_VK_REF:
      // Two refs are equal if they point to the same object
      return a.refId == b.refId;
    default: return false;
  }
}

bool etch_lt(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    return a.ival < b.ival;
  } else if (a.kind == ETCH_VK_FLOAT && b.kind == ETCH_VK_FLOAT) {
    return a.fval < b.fval;
  } else if (a.kind == ETCH_VK_CHAR && b.kind == ETCH_VK_CHAR) {
    return a.cval < b.cval;
  }
  etch_panic("Type error in etch_lt");
}

bool etch_le(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_INT && b.kind == ETCH_VK_INT) {
    return a.ival <= b.ival;
  } else if (a.kind == ETCH_VK_FLOAT && b.kind == ETCH_VK_FLOAT) {
    return a.fval <= b.fval;
  } else if (a.kind == ETCH_VK_CHAR && b.kind == ETCH_VK_CHAR) {
    return a.cval <= b.cval;
  }
  etch_panic("Type error in etch_le");
}

// Logical operations
EtchV etch_not(EtchV a) {
  if (a.kind == ETCH_VK_BOOL) {
    return etch_make_bool(!a.bval);
  }
  etch_panic("Type error in etch_not");
}

EtchV etch_and(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_BOOL && b.kind == ETCH_VK_BOOL) {
    return etch_make_bool(a.bval && b.bval);
  }
  etch_panic("Type error in etch_and");
}

EtchV etch_or(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_BOOL && b.kind == ETCH_VK_BOOL) {
    return etch_make_bool(a.bval || b.bval);
  }
  etch_panic("Type error in etch_or");
}

// Array operations
EtchV etch_get_index(EtchV container, EtchV idx) {
  assert(idx.kind == ETCH_VK_INT);
  int64_t i = idx.ival;

  if (container.kind == ETCH_VK_REF) {
    int id = container.refId;
    if (id > 0 && id < etch_next_heap_id && etch_heap[id].kind == ETCH_HOK_ARRAY) {
      assert(i >= 0 && (size_t)i < etch_heap[id].array.len);
      return etch_heap_get_array_element(id, (size_t)i);
    }
    etch_panic("Type error: ref is not an array");
  } else if (container.kind == ETCH_VK_ARRAY) {
    assert(i >= 0 && (size_t)i < container.aval.len);
    return container.aval.data[i];
  } else if (container.kind == ETCH_VK_STRING) {
    assert(i >= 0 && (size_t)i < strlen(container.sval));
    return etch_make_char(container.sval[i]);
  }

  etch_panic("Type error in etch_get_index, indexing requires array or string");
}

void etch_set_index(EtchV* arr, EtchV idx, EtchV val) {
  assert(idx.kind == ETCH_VK_INT);
  int64_t i = idx.ival;

  if (arr->kind == ETCH_VK_REF) {
    // Handle heap arrays: ref[array[T]]
    int id = arr->refId;
    if (id > 0 && id < etch_next_heap_id && etch_heap[id].kind == ETCH_HOK_ARRAY) {
      assert(i >= 0 && (size_t)i < etch_heap[id].array.len);
      etch_heap_set_array_element(id, (size_t)i, val);
      return;
    }
    etch_panic("Type error: ref is not an array");
  } else if (arr->kind == ETCH_VK_ARRAY) {
    assert(i >= 0 && (size_t)i < arr->aval.len);
    EtchV* slot = &arr->aval.data[i];
    etch_value_release(*slot);
    *slot = etch_value_retain(val);
  } else {
    etch_panic("Type error: not an array");
  }
}

EtchV etch_get_length(EtchV arr) {
  if (arr.kind == ETCH_VK_REF) {
    // Handle heap arrays: ref[array[T]]
    int id = arr.refId;
    if (id > 0 && id < etch_next_heap_id && etch_heap[id].kind == ETCH_HOK_ARRAY) {
      return etch_make_int((int64_t)etch_heap[id].array.len);
    }
    etch_panic("Type error: ref is not an array");
  } else if (arr.kind == ETCH_VK_ARRAY) {
    return etch_make_int((int64_t)arr.aval.len);
  } else if (arr.kind == ETCH_VK_STRING) {
    return etch_make_int((int64_t)strlen(arr.sval));
  }
  etch_panic("Type error in etch_get_length, length requires array or string");
}

// Array concatenation
EtchV etch_concat_array(EtchV left, EtchV right) {
  if (left.kind != ETCH_VK_ARRAY || right.kind != ETCH_VK_ARRAY) {
    etch_panic("Type error: concatenation requires two arrays");
  }

  size_t leftLen = left.aval.len;
  size_t rightLen = right.aval.len;
  size_t totalLen = leftLen + rightLen;

  EtchV result;
  result.kind = ETCH_VK_ARRAY;
  result.aval.len = totalLen;
  result.aval.cap = totalLen;
  result.aval.data = malloc(totalLen * sizeof(EtchV));

  // Bulk copy left array
  for (size_t i = 0; i < leftLen; i++) {
    result.aval.data[i] = left.aval.data[i];
  }

  // Bulk copy right array
  for (size_t i = 0; i < rightLen; i++) {
    result.aval.data[leftLen + i] = right.aval.data[i];
  }

  return result;
}

// String concatenation
EtchV etch_concat_strings(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_STRING && b.kind == ETCH_VK_STRING) {
    size_t len1 = strlen(a.sval);
    size_t len2 = strlen(b.sval);
    char* result = malloc(len1 + len2 + 1);
    strcpy(result, a.sval);
    strcat(result, b.sval);
    EtchV v = {.kind = ETCH_VK_STRING, .sval = result};
    return v;
  }
  etch_panic("Type error in etch_concat_strings, string concatenation requires strings");
}

// Array concatenation
EtchV etch_concat_arrays(EtchV a, EtchV b) {
  if (a.kind == ETCH_VK_ARRAY && b.kind == ETCH_VK_ARRAY) {
    size_t newLen = a.aval.len + b.aval.len;
    EtchV result = etch_make_array(newLen);
    for (size_t i = 0; i < a.aval.len; i++) {
      result.aval.data[i] = a.aval.data[i];
    }
    for (size_t i = 0; i < b.aval.len; i++) {
      result.aval.data[a.aval.len + i] = b.aval.data[i];
    }
    result.aval.len = newLen;
    return result;
  }
  etch_panic("Type error in etch_concat_arrays, array concatenation requires arrays");
}

// Table field access
EtchV etch_get_field(EtchV table, const char* fieldName) {
  // Handle heap references
  if (table.kind == ETCH_VK_REF) {
    int objId = table.refId;
    if (objId > 0 && objId < etch_next_heap_id && etch_heap[objId].kind == ETCH_HOK_TABLE) {
      // Get field from heap table
      for (size_t i = 0; i < etch_heap[objId].table.len; i++) {
        if (strcmp(etch_heap[objId].table.entries[i].key, fieldName) == 0) {
          return etch_heap[objId].table.entries[i].value;
        }
      }
      return etch_make_nil();
    }
  }

  // Linear search for field in regular table
  assert(table.kind == ETCH_VK_TABLE);
  for (size_t i = 0; i < table.tval.len; i++) {
    if (strcmp(table.tval.entries[i].key, fieldName) == 0) {
      return table.tval.entries[i].value;
    }
  }
  return etch_make_nil();  // Field not found
}

void etch_set_field(EtchV* table, const char* fieldName, EtchV value) {
  // Handle heap references
  if (table->kind == ETCH_VK_REF) {
    int objId = table->refId;
    if (objId > 0 && objId < etch_next_heap_id && etch_heap[objId].kind == ETCH_HOK_TABLE) {
      // Check if field already exists
      for (size_t i = 0; i < etch_heap[objId].table.len; i++) {
        if (strcmp(etch_heap[objId].table.entries[i].key, fieldName) == 0) {
          EtchV* slot = &etch_heap[objId].table.entries[i].value;
          etch_value_release(*slot);
          *slot = etch_value_retain(value);
          // Track reference for cycle detection
          etch_heap_track_ref(objId, value);
          return;
        }
      }
      // Add new field to heap table
      if (etch_heap[objId].table.len >= etch_heap[objId].table.cap) {
        size_t newCap = etch_heap[objId].table.cap == 0 ? 8 : etch_heap[objId].table.cap * 2;
        etch_heap[objId].table.entries = realloc(etch_heap[objId].table.entries, newCap * sizeof(EtchVTableEntry));
        etch_heap[objId].table.cap = newCap;
      }
      etch_heap[objId].table.entries[etch_heap[objId].table.len].key = strdup(fieldName);
      etch_heap[objId].table.entries[etch_heap[objId].table.len].value = etch_value_retain(value);
      etch_heap[objId].table.len++;
      // Track reference for cycle detection
      etch_heap_track_ref(objId, value);
      return;
    }
  }

  // Check if field already exists in regular table
  assert(table->kind == ETCH_VK_TABLE);
  for (size_t i = 0; i < table->tval.len; i++) {
    if (strcmp(table->tval.entries[i].key, fieldName) == 0) {
      EtchV* slot = &table->tval.entries[i].value;
      etch_value_release(*slot);
      *slot = etch_value_retain(value);
      return;
    }
  }
  // Add new field to regular table
  if (table->tval.len >= table->tval.cap) {
    size_t newCap = table->tval.cap == 0 ? 8 : table->tval.cap * 2;
    table->tval.entries = realloc(table->tval.entries, newCap * sizeof(EtchVTableEntry));
    table->tval.cap = newCap;
  }
  table->tval.entries[table->tval.len].key = strdup(fieldName);
  table->tval.entries[table->tval.len].value = etch_value_retain(value);
  table->tval.len++;
}

void etch_set_ref_value(EtchV refVal, EtchV value) {
  if (refVal.kind != ETCH_VK_REF) {
    etch_panic("Type error in etch_set_ref_value, target must be a ref");
  }
  int objId = refVal.refId;
  if (objId <= 0 || objId >= etch_next_heap_id || etch_heap[objId].kind != ETCH_HOK_SCALAR) {
    etch_panic("etch_set_ref_value expects a scalar heap object");
  }

  EtchV* slot = &etch_heap[objId].scalarValue;
  EtchV retained = etch_value_retain(value);
  etch_value_release(*slot);
  *slot = retained;
}

// String/array slicing
EtchV etch_slice_op(EtchV container, EtchV start_idx, EtchV end_idx) {
  if (container.kind == ETCH_VK_STRING) {
    if (start_idx.kind != ETCH_VK_INT || end_idx.kind != ETCH_VK_INT) {
      etch_panic("Type error in etch_slice_op, slice indices must be integers");
    }
    int64_t start = start_idx.ival;
    int64_t end = end_idx.ival;
    size_t len = strlen(container.sval);

    // Handle -1 as "until end"
    if (end < 0) end = len;
    if (start < 0) start = 0;
    if (end > (int64_t)len) end = len;
    if (start > end) start = end;

    size_t slice_len = end - start;
    char* result = malloc(slice_len + 1);
    strncpy(result, container.sval + start, slice_len);
    result[slice_len] = '\0';
    return etch_make_string(result);
  } else if (container.kind == ETCH_VK_ARRAY) {
    if (start_idx.kind != ETCH_VK_INT || end_idx.kind != ETCH_VK_INT) {
      etch_panic("Type error in etch_slice_op, slice indices must be integers");
    }
    int64_t start = start_idx.ival;
    int64_t end = end_idx.ival;

    // Handle -1 as "until end"
    if (end < 0) end = container.aval.len;
    if (start < 0) start = 0;
    if (end > (int64_t)container.aval.len) end = container.aval.len;
    if (start > end) start = end;

    size_t slice_len = end - start;
    EtchV result = etch_make_array(slice_len);
    for (size_t i = 0; i < slice_len; i++) {
      result.aval.data[i] = container.aval.data[start + i];
    }
    result.aval.len = slice_len;
    return result;
  }

  etch_panic("Type error in etch_slice_op, slice requires string or array");
}

// RNG state (global) - initialized to 1 to match VM default
static uint64_t etch_rng_state = 1;

void etch_srand(uint64_t seed) {
  // Avoid zero state (would produce all zeros)
  etch_rng_state = (seed == 0) ? 1 : seed;
}

uint64_t etch_rand(void) {
  // Xorshift64* algorithm (matches Nim VM implementation)
  uint64_t x = etch_rng_state;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  etch_rng_state = x;
  return x * 0x2545F4914F6CDD1DULL;  // Multiplication constant for better distribution
}

// File I/O
EtchV etch_read_file(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) {
    char errbuf[512];
    snprintf(errbuf, sizeof(errbuf), "unable to read from '%s': %s", path, strerror(errno));
    return etch_make_err(etch_make_string(errbuf));
  }

  if (fseek(f, 0, SEEK_END) != 0) {
    char errbuf[512];
    snprintf(errbuf, sizeof(errbuf), "unable to read from '%s': %s", path, strerror(errno));
    fclose(f);
    return etch_make_err(etch_make_string(errbuf));
  }
  long size = ftell(f);
  if (size < 0) {
    char errbuf[512];
    snprintf(errbuf, sizeof(errbuf), "unable to read from '%s': %s", path, strerror(errno));
    fclose(f);
    return etch_make_err(etch_make_string(errbuf));
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    char errbuf[512];
    snprintf(errbuf, sizeof(errbuf), "unable to read from '%s': %s", path, strerror(errno));
    fclose(f);
    return etch_make_err(etch_make_string(errbuf));
  }

  size_t allocSize = (size_t)size;
  char* buffer = malloc(allocSize + 1);
  if (!buffer) {
    fclose(f);
    return etch_make_err(etch_make_string("unable to allocate buffer for readFile"));
  }

  size_t readBytes = fread(buffer, 1, allocSize, f);
  if (ferror(f)) {
    char errbuf[512];
    snprintf(errbuf, sizeof(errbuf), "unable to read from '%s': %s", path, strerror(errno));
    free(buffer);
    fclose(f);
    return etch_make_err(etch_make_string(errbuf));
  }
  buffer[readBytes] = '\0';
  fclose(f);

  EtchV strVal = etch_make_string(buffer);
  free(buffer);
  return etch_make_ok(strVal);
}

// String to int parsing
EtchV etch_parse_int(const char* str) {
  char* endptr;
  errno = 0;
  long long val = strtoll(str, &endptr, 10);
  if (errno == ERANGE || endptr == str || *endptr != '\0') {
    char errbuf[256];
    snprintf(errbuf, sizeof(errbuf), "unable to parse int from '%s'", str);
    return etch_make_err(etch_make_string(errbuf));
  }
  return etch_make_ok(etch_make_int((int64_t)val));
}

// String to float parsing
EtchV etch_parse_float(const char* str) {
  char* endptr;
  errno = 0;
  double val = strtod(str, &endptr);
  if (errno == ERANGE || endptr == str || *endptr != '\0') {
    char errbuf[256];
    snprintf(errbuf, sizeof(errbuf), "unable to parse float from '%s'", str);
    return etch_make_err(etch_make_string(errbuf));
  }
  return etch_make_ok(etch_make_float(val));
}

// String to bool parsing
EtchV etch_parse_bool(const char* str) {
  if (strcmp(str, "true") == 0) {
    return etch_make_ok(etch_make_bool(true));
  } else if (strcmp(str, "false") == 0) {
    return etch_make_ok(etch_make_bool(false));
  }
  char errbuf[256];
  snprintf(errbuf, sizeof(errbuf), "unable to parse bool from '%s'", str);
  return etch_make_err(etch_make_string(errbuf));
}

// Value to string conversion
char* etch_to_string(EtchV val) {
  char buffer[1024];
  switch (val.kind) {
    case ETCH_VK_INT:
      snprintf(buffer, sizeof(buffer), "%lld", (long long)val.ival);
      return strdup(buffer);
    case ETCH_VK_FLOAT: {
      // Always include decimal point
      if (val.fval == (int64_t)val.fval) {
        snprintf(buffer, sizeof(buffer), "%.1f", val.fval);
      } else {
        snprintf(buffer, sizeof(buffer), "%g", val.fval);
        // If no decimal point and not scientific notation, add .0
        if (strchr(buffer, '.') == NULL && strchr(buffer, 'e') == NULL && strchr(buffer, 'E') == NULL) {
          strcat(buffer, ".0");
        }
      }
      return strdup(buffer);
    }
    case ETCH_VK_BOOL:
      return strdup(val.bval ? "true" : "false");
    case ETCH_VK_CHAR:
      snprintf(buffer, sizeof(buffer), "%c", val.cval);
      return strdup(buffer);
    case ETCH_VK_NIL:
      return strdup("nil");
    case ETCH_VK_NONE:
      return strdup("none");
    case ETCH_VK_STRING:
      return strdup(val.sval);
    case ETCH_VK_ENUM:
      if (val.enumVal.enumStringVal != NULL) {
        return strdup(val.enumVal.enumStringVal);
      } else {
        // Fallback to "EnumName.ValueName" format
        snprintf(buffer, sizeof(buffer), "EnumValue_%lld", (long long)val.enumVal.enumIntVal);
        return strdup(buffer);
      }
    case ETCH_VK_TYPEDESC:
      return strdup(val.sval);
    default:
      return strdup("<value>");
  }
}

// Membership operations
bool etch_in(EtchV elem, EtchV container) {
  if (container.kind == ETCH_VK_ARRAY) {
    for (size_t i = 0; i < container.aval.len; i++) {
      if (etch_eq(elem, container.aval.data[i])) {
        return true;
      }
    }
    return false;
  } else if (container.kind == ETCH_VK_STRING && elem.kind == ETCH_VK_CHAR) {
    for (size_t i = 0; i < strlen(container.sval); i++) {
      if (container.sval[i] == elem.cval) {
        return true;
      }
    }
    return false;
  } else if (container.kind == ETCH_VK_STRING && elem.kind == ETCH_VK_STRING) {
    return strstr(container.sval, elem.sval) != NULL;
  }
  return false;
}

// Type casting
EtchV etch_cast_value(EtchV val, EtchVKind target_kind) {
  if (val.kind == target_kind) return val;

  switch (target_kind) {
    case ETCH_VK_INT:
      if (val.kind == ETCH_VK_FLOAT) return etch_make_int((int64_t)val.fval);
      if (val.kind == ETCH_VK_BOOL) return etch_make_int(val.bval ? 1 : 0);
      if (val.kind == ETCH_VK_CHAR) return etch_make_int((int64_t)val.cval);
      if (val.kind == ETCH_VK_ENUM) return etch_make_int(val.enumVal.enumIntVal);
      if (val.kind == ETCH_VK_TYPEDESC) {
        uint64_t hash = 1469598103934665603ULL;
        const char* str = val.sval;
        while (*str) {
          hash ^= (uint64_t)(uint8_t)*str;
          hash *= 1099511628211ULL;
          str++;
        }
        return etch_make_int((int64_t)(hash & 0x7FFFFFFFULL));
      }
      break;
    case ETCH_VK_FLOAT:
      if (val.kind == ETCH_VK_INT) return etch_make_float((double)val.ival);
      break;
    case ETCH_VK_BOOL:
      if (val.kind == ETCH_VK_INT) return etch_make_bool(val.ival != 0);
      break;
    case ETCH_VK_CHAR:
      if (val.kind == ETCH_VK_INT) return etch_make_char((char)val.ival);
      break;
    case ETCH_VK_STRING:
      return etch_make_string(etch_to_string(val));
    default:
      break;
  }

  etch_panic("Invalid type cast");
}

// Print operation
void etch_print_value(EtchV val) {
  switch (val.kind) {
    case ETCH_VK_INT:
      printf("%lld", (long long)val.ival);
      break;
    case ETCH_VK_FLOAT: {
      // Always print floats with decimal point (X.Y format)
      if (val.fval == (int64_t)val.fval) {
        printf("%.1f", val.fval);  // Print as X.0 for whole numbers
      } else {
        // Use %g but ensure decimal point is present
        char buf[64];
        snprintf(buf, sizeof(buf), "%g", val.fval);
        printf("%s", buf);
        // If no decimal point and not scientific notation, add .0
        if (strchr(buf, '.') == NULL && strchr(buf, 'e') == NULL && strchr(buf, 'E') == NULL) {
          printf(".0");
        }
      }
      break;
    }
    case ETCH_VK_BOOL:
      printf("%s", val.bval ? "true" : "false");
      break;
    case ETCH_VK_CHAR:
      printf("%c", val.cval);
      break;
    case ETCH_VK_NIL:
      printf("nil");
      break;
    case ETCH_VK_NONE:
      printf("none");
      break;
    case ETCH_VK_STRING:
      printf("%s", val.sval);
      break;
    case ETCH_VK_SOME:
      printf("some(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case ETCH_VK_OK:
      printf("ok(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case ETCH_VK_ERR:
      printf("error(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case ETCH_VK_ARRAY:
      printf("[");
      for (size_t i = 0; i < val.aval.len; i++) {
        if (i > 0) printf(", ");
        // Special case for chars: print with quotes
        if (val.aval.data[i].kind == ETCH_VK_CHAR) {
          printf("'%c'", val.aval.data[i].cval);
        } else {
          etch_print_value(val.aval.data[i]);
        }
      }
      printf("]");
      break;
    case ETCH_VK_TABLE:
      printf("<table>");
      break;
    case ETCH_VK_REF:
      printf("<ref#%d>", val.refId);
      break;
    case ETCH_VK_CLOSURE:
      printf("<closure#%d>", val.closureId);
      break;
    case ETCH_VK_WEAK:
      printf("<weak#%d>", val.weakId);
      break;
    case ETCH_VK_COROUTINE:
      printf("<coroutine#%d>", val.coroId);
      break;
    case ETCH_VK_ENUM:
      if (val.enumVal.enumStringVal != NULL) {
        printf("%s", val.enumVal.enumStringVal);
      } else {
        printf("EnumValue_%lld", (long long)val.enumVal.enumIntVal);
      }
      break;
    case ETCH_VK_TYPEDESC:
      printf("%s", val.sval);
      break;
    default:
      printf("<value>");
      break;
  }
}

// Coroutine runtime implementations
static inline bool etch_coro_is_active(int coroId) {
  return coroId >= 0 && coroId < etch_next_coro_id && etch_coroutines[coroId].state != CORO_DEAD;
}

static void etch_coro_retain(int coroId) {
  if (coroId < 0 || coroId >= ETCH_MAX_COROUTINES) {
    return;
  }
  etch_coro_refcounts[coroId]++;
}

static void etch_coro_release(int coroId) {
  if (coroId < 0 || coroId >= ETCH_MAX_COROUTINES) {
    return;
  }
  if (etch_coro_refcounts[coroId] == 0) {
    return;
  }
  etch_coro_refcounts[coroId]--;
  if (etch_coro_refcounts[coroId] == 0) {
    etch_coro_cleanup(coroId);
  }
}

static int etch_coro_spawn(int funcIdx, EtchV* args, int numArgs) {
  if (etch_next_coro_id >= ETCH_MAX_COROUTINES) {
    etch_panic("Coroutine limit exceeded");
  }

  int coroId = etch_next_coro_id++;
  EtchCoroutine* coro = &etch_coroutines[coroId];

  coro->id = coroId;
  coro->state = CORO_READY;
  coro->funcIdx = funcIdx;
  coro->resumePC = 0;  // Will be set on first resume
  coro->numRegisters = 0;  // Will be set when function yields
  coro->deferCount = 0;  // Will be set when function yields
  coro->deferReturnPC = -1;

  // Copy arguments to coroutine registers
  for (int i = 0; i < numArgs && i < ETCH_MAX_CORO_REGISTERS; i++) {
    coro->registers[i] = args[i];
  }

  coro->yieldValue = etch_make_nil();
  coro->returnValue = etch_make_nil();

  etch_coro_refcounts[coroId] = 1;

  return coroId;
}

static EtchV etch_coro_resume(int coroId) {
  if (coroId < 0 || coroId >= etch_next_coro_id) {
    etch_panic("Invalid coroutine ID");
  }

  EtchCoroutine* coro = &etch_coroutines[coroId];

  if (coro->state == CORO_COMPLETED || coro->state == CORO_DEAD) {
    return coro->returnValue;
  }

  // Save previous active coroutine
  int prev_active = etch_active_coro_id;
  etch_active_coro_id = coroId;

  // Set state to running
  coro->state = CORO_RUNNING;

  // The actual resume will be handled by the generated code
  // This function just sets up the context

  return etch_make_nil();  // Will be replaced by yielded/returned value
}

static void etch_coro_yield(EtchV value) {
  if (etch_active_coro_id < 0) {
    etch_panic("Cannot yield from main context");
  }

  EtchCoroutine* coro = &etch_coroutines[etch_active_coro_id];
  coro->yieldValue = value;
  coro->state = CORO_SUSPENDED;

  // The actual yield (saving state and returning) is handled by generated code
}

static void etch_coro_cleanup(int coroId) {
  if (coroId < 0 || coroId >= etch_next_coro_id) {
    return;  // Invalid coroutine ID, nothing to clean up
  }

  EtchCoroutine* coro = &etch_coroutines[coroId];

  if (coro->state == CORO_DEAD) {
    return;  // Already cleaned up
  }

  // If coroutine has pending defers, execute them by resuming
  if (coro->deferCount > 0 && coro->state == CORO_SUSPENDED) {
    coro->state = CORO_CLEANUP;  // Mark as cleanup mode
    etch_active_coro_id = coroId;  // Set as active
    (void)etch_coro_dispatch(coroId);  // Dispatch to execute defers
    etch_active_coro_id = -1;  // Clear active
  }

  // DecRef all registers in the coroutine's saved state
  for (int i = 0; i < coro->numRegisters && i < ETCH_MAX_CORO_REGISTERS; i++) {
    etch_value_release(coro->registers[i]);
  }

  // Mark coroutine as dead
  coro->state = CORO_DEAD;
}

#endif
