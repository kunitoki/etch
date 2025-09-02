/**
 * Frame Budget Example - Demonstrating GC frame budget API for game engines
 *
 * This example shows:
 * - Setting GC time budgets per frame
 * - Monitoring GC statistics
 * - Detecting when GC needs more time
 * - Typical game loop integration patterns
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "../../include/etch.h"

// Simulate a game loop with frame budget control
void game_loop_with_budget(EtchContext ctx, int num_frames) {
    printf("=== Game Loop with Frame Budget ===\n");
    printf("Simulating %d frames at 60fps (16.67ms per frame)\n", num_frames);
    printf("Allocating 2ms GC budget per frame\n\n");

    for (int frame = 0; frame < num_frames; frame++) {
        // Start frame with 2ms (2000us) GC budget in a 16ms frame
        etch_begin_frame(ctx, 2000);

        // Debug: Check stats immediately after begin_frame
        EtchGCFrameStats debugStats = etch_get_gc_stats(ctx);
        if (frame == 0) {
            printf("Debug after begin_frame: budget=%lld us\n", (long long)debugStats.budgetUs);
        }

        // Execute game logic (allocates many objects)
        if (etch_execute(ctx) != 0) {
            fprintf(stderr, "Execution failed on frame %d: %s\n",
                    frame, etch_get_error(ctx));
            return;
        }

        // Get GC statistics for this frame
        EtchGCFrameStats stats = etch_get_gc_stats(ctx);

        printf("Frame %3d: GC used %5lld/%5lld us, checked: %4d objects",
               frame,
               (long long)stats.gcTimeUs,
               (long long)stats.budgetUs,
               stats.dirtyObjects);

        // Check if GC is backed up and needs more time
        if (etch_needs_gc_frame(ctx)) {
            printf(" [WARNING: GC needs full frame!]\n");

            // In a real game engine, you would:
            // 1. Skip rendering this frame
            // 2. Give full 16ms to GC
            // 3. Continue with next frame
            printf("  -> Giving full 16ms frame to GC\n");
            etch_begin_frame(ctx, 16000);  // Full frame budget
        } else if (stats.gcTimeUs > 1000) {
            printf(" [GC taking >1ms]\n");
        } else {
            printf(" [OK]\n");
        }

        // Check if heap needs collection (informational)
        if (etch_heap_needs_collection(ctx)) {
            // This is a hint that cycle detection would be beneficial
            // when budget allows
        }
    }
    printf("\n");
}

// Demonstrate heavy allocation workload with reference cycles
void heavy_allocation_test(EtchContext ctx) {
    printf("=== Heavy Allocation Test ===\n");
    printf("Allocating 2500 nodes per frame to stress-test GC\n");
    printf("Running 50 frames to show budget enforcement and GC pressure\n\n");

    // Compile the example script with reference cycles
    if (etch_compile_file(ctx, "frame_budget_heavy.etch") != 0) {
        fprintf(stderr, "Compilation failed: %s\n", etch_get_error(ctx));
        fprintf(stderr, "Note: frame_budget_heavy.etch must be in current directory\n");
        return;
    }

    // Run 50 frames - each creates 2500 nodes
    // This creates heavy GC pressure and may exceed budgets
    game_loop_with_budget(ctx, 50);
}

int main(void) {
    printf("===============================================\n");
    printf("Etch Frame Budget API - Heavy Allocation Test\n");
    printf("===============================================\n\n");

    // Create Etch context with default options (verbose=0, debug=0, default GC interval)
    EtchContextOptions opts = {
        .verbose = 0,
        .debug = 0,
        .gcCycleInterval = 0  // 0 = use default (1000)
    };
    EtchContext ctx = etch_context_new_with_options(&opts);
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    heavy_allocation_test(ctx);

    printf("\n");
    printf("===============================================\n");
    printf("Test completed successfully\n");
    printf("===============================================\n");

    // Clean up
    etch_context_free(ctx);

    return 0;
}
