/**
 * VM Inspection Example
 *
 * Demonstrates:
 * - Creating context with compiler options
 * - Setting instruction callback for VM inspection
 * - Inspecting call stack, PC, registers, and current function
 */

#include <stdio.h>
#include <stdlib.h>
#include "../../include/etch.h"

// Global counter for instruction tracing
static int instruction_count = 0;

// Instruction callback that gets called before each VM instruction
int instruction_callback(EtchContext ctx, void* userData) {
    (void)userData; // Unused in this example

    instruction_count++;

    // Only print every 10th instruction to avoid too much output
    if (instruction_count % 10 == 0) {
        int pc = etch_get_program_counter(ctx);
        int stack_depth = etch_get_call_stack_depth(ctx);
        const char* func = etch_get_current_function(ctx);

        printf("[Trace] PC=%d, Stack=%d, Function=%s\n",
               pc, stack_depth, func ? func : "unknown");
    }

    // Return 0 to continue execution
    return 0;
}

int main(void) {
    printf("=== Etch VM Inspection Example ===\n\n");

    // Create context with custom compiler options
    EtchContextOptions opts = {
        .verbose = 0,
        .debug = 1,
        .gcCycleInterval = 0  // Use default
    };
    EtchContext ctx = etch_context_new_with_options(&opts);
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    printf("Example 1: Create context with custom options\n");
    printf("Created context with: verbose=off, debug=on, gc-interval=default\n\n");

    // Example 2: Basic VM inspection without callback
    printf("Example 2: VM inspection without callback\n");

    const char* simple_code =
        "fn factorial(n: int) -> int {\n"
        "    if n <= 1 {\n"
        "        return 1;\n"
        "    }\n"
        "    return n * factorial(n - 1);\n"
        "}\n"
        "\n"
        "fn main() -> void {\n"
        "    let result: int = factorial(5);\n"
        "    print(result);\n"
        "}\n";

    if (etch_compile_string(ctx, simple_code, "factorial.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    int inst_count = etch_get_instruction_count(ctx);
    printf("Compiled program has %d instructions\n", inst_count);
    printf("Executing (without tracing)...\n");

    if (etch_execute(ctx) != 0) {
        fprintf(stderr, "Execution failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }
    printf("\n");

    // Example 3: VM inspection WITH instruction callback
    printf("Example 3: VM inspection with instruction callback\n");

    // Recompile to reset VM state
    if (etch_compile_string(ctx, simple_code, "factorial.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    // Set instruction callback
    instruction_count = 0;
    etch_set_instruction_callback(ctx, instruction_callback, NULL);

    printf("Executing with instruction tracing (every 10th instruction)...\n");
    if (etch_execute(ctx) != 0) {
        fprintf(stderr, "Execution failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    printf("\nTotal instructions executed: %d\n", instruction_count);
    printf("\n");

    // Example 4: Change compiler options at runtime
    printf("Example 4: Change compiler options at runtime\n");

    // Switch to release mode (more optimizations)
    etch_context_set_debug(ctx, 0); // 0 = release mode
    etch_context_set_verbose(ctx, 1); // Enable verbose for demonstration

    printf("Changed to: verbose=on, debug=off (release mode)\n");
    printf("Recompiling with new options...\n");

    if (etch_compile_string(ctx, simple_code, "factorial.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    // Clear callback for this run
    etch_set_instruction_callback(ctx, NULL, NULL);

    printf("Executing (optimized)...\n");
    if (etch_execute(ctx) != 0) {
        fprintf(stderr, "Execution failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    printf("\n=== All examples completed successfully ===\n");

    // Cleanup
    etch_context_free(ctx);

    return 0;
}
