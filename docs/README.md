# Etch Language Documentation

Welcome to Etch! This documentation will guide you through everything you need to know about writing safe, fast game scripts in Etch.

## What Makes Etch Special?

Etch is a statically-typed scripting language designed for **game development**. It runs in two modes: a fast VM for development with hot-reloading and debugging, and a C backend for production performance. Before your code runs, the Etch compiler verifies it's free from common bugs like integer overflow, array bounds violations, and uninitialized variables.

The result? You get Lua-style iteration speed during development, compile-time safety guarantees, and native-level performance in production—all from the same source code.

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

Tools crucial for game development workflows:

10. **[debugging.md](debugging.md)** - Interactive debugging

    Debug Etch programs directly in VSCode with breakpoints and stepping. Remote-debug scripts embedded in running games. Use compound debugging to step through both Etch scripts and C++ engine code simultaneously.

11. **[c-api.md](c-api.md)** - Embedding Etch in game engines

    Learn the C API for embedding Etch as a scripting language in game engines and applications. Covers hot-reloading, bidirectional value passing, and performance considerations.

12. **[performance.md](performance.md)** - Performance benchmarks

    Understand Etch's performance characteristics compared to Python, Lua, and C. Learn when to use VM mode vs C backend for different game scripting scenarios.

## Learning Paths

### New to Etch?

Start with these fundamentals to build a solid foundation:

1. **[index.md](index.md)** - Get the big picture: Etch as a game scripting language with dual execution modes
2. **[types.md](types.md)** - Learn the type system and how inference works
3. **[functions.md](functions.md)** - Write and chain functions with UFCS
4. **[control-flow.md](control-flow.md)** - Master conditionals, loops, and pattern matching

After these, you'll be ready to write game scripts in Etch!

### Integrating with Your Game Engine?

Once you're comfortable with the basics, explore these topics:

1. **[c-api.md](c-api.md)** - Embed Etch in your C/C++ game engine
2. **[debugging.md](debugging.md)** - Set up compound debugging for Etch + C++
3. **[performance.md](performance.md)** - Understand when to use VM vs C backend
4. **[safety.md](safety.md)** - Understand the compile-time safety guarantees
5. **[modules.md](modules.md)** - Organize code into modules and call C libraries via FFI

### Ready for Advanced Features?

Unlock Etch's power features for sophisticated game systems:

- **[comptime.md](comptime.md)** - Execute code at compile time to pre-compute data tables or embed assets
- **[operator-overloading.md](operator-overloading.md)** - Create intuitive DSLs for AI behavior or math
- **[overflow.md](overflow.md)** - Deep dive on how range analysis prevents bugs

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
- **Null safe** - Multiple layers of protection:
  - `option[T]` and `result[T]` monads for optional values with mandatory pattern matching
  - `ref[T]` - Strong references, can be nil, prover enforces checking when potentially nil
  - `weak[T]` - Weak references, can be nil, must be checked before use or promotion to `ref[T]`
  - The prover uses data flow and control flow analysis to track nil states and enforce checks
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
