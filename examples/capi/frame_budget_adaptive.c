/**
 * Adaptive Budget Test - Testing different GC budget levels
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "../../include/etch.h"

int main(void) {
    printf("===============================================\n");
    printf("Etch Frame Budget API - Adaptive Budget Test\n");
    printf("===============================================\n\n");

    // Create Etch context with custom GC interval (500 ops instead of default 1000)
    EtchContextOptions opts = {
        .verbose = 0,
        .debug = 0,
        .gcCycleInterval = 500  // Run GC more frequently for this test
    };
    EtchContext ctx = etch_context_new_with_options(&opts);
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    printf("=== Testing Different GC Budget Levels ===\n");
    printf("Moderate allocation with varying budgets\n\n");

    // Compile the test script
    if (etch_compile_file(ctx, "frame_budget_adaptive.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        fprintf(stderr, "Note: frame_budget_adaptive.etch must be in current directory\n");
        etch_context_free(ctx);
        return 1;
    }

    // Test with different budgets
    int64_t budgets[] = {500, 1000, 2000, 5000};  // us
    const char* budget_names[] = {"0.5ms", "1ms", "2ms", "5ms"};

    for (int i = 0; i < 4; i++) {
        printf("Testing with %s budget:\n", budget_names[i]);

        for (int frame = 0; frame < 5; frame++) {
            etch_begin_frame(ctx, budgets[i]);
            etch_execute(ctx);

            EtchGCFrameStats stats = etch_get_gc_stats(ctx);
            printf("  Frame %d: %lld/%lld us, checked: %d objects\n",
                   frame,
                   (long long)stats.gcTimeUs,
                   (long long)stats.budgetUs,
                   stats.dirtyObjects);
        }
        printf("\n");
    }

    printf("===============================================\n");
    printf("Test completed successfully\n");
    printf("===============================================\n");

    etch_context_free(ctx);
    return 0;
}
