/**
 * Example demonstrating host function registration
 *
 * This example shows how to:
 * - Register C functions that can be called from Etch
 * - Pass arguments and return values
 * - Use user data in callbacks
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "../../include/etch.h"

// Host function: add two integers
EtchValue host_add(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx;      // Unused
    (void)userData; // Unused

    if (numArgs != 2) {
        fprintf(stderr, "host_add: Expected 2 arguments, got %d\n", numArgs);
        return NULL;
    }

    int64_t a, b;
    if (etch_value_to_int(args[0], &a) != 0 || etch_value_to_int(args[1], &b) != 0) {
        fprintf(stderr, "host_add: Arguments must be integers\n");
        return NULL;
    }

    return etch_value_new_int(a + b);
}

// Host function: compute square root
EtchValue host_sqrt(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx;      // Unused
    (void)userData; // Unused

    if (numArgs != 1) {
        fprintf(stderr, "host_sqrt: Expected 1 argument, got %d\n", numArgs);
        return NULL;
    }

    // Try to get as float first
    double val;
    if (etch_value_to_float(args[0], &val) != 0) {
        // Try as int
        int64_t ival;
        if (etch_value_to_int(args[0], &ival) != 0) {
            fprintf(stderr, "host_sqrt: Argument must be a number\n");
            return NULL;
        }
        val = (double)ival;
    }

    return etch_value_new_float(sqrt(val));
}

// Host function: greet with custom prefix (uses user data)
EtchValue host_greet(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; // Unused

    if (numArgs != 1) {
        fprintf(stderr, "host_greet: Expected 1 argument, got %d\n", numArgs);
        return NULL;
    }

    const char* name = etch_value_to_string(args[0]);
    if (!name) {
        fprintf(stderr, "host_greet: Argument must be a string\n");
        return NULL;
    }

    const char* prefix = userData ? (const char*)userData : "Hello";

    // Build greeting string
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "%s, %s!", prefix, name);

    return etch_value_new_string(buffer);
}

// Host function: max of variable number of integers
EtchValue host_max(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx;      // Unused
    (void)userData; // Unused

    if (numArgs == 0) {
        fprintf(stderr, "host_max: Expected at least 1 argument\n");
        return NULL;
    }

    int64_t maxVal;
    if (etch_value_to_int(args[0], &maxVal) != 0) {
        fprintf(stderr, "host_max: Arguments must be integers\n");
        return NULL;
    }

    for (int i = 1; i < numArgs; i++) {
        int64_t val;
        if (etch_value_to_int(args[i], &val) != 0) {
            fprintf(stderr, "host_max: Arguments must be integers\n");
            return NULL;
        }
        if (val > maxVal) {
            maxVal = val;
        }
    }

    return etch_value_new_int(maxVal);
}


int main(void) {
    printf("=== Etch C API Host Functions Example ===\n\n");

    // Create Etch context
    EtchContext ctx = etch_context_new();
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    // Register host functions
    printf("Registering host functions...\n");
    if (etch_register_function(ctx, "host_add", host_add, NULL) != 0) {
        fprintf(stderr, "Failed to register host_add\n");
        etch_context_free(ctx);
        return 1;
    }

    if (etch_register_function(ctx, "host_sqrt", host_sqrt, NULL) != 0) {
        fprintf(stderr, "Failed to register host_sqrt\n");
        etch_context_free(ctx);
        return 1;
    }

    const char* greeting_prefix = "Greetings";
    if (etch_register_function(ctx, "host_greet", host_greet, (void*)greeting_prefix) != 0) {
        fprintf(stderr, "Failed to register host_greet\n");
        etch_context_free(ctx);
        return 1;
    }

    if (etch_register_function(ctx, "host_max", host_max, NULL) != 0) {
        fprintf(stderr, "Failed to register host_max\n");
        etch_context_free(ctx);
        return 1;
    }

    printf("Host functions registered successfully!\n\n");

    // Test calling host functions from C
    printf("Testing host functions from C:\n");

    // Test host_add
    EtchValue args[4];
    args[0] = etch_value_new_int(10);
    args[1] = etch_value_new_int(32);
    EtchValue result = etch_call_function(ctx, "host_add", args, 2);
    if (result) {
        int64_t val;
        if (etch_value_to_int(result, &val) == 0) {
            printf("  host_add(10, 32) = %lld\n", (long long)val);
        }
        etch_value_free(result);
    }
    etch_value_free(args[0]);
    etch_value_free(args[1]);

    // Test host_sqrt
    args[0] = etch_value_new_float(16.0);
    result = etch_call_function(ctx, "host_sqrt", args, 1);
    if (result) {
        double val;
        if (etch_value_to_float(result, &val) == 0) {
            printf("  host_sqrt(16.0) = %f\n", val);
        }
        etch_value_free(result);
    }
    etch_value_free(args[0]);

    // Test host_greet
    args[0] = etch_value_new_string("World");
    result = etch_call_function(ctx, "host_greet", args, 1);
    if (result) {
        const char* str = etch_value_to_string(result);
        if (str) {
            printf("  host_greet(\"World\") = \"%s\"\n", str);
        }
        etch_value_free(result);
    }
    etch_value_free(args[0]);

    // Test host_max
    args[0] = etch_value_new_int(5);
    args[1] = etch_value_new_int(12);
    args[2] = etch_value_new_int(7);
    args[3] = etch_value_new_int(3);
    result = etch_call_function(ctx, "host_max", args, 4);
    if (result) {
        int64_t val;
        if (etch_value_to_int(result, &val) == 0) {
            printf("  host_max(5, 12, 7, 3) = %lld\n", (long long)val);
        }
        etch_value_free(result);
    }
    etch_value_free(args[0]);
    etch_value_free(args[1]);
    etch_value_free(args[2]);
    etch_value_free(args[3]);

    printf("\n");
    printf("=== Example completed successfully ===\n");

    // Note: In a real integration, you would compile Etch code that calls these
    // host functions, but that requires implementing the integration between
    // the Etch typechecker/compiler and the host function registry.

    // Clean up
    etch_context_free(ctx);

    return 0;
}
