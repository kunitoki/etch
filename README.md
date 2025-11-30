# Etch

**Define once, Etch forever.**

A safety-first scripting language designed for game development. Etch runs as fast bytecode in a VM for rapid prototyping and hot-reloading, then compiles to C for production performance. Write once, deploy both ways—with full VSCode debugging, C/C++ interop, type safety, and ergonomic syntax optimized for game scripting.

[![Tests](https://github.com/kunitoki/etch/actions/workflows/test.yml/badge.svg)](https://github.com/kunitoki/etch/actions/workflows/test.yml)

## Why Etch?

**Built for Game Development**
- **Dual execution modes**: VM for iteration speed, C backend for production performance
- **Hot-reload scripts** during development without recompiling your engine
- **Compound debugging**: Step through both Etch scripts and C/C++ engine code together
- **Easy embedding**: Clean C API designed for game engines
- **Budgeted GC pauses for cycles**: Deterministic reference counting keeps frame times stable

**Safety Without Runtime Cost**
- **No null pointer dereferences**: Monads (`option[T]`, `result[T]`) for optional values; `ref[T]` and `weak[T]` references with prover-enforced nil checking when potentially nil
- **No division-by-zero**: Range analysis proves divisors are never zero
- **No integer overflow**: Detect overflow before your code ever runs
- **No uninitialized variables**: Definite initialization analysis
- **No array out-of-bounds**: Compile-time bounds verification

**Developer Experience**
- Clean, minimal C-like syntax that game programmers already know
- Fast bytecode compilation with caching for instant iteration
- VSCode integration with breakpoints, stepping, and variable inspection
- Remote debugging for scripts embedded in running games
- Helpful error messages that guide you to solutions

**Not Aiming to Replace C, Rust, or Nim**
Etch focuses on the sweet spot between Lua-style ease of use and native performance. It's not a systems language—it's a game scripting language that doesn't sacrifice safety or debuggability for speed.

## Quick Start

```bash
# Run a program in VM mode
etch --run examples/simple_hello.etch

# Run a program in C mode
etch --run c examples/simple_hello.etch

# Compile and cache bytecode, or cache .c file
etch --gen examples/simple_hello.etch
etch --gen c examples/simple_hello.etch

# Run test suite (both VM and C)
just tests
just tests-c

# Test a specific file
just test examples/simple_test.etch

# Try the raylib arkanoid demo with hot reload
just demo release
```

## Dual Execution Modes

Etch's killer feature is running the same code in two ways:

**VM Mode (Development)**
- Instant compilation to bytecode (~milliseconds)
- Hot-reload scripts without restarting your game
- Full source-level debugging with breakpoints
- Perfect for rapid iteration

**C Backend (Production)**
- Compiles Etch → C for maximum performance
- Integrates with your existing build system
- Performance competitive with hand-written C
- Same source code, zero changes needed

Switch between modes with a single flag:
```bash
etch --run game_logic.etch      # VM mode
etch --run c game_logic.etch    # C backend
```

## Hello World

```etch
fn main() {
    print("Hello, World!");
}
```

## Language Features

### 1. Compile-Time Execution
Execute code at compile-time to generate optimized runtime code. Functions marked with `comptime()` are evaluated during compilation, and their results are embedded as constants. Use `comptime { }` blocks to run code during compilation (useful for configuration), and `inject()` to generate runtime variables from compile-time computations.

### 2. Range-Based Safety Analysis
Etch tracks value ranges throughout your program to prove safety properties. The prover analyzes integer ranges to prevent division-by-zero, detect potential overflow/underflow, and eliminate dead code branches that can never execute.

### 3. Null Safety
Multiple layers of protection prevent null pointer dereferences:
- `option[T]` and `result[T]` monads force explicit handling through pattern matching
- `ref[T]` and `weak[T]` reference types are analyzed by the prover for potential nil states
- The prover enforces nil checks when it cannot prove a reference is non-nil
- Weak-to-ref promotion requires explicit nil checking

### 4. Uninitialized Variable Detection
The compiler ensures all variables are initialized before use through definite initialization analysis. It tracks initialization through all control flow paths, including conditional branches, loops, and function calls.

### 5. Array Safety
Compile-time bounds checking and safe array operations. The prover verifies array access is within bounds when possible, and enforces runtime checks when necessary. Supports length operator (`#array`), safe indexing, and slicing.

### 6. Type Safety & Inference
Strong static typing with Hindley-Milner style type inference for generics. Types flow through expressions automatically while maintaining full type safety. Supports primitives (`int`, `float`, `bool`, `char`, `string`), arrays, objects, unions, generics, options, and results.

### 7. Pattern Matching
Exhaustive pattern matching for `option[T]` and `result[T]` types. The compiler ensures all cases are handled (some/none, ok/error) through match expressions, making error handling explicit and preventing accidental null access.

### 8. Uniform Function Call Syntax (UFCS)
Call any function as if it were a method using dot notation. The first parameter becomes the receiver, enabling clean left-to-right method chains without OOP overhead.

### 9. Lambdas & Closures
First-class functions with full closure support. Anonymous functions can capture variables from enclosing scope, enabling functional programming patterns like map, filter, and reduce.

### 10. Defer Statements
Guaranteed cleanup code that executes when scope exits. Defer blocks run in reverse order (LIFO), perfect for resource management and cleanup operations.

### 11. Objects & Type Aliases
Define structured data with object types, create type aliases for clarity, and use union types for sum types. Object fields must be initialized before use, enforced by the prover.

### 12. Control Flow
Standard control flow (`if`/`elif`/`else`, `while`, `for`) with safety guarantees. Includes short-circuit boolean operators and loop control statements.

### 13. Default Parameters
Function parameters can have default values, checked for safety at compile-time (e.g., default divisors must be non-zero).

### 14. C FFI & Module System
Import Etch modules or call C functions directly through FFI declarations. Zero-cost abstractions with type-safe boundaries and dynamic library loading.

## Tools & Integration

### Command Line Interface

```bash
# Run with verbose output
etch --run --verbose examples/test.etch

# Release mode (optimized, no debug info)
etch --run --release examples/test.etch

# Dump bytecode for inspection
etch --dump examples/test.etch

# Start debug server for VSCode
etch --debug-server examples/test.etch

# Run test suite
etch --test examples/
```

### VSCode Extension

Full IDE support with:
- Syntax highlighting
- Interactive debugging with breakpoints
- Step-through execution
- Variable inspection
- Compile error highlighting

Install with: `just vscode`

## Building Etch

```bash
# Development build
nim c src/etch.nim

# Optimized release build
just build release

# Run all tests
just tests
just tests-c

# Clean build artifacts
just clean
```

## Testing

Etch uses a simple but effective testing system:

```bash
# Run all example tests
just tests

# Test a specific file
just test examples/simple_test.etch
```

Tests require companion files:
- `.pass` file: Contains expected stdout output for successful tests
- `.fail` file: Marker for tests that should fail compilation

## Architecture

Etch employs a multi-stage compilation pipeline with two backends:

1. **Parsing**: Source code → AST
2. **Type Checking**: Static analysis with range propagation
3. **Safety Proofs**: Division-by-zero, overflow, initialization checks
4. **Compile-Time Execution**: `comptime` evaluation and code injection
5. **Backend Selection**:
   - **VM Path**: AST → register-based bytecode → bytecode caching → VM execution
   - **C Path**: AST → C code generation → native compilation

### VM Backend
- Register-based bytecode for fast interpretation
- Bytecode caching with source hash verification
- Full debugging support (breakpoints, stepping, variable inspection)
- Optimized for quick iteration during development
- Performance: 2-7× faster than Python, comparable to Lua

### C Backend
- Generates clean, readable C code
- Integrates with existing C/C++ build systems
- Near-native performance (competitive with hand-written C)
- Same safety guarantees as VM mode
- Performance: 10-20× faster than Python, faster than Lua

## Safety Guarantees

Etch proves the following at compile-time:

- **No null pointer dereferences**:
  - Use `option[T]` and `result[T]` monads for optional values (forces explicit checking via pattern matching)
  - `ref[T]` - Strong references, can be nil, prover enforces checking when potentially nil
  - `weak[T]` - Weak references, can be nil, must be checked before use or promotion to `ref[T]`
  - The prover uses data flow and control flow analysis to track nil states
  - When the prover cannot prove a reference is non-nil, it requires an explicit nil check
  - Pattern matching ensures all cases are handled
- **No division by zero**: Range analysis proves divisor is non-zero
- **No integer overflow**: Arithmetic checked against type bounds
- **No uninitialized variables**: Definite initialization analysis
- **No array out-of-bounds**: Static bounds checking where possible
- **No dead code overhead**: Impossible branches are eliminated
- **Type safety**: No implicit conversions or type confusion

## Project Structure

```
etch/
├── src/
│   └── etch/
│       ├── compiler.nim       # Main compilation pipeline
│       ├── comptime.nim       # Compile-time execution engine
│       ├── tester.nim         # Test runner
│       └── interpreter/       # Bytecode VM and debugger
├── examples/                  # Language examples and tests
├── tests/                     # Debugger integration tests
├── vscode/                    # VSCode extension
└── performance/               # Performance benchmarks
```

## Use Cases

**Game Scripting (Primary)**
- NPC AI behavior trees and state machines
- Quest logic and dialogue systems
- Gameplay mechanics and rules
- Level scripting and event triggers
- Modding support with safety guarantees

**Other Applications**
- Embedded scripting for applications
- Configuration DSLs with validation
- Plugin systems with sandboxing
- Command-line tools
- Educational programming environments

## Performance Context

Etch is designed for game scripting workloads where:
- Most frame time is in your engine (rendering, physics)
- Scripts run intermittently (AI decisions, event handlers)
- You need predictable performance (no GC pauses)
- Hot-reloading is crucial for iteration speed

**Not designed for:**
- Replacing your entire engine
- High-frequency per-frame logic (use C/C++ or the C backend)
- Systems programming
- Matching Rust/C++ safety guarantees

## Contributing

Contributions are welcome! Key areas for improvement:

- Game-specific standard library functions
- More sophisticated range analysis
- Enhanced type inference
- Performance optimizations
- Additional compile-time functions

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Etch**: Where safety is proven, not promised.
