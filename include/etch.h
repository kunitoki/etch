/**
 * @file etch.h
 *
 * @brief C API for Etch scripting language
 *
 * This header provides a C interface for embedding the Etch scripting engine
 * into C/C++ applications. Etch can be used as a safe, statically-typed
 * scripting language with compile-time verification and runtime safety checks.
 *
 * Example usage:
 * @code
 *   EtchContext* ctx = etch_context_new();
 *
 *   if (etch_compile_file(ctx, "script.etch") == 0) {
 *     etch_execute(ctx);
 *   } else {
 *     printf("Error: %s\n", etch_get_error(ctx));
 *   }
 *
 *   etch_context_free(ctx);
 * @endcode
 */

#ifndef ETCH_H
#define ETCH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Types
 * ========================================================================== */

/** Opaque handle to an Etch execution context */
typedef struct EtchContextObj* EtchContext;

/** Opaque handle to an Etch value */
typedef struct EtchValueObj* EtchValue;

/** Opaque handle to an Etch debug server */
typedef struct EtchDebugServerObj* EtchDebugServer;

/**
 * Host function callback signature
 *
 * @param ctx Current Etch context
 * @param args Array of argument values
 * @param numArgs Number of arguments
 * @param userData User-defined data pointer passed during registration
 *
 * @return Result value (must be created with etch_value_new_* functions)
 */
typedef EtchValue (*EtchHostFunction)(EtchContext ctx, EtchValue* args, int numArgs, void* userData);

/**
 * Instruction callback signature for VM inspection
 *
 * Called before each instruction is executed. Useful for debugging,
 * profiling, or implementing step-by-step execution.
 *
 * @param ctx Current Etch context
 * @param userData User-defined data pointer passed during registration
 *
 * @return 0 to continue execution, non-zero to stop
 */
typedef int (*EtchInstructionCallback)(EtchContext ctx, void* userData);


/* ============================================================================
 * Value Type Enumeration
 * ========================================================================== */

/** Etch value type identifiers */
typedef enum {
    ETCH_TYPE_INT = 0,      /**< Integer (int64) */
    ETCH_TYPE_FLOAT = 1,    /**< Float (double) */
    ETCH_TYPE_BOOL = 2,     /**< Boolean */
    ETCH_TYPE_CHAR = 3,     /**< Character */
    ETCH_TYPE_NIL = 4,      /**< Nil/null value */
    ETCH_TYPE_STRING = 5,   /**< String */
    ETCH_TYPE_ARRAY = 6,    /**< Array */
    ETCH_TYPE_TABLE = 7,    /**< Table/dictionary */
    ETCH_TYPE_SOME = 8,     /**< Option: some(value) */
    ETCH_TYPE_NONE = 9,     /**< Option: none */
    ETCH_TYPE_OK = 10,      /**< Result: ok(value) */
    ETCH_TYPE_ERR = 11,     /**< Result: error(value) */
    ETCH_TYPE_ENUM = 12     /**< Enum value */
} EtchValueType;


/* ============================================================================
 * Context Management
 * ========================================================================== */

/**
 * Context creation options
 */
typedef struct {
    int verbose;              /**< Enable verbose logging (0 = off, non-zero = on) */
    int debug;                /**< Enable debug mode (0 = release/optimized, non-zero = debug) */
    int gcCycleInterval;      /**< GC cycle detection interval in operations (0 = use default 1000) */
} EtchContextOptions;

/**
 * Create a new Etch execution context with default options
 *
 * Default options: non-verbose, debug mode, GC interval = 1000
 *
 * @return New context or NULL on failure
 */
EtchContext etch_context_new(void);

/**
 * Create a new Etch execution context with specified options
 *
 * @param options Context creation options (pass NULL for defaults)
 *
 * @return New context or NULL on failure
 */
EtchContext etch_context_new_with_options(const EtchContextOptions* options);

/**
 * Free an Etch context and all associated resources
 *
 * @param ctx Context to free
 */
void etch_context_free(EtchContext ctx);

/**
 * Enable or disable verbose logging
 *
 * @param ctx Context
 * @param verbose Non-zero to enable, zero to disable
 */
void etch_context_set_verbose(EtchContext ctx, int verbose);

/**
 * Enable or disable debug mode (affects optimization level)
 *
 * @param ctx Context
 * @param debug 0 = release mode with optimizations, non-zero = debug mode
 */
void etch_context_set_debug(EtchContext ctx, int debug);


/* ============================================================================
 * Error Handling
 * ========================================================================== */

/**
 * Get the last error message from the context
 *
 * @param ctx Context
 *
 * @return Error string or NULL if no error
 *
 * @note The returned string is owned by the context. Do NOT free it.
 *       The string remains valid until the next error or etch_context_free().
 */
const char* etch_get_error(EtchContext ctx);

/**
 * Clear the error state
 *
 * @param ctx Context
 */
void etch_clear_error(EtchContext ctx);


/* ============================================================================
 * Compilation
 * ========================================================================== */

/**
 * Compile Etch source code from a string
 *
 * @param ctx Context
 * @param source Source code string
 * @param filename Filename for error messages (can be NULL)
 *
 * @return 0 on success, non-zero on error
 */
int etch_compile_string(EtchContext ctx, const char* source, const char* filename);

/**
 * Compile Etch source code from a file
 *
 * @param ctx Context
 * @param path Path to source file
 *
 * @return 0 on success, non-zero on error
 */
int etch_compile_file(EtchContext ctx, const char* path);


/* ============================================================================
 * Execution
 * ========================================================================== */

/**
 * Execute the compiled program (runs main function if it exists)
 *
 * @param ctx Context
 *
 * @return Exit code (0 on success)
 */
int etch_execute(EtchContext ctx);

/**
 * Call a specific function by name with arguments
 *
 * @param ctx Context
 * @param name Function name
 * @param args Array of argument values (can be NULL if numArgs is 0)
 * @param numArgs Number of arguments
 *
 * @return Result value or NULL on error
 */
EtchValue etch_call_function(EtchContext ctx, const char* name, EtchValue* args, int numArgs);


/* ============================================================================
 * Value Creation
 * ========================================================================== */

/** Create a nil value */
EtchValue etch_value_new_nil(void);

/** Create a boolean value (0 = false, non-zero = true) */
EtchValue etch_value_new_bool(int v);

/** Create a character value */
EtchValue etch_value_new_char(char v);

/** Create an integer value */
EtchValue etch_value_new_int(int64_t v);

/** Create a float value */
EtchValue etch_value_new_float(double v);

/** Create a string value (copies the string) */
EtchValue etch_value_new_string(const char* v);

/** Create an enum value with type ID and integer value */
EtchValue etch_value_new_enum(int typeId, int64_t intVal);

/** Create an enum value with type ID, integer value, and string representation */
EtchValue etch_value_new_enum_with_string(int typeId, int64_t intVal, const char* stringVal);

/** Clone an existing EtchValue handle (deep copy) */
EtchValue etch_value_clone(EtchValue v);

/** Create an array from an optional list of EtchValue handles */
EtchValue etch_value_new_array(EtchValue* elements, int count);

/** Wrap a value in option some */
EtchValue etch_value_new_some(EtchValue inner);

/** Create option none */
EtchValue etch_value_new_none(void);

/** Wrap a value in result ok */
EtchValue etch_value_new_ok(EtchValue inner);

/** Wrap a value in result err */
EtchValue etch_value_new_err(EtchValue inner);


/* ============================================================================
 * Value Inspection
 * ========================================================================== */

/**
 * Get the type of a value
 *
 * @param v Value
 *
 * @return Type enum or -1 on error
 */
int etch_value_get_type(EtchValue v);

/** Check if value is nil */
int etch_value_is_nil(EtchValue v);

/** Check if value is a boolean */
int etch_value_is_bool(EtchValue v);

/** Check if value is a char */
int etch_value_is_char(EtchValue v);

/** Check if value is an integer */
int etch_value_is_int(EtchValue v);

/** Check if value is a float */
int etch_value_is_float(EtchValue v);

/** Check if value is a string */
int etch_value_is_string(EtchValue v);

/** Check if value is an enum */
int etch_value_is_enum(EtchValue v);

/** Check if value is an array */
int etch_value_is_array(EtchValue v);

/** Check if value is option some */
int etch_value_is_some(EtchValue v);

/** Check if value is option none */
int etch_value_is_none(EtchValue v);

/** Check if value is result ok */
int etch_value_is_ok(EtchValue v);

/** Check if value is result err */
int etch_value_is_err(EtchValue v);


/* ============================================================================
 * Value Extraction
 * ========================================================================== */

/**
 * Extract boolean value
 *
 * @param v Value
 * @param outVal Pointer to store result (0 or 1)
 *
 * @return 0 on success, non-zero if value is not a boolean
 */
int etch_value_to_bool(EtchValue v, int* outVal);

/**
 * Extract character value
 *
 * @param v Value
 * @param outVal Pointer to store result
 *
 * @return 0 on success, non-zero if value is not a character
 */
int etch_value_to_char(EtchValue v, char* outVal);

/**
 * Extract integer value
 *
 * @param v Value
 * @param outVal Pointer to store result
 *
 * @return 0 on success, non-zero if value is not an integer
 */
int etch_value_to_int(EtchValue v, int64_t* outVal);

/**
 * Extract float value
 *
 * @param v Value
 * @param outVal Pointer to store result
 *
 * @return 0 on success, non-zero if value is not a float
 */
int etch_value_to_float(EtchValue v, double* outVal);

/**
 * Extract string value
 *
 * @param v Value
 *
 * @return String pointer or NULL if value is not a string
 *
 * @note The returned string is owned by the value. Do NOT free it.
 *       The string remains valid as long as the value exists.
 */
const char* etch_value_to_string(EtchValue v);

/**
 * Extract enum type ID
 *
 * @param v Value
 * @param outVal Pointer to store result
 *
 * @return 0 on success, non-zero if value is not an enum
 */
int etch_value_to_enum_type_id(EtchValue v, int* outVal);

/**
 * Extract enum integer value
 *
 * @param v Value
 * @param outVal Pointer to store result
 *
 * @return 0 on success, non-zero if value is not an enum
 */
int etch_value_to_enum_int_val(EtchValue v, int64_t* outVal);

/**
 * Extract enum string value
 *
 * @param v Value
 *
 * @return String pointer or NULL if value is not an enum or has no string representation
 *
 * @note The returned string is owned by the value. Do NOT free it.
 *       The string remains valid as long as the value exists.
 */
const char* etch_value_to_enum_string(EtchValue v);


/* ============================================================================
 * Array Helpers
 * ========================================================================== */

/** Get the number of elements in an array (returns -1 if not an array) */
int etch_value_array_length(EtchValue v);

/** Fetch an element from an array by index (caller must free the returned handle) */
EtchValue etch_value_array_get(EtchValue v, int index);

/** Replace an element inside an array */
int etch_value_array_set(EtchValue v, int index, EtchValue value);

/** Append a value to the end of an array */
int etch_value_array_push(EtchValue v, EtchValue value);


/* ============================================================================
 * Option Helpers
 * ========================================================================== */

/** Returns non-zero when the option is some */
int etch_value_option_has_value(EtchValue v);

/** Extract the inner value from option some (caller must free result) */
EtchValue etch_value_option_unwrap(EtchValue v);


/* ============================================================================
 * Result Helpers
 * ========================================================================== */

/** Returns non-zero when the result is ok */
int etch_value_result_is_ok(EtchValue v);

/** Returns non-zero when the result is err */
int etch_value_result_is_err(EtchValue v);

/** Extract the ok payload from a result (caller must free result) */
EtchValue etch_value_result_unwrap_ok(EtchValue v);

/** Extract the error payload from a result (caller must free result) */
EtchValue etch_value_result_unwrap_err(EtchValue v);


/* ============================================================================
 * Value Cleanup
 * ========================================================================== */

/**
 * Free a value created by the API
 *
 * @param v Value to free
 */
void etch_value_free(EtchValue v);


/* ============================================================================
 * Enum Helper Functions
 * ========================================================================== */

/**
 * Compute the enum type ID for a given type name
 *
 * This function computes the same deterministic integer ID that Etch uses
 * internally for enum types. Use this to get the type ID needed for
 * etch_value_new_enum() and related functions.
 *
 * @param typeName Name of the enum type (e.g., "Color", "Status")
 *
 * @return Integer type ID, or -1 if typeName is NULL
 *
 * @note The same type name will always produce the same ID
 */
int etch_compute_enum_type_id(const char* typeName);


/* ============================================================================
 * Global Variables
 * ========================================================================== */

/**
 * Set a global variable in the Etch context
 *
 * @param ctx Context
 * @param name Variable name
 * @param value Value to set
 */
void etch_set_global(EtchContext ctx, const char* name, EtchValue value);

/**
 * Get a global variable from the Etch context
 *
 * @param ctx Context
 * @param name Variable name
 *
 * @return Value or NULL if not found (must be freed with etch_value_free)
 */
EtchValue etch_get_global(EtchContext ctx, const char* name);


/* ============================================================================
 * Host Function Registration
 * ========================================================================== */

/**
 * Register a C function that can be called from Etch
 *
 * The registered function will be available in Etch scripts with the given name.
 * The callback receives arguments as an array of EtchValue pointers and must
 * return a new EtchValue (or NULL on error).
 *
 * @param ctx Context
 * @param name Function name (how it will be called from Etch)
 * @param callback Function pointer
 * @param userData User-defined data passed to callback (can be NULL)
 *
 * @return 0 on success, non-zero on error
 *
 * @code
 * EtchValue my_add(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
 *     if (numArgs != 2) return NULL;
 *     int64_t a, b;
 *     if (etch_value_to_int(args[0], &a) != 0) return NULL;
 *     if (etch_value_to_int(args[1], &b) != 0) return NULL;
 *     return etch_value_new_int(a + b);
 * }
 *
 * etch_register_function(ctx, "my_add", my_add, NULL);
 * @endcode
 */
int etch_register_function(EtchContext ctx, const char* name, EtchHostFunction callback, void* userData);


/* ============================================================================
 * Instruction Callback and VM Inspection
 * ========================================================================== */

/**
 * Set a callback to be invoked before each instruction is executed
 *
 * This is useful for debugging, profiling, or implementing step-by-step execution.
 * The callback can inspect VM state using the inspection functions below.
 *
 * @param ctx Context
 * @param callback Function pointer called before each instruction (return 0 to continue, non-zero to stop)
 * @param userData User-defined data passed to the callback
 */
void etch_set_instruction_callback(EtchContext ctx, EtchInstructionCallback callback, void* userData);

/**
 * Get the current call stack depth
 *
 * @param ctx Context
 *
 * @return Number of active stack frames, or -1 on error
 */
int etch_get_call_stack_depth(EtchContext ctx);

/**
 * Get the current program counter (instruction index)
 *
 * @param ctx Context
 *
 * @return Current PC, or -1 on error
 */
int etch_get_program_counter(EtchContext ctx);

/**
 * Get the number of registers in the current frame
 *
 * @param ctx Context
 *
 * @return Always returns 256 (max registers), or -1 on error
 */
int etch_get_register_count(EtchContext ctx);

/**
 * Get the value of a register in the current frame
 *
 * @param ctx Context
 * @param regIndex Register index (0-255)
 *
 * @return Register value (must be freed with etch_value_free), or NULL on error
 */
EtchValue etch_get_register(EtchContext ctx, int regIndex);

/**
 * Get the total number of instructions in the program
 *
 * @param ctx Context
 *
 * @return Instruction count, or -1 on error
 */
int etch_get_instruction_count(EtchContext ctx);

/**
 * Get the name of the currently executing function
 *
 * @param ctx Context
 *
 * @return Function name or NULL on error
 *
 * @note The returned string is owned by the program. Do NOT free it.
 *       The string remains valid as long as the context exists.
 */
const char* etch_get_current_function(EtchContext ctx);


/* ============================================================================
 * Frame Budget API for Game Engines
 * ========================================================================== */

/**
 * GC frame statistics structure
 *
 * Returned by etch_get_gc_stats() to provide information about GC work
 * performed during the current frame.
 */
typedef struct {
    int64_t gcTimeUs;      /**< Microseconds spent on GC this frame */
    int64_t budgetUs;      /**< Total GC budget allocated for this frame */
    int dirtyObjects;      /**< Number of objects modified since last GC */
} EtchGCFrameStats;

/**
 * Start a new frame with a GC time budget
 *
 * Call this at the start of each game frame to set a time budget for
 * garbage collection. The GC will respect this budget and skip collection
 * if insufficient time remains.
 *
 * @param ctx Context
 * @param budgetUs Microseconds available for GC work this frame
 *                 (e.g., 2000 for 2ms in a 16ms frame)
 *                 Set to 0 to disable frame budgeting and use adaptive intervals
 *
 * @code
 * // In game loop: allocate 2ms for GC in a 60fps (16ms) frame
 * etch_begin_frame(ctx, 2000);
 * etch_execute(ctx);  // GC respects budget automatically
 * @endcode
 */
void etch_begin_frame(EtchContext ctx, int64_t budgetUs);

/**
 * Check if GC is backed up and needs more time
 *
 * Returns true if many dirty objects have accumulated. The game engine
 * can use this to skip a render frame and give more time to GC.
 *
 * @param ctx Context
 *
 * @return Non-zero if GC needs a full frame, zero otherwise
 *
 * @code
 * if (etch_needs_gc_frame(ctx)) {
 *     // Skip rendering, give full 16ms frame to GC
 *     etch_begin_frame(ctx, 16000);
 *     // Skip render_frame() this iteration
 * }
 * @endcode
 */
int etch_needs_gc_frame(EtchContext ctx);

/**
 * Get GC statistics for the current frame
 *
 * Returns information about GC work performed this frame, including
 * time spent, budget allocated, and number of dirty objects.
 *
 * @param ctx Context
 *
 * @return GC statistics structure
 *
 * @code
 * EtchGCFrameStats stats = etch_get_gc_stats(ctx);
 * printf("GC: %lldus / %lldus, dirty: %d\n",
 *        stats.gcTimeUs, stats.budgetUs, stats.dirtyObjects);
 * @endcode
 */
EtchGCFrameStats etch_get_gc_stats(EtchContext ctx);

/**
 * Check if heap needs cycle detection
 *
 * Returns true if there are enough dirty objects to warrant running
 * cycle detection (when budget allows).
 *
 * @param ctx Context
 *
 * @return Non-zero if collection is recommended, zero otherwise
 */
int etch_heap_needs_collection(EtchContext ctx);

#ifdef __cplusplus
}
#endif

#endif /* ETCH_H */
