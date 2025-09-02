# Etch Language Documentation

Welcome to Etch! This documentation will guide you through everything you need to know about writing safe, fast, and expressive programs in Etch.

## What Makes Etch Special?

Etch is a statically-typed language that combines **compile-time safety verification** with **zero runtime overhead**. Before your code even runs, the Etch prover analyzes your program to guarantee it's free from common bugs like integer overflow, array bounds violations, null pointer dereferences, and uninitialized variables.

The result? You write code that feels simple and expressive, but get the safety guarantees of formal verification and the performance of hand-optimized C.

## Documentation Structure

### Getting Started

**[index.md](index.md)** - Start here for an overview of Etch's philosophy, key features, and a quick tour of the language. Perfect for understanding what Etch is and whether it's right for your project.

### Core Language Features

These guides cover the fundamental building blocks of Etch programs:

1. **[types.md](types.md)** - The type system and inference

   Learn about Etch's expressive type system, from basic primitives to algebraic data types. Discover how type inference lets you write code that feels dynamic but is fully statically checked.

2. **[functions.md](functions.md)** - Functions and UFCS

   Master function definitions, discover UFCS (Uniform Function Call Syntax) for beautiful left-to-right code, and learn about higher-order functions and recursion.

3. **[control-flow.md](control-flow.md)** - Conditionals, loops, and patterns

   Explore if expressions, for and while loops, and powerful pattern matching that combines type checking with destructuring.

4. **[modules.md](modules.md)** - Code organization and C interop

   Structure larger projects with modules, export public APIs, and seamlessly call C libraries through Etch's simple FFI system.

5. **[globals.md](globals.md)** - Global variables and state

   Understand when and how to use global state safely, with compile-time initialization guarantees.

### Safety and Verification

The heart of Etch's safety story:

6. **[safety.md](safety.md)** - Compile-time safety overview

   Discover what "if it compiles, it's safe" really means. Learn about all the safety guarantees Etch provides and how the prover works behind the scenes.

7. **[overflow.md](overflow.md)** - Deep dive on overflow detection

   Understand how Etch's range analysis prevents integer overflow at compile time, with practical examples and debugging strategies.

### Advanced Features

Power features for metaprogramming and performance:

8. **[comptime.md](comptime.md)** - Compile-time evaluation

   Run code during compilation to embed files, pre-compute expensive calculations, and generate code dynamically.

9. **[operator-overloading.md](operator-overloading.md)** - Custom operators

   Define custom behavior for operators on your types, enabling intuitive syntax for domain-specific operations.

### Development Tools

Tools for debugging and embedding:

10. **[debugging.md](debugging.md)** - Interactive debugging

    Debug Etch programs directly, remotely debug scripts embedded in C++ applications, or use compound debugging to step through both languages simultaneously.

11. **[c-api.md](c-api.md)** - Embedding Etch in C/C++

    Learn the C API for embedding Etch as a scripting language in your applications, with full control over execution and error handling.

## Learning Paths

### New to Etch?

Start with these fundamentals to build a solid foundation:

1. **[index.md](index.md)** - Get the big picture of what Etch is and why it exists
2. **[types.md](types.md)** - Learn the type system and how inference works
3. **[functions.md](functions.md)** - Write and chain functions with UFCS
4. **[control-flow.md](control-flow.md)** - Master conditionals, loops, and pattern matching

After these, you'll be ready to write your first Etch programs!

### Building Real Applications?

Once you're comfortable with the basics, explore these topics:

1. **[safety.md](safety.md)** - Understand the compile-time safety guarantees that make Etch special
2. **[overflow.md](overflow.md)** - Learn how the prover prevents overflow bugs before runtime
3. **[modules.md](modules.md)** - Organize code into modules and call C libraries via FFI
4. **[globals.md](globals.md)** - Manage application-wide state safely

### Ready for Advanced Techniques?

Push Etch to its limits with these power features:

- **[comptime.md](comptime.md)** - Execute code at compile time for metaprogramming and optimization
- **[operator-overloading.md](operator-overloading.md)** - Create intuitive DSLs with custom operators
- **[c-api.md](c-api.md)** - Embed Etch as a scripting language in C/C++ applications
- **[debugging.md](debugging.md)** - Debug with full source-level visibility, even when embedded

## Quick Reference

### Etch at a Glance

```etch
// Variables: let for immutable, var for mutable
let x = 42;
var count = 0;

// Functions with explicit signatures
fn add(a: int, b: int) -> int {
    return a + b;
}

// UFCS: call functions like methods
5.double().add(3);

// Pattern matching for type-safe branching
match result {
    ok(value) => process(value),
    error(msg) => handleError(msg),
}
```

### Core Safety Guarantees

Etch's prover ensures these properties at compile time:

- **Memory safe** - No buffer overruns; array accesses proven in-bounds
- **Overflow free** - Range analysis prevents integer overflow/underflow
- **Null safe** - No null pointers; use `option[T]` for optional values
- **Initialized** - All variables must be initialized before use
- **Type safe** - Static types with full inference; no implicit conversions
- **Zero cost** - All verification happens at compile time with no runtime overhead

## Learning by Example

The `examples/` directory contains working code demonstrating Etch features:

```bash
# Basic features
./etch --run examples/arrays_test.etch        # Array operations and bounds checking
./etch --run examples/match_pattern_test.etch # Pattern matching with option/result
./etch --run examples/ufcs_advanced_test.etch # UFCS method chaining

# C interop
./etch --run examples/cffi_math_test.etch     # Calling C library functions
```

Browse the `examples/` directory to find patterns similar to what you're building.

## Getting Help

When you're stuck:

- **Read compiler errors carefully** - Etch provides detailed, actionable error messages that explain what went wrong and often suggest fixes
- **Use `--verbose` flag** - See exactly what the prover is analyzing and where it's getting stuck
- **Check examples/** - Find similar patterns and learn from working code
- **Consult this documentation** - Use the navigation above to dive deep into specific features

## Contributing

Found a typo or want to improve the documentation? We welcome contributions!

- Documentation lives in `docs/*.md`
- Keep the tone conversational and example-driven
- Break up large code blocks into digestible snippets
- Test all code examples to ensure they work

---

**Happy coding with Etch!**
