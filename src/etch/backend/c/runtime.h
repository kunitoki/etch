// Etch C Runtime

#ifndef ETCH_RUNTIME_H
#define ETCH_RUNTIME_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// Global constants
#ifndef ETCH_MAX_GLOBALS
#define ETCH_MAX_GLOBALS 256
#endif

#ifndef ETCH_MAX_HEAP_OBJECTS
#define ETCH_MAX_HEAP_OBJECTS 1024
#endif

#ifndef ETCH_MAX_FIELD_REFS
#define ETCH_MAX_FIELD_REFS 64
#endif

#ifndef ETCH_MAX_SCC_STACK
#define ETCH_MAX_SCC_STACK 256
#endif

// Value types
typedef enum {
  VK_INT, VK_FLOAT, VK_BOOL, VK_CHAR, VK_NIL,
  VK_STRING, VK_ARRAY, VK_TABLE,
  VK_SOME, VK_NONE, VK_OK, VK_ERR,
  VK_REF, VK_WEAK
} EtchVKind;

// Forward declarations
typedef struct EtchV EtchV;
typedef struct EtchVTableEntry EtchVTableEntry;

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
    int refId;       // For VK_REF - heap object ID
    int weakId;      // For VK_WEAK - weak reference ID
  };
};

// Table entry (defined after EtchV)
struct EtchVTableEntry {
  char* key;
  EtchV value;
};

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
__attribute__((noreturn)) static inline void etch_panic(const char* msg);

// Heap object kinds
typedef enum {
  HOK_SCALAR, HOK_TABLE, HOK_ARRAY, HOK_WEAK
} HeapObjectKind;

// Set for tracking references (simple implementation)
typedef struct {
  int refs[ETCH_MAX_FIELD_REFS];
  int count;
} RefSet;

// Destructor function pointer type
typedef EtchV (*DestructorFn)(EtchV);

// Heap object
typedef struct {
  int id;
  int strongRefs;
  int weakRefs;
  bool marked;  // For cycle detection
  HeapObjectKind kind;
  DestructorFn destructor;  // Function to call when object is destroyed (can be NULL)
  union {
    EtchV scalarValue;  // For HOK_SCALAR
    struct {
      EtchVTableEntry* entries;
      size_t len;
      size_t cap;
      RefSet fieldRefs;  // Track refs to other heap objects
    } table;  // For HOK_TABLE
    int targetId;  // For HOK_WEAK - target object ID
  };
} HeapObject;

// Heap with cycle detection
HeapObject etch_heap[ETCH_MAX_HEAP_OBJECTS];
int etch_next_heap_id = 1;

// Cycle detection (Tarjan's SCC algorithm)
typedef struct {
  int stack[ETCH_MAX_SCC_STACK];
  bool onStack[ETCH_MAX_HEAP_OBJECTS];
  int index[ETCH_MAX_HEAP_OBJECTS];
  int lowLink[ETCH_MAX_HEAP_OBJECTS];
  int stackSize;
  int currentIndex;
  int cyclesFound;
} TarjanState;

// Heap functions
static int etch_heap_alloc_scalar(EtchV val, DestructorFn destructor);
static int etch_heap_alloc_table(DestructorFn destructor);
static int etch_heap_alloc_weak(int targetId);
static void etch_heap_inc_ref(int id);
static void etch_heap_dec_ref(int id);
static EtchV etch_heap_get_scalar(int id);
static int etch_heap_weak_to_strong(int weakId);
static void etch_heap_track_ref(int parentId, EtchV childValue);
static void etch_heap_detect_cycles(void);
static void etch_heap_free_object(int id);

// Global variables table
typedef struct {
  char* name;
  EtchV value;
} EtchGlobalEntry;

EtchGlobalEntry etch_globals_table[ETCH_MAX_GLOBALS];
int etch_globals_count = 0;

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
      etch_globals_table[i].value = value;
      return;
    }
  }
  // Add new global
  if (etch_globals_count < ETCH_MAX_GLOBALS) {
    etch_globals_table[etch_globals_count].name = strdup(name);
    etch_globals_table[etch_globals_count].value = value;
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
  EtchV v = {.kind = VK_INT, .ival = val};
  return v;
}

static inline EtchV etch_make_float(double val) {
  EtchV v = {.kind = VK_FLOAT, .fval = val};
  return v;
}

static inline EtchV etch_make_bool(bool val) {
  EtchV v = {.kind = VK_BOOL, .bval = val};
  return v;
}

static inline EtchV etch_make_char(char val) {
  EtchV v = {.kind = VK_CHAR, .cval = val};
  return v;
}

static inline EtchV etch_make_nil(void) {
  EtchV v = {.kind = VK_NIL};
  return v;
}

static inline EtchV etch_make_none(void) {
  EtchV v = {.kind = VK_NONE};
  return v;
}

static inline EtchV etch_make_string(const char* val) {
  EtchV v = {.kind = VK_STRING};
  v.sval = strdup(val);
  return v;
}

static inline EtchV etch_make_array(size_t cap) {
  EtchV v = {.kind = VK_ARRAY};
  v.aval.data = malloc(cap * sizeof(EtchV));
  v.aval.len = 0;
  v.aval.cap = cap;
  return v;
}

static inline EtchV etch_make_table(void) {
  EtchV v = {.kind = VK_TABLE};
  v.tval.entries = NULL;
  v.tval.len = 0;
  v.tval.cap = 0;
  return v;
}

static inline EtchV etch_make_some(EtchV val) {
  EtchV v = {.kind = VK_SOME};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_ok(EtchV val) {
  EtchV v = {.kind = VK_OK};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_err(EtchV val) {
  EtchV v = {.kind = VK_ERR};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

static inline EtchV etch_make_ref(int id) {
  EtchV v = {.kind = VK_REF, .refId = id};
  return v;
}

static inline EtchV etch_make_weak(int id) {
  EtchV v = {.kind = VK_WEAK, .weakId = id};
  return v;
}

// Heap management with cycle detection
static int etch_heap_alloc_scalar(EtchV val, DestructorFn destructor) {
  if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
    etch_panic("Heap overflow");
  }
  int id = etch_next_heap_id++;
  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = HOK_SCALAR;
  etch_heap[id].destructor = destructor;
  etch_heap[id].scalarValue = val;
  return id;
}

static int etch_heap_alloc_table(DestructorFn destructor) {
  if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
    etch_panic("Heap overflow");
  }
  int id = etch_next_heap_id++;
  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = HOK_TABLE;
  etch_heap[id].destructor = destructor;
  etch_heap[id].table.entries = NULL;
  etch_heap[id].table.len = 0;
  etch_heap[id].table.cap = 0;
  etch_heap[id].table.fieldRefs.count = 0;
  return id;
}

static int etch_heap_alloc_weak(int targetId) {
  if (targetId == 0) return 0;
  if (etch_next_heap_id >= ETCH_MAX_HEAP_OBJECTS) {
    etch_panic("Heap overflow");
  }
  int id = etch_next_heap_id++;
  etch_heap[id].id = id;
  etch_heap[id].strongRefs = 1;
  etch_heap[id].weakRefs = 0;
  etch_heap[id].marked = false;
  etch_heap[id].kind = HOK_WEAK;
  etch_heap[id].destructor = NULL;  // Weak refs don't have destructors
  etch_heap[id].targetId = targetId;
  if (targetId > 0 && targetId < etch_next_heap_id) {
    etch_heap[targetId].weakRefs++;
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
  HeapObject* obj = &etch_heap[id];

  // Call destructor if present
  if (obj->destructor != NULL && obj->kind == HOK_SCALAR) {
    // Call destructor with the scalar value
    obj->destructor(obj->scalarValue);
  } else if (obj->destructor != NULL && obj->kind == HOK_TABLE) {
    // Call destructor with a ref to the table
    EtchV tableRef = etch_make_ref(id);
    obj->destructor(tableRef);
  }

  // Free memory based on object kind
  if (obj->kind == HOK_TABLE && obj->table.entries != NULL) {
    // Free table entries
    for (size_t i = 0; i < obj->table.len; i++) {
      if (obj->table.entries[i].key != NULL) {
        free(obj->table.entries[i].key);
      }
    }
    free(obj->table.entries);
    obj->table.entries = NULL;
    obj->table.len = 0;
    obj->table.cap = 0;
  }

  // Decrement weak reference counts on target if this was a weak ref
  if (obj->kind == HOK_WEAK) {
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

static EtchV etch_heap_get_scalar(int id) {
  if (id > 0 && id < etch_next_heap_id && etch_heap[id].kind == HOK_SCALAR) {
    return etch_heap[id].scalarValue;
  }
  return etch_make_nil();
}

static int etch_heap_weak_to_strong(int weakId) {
  if (weakId > 0 && weakId < etch_next_heap_id && etch_heap[weakId].kind == HOK_WEAK) {
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
  if (parentId == 0 || childValue.kind != VK_REF) return;
  if (parentId <= 0 || parentId >= etch_next_heap_id) return;

  HeapObject* parent = &etch_heap[parentId];
  if (parent->kind == HOK_TABLE) {
    int childId = childValue.refId;
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

// Tarjan's SCC algorithm for cycle detection
static void tarjan_strongconnect(int v, TarjanState* state) {
  state->index[v] = state->currentIndex;
  state->lowLink[v] = state->currentIndex;
  state->currentIndex++;

  if (state->stackSize < ETCH_MAX_SCC_STACK) {
    state->stack[state->stackSize++] = v;
    state->onStack[v] = true;
  }

  // Get successors (children) from fieldRefs
  if (etch_heap[v].kind == HOK_TABLE) {
    RefSet* refs = &etch_heap[v].table.fieldRefs;
    for (int i = 0; i < refs->count; i++) {
      int w = refs->refs[i];
      if (w <= 0 || w >= etch_next_heap_id) continue;

      if (state->index[w] == -1) {
        tarjan_strongconnect(w, state);
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
            case HOK_SCALAR: kindName = "hokScalar"; break;
            case HOK_TABLE: kindName = "hokTable"; break;
            case HOK_ARRAY: kindName = "hokArray"; break;
            case HOK_WEAK: kindName = "hokWeak"; break;
          }
        }
        printf("#%d (%s)", objId, kindName);
      }
      printf("\n");
      state->cyclesFound++;
    }
  }
}

static void etch_heap_detect_cycles(void) {
  TarjanState state;
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
      tarjan_strongconnect(v, &state);
    }
  }
}

// Forward declarations for functions used in arithmetic operations
EtchV etch_concat_strings(EtchV a, EtchV b);

// Arithmetic operations
EtchV etch_add(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return etch_make_int(a.ival + b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av + bv);
  } else if (a.kind == VK_STRING && b.kind == VK_STRING) {
    return etch_concat_strings(a, b);
  }
  etch_panic("Type error in etch_add");
}

EtchV etch_sub(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return etch_make_int(a.ival - b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av - bv);
  }
  etch_panic("Type error in etch_sub");
}

EtchV etch_mul(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return etch_make_int(a.ival * b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av * bv);
  }
  etch_panic("Type error in etch_mul");
}

EtchV etch_div(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    if (b.ival == 0) {
      etch_panic("Division by zero");
    }
    return etch_make_int(a.ival / b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av / bv);
  }
  etch_panic("Type error in etch_div");
}

EtchV etch_mod(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    if (b.ival == 0) {
      etch_panic("Modulo by zero");
    }
    return etch_make_int(a.ival % b.ival);
  }
  etch_panic("Type error in etch_mod");
}

EtchV etch_pow(EtchV a, EtchV b) {
  double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
  double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
  return etch_make_float(pow(av, bv));
}

EtchV etch_unm(EtchV a) {
  if (a.kind == VK_INT) {
    return etch_make_int(-a.ival);
  } else if (a.kind == VK_FLOAT) {
    return etch_make_float(-a.fval);
  }
  etch_panic("Type error in etch_unm");
}

// Helper to check if a weak reference is still valid
static inline bool etch_weak_is_valid(int weakId) {
  if (weakId <= 0 || weakId >= etch_next_heap_id) return false;
  if (etch_heap[weakId].kind != HOK_WEAK) return false;
  int targetId = etch_heap[weakId].targetId;
  if (targetId <= 0 || targetId >= etch_next_heap_id) return false;
  return etch_heap[targetId].strongRefs > 0;
}

// Comparison operations
bool etch_eq(EtchV a, EtchV b) {
  // Special handling for weak references - compare based on validity
  if (a.kind == VK_WEAK && b.kind == VK_NIL) {
    return !etch_weak_is_valid(a.weakId);
  }
  if (a.kind == VK_NIL && b.kind == VK_WEAK) {
    return !etch_weak_is_valid(b.weakId);
  }

  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case VK_INT: return a.ival == b.ival;
    case VK_FLOAT: return a.fval == b.fval;
    case VK_BOOL: return a.bval == b.bval;
    case VK_CHAR: return a.cval == b.cval;
    case VK_NIL: return true;
    case VK_NONE: return true;
    case VK_STRING: return strcmp(a.sval, b.sval) == 0;
    case VK_WEAK:
      // Two weak refs are equal if they point to the same target and both are valid
      return a.weakId == b.weakId;
    case VK_REF:
      // Two refs are equal if they point to the same object
      return a.refId == b.refId;
    default: return false;
  }
}

bool etch_lt(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return a.ival < b.ival;
  } else if ((a.kind == VK_INT || a.kind == VK_FLOAT) &&
             (b.kind == VK_INT || b.kind == VK_FLOAT)) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return av < bv;
  }
  etch_panic("Type error in etch_lt");
}

bool etch_le(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return a.ival <= b.ival;
  } else if ((a.kind == VK_INT || a.kind == VK_FLOAT) &&
             (b.kind == VK_INT || b.kind == VK_FLOAT)) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return av <= bv;
  }
  etch_panic("Type error in etch_le");
}

// Logical operations
EtchV etch_not(EtchV a) {
  if (a.kind == VK_BOOL) {
    return etch_make_bool(!a.bval);
  }
  etch_panic("Type error in etch_not");
}

EtchV etch_and(EtchV a, EtchV b) {
  if (a.kind == VK_BOOL && b.kind == VK_BOOL) {
    return etch_make_bool(a.bval && b.bval);
  }
  etch_panic("Type error in etch_and");
}

EtchV etch_or(EtchV a, EtchV b) {
  if (a.kind == VK_BOOL && b.kind == VK_BOOL) {
    return etch_make_bool(a.bval || b.bval);
  }
  etch_panic("Type error in etch_or");
}

// Array operations
EtchV etch_get_index(EtchV container, EtchV idx) {
  if (idx.kind != VK_INT) {
    etch_panic("Type error: index must be int");
  }
  int64_t i = idx.ival;

  if (container.kind == VK_ARRAY) {
    if (i < 0 || (size_t)i >= container.aval.len) {
      etch_panic("Index out of bounds");
    }
    return container.aval.data[i];
  } else if (container.kind == VK_STRING) {
    size_t len = strlen(container.sval);
    if (i < 0 || (size_t)i >= len) {
      etch_panic("Index out of bounds");
    }
    return etch_make_char(container.sval[i]);
  }

  etch_panic("Type error in etch_get_index, indexing requires array or string");
}

void etch_set_index(EtchV* arr, EtchV idx, EtchV val) {
  if (arr->kind != VK_ARRAY) {
    etch_panic("Type error: not an array");
  }
  if (idx.kind != VK_INT) {
    etch_panic("Type error: index must be int");
  }
  int64_t i = idx.ival;
  if (i < 0 || (size_t)i >= arr->aval.len) {
    etch_panic("Index out of bounds");
  }
  arr->aval.data[i] = val;
}

EtchV etch_get_length(EtchV arr) {
  if (arr.kind == VK_ARRAY) {
    return etch_make_int((int64_t)arr.aval.len);
  } else if (arr.kind == VK_STRING) {
    return etch_make_int((int64_t)strlen(arr.sval));
  }
  etch_panic("Type error in etch_get_length, length requires array or string");
}

// String concatenation
EtchV etch_concat_strings(EtchV a, EtchV b) {
  if (a.kind == VK_STRING && b.kind == VK_STRING) {
    size_t len1 = strlen(a.sval);
    size_t len2 = strlen(b.sval);
    char* result = malloc(len1 + len2 + 1);
    strcpy(result, a.sval);
    strcat(result, b.sval);
    EtchV v = {.kind = VK_STRING, .sval = result};
    return v;
  }
  etch_panic("Type error in etch_concat_strings, string concatenation requires strings");
}

// Array concatenation
EtchV etch_concat_arrays(EtchV a, EtchV b) {
  if (a.kind == VK_ARRAY && b.kind == VK_ARRAY) {
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
  if (table.kind == VK_REF) {
    int objId = table.refId;
    if (objId > 0 && objId < etch_next_heap_id && etch_heap[objId].kind == HOK_TABLE) {
      // Get field from heap table
      for (size_t i = 0; i < etch_heap[objId].table.len; i++) {
        if (strcmp(etch_heap[objId].table.entries[i].key, fieldName) == 0) {
          return etch_heap[objId].table.entries[i].value;
        }
      }
      return etch_make_nil();
    }
  }

  if (table.kind != VK_TABLE) {
    etch_panic("Type error in etch_get_field, field access requires table");
  }
  // Linear search for field in regular table
  for (size_t i = 0; i < table.tval.len; i++) {
    if (strcmp(table.tval.entries[i].key, fieldName) == 0) {
      return table.tval.entries[i].value;
    }
  }
  return etch_make_nil();  // Field not found
}

void etch_set_field(EtchV* table, const char* fieldName, EtchV value) {
  // Handle heap references
  if (table->kind == VK_REF) {
    int objId = table->refId;
    if (objId > 0 && objId < etch_next_heap_id && etch_heap[objId].kind == HOK_TABLE) {
      // Check if field already exists
      for (size_t i = 0; i < etch_heap[objId].table.len; i++) {
        if (strcmp(etch_heap[objId].table.entries[i].key, fieldName) == 0) {
          etch_heap[objId].table.entries[i].value = value;
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
      etch_heap[objId].table.entries[etch_heap[objId].table.len].value = value;
      etch_heap[objId].table.len++;
      // Track reference for cycle detection
      etch_heap_track_ref(objId, value);
      return;
    }
  }

  if (table->kind != VK_TABLE) {
    etch_panic("Type error in etch_set_field, field access requires table");
  }
  // Check if field already exists in regular table
  for (size_t i = 0; i < table->tval.len; i++) {
    if (strcmp(table->tval.entries[i].key, fieldName) == 0) {
      table->tval.entries[i].value = value;
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
  table->tval.entries[table->tval.len].value = value;
  table->tval.len++;
}

// String/array slicing
EtchV etch_slice_op(EtchV container, EtchV start_idx, EtchV end_idx) {
  if (container.kind == VK_STRING) {
    if (start_idx.kind != VK_INT || end_idx.kind != VK_INT) {
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
  } else if (container.kind == VK_ARRAY) {
    if (start_idx.kind != VK_INT || end_idx.kind != VK_INT) {
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
  FILE* f = fopen(path, "r");
  if (!f) {
    return etch_make_string("");
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* buffer = malloc(size + 1);
  fread(buffer, 1, size, f);
  buffer[size] = '\0';
  fclose(f);
  return etch_make_string(buffer);
}

// String to int parsing
EtchV etch_parse_int(const char* str) {
  char* endptr;
  long long val = strtoll(str, &endptr, 10);
  if (endptr == str || *endptr != '\0') {
    return etch_make_none();
  }
  return etch_make_some(etch_make_int((int64_t)val));
}

// String to float parsing
EtchV etch_parse_float(const char* str) {
  char* endptr;
  double val = strtod(str, &endptr);
  if (endptr == str || *endptr != '\0') {
    return etch_make_none();
  }
  return etch_make_some(etch_make_float(val));
}

// String to bool parsing
EtchV etch_parse_bool(const char* str) {
  if (strcmp(str, "true") == 0) {
    return etch_make_some(etch_make_bool(true));
  } else if (strcmp(str, "false") == 0) {
    return etch_make_some(etch_make_bool(false));
  }
  return etch_make_none();
}

// Value to string conversion
char* etch_to_string(EtchV val) {
  char buffer[1024];
  switch (val.kind) {
    case VK_INT:
      snprintf(buffer, sizeof(buffer), "%lld", (long long)val.ival);
      return strdup(buffer);
    case VK_FLOAT: {
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
    case VK_BOOL:
      return strdup(val.bval ? "true" : "false");
    case VK_CHAR:
      snprintf(buffer, sizeof(buffer), "%c", val.cval);
      return strdup(buffer);
    case VK_NIL:
      return strdup("nil");
    case VK_NONE:
      return strdup("none");
    case VK_STRING:
      return strdup(val.sval);
    default:
      return strdup("<value>");
  }
}

// Membership operations
bool etch_in(EtchV elem, EtchV container) {
  if (container.kind == VK_ARRAY) {
    for (size_t i = 0; i < container.aval.len; i++) {
      if (etch_eq(elem, container.aval.data[i])) {
        return true;
      }
    }
    return false;
  } else if (container.kind == VK_STRING && elem.kind == VK_CHAR) {
    for (size_t i = 0; i < strlen(container.sval); i++) {
      if (container.sval[i] == elem.cval) {
        return true;
      }
    }
    return false;
  } else if (container.kind == VK_STRING && elem.kind == VK_STRING) {
    return strstr(container.sval, elem.sval) != NULL;
  }
  return false;
}

// Type casting
EtchV etch_cast_value(EtchV val, EtchVKind target_kind) {
  if (val.kind == target_kind) return val;

  switch (target_kind) {
    case VK_INT:
      if (val.kind == VK_FLOAT) return etch_make_int((int64_t)val.fval);
      if (val.kind == VK_BOOL) return etch_make_int(val.bval ? 1 : 0);
      if (val.kind == VK_CHAR) return etch_make_int((int64_t)val.cval);
      break;
    case VK_FLOAT:
      if (val.kind == VK_INT) return etch_make_float((double)val.ival);
      break;
    case VK_BOOL:
      if (val.kind == VK_INT) return etch_make_bool(val.ival != 0);
      break;
    case VK_CHAR:
      if (val.kind == VK_INT) return etch_make_char((char)val.ival);
      break;
    case VK_STRING:
      return etch_make_string(etch_to_string(val));
    default:
      break;
  }

  etch_panic("Invalid type cast");
}

// Print operation
void etch_print_value(EtchV val) {
  switch (val.kind) {
    case VK_INT:
      printf("%lld", (long long)val.ival);
      break;
    case VK_FLOAT: {
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
    case VK_BOOL:
      printf("%s", val.bval ? "true" : "false");
      break;
    case VK_CHAR:
      printf("%c", val.cval);
      break;
    case VK_NIL:
      printf("nil");
      break;
    case VK_NONE:
      printf("none");
      break;
    case VK_STRING:
      printf("%s", val.sval);
      break;
    case VK_SOME:
      printf("some(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case VK_OK:
      printf("ok(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case VK_ERR:
      printf("error(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case VK_ARRAY:
      printf("[");
      for (size_t i = 0; i < val.aval.len; i++) {
        if (i > 0) printf(", ");
        // Special case for chars: print with quotes
        if (val.aval.data[i].kind == VK_CHAR) {
          printf("'%c'", val.aval.data[i].cval);
        } else {
          etch_print_value(val.aval.data[i]);
        }
      }
      printf("]");
      break;
    case VK_TABLE:
      printf("<table>");
      break;
    case VK_REF:
      printf("<ref#%d>", val.refId);
      break;
    case VK_WEAK:
      printf("<weak#%d>", val.weakId);
      break;
    default:
      printf("<value>");
      break;
  }
}

#endif
