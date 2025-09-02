/**
 * Global Override Example - demonstrates C API global variable overriding
 *
 * This example shows how to:
 * - Set global variables from C before execution
 * - Override compile-time global initialization
 * - Verify that C API values take precedence
 */

#include <stdio.h>
#include <stdlib.h>

#include "../../include/etch.h"

int main(void) {
    printf("=== Etch C API Global Override Example ===\n\n");

    // Create Etch context
    EtchContext ctx = etch_context_new();
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    // Example 1: Override globals before execution
    printf("Example 1: Override global variables before execution\n");

    // Etch code with compile-time global initialization
    const char* etch_code =
        "var x: int = 10;\n"
        "var y: int = 20;\n"
        "var message: string = \"default\";\n"
        "\n"
        "fn main() -> void {\n"
        "    print(\"x = \");\n"
        "    print(string(x));\n"
        "    print(\", y = \");\n"
        "    print(string(y));\n"
        "    print(\", message = \");\n"
        "    print(message);\n"
        "}\n";

    // Compile the program
    if (etch_compile_string(ctx, etch_code, "test.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }
    printf("Compiled program with globals: x=10, y=20, message=\"default\"\n");

    // Override globals BEFORE execution
    printf("Setting overrides from C API: x=100, y=200, message=\"overridden\"\n");

    EtchValue x_val = etch_value_new_int(100);
    etch_set_global(ctx, "x", x_val);
    etch_value_free(x_val);

    EtchValue y_val = etch_value_new_int(200);
    etch_set_global(ctx, "y", y_val);
    etch_value_free(y_val);

    EtchValue msg_val = etch_value_new_string("overridden");
    etch_set_global(ctx, "message", msg_val);
    etch_value_free(msg_val);

    // Execute - should use overridden values
    printf("\nExecuting program (should print overridden values):\n");
    if (etch_execute(ctx) != 0) {
        fprintf(stderr, "Execution failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    // Verify the values after execution
    printf("\nVerifying globals after execution:\n");

    EtchValue result = etch_get_global(ctx, "x");
    if (result && etch_value_is_int(result)) {
        int64_t x;
        if (etch_value_to_int(result, &x) == 0) {
            printf("  x = %lld (expected 100)\n", (long long)x);
            if (x != 100) {
                fprintf(stderr, "ERROR: x should be 100, got %lld\n", (long long)x);
                etch_context_free(ctx);
                return 1;
            }
        }
        etch_value_free(result);
    }

    result = etch_get_global(ctx, "y");
    if (result && etch_value_is_int(result)) {
        int64_t y;
        if (etch_value_to_int(result, &y) == 0) {
            printf("  y = %lld (expected 200)\n", (long long)y);
            if (y != 200) {
                fprintf(stderr, "ERROR: y should be 200, got %lld\n", (long long)y);
                etch_context_free(ctx);
                return 1;
            }
        }
        etch_value_free(result);
    }

    result = etch_get_global(ctx, "message");
    if (result && etch_value_is_string(result)) {
        const char* msg = etch_value_to_string(result);
        if (msg) {
            printf("  message = \"%s\" (expected \"overridden\")\n", msg);
        }
        etch_value_free(result);
    }

    printf("\n=== SUCCESS: Global overrides working correctly! ===\n");

    // Clean up
    etch_context_free(ctx);
    return 0;
}
