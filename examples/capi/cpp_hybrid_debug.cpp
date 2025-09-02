/**
 * C++ Hybrid Debug Example
 *
 * Demonstrates transparent remote debugging of Etch scripts embedded in C++ applications.
 * This example shows how to:
 * - Embed Etch scripting in a C++ application
 * - Enable transparent remote debugging via environment variables
 * - Debug both C++ and Etch code simultaneously in VSCode
 *
 * Usage:
 *   Normal execution:
 *     ./cpp_hybrid_debug script.etch
 *
 *   With remote debugging (transparent):
 *     ETCH_DEBUG_PORT=9823 ./cpp_hybrid_debug script.etch
 *
 * The environment variable ETCH_DEBUG_PORT automatically enables remote debugging.
 * No code changes needed! Just set the env var and VSCode can attach.
 */

#include <iostream>
#include <string>
#include <cstdlib>

#include "../../include/etch.hpp"

// Example C++ function that could be called before/after Etch execution
void setupApplication() {
    std::cout << "=== C++ Application Startup ===\n";
    std::cout << "Initializing C++ subsystems...\n";
    std::cout << "Ready to execute Etch scripts.\n\n";
}

void shutdownApplication() {
    std::cout << "\n=== C++ Application Shutdown ===\n";
    std::cout << "Cleaning up resources...\n";
    std::cout << "Done.\n";
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <script.etch>\n";
        std::cerr << "\n";
        std::cerr << "Transparent Remote Debugging:\n";
        std::cerr << "  To enable debugging, set environment variable:\n";
        std::cerr << "    ETCH_DEBUG_PORT=9823 " << argv[0] << " <script.etch>\n";
        std::cerr << "\n";
        std::cerr << "  Then in VSCode, use 'Attach to Etch Remote Debugger' configuration\n";
        std::cerr << "  or the compound 'Debug C++ + Etch (Remote)' configuration.\n";
        return 1;
    }

    const std::string scriptPath = argv[1];

    // Check if remote debugging is enabled (transparent detection)
    const char* debugPort = std::getenv("ETCH_DEBUG_PORT");
    if (debugPort) {
        std::cout << "=== REMOTE DEBUGGING ENABLED ===\n";
        std::cout << "Debug port: " << debugPort << "\n";
        std::cout << "Waiting for debugger connection...\n\n";
    }

    try {
        // C++ application setup (you can debug this with gdb/lldb)
        setupApplication();

        // Create Etch context with debug mode enabled
        // When debug=true and ETCH_DEBUG_PORT is set, remote debugging is automatic
        etch::Context ctx(false, true);  // verbose=false, debug=true

        std::cout << "=== Compiling Etch Script: " << scriptPath << " ===\n";

        // Compile the Etch script
        ctx.compileFile(scriptPath);

        std::cout << "Compilation successful!\n\n";

        // Set some C++ globals that Etch can access
        std::cout << "=== Setting up C++ <-> Etch integration ===\n";
        ctx.setGlobal("cpp_version", etch::Value("1.0.0"));
        ctx.setGlobal("cpp_ready", etch::Value(true));
        ctx.setGlobal("magic_number", etch::Value(static_cast<int64_t>(42)));
        std::cout << "Globals set from C++\n\n";

        std::cout << "=== Executing Etch Script ===\n";
        std::cout << "(If remote debugging is enabled, debugger will attach now)\n\n";

        // Execute the Etch script
        // NOTE: If ETCH_DEBUG_PORT is set, this will:
        //   1. Start TCP server on specified port
        //   2. Wait for debugger connection (with timeout)
        //   3. Enter debug mode allowing breakpoints, stepping, etc.
        //   4. Continue normally if no debugger connects
        int exitCode = ctx.execute();

        std::cout << "\n=== Etch Script Execution Complete ===\n";
        std::cout << "Exit code: " << exitCode << "\n\n";

        // Read back globals modified by Etch
        std::cout << "=== Reading Etch Results ===\n";
        try {
            auto result = ctx.getGlobal("magic_number");
            std::cout << "magic_number (possibly modified by Etch): " << result.toInt() << "\n";
        } catch (const etch::Exception& e) {
            std::cout << "Note: magic_number not found (that's ok)\n";
        }

        // C++ application cleanup (you can debug this with gdb/lldb too)
        shutdownApplication();

        return exitCode;

    } catch (const etch::Exception& e) {
        std::cerr << "\nERROR: " << e.what() << "\n";
        shutdownApplication();
        return 1;
    }

    return 0;
}
