# Etch

**Define once, Etch forever.**

A safety-first scripting language designed for game development. Etch runs as fast bytecode in a VM for rapid prototyping and hot-reloading, then compiles to C for production performance. Write once, deploy both ways—with full VSCode debugging, C/C++ interop, type safety, and ergonomic syntax optimized for game scripting.

[![Tests](https://github.com/kunitoki/etch/actions/workflows/test.yml/badge.svg)](https://github.com/kunitoki/etch/actions/workflows/test.yml)

## Example

Clean C-like syntax with compile-time safety guarantees:

```etch
fn roll_dice() -> int {
  return rand(1, 6);  // Random value from 1 to 6
}

fn calculate_damage(base: int, armor: int) -> int {
  let variance = rand(5);  // 0 to +5
  let damage = base + variance - armor;

  // Division-by-zero proof: prover ensures armor != 0
  if armor == 0 {
    return damage;
  }

  return damage / armor;  // ✅ Safe: proven non-zero
}

fn main() {
  let roll = roll_dice();
  print("You rolled: " + string(roll));

  let damage = calculate_damage(20, 5);
  print("Damage dealt: " + string(damage));
}
```

Run in the VM for instant iteration:
```bash
etch --run game.etch  # VM mode: instant compilation, hot-reload
```

Or compile to native C for production:
```bash
etch --run c game.etch  # C backend: maximum performance
```

## C/C++ Interop

Etch provides a straightforward C API with direct value access, avoiding the stack-based approach used by Lua:

**Calling C from Etch:**
```etch
// Import C math functions
import ffi cmath {
  fn sin(x: float) -> float;
  fn sqrt(x: float) -> float;
  fn pow(x: float, y: float) -> float;
}

fn main() {
  let result = sqrt(16.0);  // Calls C's sqrt()
  print(result);  // 4.0
}
```

**Calling Etch from C:**
```c
// Create context, compile, and run
EtchContext ctx = etch_context_new();
etch_compile_string(ctx, code, "game.etch");
etch_execute(ctx);

// Get/set variables directly (no stack!)
EtchValue health = etch_get_global(ctx, "player_health");
int64_t hp;
etch_value_to_int(health, &hp);

// Register C functions
EtchValue my_function(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
  int64_t a, b;
  etch_value_to_int(args[0], &a);
  etch_value_to_int(args[1], &b);
  return etch_value_new_int(a + b);
}

etch_register_function(ctx, "add", my_function, NULL);
```

**Compare with Lua's stack-based API:**
```c
// Lua equivalent requires stack manipulation
lua_getglobal(L, "player_health");      // push to stack
int hp = lua_tointeger(L, -1);          // read from stack index
lua_pop(L, 1);                          // manually manage stack

// Lua C function registration
int my_lua_function(lua_State *L) {
  int a = lua_tointeger(L, 1);          // argument at stack position 1
  int b = lua_tointeger(L, 2);          // argument at stack position 2
  lua_pushinteger(L, a + b);            // push result to stack
  return 1;                             // return number of values on stack
}
```

Etch's API uses direct value handles without requiring stack position tracking.

## Example: Arkanoid Game Demo

The repository includes a complete Arkanoid game implementation (`demo/etch/arkanoid.etch`) demonstrating Etch's capabilities with hot-reload:

```bash
just demo release  # Build and run with hot-reload enabled
```

The game implements paddle movement, ball physics, brick collision, and scoring entirely in Etch. During development, you can modify the script (paddle speed, ball velocity, game rules) and see changes applied immediately without restarting the process. The game uses Raylib host functions for rendering.

## Why Etch?

**Built for Game Development**
- **Dual execution modes**: VM for iteration speed, C backend for production performance
- **Hot-reload scripts** during development without recompiling your engine
- **Compound debugging**: Step through both Etch scripts and C/C++ engine code together
- **Simple C API**: No stack manipulation, direct value access
- **Budgeted GC pauses**: Deterministic reference counting keeps frame times stable

**Safety Without Runtime Cost**
- **Null safety**: Optional types (`option[T]`, `result[T]`) with pattern matching enforcement
- **Division-by-zero prevention**: Static range analysis verifies divisors are non-zero
- **Integer overflow detection**: Arithmetic operations checked against type bounds at compile-time
- **Definite initialization**: Variables must be initialized before use on all code paths
- **Bounds checking**: Array accesses verified at compile-time where possible

**Developer Experience**
- Familiar C-like syntax with minimal learning curve
- Fast bytecode compilation with caching
- VSCode extension with debugging support (breakpoints, stepping, inspection)
- Remote debugging capability for embedded scripts
- Clear error messages with actionable feedback

**Design Philosophy**
Etch targets the space between Lua's simplicity and Rust's safety guarantees. It's designed specifically for game scripting rather than systems programming, prioritizing ease of embedding, fast iteration, and compile-time safety verification.

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

Etch supports two execution modes from the same source code:

**VM Mode (Development)**
- Fast compilation to bytecode (typically < 100ms)
- Hot-reload support without process restart
- Full source-level debugging (breakpoints, stepping, inspection)
- Optimized for iteration speed

**C Backend (Production)**
- Transpiles Etch to C for native compilation
- Integrates with standard C/C++ build systems
- Enables compiler optimizations and native performance
- Identical semantics to VM mode

Switch modes with a command-line flag:
```bash
etch --run game_logic.etch      # VM mode
etch --run c game_logic.etch    # C backend
```

## Language Features

### 1. Compile-Time Execution
Execute code at compile-time to generate optimized runtime code. Functions marked with `comptime()` are evaluated during compilation, and their results are embedded as constants. Use `comptime { }` blocks to run code during compilation (useful for configuration), and `inject()` to generate runtime variables from compile-time computations.

### 2. Range-Based Safety Analysis
Etch tracks value ranges throughout your program to prove safety properties. The prover analyzes integer ranges to prevent division-by-zero, detect potential overflow/underflow, and eliminate dead code branches that can never execute.

### 3. Null Safety
The type system and static analyzer prevent null pointer dereferences:
- `option[T]` and `result[T]` types require explicit handling via pattern matching
- `ref[T]` and `weak[T]` reference types tracked with nil-state analysis
- Nil checks enforced when the analyzer cannot prove non-nil
- Weak references require validation before use

### 4. Uninitialized Variable Detection
The compiler ensures all variables are initialized before use through definite initialization analysis. It tracks initialization through all control flow paths, including conditional branches, loops, and function calls.

### 5. Array Safety
Static bounds checking where array indices are known at compile-time. The analyzer verifies accesses are within bounds and emits runtime checks only when static verification is impossible. Includes length operator (`#array`), indexing, and slice operations.

### 6. Type Safety & Inference
Strong static typing with Hindley-Milner style type inference for generics. Types flow through expressions automatically while maintaining full type safety. Supports primitives (`int`, `float`, `bool`, `char`, `string`), arrays, objects, unions, generics, options, and results.

### 7. Pattern Matching
Exhaustive pattern matching for `option[T]` and `result[T]` types ensures all cases are handled (some/none, ok/error), making error handling explicit at the type level.

### 8. Uniform Function Call Syntax (UFCS)
Call any function as if it were a method using dot notation. The first parameter becomes the receiver, enabling clean left-to-right method chains without OOP overhead.

### 9. Lambdas & Closures
First-class functions with closure support. Anonymous functions capture variables from enclosing scope, enabling functional programming patterns.

### 10. Defer Statements
Deferred execution blocks run when scope exits (LIFO order), useful for resource cleanup and guaranteed finalization.

### 11. Objects & Type Aliases
Structured data types, type aliases, and union types for sum types. Object field initialization verified before use.

### 12. Control Flow
Standard control flow (`if`/`elif`/`else`, `while`, `for`) with safety guarantees. Includes short-circuit boolean operators and loop control statements.

### 13. Default Parameters
Function parameters can have default values, checked for safety at compile-time (e.g., default divisors must be non-zero).

### 14. C FFI & Module System
Import Etch modules or declare C function interfaces for FFI. Type-safe boundaries with support for dynamic library loading.

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
- Register-based bytecode interpreter
- Bytecode caching with source hash verification
- Full debugging support (breakpoints, stepping, variable inspection)
- Optimized for quick iteration during development
- Typical performance ranges from comparable to faster than interpreted Python and Lua

### C Backend
- Generates readable C code
- Integrates with existing C/C++ build systems
- Performance comparable to hand-written C for many workloads
- Same safety guarantees as VM mode
- Enables AOT compilation and native optimization

## Safety Guarantees

Etch's static analyzer verifies the following properties at compile-time:

- **Null safety**:
  - Optional types (`option[T]`, `result[T]`) require explicit handling via pattern matching
  - Reference types (`ref[T]`, `weak[T]`) tracked by the prover with nil-state analysis
  - The prover uses control flow analysis to determine when nil checks are required
  - Weak references must be validated before use or promotion to strong references
- **Division-by-zero prevention**: Range analysis verifies divisors are non-zero
- **Integer overflow detection**: Arithmetic operations checked against type bounds
- **Definite initialization**: Variables must be initialized on all code paths before use
- **Bounds checking**: Array accesses verified statically where indices are known
- **Dead code elimination**: Unreachable branches identified and removed
- **Type safety**: Explicit type conversions required, no implicit coercion

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

## Performance Characteristics

Etch is optimized for typical game scripting workloads:
- Event-driven logic (AI decisions, quest triggers, dialogue systems)
- Turn-based or intermittent computation rather than continuous per-frame work
- Deterministic reference counting without unpredictable GC pauses
- Development iteration speed via hot-reload

**Trade-offs:**
- Not intended to replace native engine code for performance-critical systems
- For high-frequency per-frame logic, consider the C backend or native code
- Safety analysis adds compile-time overhead (typically < 1s for game scripts)
- Dynamic features are limited compared to pure dynamic languages

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
