/**
 * Simple example demonstrating Etch C API usage
 *
 * This example shows:
 * - Creating a context
 * - Compiling and executing Etch code
 * - Reading/writing global variables
 * - Error handling
 */

#include <stdio.h>
#include <stdlib.h>

#include "../../include/etch.h"

int main(void) {
    printf("=== Etch C API Simple Example ===\n\n");

    // Create Etch context
    EtchContext ctx = etch_context_new();
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    // Example 1: Compile and execute simple code
    printf("Example 1: Compile and execute simple code\n");
    const char* simple_code =
        "fn main() -> int {\n"
        "    print(\"Hello from Etch!\");\n"
        "    return 0;\n"
        "}\n";

    if (etch_compile_string(ctx, simple_code, "simple.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    if (etch_execute(ctx) != 0) {
        fprintf(stderr, "Execution failed: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }
    printf("\n");

    // Example 2: Set and get global variables from C
    printf("Example 2: Set and get global variables from C\n");

    // Set a global variable from C (after compilation)
    EtchValue my_value = etch_value_new_int(42);
    etch_set_global(ctx, "my_number", my_value);
    etch_value_free(my_value);
    printf("Set 'my_number' to 42 from C\n");

    // Read it back
    EtchValue result_val = etch_get_global(ctx, "my_number");
    if (result_val) {
        if (etch_value_is_int(result_val)) {
            int64_t result;
            if (etch_value_to_int(result_val, &result) == 0) {
                printf("Got 'my_number' back from context: %lld\n", (long long)result);
            }
        }
        etch_value_free(result_val);
    }

    // Modify it from C
    my_value = etch_value_new_int(100);
    etch_set_global(ctx, "my_number", my_value);
    etch_value_free(my_value);
    printf("Changed 'my_number' to 100 from C\n");

    // Verify it was updated
    result_val = etch_get_global(ctx, "my_number");
    if (result_val) {
        if (etch_value_is_int(result_val)) {
            int64_t result;
            if (etch_value_to_int(result_val, &result) == 0) {
                printf("Verified 'my_number' is now: %lld\n", (long long)result);
            }
        }
        etch_value_free(result_val);
    }
    printf("\n");

    // Example 3: Working with different value types
    printf("Example 3: Working with different value types\n");

    EtchValue int_val = etch_value_new_int(42);
    EtchValue float_val = etch_value_new_float(3.14159);
    EtchValue bool_val = etch_value_new_bool(1);
    EtchValue string_val = etch_value_new_string("Hello");
    EtchValue nil_val = etch_value_new_nil();

    // Check types
    printf("  int_val is int: %d\n", etch_value_is_int(int_val));
    printf("  float_val is float: %d\n", etch_value_is_float(float_val));
    printf("  bool_val is bool: %d\n", etch_value_is_bool(bool_val));
    printf("  string_val is string: %d\n", etch_value_is_string(string_val));
    printf("  nil_val is nil: %d\n", etch_value_is_nil(nil_val));

    // Extract values
    int64_t i;
    double f;
    int b;
    const char* s;

    if (etch_value_to_int(int_val, &i) == 0) {
        printf("  int value: %lld\n", (long long)i);
    }
    if (etch_value_to_float(float_val, &f) == 0) {
        printf("  float value: %f\n", f);
    }
    if (etch_value_to_bool(bool_val, &b) == 0) {
        printf("  bool value: %d\n", b);
    }
    s = etch_value_to_string(string_val);
    if (s) {
        printf("  string value: %s\n", s);
    }

    // Clean up values
    etch_value_free(int_val);
    etch_value_free(float_val);
    etch_value_free(bool_val);
    etch_value_free(string_val);
    etch_value_free(nil_val);
    printf("\n");

    printf("=== All examples completed successfully ===\n");

    // Clean up context
    etch_context_free(ctx);

    return 0;
}
