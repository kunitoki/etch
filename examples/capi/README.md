# Etch C/C++ API Examples

This directory contains examples demonstrating how to use Etch as an embedded scripting engine in C and C++ applications.

## Overview

Etch can be compiled as a shared library (`libetch.so` / `libetch.dylib` / `etch.dll`) and linked into C/C++ applications. This allows you to use Etch as a safe, statically-typed scripting language with:

- **Compile-time type checking** - Catch errors before runtime
- **Memory safety** - No buffer overflows, null pointer dereferences, or use-after-free
- **Clean C API** - Simple, well-documented interface
- **Modern C++ wrapper** - RAII, exceptions, and type safety
- **Host function registration** - Expose C/C++ functions to Etch scripts
- **Bidirectional value passing** - Easy conversion between C/C++ and Etch types

## Building the Library

First, build the Etch shared library:

```bash
cd ../..  # Go to project root
just build-lib
```

This will create `lib/libetch.so` (or `.dylib` on macOS).

## Building the Examples

From this directory:

```bash
make all
```

This will build all examples:
- `simple_example` - Basic C API usage
- `host_functions_example` - Registering C functions
- `cpp_example` - C++ wrapper usage

## Running the Examples

```bash
./simple_example
./host_functions_example
./cpp_example
```

## API Overview

### C API (`include/etch.h`)

The C API provides a minimal, portable interface:

```c
#include "etch.h"

// Create context
EtchContext* ctx = etch_context_new();

// Compile code
if (etch_compile_string(ctx, source, "script.etch") == 0) {
    // Execute
    etch_execute(ctx);
} else {
    printf("Error: %s\n", etch_get_error(ctx));
}

// Clean up
etch_context_free(ctx);
```

**Key features:**
- Opaque handles for contexts and values
- C-style error handling (return codes + error strings)
- Manual memory management
- Compatible with any C/C++ compiler

### C++ API (`include/etch.hpp`)

The C++ wrapper provides a modern interface:

```cpp
#include "etch.hpp"

try {
    etch::Context ctx;
    ctx.compileString(source, "script.etch");
    ctx.execute();
} catch (const etch::Exception& e) {
    std::cerr << "Error: " << e.what() << std::endl;
}
```

**Key features:**
- RAII for automatic resource management
- Exception-based error handling
- Move semantics for efficient value passing
- Type-safe value extraction
- Works with C++11 and later

## Value Types

Etch supports these value types in the C API:

| Etch Type | C Type | Create Function | Extract Function |
|-----------|--------|----------------|------------------|
| `int` | `int64_t` | `etch_value_new_int()` | `etch_value_to_int()` |
| `float` | `double` | `etch_value_new_float()` | `etch_value_to_float()` |
| `bool` | `int` | `etch_value_new_bool()` | `etch_value_to_bool()` |
| `string` | `const char*` | `etch_value_new_string()` | `etch_value_to_string()` |
| `char` | `char` | `etch_value_new_char()` | `etch_value_to_char()` |
| `nil` | - | `etch_value_new_nil()` | `etch_value_is_nil()` |

## Host Functions

You can register C functions that are callable from Etch:

```c
EtchValue my_function(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    // Validate arguments
    if (numArgs != 2) return NULL;

    // Extract values
    int64_t a, b;
    etch_value_to_int(args[0], &a);
    etch_value_to_int(args[1], &b);

    // Return result
    return etch_value_new_int(a + b);
}

// Register the function
etch_register_function(ctx, "my_function", my_function, NULL);
```

**Note:** Full integration with the Etch type system for host functions is in progress. Currently, registered functions can be called from C but the Etch compiler doesn't yet know about their signatures.

## Global Variables

You can read and write Etch global variables from C/C++:

```c
// Set global variable
EtchValue val = etch_value_new_int(42);
etch_set_global(ctx, "my_var", val);
etch_value_free(val);

// Get global variable
EtchValue result = etch_get_global(ctx, "my_var");
int64_t value;
etch_value_to_int(result, &value);
etch_value_free(result);
```

## Error Handling

### C API
```c
if (etch_compile_file(ctx, "script.etch") != 0) {
    const char* error = etch_get_error(ctx);
    fprintf(stderr, "Error: %s\n", error);
    // Note: error string is owned by context, don't free it
}
```

### C++ API
```cpp
try {
    ctx.compileFile("script.etch");
} catch (const etch::Exception& e) {
    std::cerr << "Error: " << e.what() << std::endl;
}
```

## Memory Management

### C API
- Values created with `etch_value_new_*()` must be freed with `etch_value_free()`
- Contexts created with `etch_context_new()` must be freed with `etch_context_free()`
- Strings returned by `etch_value_to_string()` are owned by the value
- Error strings from `etch_get_error()` are owned by the context

### C++ API
- All resources are automatically managed via RAII
- Values and contexts are automatically freed when they go out of scope
- Use move semantics to transfer ownership efficiently

## Linking

### Linux
```bash
gcc -o myapp myapp.c -I/path/to/etch/include -L/path/to/etch/lib -letch -lm
```

### macOS
```bash
clang -o myapp myapp.c -I/path/to/etch/include -L/path/to/etch/lib -letch -lm
```

### Runtime Library Path

On Unix systems, you may need to set `LD_LIBRARY_PATH` (Linux) or `DYLD_LIBRARY_PATH` (macOS):

```bash
export LD_LIBRARY_PATH=/path/to/etch/lib:$LD_LIBRARY_PATH
./myapp
```

Or use rpath flags during compilation (see the Makefile for examples).

## Use Cases

Etch as an embedded scripting engine is ideal for:

1. **Game scripting** - Safe, fast scripting for game logic
2. **Application plugins** - Allow users to extend your app
3. **Configuration** - More powerful than JSON/YAML, safer than Lua
4. **Data processing** - Safe scripts for data transformation
5. **Testing** - Script-driven test scenarios
6. **DSLs** - Domain-specific languages on top of Etch

## Advanced Topics

### Thread Safety

The current API is **not thread-safe**. Each thread should have its own `EtchContext`.

### Performance

- Etch uses a register-based bytecode VM for fast execution
- The C backend can generate standalone C code for maximum performance
- JIT compilation is planned for future versions

### Debugging

Enable verbose logging:
```c
etch_context_set_verbose(ctx, 1);
```

## Future Enhancements

Planned improvements to the C API:

- [ ] Full integration of host functions with type system
- [ ] Array and table manipulation from C
- [ ] Option and Result type support in C API
- [ ] Async/await support for host functions
- [ ] Better integration with the C backend
- [ ] JIT compilation support
- [ ] Debugging API (breakpoints, stepping, etc.)
- [ ] Serialization of compiled bytecode

## Questions?

See the main Etch documentation or file an issue on GitHub.
