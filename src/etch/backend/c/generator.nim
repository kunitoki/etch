# generator.nim
# C backend generator for Etch Register VM bytecode

import std/[tables, strformat, strutils]
import ../../common/[constants]
import ../../interpreter/[regvm]

type
  CGenerator* = object
    output: string
    indent: int
    labelCounter: int
    program: RegBytecodeProgram
    deferTargets: seq[int]  # Target PCs for defer blocks in current function
    execDefersLocations: seq[int]  # PCs where ExecDefers is called

proc newCGenerator*(program: RegBytecodeProgram): CGenerator =
  CGenerator(output: "", indent: 0, labelCounter: 0, program: program, deferTargets: @[], execDefersLocations: @[])

proc emit(gen: var CGenerator, code: string) =
  gen.output.add(repeat("  ", gen.indent) & code & "\n")

proc incIndent(gen: var CGenerator) =
  inc gen.indent

proc decIndent(gen: var CGenerator) =
  dec gen.indent

proc sanitizeFunctionName(name: string): string =
  ## Sanitize function names for C by replacing operators with descriptive names
  ## Process multi-char operators first to avoid collisions
  result = name.multiReplace([
    ("==", "_eq_"), ("!=", "_ne_"), ("<=", "_le_"), (">=", "_ge_"),
    ("<", "_lt_"), (">", "_gt_"), ("::", "_scope_"), (":", "_"),
    ("+", "_plus_"), ("-", "_minus_"), ("*", "_mul_"), ("/", "_div_"),
    ("%", "_mod_"), ("!", "_not_"), ("&", "_and_"), ("|", "_or_"),
    ("^", "_xor_"), ("~", "_bnot_"), ("[", "_lbr_"), ("]", "_rbr_"),
    ("(", "_lp_"), (")", "_rp_"), (".", "_dot_"), (",", "_comma_"),
    (" ", "_"), ("=", "_assign_")
  ])

proc emitCRuntime(gen: var CGenerator) =
  ## Emit the C runtime header with EtchV type implementation
  gen.emit("""
// Etch C Runtime
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// Value types
typedef enum {
  VK_INT, VK_FLOAT, VK_BOOL, VK_CHAR, VK_NIL,
  VK_STRING, VK_ARRAY, VK_TABLE,
  VK_SOME, VK_NONE, VK_OK, VK_ERR
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
    EtchV* wrapped;  // For Some/Ok/Err
  };
};

// Table entry (defined after EtchV)
struct EtchVTableEntry {
  char* key;
  EtchV value;
};

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

EtchV etch_make_string(const char* val) {
  EtchV v = {.kind = VK_STRING};
  v.sval = strdup(val);
  return v;
}

EtchV etch_make_array(size_t cap) {
  EtchV v = {.kind = VK_ARRAY};
  v.aval.data = malloc(cap * sizeof(EtchV));
  v.aval.len = 0;
  v.aval.cap = cap;
  return v;
}

EtchV etch_make_table(void) {
  EtchV v = {.kind = VK_TABLE};
  v.tval.entries = NULL;
  v.tval.len = 0;
  v.tval.cap = 0;
  return v;
}

// Global variables table
#define ETCH_MAX_GLOBALS 256
typedef struct {
  char* name;
  EtchV value;
} EtchGlobalEntry;

EtchGlobalEntry etch_globals_table[ETCH_MAX_GLOBALS];
int etch_globals_count = 0;

EtchV etch_get_global(const char* name) {
  for (int i = 0; i < etch_globals_count; i++) {
    if (strcmp(etch_globals_table[i].name, name) == 0) {
      return etch_globals_table[i].value;
    }
  }
  return etch_make_nil();
}

void etch_set_global(const char* name, EtchV value) {
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

EtchV etch_make_some(EtchV val) {
  EtchV v = {.kind = VK_SOME};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

EtchV etch_make_ok(EtchV val) {
  EtchV v = {.kind = VK_OK};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
}

EtchV etch_make_err(EtchV val) {
  EtchV v = {.kind = VK_ERR};
  v.wrapped = malloc(sizeof(EtchV));
  *v.wrapped = val;
  return v;
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
  fprintf(stderr, "Type error in etch_add\n");
  exit(1);
}

EtchV etch_sub(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return etch_make_int(a.ival - b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av - bv);
  }
  fprintf(stderr, "Type error in etch_sub\n");
  exit(1);
}

EtchV etch_mul(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    return etch_make_int(a.ival * b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av * bv);
  }
  fprintf(stderr, "Type error in etch_mul\n");
  exit(1);
}

EtchV etch_div(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    if (b.ival == 0) {
      fprintf(stderr, "Division by zero\n");
      exit(1);
    }
    return etch_make_int(a.ival / b.ival);
  } else if (a.kind == VK_FLOAT || b.kind == VK_FLOAT) {
    double av = (a.kind == VK_INT) ? (double)a.ival : a.fval;
    double bv = (b.kind == VK_INT) ? (double)b.ival : b.fval;
    return etch_make_float(av / bv);
  }
  fprintf(stderr, "Type error in etch_div\n");
  exit(1);
}

EtchV etch_mod(EtchV a, EtchV b) {
  if (a.kind == VK_INT && b.kind == VK_INT) {
    if (b.ival == 0) {
      fprintf(stderr, "Modulo by zero\n");
      exit(1);
    }
    return etch_make_int(a.ival % b.ival);
  }
  fprintf(stderr, "Type error in mod\n");
  exit(1);
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
  fprintf(stderr, "Type error in etch_unm\n");
  exit(1);
}

// Comparison operations
bool etch_eq(EtchV a, EtchV b) {
  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case VK_INT: return a.ival == b.ival;
    case VK_FLOAT: return a.fval == b.fval;
    case VK_BOOL: return a.bval == b.bval;
    case VK_CHAR: return a.cval == b.cval;
    case VK_NIL: return true;
    case VK_NONE: return true;
    case VK_STRING: return strcmp(a.sval, b.sval) == 0;
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
  fprintf(stderr, "Type error in etch_lt\n");
  exit(1);
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
  fprintf(stderr, "Type error in etch_le\n");
  exit(1);
}

// Logical operations
EtchV etch_not(EtchV a) {
  if (a.kind == VK_BOOL) {
    return etch_make_bool(!a.bval);
  }
  fprintf(stderr, "Type error in not\n");
  exit(1);
}

EtchV etch_and(EtchV a, EtchV b) {
  if (a.kind == VK_BOOL && b.kind == VK_BOOL) {
    return etch_make_bool(a.bval && b.bval);
  }
  fprintf(stderr, "Type error in and\n");
  exit(1);
}

EtchV etch_or(EtchV a, EtchV b) {
  if (a.kind == VK_BOOL && b.kind == VK_BOOL) {
    return etch_make_bool(a.bval || b.bval);
  }
  fprintf(stderr, "Type error in or\n");
  exit(1);
}

// Array operations
EtchV etch_get_index(EtchV container, EtchV idx) {
  if (idx.kind != VK_INT) {
    fprintf(stderr, "Type error: index must be int\n");
    exit(1);
  }
  int64_t i = idx.ival;

  if (container.kind == VK_ARRAY) {
    if (i < 0 || (size_t)i >= container.aval.len) {
      fprintf(stderr, "Index out of bounds\n");
      exit(1);
    }
    return container.aval.data[i];
  } else if (container.kind == VK_STRING) {
    size_t len = strlen(container.sval);
    if (i < 0 || (size_t)i >= len) {
      fprintf(stderr, "Index out of bounds\n");
      exit(1);
    }
    return etch_make_char(container.sval[i]);
  }

  fprintf(stderr, "Type error: indexing requires array or string\n");
  exit(1);
}

void etch_set_index(EtchV* arr, EtchV idx, EtchV val) {
  if (arr->kind != VK_ARRAY) {
    fprintf(stderr, "Type error: not an array\n");
    exit(1);
  }
  if (idx.kind != VK_INT) {
    fprintf(stderr, "Type error: index must be int\n");
    exit(1);
  }
  int64_t i = idx.ival;
  if (i < 0 || (size_t)i >= arr->aval.len) {
    fprintf(stderr, "Index out of bounds\n");
    exit(1);
  }
  arr->aval.data[i] = val;
}

EtchV etch_get_length(EtchV arr) {
  if (arr.kind == VK_ARRAY) {
    return etch_make_int((int64_t)arr.aval.len);
  } else if (arr.kind == VK_STRING) {
    return etch_make_int((int64_t)strlen(arr.sval));
  }
  fprintf(stderr, "Type error: len requires array or string\n");
  exit(1);
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
  fprintf(stderr, "Type error: string concatenation requires strings\n");
  exit(1);
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
  fprintf(stderr, "Type error: array concatenation requires arrays\n");
  exit(1);
}

// Table field access
EtchV etch_get_field(EtchV table, const char* fieldName) {
  if (table.kind != VK_TABLE) {
    fprintf(stderr, "Type error: field access requires table\n");
    exit(1);
  }
  // Linear search for field
  for (size_t i = 0; i < table.tval.len; i++) {
    if (strcmp(table.tval.entries[i].key, fieldName) == 0) {
      return table.tval.entries[i].value;
    }
  }
  return etch_make_nil();  // Field not found
}

void etch_set_field(EtchV* table, const char* fieldName, EtchV value) {
  if (table->kind != VK_TABLE) {
    fprintf(stderr, "Type error: field access requires table\n");
    exit(1);
  }
  // Check if field already exists
  for (size_t i = 0; i < table->tval.len; i++) {
    if (strcmp(table->tval.entries[i].key, fieldName) == 0) {
      table->tval.entries[i].value = value;
      return;
    }
  }
  // Add new field
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
      fprintf(stderr, "Type error: slice indices must be integers\n");
      exit(1);
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
      fprintf(stderr, "Type error: slice indices must be integers\n");
      exit(1);
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
  fprintf(stderr, "Type error: slice requires string or array\n");
  exit(1);
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
      return strdup("None");
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
  fprintf(stderr, "Invalid type cast\n");
  exit(1);
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
      printf("None");
      break;
    case VK_STRING:
      printf("%s", val.sval);
      break;
    case VK_SOME:
      printf("Some(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case VK_OK:
      printf("Ok(");
      etch_print_value(*val.wrapped);
      printf(")");
      break;
    case VK_ERR:
      printf("Err(");
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
    default:
      printf("<value>");
      break;
  }
}
""")

proc emitConstantPool(gen: var CGenerator) =
  ## Emit the constant pool as a C array
  let poolSize = max(1, gen.program.constants.len)
  gen.emit(&"\n// Constant pool ({gen.program.constants.len} etch_constants)")
  gen.emit(&"#define CONST_POOL_SIZE {poolSize}")
  gen.emit(&"EtchV etch_constants[{poolSize}];")
  gen.emit("\nvoid etch_init_constants(void) {")
  gen.incIndent()

  for i, constant in gen.program.constants:
    case constant.kind
    of vkInt:
      gen.emit(&"etch_constants[{i}] = etch_make_int({constant.ival});")
    of vkFloat:
      gen.emit(&"etch_constants[{i}] = etch_make_float({constant.fval});")
    of vkBool:
      gen.emit(&"etch_constants[{i}] = etch_make_bool({($constant.bval).toLowerAscii()});")
    of vkChar:
      let charRepr = if constant.cval == '\'': "\\'"
                     elif constant.cval == '\\': "\\\\"
                     else: $constant.cval
      gen.emit(&"etch_constants[{i}] = etch_make_char('{charRepr}');")
    of vkNil:
      gen.emit(&"etch_constants[{i}] = etch_make_nil();")
    of vkNone:
      gen.emit(&"etch_constants[{i}] = etch_make_none();")
    of vkString:
      # Escape string properly
      let escaped = constant.sval.multiReplace([("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\t", "\\t")])
      gen.emit(&"etch_constants[{i}] = etch_make_string(\"{escaped}\");")
    else:
      gen.emit(&"// TODO: Unsupported constant type: {constant.kind}")
      gen.emit(&"etch_constants[{i}] = etch_make_nil();")

  gen.decIndent()
  gen.emit("}")

proc emitCFFIDeclarations(gen: var CGenerator) =
  ## Emit forward declarations for CFFI functions
  if gen.program.cffiInfo.len == 0:
    return

  gen.emit("\n// CFFI forward declarations")
  for funcName, info in gen.program.cffiInfo:
    # Generate parameter list
    var params = ""
    if info.paramTypes.len > 0:
      for i, paramType in info.paramTypes:
        if i > 0:
          params &= ", "
        # Map TypeKind strings to C types
        case paramType
        of "tkInt":
          params &= "int64_t"
        of "tkFloat":
          params &= "double"
        of "tkBool":
          params &= "bool"
        of "tkChar":
          params &= "char"
        else:
          params &= "void*"  # Default to void* for unknown types
    else:
      params = "void"

    # Map return type
    let returnType = case info.returnType
    of "tkInt": "int64_t"
    of "tkFloat": "double"
    of "tkBool": "bool"
    of "tkChar": "char"
    of "tkVoid": "void"
    else: "void*"

    gen.emit(&"extern {returnType} {info.symbol}({params});")

proc emitInstruction(gen: var CGenerator, instr: RegInstruction, pc: int) =
  ## Emit C code for a single RegVM instruction
  let a = instr.a

  # Debug output for opType 1 instructions
  when defined(debug):
    if instr.opType == 1:
      echo &"DEBUG PC {pc}: {instr.op} with opType 1"

  case instr.op
  of ropLoadK:
    # LoadK can be either ABx (constant pool index) or AsBx (immediate value)
    if instr.opType == 1:  # ABx format - constant pool index
      let bx = instr.bx
      gen.emit(&"r[{a}] = etch_constants[{bx}];  // LoadK from constant pool")
    elif instr.opType == 2:  # AsBx format - immediate value
      let sbx = instr.sbx
      gen.emit(&"r[{a}] = etch_make_int({sbx});  // LoadK immediate")

  of ropMove:
    if instr.opType == 0:
      let b = instr.b
      gen.emit(&"r[{a}] = r[{b}];  // Move")
    else:
      gen.emit(&"// TODO: Move with opType {instr.opType}")

  of ropLoadBool:
    if instr.opType == 0:
      let b = instr.b
      let c = instr.c
      gen.emit(&"r[{a}] = etch_make_bool({($bool(b)).toLowerAscii()});  // LoadBool")
      if c != 0:
        gen.emit(&"goto L{pc + 2};  // Skip next instruction")
    else:
      gen.emit(&"// TODO: LoadBool with opType {instr.opType}")

  of ropLoadNil:
    if instr.opType == 0:
      let b = instr.b
      gen.emit(&"// LoadNil: R[{a}]..R[{b}] = nil")
      gen.emit(&"for (int i = {a}; i <= {b}; i++) r[i] = etch_make_nil();")
    else:
      gen.emit(&"r[{a}] = etch_make_nil();  // LoadNil (single)")

  of ropLoadNone:
    gen.emit(&"r[{a}] = etch_make_none();  // LoadNone")

  of ropAdd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"// Add (with string/array concat support)")
    gen.emit(&"if (r[{b}].kind == VK_STRING && r[{c}].kind == VK_STRING) {{")
    gen.emit(&"  r[{a}] = etch_concat_strings(r[{b}], r[{c}]);")
    gen.emit(&"}} else if (r[{b}].kind == VK_ARRAY && r[{c}].kind == VK_ARRAY) {{")
    gen.emit(&"  r[{a}] = etch_concat_arrays(r[{b}], r[{c}]);")
    gen.emit(&"}} else {{")
    gen.emit(&"  r[{a}] = etch_add(r[{b}], r[{c}]);")
    gen.emit(&"}}")

  of ropAddI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let imm = int8(instr.bx shr 8)
      gen.emit(&"r[{a}] = etch_add(r[{regIdx}], etch_make_int({imm}));  // AddI")
    else:
      gen.emit(&"// TODO: AddI with opType {instr.opType}")

  of ropSub:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_sub(r[{b}], r[{c}]);  // Sub")

  of ropSubI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let imm = int8(instr.bx shr 8)
      gen.emit(&"r[{a}] = etch_sub(r[{regIdx}], etch_make_int({imm}));  // SubI")
    else:
      gen.emit(&"// TODO: SubI with opType {instr.opType}")

  of ropMul:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mul(r[{b}], r[{c}]);  // Mul")

  of ropMulI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let imm = int8(instr.bx shr 8)
      gen.emit(&"r[{a}] = etch_mul(r[{regIdx}], etch_make_int({imm}));  // MulI")
    else:
      gen.emit(&"// TODO: MulI with opType {instr.opType}")

  of ropDiv:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_div(r[{b}], r[{c}]);  // Div")

  of ropMod:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_mod(r[{b}], r[{c}]);  // Mod")

  of ropPow:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_pow(r[{b}], r[{c}]);  // Pow")

  of ropUnm:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_unm(r[{b}]);  // Unm")

  of ropEq:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_eq" else: "!etch_eq"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Eq")

  of ropLt:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_lt" else: "!etch_lt"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Lt")

  of ropLe:
    let b = instr.b
    let c = instr.c
    # When a=0: skip if TRUE; when a≠0: skip if FALSE
    let cond = if a == 0: "etch_le" else: "!etch_le"
    gen.emit(&"if ({cond}(r[{b}], r[{c}])) goto L{pc + 2};  // Le")

  of ropEqStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_eq(r[{b}], r[{c}]));  // EqStore")

  of ropLtStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_lt(r[{b}], r[{c}]));  // LtStore")

  of ropLeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_le(r[{b}], r[{c}]));  // LeStore")

  of ropNeStore:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_eq(r[{b}], r[{c}]));  // NeStore")

  of ropNot:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_not(r[{b}]);  // Not")

  of ropAnd:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_and(r[{b}], r[{c}]);  // And")

  of ropOr:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_or(r[{b}], r[{c}]);  // Or")

  of ropJmp:
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"goto L{target};  // Jmp")

  of ropTest:
    let c = instr.c
    # isTrue = not nil AND not (bool and false)
    # When c=1: skip if NOT isTrue (skip if false or nil)
    # When c=0: skip if isTrue (skip if true)
    if c == 1:
      # Skip if value is nil or (bool and false)
      gen.emit(&"if (r[{a}].kind == VK_NIL || (r[{a}].kind == VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")
    else:
      # Skip if value is NOT nil and NOT (bool and false)
      gen.emit(&"if (r[{a}].kind != VK_NIL && !(r[{a}].kind == VK_BOOL && !r[{a}].bval)) goto L{pc + 2};  // Test")

  of ropNewArray:
    if instr.opType == 1:
      let size = instr.bx
      gen.emit(&"r[{a}] = etch_make_array({size});  // NewArray")
      gen.emit(&"r[{a}].aval.len = {size};  // Set array length")
      # Initialize all elements to nil
      gen.emit(&"for (size_t i = 0; i < {size}; i++) r[{a}].aval.data[i] = etch_make_nil();")
    else:
      gen.emit(&"// TODO: NewArray with opType {instr.opType}")

  of ropGetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_index(r[{b}], r[{c}]);  // GetIndex")

  of ropSetIndex:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_index(&r[{a}], r[{b}], r[{c}]);  // SetIndex")

  of ropGetIndexI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let idx = instr.bx shr 8
      gen.emit(&"r[{a}] = etch_get_index(r[{regIdx}], etch_make_int({idx}));  // GetIndexI")
    else:
      gen.emit(&"// TODO: GetIndexI with opType {instr.opType}")

  of ropSetIndexI:
    if instr.opType == 1:
      let regIdx = instr.bx and 0xFF
      let idx = instr.bx shr 8
      gen.emit(&"etch_set_index(&r[{a}], etch_make_int({idx}), r[{regIdx}]);  // SetIndexI")
    else:
      gen.emit(&"// TODO: SetIndexI with opType {instr.opType}")

  of ropLen:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_get_length(r[{b}]);  // Len")

  of ropWrapSome:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_some(r[{b}]);  // WrapSome")

  of ropWrapOk:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_ok(r[{b}]);  // WrapOk")

  of ropWrapErr:
    let b = instr.b
    gen.emit(&"r[{a}] = etch_make_err(r[{b}]);  // WrapErr")

  of ropReturn:
    # ropReturn: A = number of results, B = starting register
    # If A is 0, return nil; if A is 1, return r[B]
    if instr.opType == 0:  # ABC format
      let numResults = a
      let retReg = instr.b
      if numResults == 0:
        gen.emit(&"return etch_make_nil();  // Return (no value)")
      elif numResults == 1:
        gen.emit(&"return r[{retReg}];  // Return")
      else:
        gen.emit(&"// TODO: Multiple return values not yet supported")
        gen.emit(&"return r[{retReg}];  // Return first value")
    else:
      gen.emit(&"return etch_make_nil();  // Return (no value)")

  of ropExecDefers:
    gen.emit(&"// ExecDefers: execute all deferred blocks in LIFO order")
    gen.emit(&"if (__etch_defer_count > 0) {{")
    gen.emit(&"  defer_return_pc = {pc};  // Save return point")
    gen.emit(&"  int __etch_defer_pc = __etch_defer_stack[--__etch_defer_count];  // Pop defer")
    gen.emit(&"  switch (__etch_defer_pc) {{")
    # Generate case statements for all defer targets
    for target in gen.deferTargets:
      gen.emit(&"    case {target}: goto L{target};")
    gen.emit(&"  }}")
    gen.emit(&"}}")

  of ropPushDefer:
    if instr.opType == 2:  # AsBx format - signed offset
      let offset = instr.sbx
      let targetPC = pc + offset
      gen.emit(&"// PushDefer: register defer block at L{targetPC}")
      gen.emit(&"__etch_defer_stack[__etch_defer_count++] = {targetPC};")

  of ropDeferEnd:
    gen.emit(&"// DeferEnd: end of defer block")
    gen.emit(&"if (__etch_defer_count > 0) {{")
    gen.emit(&"  // More defers to execute")
    gen.emit(&"  int __etch_defer_pc = __etch_defer_stack[--__etch_defer_count];")
    gen.emit(&"  switch (__etch_defer_pc) {{")
    for target in gen.deferTargets:
      gen.emit(&"    case {target}: goto L{target};")
    gen.emit(&"  }}")
    gen.emit(&"}} else {{")
    gen.emit(&"  // All defers executed, return to saved PC")
    gen.emit(&"  switch (defer_return_pc) {{")
    # Generate cases for all ExecDefers locations (return points)
    for returnPC in gen.execDefersLocations:
      gen.emit(&"    case {returnPC}: goto L{returnPC};")
    gen.emit(&"    default: break;  // Should not reach here")
    gen.emit(&"  }}")
    gen.emit(&"}}")

  of ropSlice:
    let b = instr.b
    let c = instr.c
    # R[A] = R[B][R[C]:R[C+1]] - start index in R[C], end index in R[C+1]
    gen.emit(&"// Slice: R[{a}] = R[{b}][R[{c}]:R[{c+1}]]")
    gen.emit(&"r[{a}] = etch_slice_op(r[{b}], r[{c}], r[{c + 1}]);  // Slice")

  of ropNewTable:
    gen.emit(&"r[{a}] = etch_make_table();  // NewTable")

  of ropGetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_get_field(r[{b}], etch_constants[{c}].sval);  // GetField")

  of ropSetField:
    let b = instr.b
    let c = instr.c
    gen.emit(&"etch_set_field(&r[{b}], etch_constants[{c}].sval, r[{a}]);  // SetField")

  of ropCast:
    let b = instr.b
    let targetKind = instr.c  # VKind enum value
    gen.emit(&"r[{a}] = etch_cast_value(r[{b}], {targetKind});  // Cast")

  of ropTestTag:
    let tag = instr.b
    let vkind = VKind(tag)
    case vkind
    of vkInt:
      gen.emit(&"if (r[{a}].kind == VK_INT) goto L{pc + 2};  // TestTag Int - skip Jmp if match")
    of vkFloat:
      gen.emit(&"if (r[{a}].kind == VK_FLOAT) goto L{pc + 2};  // TestTag Float - skip Jmp if match")
    of vkBool:
      gen.emit(&"if (r[{a}].kind == VK_BOOL) goto L{pc + 2};  // TestTag Bool - skip Jmp if match")
    of vkChar:
      gen.emit(&"if (r[{a}].kind == VK_CHAR) goto L{pc + 2};  // TestTag Char - skip Jmp if match")
    of vkNil:
      gen.emit(&"if (r[{a}].kind == VK_NIL) goto L{pc + 2};  // TestTag Nil - skip Jmp if match")
    of vkString:
      gen.emit(&"if (r[{a}].kind == VK_STRING) goto L{pc + 2};  // TestTag String - skip Jmp if match")
    of vkArray:
      gen.emit(&"if (r[{a}].kind == VK_ARRAY) goto L{pc + 2};  // TestTag Array - skip Jmp if match")
    of vkTable:
      gen.emit(&"if (r[{a}].kind == VK_TABLE) goto L{pc + 2};  // TestTag Table - skip Jmp if match")
    of vkSome:
      gen.emit(&"if (r[{a}].kind == VK_SOME) goto L{pc + 2};  // TestTag Some - skip Jmp if match")
    of vkNone:
      gen.emit(&"if (r[{a}].kind == VK_NONE) goto L{pc + 2};  // TestTag None - skip Jmp if match")
    of vkOk:
      gen.emit(&"if (r[{a}].kind == VK_OK) goto L{pc + 2};  // TestTag Ok - skip Jmp if match")
    of vkErr:
      gen.emit(&"if (r[{a}].kind == VK_ERR) goto L{pc + 2};  // TestTag Err - skip Jmp if match")

  of ropUnwrapOption:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == VK_SOME) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapOption")

  of ropUnwrapResult:
    let b = instr.b
    gen.emit(&"r[{a}] = (r[{b}].kind == VK_OK || r[{b}].kind == VK_ERR) ? *r[{b}].wrapped : etch_make_nil();  // UnwrapResult (Ok or Err)")

  of ropIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(etch_in(r[{b}], r[{c}]));  // In")

  of ropNotIn:
    let b = instr.b
    let c = instr.c
    gen.emit(&"r[{a}] = etch_make_bool(!etch_in(r[{b}], r[{c}]));  // NotIn")

  of ropForPrep:
    # For loop preparation: set up loop variables
    # A = iterator variable, sBx = jump offset to loop end
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForPrep: setup for loop")
    gen.emit(&"if (r[{a}].kind == VK_INT && r[{a + 1}].kind == VK_INT) {{")
    gen.emit(&"  if (r[{a}].ival >= r[{a + 1}].ival) goto L{target};  // Empty range")
    gen.emit(&"}}")

  of ropForLoop:
    # For loop increment and test: increment iterator and check if done
    # A = iterator variable, sBx = jump offset back to loop start
    let offset = instr.sbx
    let target = pc + 1 + offset
    gen.emit(&"// ForLoop: increment and test")
    gen.emit(&"r[{a}].ival++;  // Increment iterator")
    gen.emit(&"if (r[{a}].ival < r[{a + 1}].ival) goto L{target};  // Continue loop")

  of ropCall:
    # Function call: A = result register, funcIdx = function index, numArgs = arg count
    if instr.opType == 4:
      let resultReg = a
      let funcIdx = instr.funcIdx
      let numArgs = instr.numArgs

      # Get function name from function table
      if int(funcIdx) < gen.program.functionTable.len:
        let funcName = gen.program.functionTable[int(funcIdx)]

        # Handle builtin functions
        case funcName
        of "print":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"etch_print_value(r[{argReg}]);  // Call print")
            gen.emit(&"printf(\"\\n\");")
            gen.emit(&"r[{resultReg}] = etch_make_nil();  // print returns nil")
          else:
            gen.emit(&"// TODO: print with {numArgs} args")

        of "seed":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_INT) {{")
            gen.emit(&"  etch_srand((uint64_t)r[{argReg}].ival);")
            gen.emit(&"}}")
            gen.emit(&"r[{resultReg}] = etch_make_nil();  // seed returns nil")

        of "rand":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t maxInt = r[{argReg}].ival;")
            gen.emit(&"  if (maxInt > 0) {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)maxInt));")
            gen.emit(&"  }} else {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"  }}")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"}}")
          elif numArgs == 2:
            let arg1Reg = resultReg + 1
            let arg2Reg = resultReg + 2
            gen.emit(&"if (r[{arg1Reg}].kind == VK_INT && r[{arg2Reg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t minInt = r[{arg1Reg}].ival;")
            gen.emit(&"  int64_t maxInt = r[{arg2Reg}].ival;")
            gen.emit(&"  int64_t range = maxInt - minInt;")
            gen.emit(&"  if (range > 0) {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int((int64_t)(etch_rand() % (uint64_t)range) + minInt);")
            gen.emit(&"  }} else {{")
            gen.emit(&"    r[{resultReg}] = etch_make_int(minInt);")
            gen.emit(&"  }}")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_int(0);")
            gen.emit(&"}}")

        of "toString":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_string(etch_to_string(r[{argReg}]));  // toString")

        of "readFile":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_read_file(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_string(\"\");")
            gen.emit(&"}}")

        of "parseInt":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_int(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "parseFloat":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_float(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "parseBool":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"if (r[{argReg}].kind == VK_STRING) {{")
            gen.emit(&"  r[{resultReg}] = etch_parse_bool(r[{argReg}].sval);")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_none();")
            gen.emit(&"}}")

        of "isSome":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_SOME);  // isSome")

        of "isNone":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_NONE);  // isNone")

        of "isOk":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_OK);  // isOk")

        of "isErr":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = etch_make_bool(r[{argReg}].kind == VK_ERR);  // isErr")

        of "arrayNew":
          if numArgs == 2:
            let sizeReg = resultReg + 1
            let defaultReg = resultReg + 2
            gen.emit(&"if (r[{sizeReg}].kind == VK_INT) {{")
            gen.emit(&"  int64_t size = r[{sizeReg}].ival;")
            gen.emit(&"  EtchV arr = etch_make_array(size);")
            gen.emit(&"  for (int64_t i = 0; i < size; i++) {{")
            gen.emit(&"    arr.aval.data[i] = r[{defaultReg}];")
            gen.emit(&"  }}")
            gen.emit(&"  arr.aval.len = size;")
            gen.emit(&"  r[{resultReg}] = arr;")
            gen.emit(&"}} else {{")
            gen.emit(&"  r[{resultReg}] = etch_make_array(0);")
            gen.emit(&"}}")

        of "new", "deref":
          if numArgs == 1:
            let argReg = resultReg + 1
            gen.emit(&"r[{resultReg}] = r[{argReg}];  // {funcName}")
          else:
            gen.emit(&"r[{resultReg}] = etch_make_nil();")

        else:
          # Check if this is a CFFI function
          if gen.program.cffiInfo.hasKey(funcName):
            let cffiInfo = gen.program.cffiInfo[funcName]
            let symbol = cffiInfo.symbol

            # Build argument list - convert from EtchV to C types based on signature
            var args = ""
            if numArgs > 0:
              for i in 0 ..< int(numArgs):
                if i > 0:
                  args &= ", "
                let argReg = resultReg.int + 1 + i
                # Convert based on parameter type
                if i < cffiInfo.paramTypes.len:
                  let paramType = cffiInfo.paramTypes[i]
                  case paramType
                  of "tkFloat":
                    args &= &"r[{argReg}].fval"
                  of "tkInt":
                    args &= &"r[{argReg}].ival"
                  of "tkBool":
                    args &= &"r[{argReg}].bval"
                  else:
                    args &= &"r[{argReg}]"  # Pass whole EtchV struct
                else:
                  args &= &"r[{argReg}].fval"  # Default to float

            # Generate direct C function call with return type conversion
            gen.emit(&"// CFFI call to {cffiInfo.library}.{symbol}")
            case cffiInfo.returnType
            of "tkFloat":
              gen.emit(&"r[{resultReg}] = etch_make_float({symbol}({args}));")
            of "tkInt":
              gen.emit(&"r[{resultReg}] = etch_make_int({symbol}({args}));")
            of "tkBool":
              gen.emit(&"r[{resultReg}] = etch_make_bool({symbol}({args}));")
            of "tkVoid":
              gen.emit(&"{symbol}({args});")
              gen.emit(&"r[{resultReg}] = etch_make_nil();")
            else:
              gen.emit(&"r[{resultReg}] = etch_make_float({symbol}({args}));")  # Default to float
          # User-defined function call
          elif gen.program.functions.hasKey(funcName):
            let funcInfo = gen.program.functions[funcName]
            let safeName = sanitizeFunctionName(funcName)

            # Build argument list
            var args = ""
            if funcInfo.numParams > 0:
              for i in 0 ..< funcInfo.numParams:
                if i > 0:
                  args &= ", "
                let argReg = resultReg.int + 1 + i
                args &= &"r[{argReg}]"

            gen.emit(&"r[{resultReg}] = func_{safeName}({args});  // Call user function")
          else:
            gen.emit(&"// TODO: Call to unknown function '{funcName}'")
      else:
        gen.emit(&"// TODO: Invalid function index {funcIdx}")
    else:
      gen.emit(&"// TODO: ropCall with unexpected opType {instr.opType}")

  of ropGetGlobal:
    if instr.opType == 1:
      let bx = instr.bx
      gen.emit(&"// GetGlobal: R[{a}] = globals[K[{bx}]]")
      gen.emit(&"if ({bx} < CONST_POOL_SIZE) {{")
      gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
      gen.emit(&"  r[{a}] = etch_get_global(name);")
      gen.emit(&"}} else {{")
      gen.emit(&"  r[{a}] = etch_make_nil();")
      gen.emit(&"}}")
    else:
      gen.emit(&"// TODO: GetGlobal with opType {instr.opType}")

  of ropSetGlobal:
    if instr.opType == 1:
      let bx = instr.bx
      gen.emit(&"// SetGlobal: globals[K[{bx}]] = R[{a}]")
      gen.emit(&"if ({bx} < CONST_POOL_SIZE) {{")
      gen.emit(&"  const char* name = etch_constants[{bx}].sval;")
      gen.emit(&"  etch_set_global(name, r[{a}]);")
      gen.emit(&"}}")
    else:
      gen.emit(&"// TODO: SetGlobal with opType {instr.opType}")

  of ropTailCall, ropTestSet:
    gen.emit(&"// TODO: Implement {instr.op}")

  of ropAddAdd, ropMulAdd, ropCmpJmp, ropIncTest, ropLoadAddStore, ropGetAddSet:
    gen.emit(&"// TODO: Fused instruction {instr.op}")

  else:
    gen.emit(&"// TODO: Implement {instr.op}")

proc emitFunction(gen: var CGenerator, funcName: string, info: FunctionInfo) =
  ## Emit a C function from RegVM bytecode
  let safeName = sanitizeFunctionName(funcName)
  gen.emit(&"\n// Function: {funcName}")

  # Check if function uses defer blocks
  var hasDefer = false
  var deferTargets: seq[int] = @[]
  var execDefersLocations: seq[int] = @[]
  for pc in info.startPos ..< info.endPos:
    if pc < gen.program.instructions.len:
      let instr = gen.program.instructions[pc]
      if instr.op == ropPushDefer:
        hasDefer = true
        if instr.opType == 2:
          let offset = instr.sbx
          let targetPC = pc + offset
          if targetPC notin deferTargets:
            deferTargets.add(targetPC)
      elif instr.op == ropExecDefers or instr.op == ropDeferEnd:
        hasDefer = true  # Function has defer opcodes
        if instr.op == ropExecDefers and pc notin execDefersLocations:
          execDefersLocations.add(pc)

  # Generate parameter list
  var params = ""
  if info.numParams > 0:
    for i in 0 ..< info.numParams:
      if i > 0:
        params &= ", "
      params &= &"EtchV p{i}"
  else:
    params = "void"

  gen.emit(&"EtchV func_{safeName}({params}) {{")
  gen.incIndent()

  # Allocate registers
  gen.emit(&"EtchV r[{MAX_REGISTERS}];")
  gen.emit("// Initialize registers to nil")
  gen.emit(&"for (int i = 0; i < {MAX_REGISTERS}; i++) r[i] = etch_make_nil();")

  # Defer stack for defer blocks (only if function uses defer)
  if hasDefer:
    gen.emit("")
    gen.emit("// Defer stack")
    gen.emit("int __etch_defer_stack[32];  // Stack of PC locations for defer blocks")
    gen.emit("int __etch_defer_count = 0;")
    gen.emit("int defer_return_pc = -1;")

  # Copy parameters to registers
  if info.numParams > 0:
    gen.emit("")
    gen.emit("// Copy parameters to registers")
    for i in 0 ..< info.numParams:
      gen.emit(&"r[{i}] = p{i};")

  gen.emit("")

  # Store defer targets for this function
  gen.deferTargets = deferTargets
  gen.execDefersLocations = execDefersLocations

  # Emit instructions with labels
  for pc in info.startPos ..< info.endPos:
    # Emit label for this instruction (for jumps)
    gen.emit(&"L{pc}:")
    if pc < gen.program.instructions.len:
      try:
        gen.emitInstruction(gen.program.instructions[pc], pc)
      except FieldDefect as e:
        let instr = gen.program.instructions[pc]
        echo &"ERROR at PC {pc}: {instr.op} (opType={instr.opType}): {e.msg}"
        raise

  # Default return
  gen.emit(&"L{info.endPos}:")
  gen.emit("return etch_make_nil();")

  gen.decIndent()
  gen.emit("}")

proc emitMainWrapper(gen: var CGenerator) =
  ## Emit the main function wrapper
  gen.emit("\nint main(int argc, char** argv) {")
  gen.incIndent()
  gen.emit("etch_init_constants();")

  # Call <global> function if it exists (initializes global variables and calls main)
  # Note: <global> will call main as a "transition", so we don't call main separately
  const GLOBAL_INIT_FUNCTION = "<global>"
  if gen.program.functions.hasKey(GLOBAL_INIT_FUNCTION):
    let globalSafeName = sanitizeFunctionName(GLOBAL_INIT_FUNCTION)
    gen.emit(&"func_{globalSafeName}();  // Initialize globals")
  else:
    # No <global> function, call main directly
    if gen.program.functions.hasKey(MAIN_FUNCTION_NAME):
      let safeName = sanitizeFunctionName(MAIN_FUNCTION_NAME)
      gen.emit(&"EtchV result = func_{safeName}();")
      # Don't print main's return value (matches bytecode VM behavior)
      gen.emit("// Main's return value is not printed")
    else:
      gen.emit("printf(\"No main function found\\n\");")

  gen.emit("return 0;")
  gen.decIndent()
  gen.emit("}")

proc generateCCode*(program: RegBytecodeProgram): string =
  ## Main entry point: generate complete C code from RegVM bytecode
  var gen = newCGenerator(program)

  # Emit runtime
  gen.emitCRuntime()

  # Emit constant pool
  gen.emitConstantPool()

  # Emit CFFI forward declarations
  gen.emitCFFIDeclarations()

  # Emit forward declarations for all functions
  gen.emit("\n// Forward declarations")
  for funcName, info in program.functions:
    let safeName = sanitizeFunctionName(funcName)
    var params = ""
    if info.numParams > 0:
      for i in 0 ..< info.numParams:
        if i > 0:
          params &= ", "
        params &= &"EtchV p{i}"
    else:
      params = "void"
    gen.emit(&"EtchV func_{safeName}({params});")

  # Emit all functions
  for funcName, info in program.functions:
    gen.emitFunction(funcName, info)

  # Emit main wrapper
  gen.emitMainWrapper()

  return gen.output
