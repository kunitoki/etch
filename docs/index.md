# Etch Programming Language

**Write once, script fast, ship native.**

Etch is a statically-typed scripting language built specifically for game development. Run your scripts instantly in a fast VM during development with hot-reloading and debugging, then compile the same code to C for production performance. Get the iteration speed of Lua with compile-time safety guarantees and native-level performance when you need it.

## The Etch Philosophy

Game development requires two conflicting things: fast iteration during development and maximum performance in production. Most languages make you choose one or compromise on both. Etch offers **dual execution modes**: a fast VM for prototyping with instant compilation and hot-reloading, plus a C backend for production that generates performance competitive with hand-written C—all from the same source code.

### Safety Without Runtime Cost

Before your program compiles, Etch's prover verifies it's free from entire classes of bugs:

- **No null pointer dereferences** - Multiple layers of protection:
  - `option[T]` and `result[T]` monads make optional values explicit and force handling
  - Reference types (`ref[T]`, `weak[T]`) are analyzed by the prover for potential nil states
  - The prover enforces nil checks when it cannot prove a reference is non-nil
  - Pattern matching ensures all cases (some/none, ok/error) are handled
  - Compile-time verification prevents dereferencing potentially nil references
- **No integer overflow/underflow** - Range analysis tracks value ranges through your program
- **No array bounds violations** - Every array access proven safe before compilation
- **No uninitialized variables** - The compiler ensures every variable is initialized before use
- **No division by zero** - The prover verifies divisors are never zero

If the prover can't verify these properties, your code doesn't compile. If it compiles, these bugs literally cannot happen.

## Key Features

### 1. The Prover: Your Compile-Time Safety Net

Etch's prover uses **range analysis** and **control flow analysis** to track value ranges through your entire program. When you add two variables, the prover knows the range of possible results. When you access an array, it knows whether the index is in bounds. When you divide, it knows if the divisor could be zero.

```etch
fn process(arr: array[int]) -> int {
    var sum = 0;
    for i in 0 ..< #arr {
        sum = sum + arr[i];  // ✅ Index proven in bounds
    }
    return sum;  // ✅ No overflow if inputs are bounded
}
```

The prover traces ranges through loops, conditionals, and function calls. If it can't prove safety, you get a clear error message explaining why—often with suggestions for how to fix it.

### 2. Type Inference That Just Works

You don't need to annotate every variable. Etch infers types from how you use them, giving you the conciseness of dynamic languages with the safety of static types:

```etch
let x = 42;                    // int, inferred from literal
let items = [1, 2, 3];         // array[int], inferred from elements
let doubled = items.map(|n| n * 2);  // Type flows through functions
```

Function signatures are explicit (for clarity and documentation), but local variables infer naturally.

### 3. Null Safety Through Monads and Reference Types

Etch provides multiple mechanisms to prevent null pointer dereferences:

**Monads for Optional Values**
Functions that may or may not return a value use `option[T]` or `result[T]`. Pattern matching forces you to handle both cases:

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);
}

match divide(10, 2) {
    ok(value) => print(value),
    error(msg) => print("Error: " + msg),
}
```

**Reference Types with Compile-Time Verification**
For heap-allocated objects, use `ref[T]` (strong reference) or `weak[T]` (weak reference). The prover tracks nil states and enforces checking:

```etch
fn processRef(obj: ref[GameObject]) -> void {
    // ref[T] can be nil - prover tracks when checking is needed
    if obj != nil {
        obj.update();  // Safe: prover verified non-nil
    }
}

fn processWeak(weakObj: weak[GameObject]) -> void {
    // Weak references must be checked before use or promotion to ref
    if weakObj != nil {
        let strongObj: ref[GameObject] = weakObj;  // Weak-to-ref promotion
        strongObj.update();  // Safe: prover knows it's non-nil here
    }
}

fn guaranteed(obj: ref[GameObject]) -> void {
    // If prover knows obj cannot be nil (e.g., freshly created), no check needed
    obj.update();  // Safe: prover verified through data flow analysis
}
```

**Key Semantics:**
- `ref[T]` - Strong reference, can be nil, prover tracks when nil checking is required
- `weak[T]` - Weak reference, can be nil, must be checked before use or promotion to `ref[T]`
- The prover uses control flow and data flow analysis to determine when references might be nil
- When the prover cannot prove a reference is non-nil, it requires an explicit nil check before dereferencing

The compiler won't let you ignore errors, forget to check for `none`, dereference potentially nil references without checking, or promote weak references without nil checks. Null becomes a compile-time concern, not a runtime crash.

### 4. UFCS: Functions That Read Like Methods

Uniform Function Call Syntax lets you call any function as if it were a method, turning nested function calls into readable left-to-right pipelines:

```etch
// Without UFCS: nested, inside-out
process(filter(transform(getData())));

// With UFCS: natural, left-to-right
getData().transform().filter().process();
```

Any function whose first parameter matches can be called this way. It's a simple syntactic transformation that makes a huge difference in readability.

### 5. Performance Without Compromise

When the prover verifies your code is safe, the compiler generates code with zero safety overhead. No bounds checks, no overflow checks, no null checks—because they've already been proven unnecessary.

The result:

- **Fast execution** - Generated code rivals hand-optimized C
- **No garbage collection pauses** - Deterministic memory management with reference counting
- **Predictable performance** - No hidden runtime costs or surprise allocations
- **Small binaries** - No runtime library bulk; just your code and what it needs

### 6. Seamless C Interop

Etch's FFI makes calling C libraries straightforward—just declare the signatures and call them like normal functions:

```etch
import ffi cmath {
    fn sin(x: float) -> float;
    fn sqrt(x: float) -> float;
}

let result = sin(0.5).sqrt();  // C functions, Etch syntax
```

No wrapper code, no build complexity. Etch handles the calling conventions and type marshaling.

### 7. Compile-Time Superpowers

Execute functions during compilation to pre-compute expensive calculations, embed files directly into binaries, or generate code based on build-time configuration:

```etch
// Pre-compute at compile time
let fib_10: int = comptime(fibonacci(10));  // No runtime calculation!

// Embed files directly
let template: string = comptime(readFile("page.html"));

// Conditional compilation
comptime {
    if readFile(".mode") == "debug" {
        inject("logging", "int", 1);
    }
}
```

Anything you can compute at build time becomes a constant with zero runtime cost.

### 8. Simple, Consistent Syntax

Etch's syntax is small and orthogonal. Learn the basics in an afternoon, then apply them everywhere:

```etch
// Variables: let = immutable, var = mutable
let x = 42;
var count = 0;

// Functions with explicit signatures
fn greet(name: string) -> void {
    print("Hello, " + name);
}

// Pattern matching for branching
match parseNumber(input) {
    ok(n) => print("Got " + string(n)),
    error(msg) => print("Error: " + msg),
}
```

No special cases, no hidden complexity. The language gets out of your way.

## When to Use Etch

Etch is designed specifically for **game scripting** where you need:

**Primary Use Case: Game Development**
- **Gameplay logic** - AI behaviors, quest systems, dialogue trees
- **Level scripting** - Event triggers, interactive objects, cutscenes
- **Modding support** - Safe, sandboxed scripts for user-generated content
- **Rapid iteration** - Hot-reload scripts without restarting your game
- **Production performance** - Compile to C when you ship
- **Compound debugging** - Step through Etch scripts and C++ engine code together

**Other Use Cases**
- **Application scripting** - Embed in C/C++ apps for safe, fast scripting
- **Plugin systems** - Extend functionality with type-safe scripts
- **Configuration DSLs** - More expressive than JSON, safer than Lua
- **Command-line tools** - Fast startup, reliable execution

If you're building a game and want scripting that's easier than C++, safer than Lua, and can hot-reload during development, Etch is for you.

## How Etch Compares to Game Scripting Languages

Understanding Etch's position in the game scripting ecosystem:

| | Etch (VM) | Etch (C) | Lua | Python | C++ |
|---|-----------|----------|-----|--------|-----|
| **Iteration speed** | Instant | Slow | Instant | Instant | Slow |
| **Hot-reload** | ✅ Yes | ❌ No | ✅ Yes | ✅ Yes | ❌ No |
| **Type safety** | ✅ Static | ✅ Static | ❌ Dynamic | ❌ Dynamic | ✅ Static |
| **Safety checks** | Compile-time | Compile-time | Runtime | Runtime | None |
| **Performance** | ~Lua speed | ~C speed | Fast | Slow | Fastest |
| **Debugging** | Full (VSCode) | C debugger | Limited | Full | Full |
| **Compound debug** | ✅ Yes | ✅ Yes | ❌ No | ❌ No | N/A |
| **Learning curve** | Gentle | Gentle | Gentle | Gentle | Steep |
| **Memory model** | Ref-counted | Ref-counted | GC | GC | Manual |
| **Embedding** | Easy (C API) | Native | Easy | Medium | Native |

**Etch's sweet spot:** Lua's ease of use + compile-time safety + optional C-level performance, all with full debugging support.

## Quick Start

### Get Etch Running

```bash
# Clone and build
git clone https://github.com/your/etch
cd etch
just build

# Try an example
./etch --run examples/hello_world.etch
```

### Your First Program

Create `hello.etch`:

```etch
fn main() {
    print("Hello, Etch!");
}
```

Run it:

```bash
./etch --run hello.etch
```

That's it. No complex build systems, no dependency management. Just write code and run it.

## Dive Deeper

Ready to learn more? The documentation covers everything:

**Core Language**
- [Type System & Inference](types.md) - From primitives to algebraic types
- [Functions & UFCS](functions.md) - Write and chain beautiful code
- [Control Flow](control-flow.md) - Conditionals, loops, and pattern matching
- [Modules & FFI](modules.md) - Code organization and C integration

**Safety System**
- [Compile-Time Safety](safety.md) - How the prover guarantees correctness
- [Overflow Detection](overflow.md) - Deep dive on range analysis

**Advanced Topics**
- [Compile-Time Evaluation](comptime.md) - Run code during compilation
- [Operator Overloading](operator-overloading.md) - Custom operators for your types
- [Debugging](debugging.md) - Source-level debugging tools
- [C API](c-api.md) - Embed Etch in your applications

## Explore Examples

The `examples/` directory demonstrates real Etch code in action:

- `arrays_test.etch` - Array operations with compile-time bounds checking
- `match_pattern_test.etch` - Pattern matching with `option` and `result`
- `ufcs_advanced_test.etch` - Beautiful method chains with UFCS
- `cffi_math_test.etch` - Calling C library functions

Run any example: `./etch --run examples/arrays_test.etch`

## The Etch Way

Etch is built on three principles:

**Safety first** - If the prover can't verify it's safe, it doesn't compile. This feels restrictive at first, but it eliminates entire bug categories.

**Simplicity matters** - Small feature set, orthogonal design. Learn the fundamentals once, apply them everywhere.

**Performance by default** - Zero-cost abstractions. Safety checks happen at compile time; the generated code is as fast as hand-written C.

## Community

Etch is actively developed and we welcome contributions:

- **GitHub**: [github.com/your/etch](https://github.com/your/etch) - Source code, issues, discussions
- **Report bugs**: Open an issue with a minimal reproduction
- **Request features**: Explain your use case and why it matters
- **Contribute**: See [CONTRIBUTING.md](../CONTRIBUTING.md) for build instructions and guidelines

---

**Ready to dive in?** Start with [Type System & Inference](types.md) to learn how Etch's types work.
