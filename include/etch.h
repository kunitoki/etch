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
    ETCH_TYPE_ERR = 11      /**< Result: error(value) */
} EtchValueType;


/* ============================================================================
 * Context Management
 * ========================================================================== */

/**
 * Create a new Etch execution context with default options
 *
 * Default options: non-verbose, debug mode
 *
 * @return New context or NULL on failure
 */
EtchContext etch_context_new(void);

/**
 * Create a new Etch execution context with specified compiler options
 *
 * @param verbose Enable verbose logging (0 = off, non-zero = on)
 * @param debug Enable debug mode (0 = release/optimized, non-zero = debug)
 *
 * @return New context or NULL on failure
 */
EtchContext etch_context_new_with_options(int verbose, int debug);

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

#ifdef __cplusplus
}
#endif

#endif /* ETCH_H */
