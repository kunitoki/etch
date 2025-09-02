/**
 * Zero Budget Test - Testing adaptive mode without frame budget enforcement
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "../../include/etch.h"

int main(void) {
    printf("===============================================\n");
    printf("Etch Frame Budget API - Adaptive Mode Test\n");
    printf("===============================================\n\n");

    // Create Etch context with defaults
    EtchContext ctx = etch_context_new();
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    printf("=== Testing Adaptive Mode (No Budget Enforcement) ===\n");
    printf("Setting budget to 0 to test adaptive-only GC\n\n");

    // Compile the test script
    if (etch_compile_file(ctx, "frame_budget_zero.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        fprintf(stderr, "Note: frame_budget_zero.etch must be in current directory\n");
        etch_context_free(ctx);
        return 1;
    }

    // Run 10 frames with zero budget (adaptive mode only)
    for (int frame = 0; frame < 10; frame++) {
        etch_begin_frame(ctx, 0);  // Zero budget = adaptive mode only
        etch_execute(ctx);

        EtchGCFrameStats stats = etch_get_gc_stats(ctx);
        printf("Frame %d: %lld/%lld us, checked: %d objects\n",
               frame,
               (long long)stats.gcTimeUs,
               (long long)stats.budgetUs,
               stats.dirtyObjects);
    }

    printf("\n===============================================\n");
    printf("Test completed successfully\n");
    printf("===============================================\n");

    etch_context_free(ctx);
    return 0;
}
