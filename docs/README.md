# Etch Language Documentation

Welcome to the Etch programming language documentation!

## Documentation Structure

### Getting Started

- **[index.md](index.md)** - Start here! Overview of Etch, its strengths, and quick start guide

### Core Language Features

1. **[types.md](types.md)** - Type system and type inference
   - Primitive types (int, float, string, bool, char)
   - Arrays and compound types
   - Algebraic data types (option[T], result[T])
   - Generics and type inference
   - When and how to use type annotations

2. **[functions.md](functions.md)** - Functions and UFCS
   - Function declaration and parameters
   - UFCS (Uniform Function Call Syntax) for method-style calls
   - Function overloading and higher-order functions
   - Recursion patterns

3. **[control-flow.md](control-flow.md)** - Control structures
   - Conditional statements (if/else)
   - Loops (for, while)
   - Pattern matching (match expressions)
   - Loop control (break, continue)

4. **[modules.md](modules.md)** - Code organization and FFI
   - Module system and imports
   - Exporting functions
   - C FFI (Foreign Function Interface)
   - Best practices for code organization

5. **[globals.md](globals.md)** - Global variables
   - Global declaration (let vs var)
   - Compile-time initialization rules
   - Safety guarantees
   - Best practices for global state

### Safety and Verification

6. **[safety.md](safety.md)** - Compile-time safety checks (Overview)
   - What safety guarantees Etch provides
   - How the prover works
   - Working with the prover
   - Unreachable code detection
   - Common patterns for safe code

7. **[overflow.md](overflow.md)** - Overflow detection (Detailed)
   - How overflow checking works
   - Range tracking and analysis
   - Writing overflow-safe code
   - Debugging overflow errors

### Advanced Features

8. **[comptime.md](comptime.md)** - Compile-time evaluation
   - Comptime expressions and blocks
   - File embedding at compile time
   - Code injection and metaprogramming
   - Dynamic code generation
   - Build-time configuration

9. **[operator-overloading.md](operator-overloading.md)** - Custom operators
   - Overloading arithmetic operators (+, -, *, /, %)
   - Overloading comparison operators (==, !=, <, >, <=, >=)
   - Use cases and best practices
   - When to use UFCS instead

## Learning Path

### For Beginners

1. Start with [index.md](index.md) to understand what Etch is
2. Read [types.md](types.md) to learn the type system
3. Learn [functions.md](functions.md) and discover UFCS
4. Understand [control-flow.md](control-flow.md) for conditionals and loops
5. Try writing some programs!

### For Intermediate Users

1. Master [safety.md](safety.md) to understand compile-time verification
2. Read [overflow.md](overflow.md) for deep dive on overflow checking
3. Learn [modules.md](modules.md) to organize larger projects
4. Study [globals.md](globals.md) for application configuration

### For Advanced Users

1. Deep dive into the prover's [range analysis](overflow.md#how-it-works)
2. Master [compile-time evaluation](comptime.md) for metaprogramming
3. Learn [operator overloading](operator-overloading.md) for custom types
4. Explore [C FFI](modules.md#c-ffi-foreign-function-interface) for system programming
5. Study advanced [pattern matching](control-flow.md#pattern-matching) techniques
6. Explore [higher-order functions](functions.md#higher-order-functions)

## Quick Reference

### Syntax Quick Reference

```etch
// Variables
let x = 42;              // Immutable
var y = 10;              // Mutable

// Functions
fn add(a: int, b: int) -> int {
    return a + b;
}

// UFCS
x.double().print();      // Method-style calls

// Control flow
if x > 0 { }
for i in 0 ..< 10 { }
while condition { }

// Pattern matching
match value {
    some(x) => process(x),
    none => handleError(),
}

// Arrays
let arr = [1, 2, 3];
let first = arr[0];

// Imports
import lib/math
import ffi cmath {
    fn sin(x: float) -> float;
}
```

### Safety Features

- ✅ **Memory safe** - Array bounds checked at compile time
- ✅ **Integer overflow** - Detected via range analysis
- ✅ **No null pointers** - Use `option[T]` instead
- ✅ **No uninitialized variables** - Compiler enforces initialization
- ✅ **Type safe** - Static types with full inference
- ✅ **Zero runtime overhead** - All checks at compile time

## Examples

See the `examples/` directory for comprehensive code examples:

```bash
# Run examples
./etch --run examples/arrays_test.etch
./etch --run examples/match_pattern_test.etch
./etch --run examples/ufcs_advanced_test.etch
```

## Getting Help

- **Compiler errors**: Read the error message carefully - Etch provides detailed explanations
- **Verbose mode**: Use `--verbose` flag to see what the prover is doing
- **Examples**: Check `examples/` directory for similar code patterns
- **This documentation**: Use the navigation above to find relevant topics

## Contributing to Documentation

Found an error or want to improve the docs? Contributions are welcome!

- Documentation source: `docs/*.md`
- Follow the existing structure and style
- Include practical code examples
- Test all code examples

---

**Happy coding with Etch! 🚀**
