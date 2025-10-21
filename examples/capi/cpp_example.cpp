/**
 * C++ example demonstrating Etch C++ wrapper usage
 *
 * This example shows:
 * - Modern C++ interface with RAII
 * - Exception-based error handling
 * - Type-safe value handling
 */

#include <iostream>
#include <string>

#include "../../include/etch.hpp"

int main() {
    std::cout << "=== Etch C++ Wrapper Example ===\n\n";

    try {
        // Create context (RAII - automatically cleaned up)
        etch::Context ctx;

        // Example 1: Compile and execute simple code
        std::cout << "Example 1: Compile and execute simple code\n";
        ctx.compileString(
            "fn main() -> int {\n"
            "    print(\"Hello from Etch via C++!\");\n"
            "    return 0;\n"
            "}\n",
            "simple.etch"
        );
        ctx.execute();
        std::cout << "\n";

        // Example 2: Work with global variables
        std::cout << "Example 2: Work with global variables\n";

        // Set a global variable from C++ (after previous compilation)
        ctx.setGlobal("my_number", etch::Value(static_cast<int64_t>(42)));
        std::cout << "Set 'my_number' to 42 from C++\n";

        // Read it back
        etch::Value myNum = ctx.getGlobal("my_number");
        std::cout << "Got 'my_number' back: " << myNum.toInt() << "\n";

        // Modify global from C++
        ctx.setGlobal("my_number", etch::Value(static_cast<int64_t>(100)));
        myNum = ctx.getGlobal("my_number");
        std::cout << "Changed 'my_number' to: " << myNum.toInt() << "\n";
        std::cout << "\n";

        // Example 3: Type-safe value operations
        std::cout << "Example 3: Type-safe value operations\n";

        etch::Value intVal(static_cast<int64_t>(42));
        etch::Value floatVal(3.14159);
        etch::Value boolVal(true);
        etch::Value stringVal("Hello, C++!");
        etch::Value nilVal;

        std::cout << "  intVal is int: " << (intVal.isInt() ? "yes" : "no") << "\n";
        std::cout << "  floatVal is float: " << (floatVal.isFloat() ? "yes" : "no") << "\n";
        std::cout << "  boolVal is bool: " << (boolVal.isBool() ? "yes" : "no") << "\n";
        std::cout << "  stringVal is string: " << (stringVal.isString() ? "yes" : "no") << "\n";
        std::cout << "  nilVal is nil: " << (nilVal.isNil() ? "yes" : "no") << "\n";

        std::cout << "  int value: " << intVal.toInt() << "\n";
        std::cout << "  float value: " << floatVal.toFloat() << "\n";
        std::cout << "  bool value: " << (boolVal.toBool() ? "true" : "false") << "\n";
        std::cout << "  string value: " << stringVal.toString() << "\n";
        std::cout << "\n";

        // Example 4: Error handling with exceptions
        std::cout << "Example 4: Error handling with exceptions\n";
        try {
            ctx.compileString("invalid etch code {{{", "bad.etch");
        } catch (const etch::Exception& e) {
            std::cout << "  Caught expected exception: " << e.what() << "\n";
        }

        try {
            etch::Value str("not a number");
            int64_t num = str.toInt(); // Will throw
            (void)num; // Suppress unused warning
        } catch (const etch::Exception& e) {
            std::cout << "  Caught expected type conversion error: " << e.what() << "\n";
        }
        std::cout << "\n";

        std::cout << "=== All examples completed successfully ===\n";

    } catch (const etch::Exception& e) {
        std::cerr << "Unexpected error: " << e.what() << "\n";
        return 1;
    }

    return 0;
}
