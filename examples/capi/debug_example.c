/**
 * Debug Example
 *
 * Demonstrates how to create a debuggable C binary using Etch as an embedded
 * scripting engine. This program acts as a Debug Adapter Protocol (DAP) server,
 * allowing VSCode to debug Etch scripts running inside your C application.
 *
 * Usage:
 *   ./debug_example <script.etch>
 *
 * The program reads DAP requests from stdin and writes responses to stdout,
 * enabling VSCode's debugger to control execution, set breakpoints, inspect
 * variables, and step through Etch code.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../include/etch.h"

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <script.etch>\n", argv[0]);
        fprintf(stderr, "\n");
        fprintf(stderr, "This program implements a Debug Adapter Protocol (DAP) server\n");
        fprintf(stderr, "for debugging Etch scripts. It communicates via stdin/stdout.\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "To debug with VSCode, configure launch.json to use this binary:\n");
        fprintf(stderr, "  \"program\": \"${workspaceFolder}/debug_example\",\n");
        fprintf(stderr, "  \"args\": [\"${workspaceFolder}/script.etch\"]\n");
        return 1;
    }

    const char* scriptPath = argv[1];

    // Create Etch context with debug mode enabled
    EtchContext ctx = etch_context_new_with_options(0, 1);  // verbose=off, debug=on
    if (!ctx) {
        fprintf(stderr, "Failed to create Etch context\n");
        return 1;
    }

    // Compile the Etch script
    fprintf(stderr, "DEBUG: Compiling %s\n", scriptPath);
    if (etch_compile_file(ctx, scriptPath) != 0) {
        const char* error = etch_get_error(ctx);
        fprintf(stderr, "Compilation failed: %s\n", error ? error : "unknown error");

        // Send compilation error as JSON to VSCode
        printf("{\"seq\":999,\"type\":\"event\",\"event\":\"output\","
               "\"body\":{\"category\":\"stderr\",\"output\":\"Error: %s\\n\"}}\n",
               error ? error : "compilation failed");
        fflush(stdout);

        // Send terminated event
        printf("{\"seq\":1000,\"type\":\"event\",\"event\":\"terminated\",\"body\":{}}\n");
        fflush(stdout);

        etch_context_free(ctx);
        return 1;
    }

    fprintf(stderr, "DEBUG: Compilation successful\n");

    // Create debug server
    EtchDebugServer server = etch_debug_server_new(ctx, scriptPath);
    if (!server) {
        fprintf(stderr, "Failed to create debug server\n");
        etch_context_free(ctx);
        return 1;
    }

    fprintf(stderr, "DEBUG: Debug server started, waiting for DAP messages\n");

    // Main debug loop - read DAP requests from stdin, send responses to stdout
    char line[8192];
    int serverAlive = 1;

    while (serverAlive && fgets(line, sizeof(line), stdin)) {
        // Remove trailing newline
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
        }

        if (strlen(line) == 0) {
            continue;  // Skip empty lines
        }

        fprintf(stderr, "DEBUG: Received request: %.100s%s\n",
                line, strlen(line) > 100 ? "..." : "");

        // Handle the debug request
        char* response = NULL;
        int result = etch_debug_server_handle_request(server, line, &response);

        if (response) {
            fprintf(stderr, "DEBUG: Sending response: %.100s%s\n",
                    response, strlen(response) > 100 ? "..." : "");

            // Send response to VSCode
            printf("%s\n", response);
            fflush(stdout);

            // Check if this was a disconnect command
            if (strstr(line, "\"disconnect\"") != NULL) {
                fprintf(stderr, "DEBUG: Disconnect command received, exiting\n");
                serverAlive = 0;
            }

            // Free the response string
            etch_free_string(response);
        } else {
            fprintf(stderr, "DEBUG: No response generated (result=%d)\n", result);
        }
    }

    fprintf(stderr, "DEBUG: Debug server stopped\n");

    // Cleanup
    etch_debug_server_free(server);
    etch_context_free(ctx);

    return 0;
}
