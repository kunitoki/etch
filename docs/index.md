# Etch Programming Language

**Etch** is a statically-typed, compiled programming language with a focus on **safety**, **simplicity**, and **zero-cost abstractions**. It combines the safety guarantees of languages like Rust with the simplicity of Python-like syntax.

## What is Etch?

Etch is designed to catch bugs at compile time before your code ever runs. Through its powerful **safety prover**, Etch verifies that your programs are free from:
- Integer overflow/underflow
- Array bounds violations
- Null pointer dereferences
- Uninitialized variables
- Division by zero

**All of this happens at compile time with zero runtime overhead.**

## Key Strengths

### 1. Compile-Time Safety Verification

Etch's safety prover analyzes your entire program before compilation:

```etch
fn safe_sum(arr: array[int]) -> int {
    var sum = 0;
    for i in 0 ..< #arr {
        sum = sum + arr[i];  // Prover verifies: no overflow!
    }
    return sum;
}

// Prover tracks: arr elements ∈ [1, 10], loop runs 5 times
// Therefore: sum ∈ [5, 50] ✅ Safe!
var result = safe_sum([1, 2, 3, 4, 5]);
```

If the prover can't verify safety, compilation fails with a helpful error message.

### 2. Type Inference

Write code that feels dynamic but is fully statically typed:

```etch
// Type inference - no annotations needed!
var x = 42;              // inferred as int
var name = "Alice";      // inferred as string
var items = [1, 2, 3];   // inferred as array[int]

// The compiler knows all types at compile time
```

### 3. Algebraic Data Types

Express complex domains safely with `option[T]` and `result[T]`:

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("Division by zero");
    }
    return ok(a / b);
}

// Pattern matching forces you to handle all cases
let result = divide(10, 2);
match result {
    ok(value) => print("Result: " + toString(value)),
    error(msg) => print("Error: " + msg),
}
```

### 4. UFCS (Uniform Function Call Syntax)

Chain operations naturally:

```etch
fn double(x: int) -> int { return x * 2; }
fn add(x: int, y: int) -> int { return x + y; }

// Traditional: add(double(5), 3)
// UFCS: makes code read left-to-right
5.double().add(3).print();  // Output: 13
```

### 5. Zero-Cost Abstractions

All safety checks happen at compile time. The generated code is as fast as hand-written C:

- **No runtime overhead** for bounds checking (prover verifies at compile time)
- **No garbage collection** (deterministic memory management)
- **No exceptions** (errors are values, handled explicitly)
- **Direct machine code generation** via register-based VM or native compilation

### 6. Simple FFI

Call C libraries directly:

```etch
import ffi cmath {
    fn sin(x: float) -> float;
    fn cos(x: float) -> float;
}

fn main() {
    let angle = 0.0;
    print(sin(angle));  // Calls C's sin() directly
}
```

### 7. Minimalist Syntax

Etch has a small, consistent syntax that's easy to learn:

```etch
// Variables
var mutable = 10;
let immutable = 20;

// Functions
fn greet(name: string) -> void {
    print("Hello, " + name);
}

// Control flow
if x > 0 {
    print("positive");
} else {
    print("negative");
}

// Loops
for i in 0 ..< 10 {
    print(i);
}

while condition {
    doWork();
}

// Pattern matching
match option {
    some(value) => process(value),
    none => handleError(),
}
```

## Use Cases

Etch is ideal for:

- **Performance-critical applications** where safety matters
- **Embedded systems** with strict resource constraints
- **Command-line tools** that need to be fast and reliable
- **Learning** about type systems and compile-time verification
- **Systems programming** without the complexity of C++

## Comparison with Other Languages

| Feature | Etch | Python | Rust | C |
|---------|------|--------|------|---|
| Memory safety | ✅ Compile-time | ❌ Runtime | ✅ Compile-time | ❌ None |
| Overflow checking | ✅ Compile-time | ✅ Runtime | ⚠️  Debug only | ❌ None |
| Type safety | ✅ Static | ⚠️  Dynamic | ✅ Static | ⚠️  Weak static |
| Type inference | ✅ Full | ✅ Full | ✅ Partial | ❌ None |
| Runtime overhead | ✅ Zero | ❌ High | ✅ Zero | ✅ Zero |
| Learning curve | ✅ Easy | ✅ Easy | ⚠️  Steep | ⚠️  Medium |
| Null safety | ✅ option[T] | ❌ None | ✅ Option<T> | ❌ None |

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/your/etch
cd etch

# Build
just build

# Run an example
./etch --run examples/hello_world.etch
```

### Hello World

```etch
fn main() {
    print("Hello, Etch!");
}
```

### Compile and Run

```bash
./etch --run hello.etch
```

## Documentation

- **[Type System & Inference](types.md)** - Types, inference, generics, algebraic types
- **[Functions & UFCS](functions.md)** - Function definitions, UFCS, higher-order functions
- **[Control Flow](control-flow.md)** - if, for, while, match expressions
- **[Modules & FFI](modules.md)** - Imports, exports, C FFI
- **[Global Variables](globals.md)** - Global state and compile-time evaluation
- **[Compile-Time Safety](safety.md)** - How the prover works, writing safe code
- **[Overflow Detection](overflow.md)** - Understanding overflow checking

## Example Programs

Etch comes with comprehensive examples in the `examples/` directory:

```bash
# Array operations
./etch --run examples/arrays_test.etch

# Pattern matching
./etch --run examples/match_pattern_test.etch

# UFCS demonstration
./etch --run examples/ufcs_advanced_test.etch

# C FFI
./etch --run examples/cffi_math_test.etch
```

## Philosophy

Etch is built on three core principles:

### 1. **Safety First**
If the compiler can't prove your code is safe, it won't compile. This might feel restrictive at first, but it eliminates entire classes of bugs.

### 2. **Simplicity**
Etch has a small, orthogonal feature set. Learn the core concepts once, apply them everywhere.

### 3. **Performance**
Zero-cost abstractions mean you never pay for features you don't use, and safety checks have no runtime overhead.

## Contributing

Etch is under active development. See [CONTRIBUTING.md](../CONTRIBUTING.md) for details on:
- Building from source
- Running tests
- Adding new features
- Reporting bugs

## License

[Your license here]

## Community

- **GitHub**: [github.com/your/etch](https://github.com/your/etch)
- **Issues**: Report bugs and request features
- **Discussions**: Ask questions and share projects

---

**Next**: Start with [Type System & Inference](types.md) to learn Etch's type system.
