# Etch

**Define once, Etch forever.**

A modern, safety-first programming language that proves correctness at compile-time through advanced static analysis. Etch combines the simplicity of C-like syntax with powerful compile-time execution, range-based safety proofs, and intelligent dead code elimination.

[![Tests](https://github.com/kunitoki/etch/actions/workflows/test.yml/badge.svg)](https://github.com/kunitoki/etch/actions/workflows/test.yml)

## Why Etch?

**Safety Without Runtime Overhead**
- Prove division-by-zero safety at compile-time using range analysis
- Detect integer overflow before your code ever runs
- Eliminate uninitialized variables and dead code branches
- Array bounds checking with compile-time verification

**Compile-Time Superpowers**
- Execute functions at compile-time with `comptime()`
- Read files and inject code during compilation
- Generate code dynamically based on configuration
- Zero runtime cost for compile-time computations

**Developer Experience**
- Clean, minimal C-like syntax
- Fast bytecode compilation with caching
- VSCode integration with full debugger support
- Helpful error messages that guide you to solutions

## Quick Start

```bash
# Run a program
etch --run examples/simple_hello.etch

# Compile and cache bytecode
etch examples/simple_hello.etch

# Run test suite
just tests

# Test a specific file
just test examples/simple_test.etch
```

## Language Features

### 1. Compile-Time Execution

Execute code at compile-time to generate optimized runtime code:

```etch
fn square(x: int) -> int {
    return x * x;
}

fn main() -> void {
    // Computed at compile-time, stored as constant
    let result: int = comptime(square(8));
    print(result);  // Prints: 64
}
```

**Code Injection**
Generate runtime code from compile-time execution:

```etch
fn main() -> void {
    comptime {
        inject("config", "string", readFile("config.txt"));
        inject("version", "int", 42);
    }
    print(config);   // Uses injected variable
    print(version);  // Prints: 42
}
```

### 2. Range-Based Safety Analysis

Etch tracks value ranges throughout your program to **prove safety properties**:

**Division-by-Zero Prevention**
```etch
fn main() -> void {
    let divisor: int = rand(10, 5);    // Range: [5, 10]
    let result: int = 100 / divisor;   // Safe: proven non-zero
    print(result);
}
```

**Overflow Detection**
```etch
fn main() -> void {
    let large_a: int = rand(9223372036854775800);
    let large_b: int = rand(1000);
    let overflow: int = large_a + large_b;  // Compile error: potential overflow!
}
```

**Intelligent Dead Code Elimination**
```etch
fn main() -> void {
    let x: int = rand(100, 50);  // Range: [50, 100]

    if x > 200 {
        print(10 / 0);  // Dead code: condition impossible, no error!
    }

    if x > 75 {
        print("Possible!");  // This branch may execute
    }
}
```

### 3. Uninitialized Variable Detection

Never use a variable before it's initialized:

```etch
fn main() -> void {
    var x: int;
    print(x);  // Compile error: x used before initialization
}
```

**Conditional Initialization Tracking**
```etch
fn main() -> void {
    var x: int;
    let condition: int = rand(1);

    if condition == 0 {
        x = 10;
    } else {
        x = 20;
    }

    print(x);  // Safe: x initialized in all branches
}
```

### 4. Array Safety

Compile-time bounds checking and safe array operations:

```etch
fn main() -> void {
    let numbers: array[int] = [10, 20, 30, 40, 50];

    // Length operator
    let count: int = #numbers;

    // Safe indexing
    let middle: int = numbers[count / 2];

    // Safe slicing
    let secondHalf: array[int] = numbers[2:];
    let slice: array[int] = numbers[1:4];
}
```

### 5. Type Safety & Inference

Strong static typing with intelligent type inference:

```etch
fn main() -> void {
    let x: int = 42;              // Explicit type
    let y = 3.14;                 // Inferred as float
    let name = "Etch";            // Inferred as string
    let flag = true;              // Inferred as bool
}
```

### 6. Default Parameters with Safety

Default parameter values are checked for safety at compile-time:

```etch
fn safeDivide(numerator: int, divisor: int = 5) -> int {
    return numerator / divisor;  // Safe: default is non-zero
}

fn unsafeDivide(numerator: int, divisor: int = 0) -> int {
    return numerator / divisor;  // Compile error: default causes division by zero!
}
```

### 7. Control Flow

Standard control flow with safety guarantees:

```etch
fn main() -> void {
    let x: int = rand(10);

    // If-elif-else
    if x < 3 {
        print("Small");
    } else if x < 7 {
        print("Medium");
    } else {
        print("Large");
    }

    // While loops
    var i: int = 0;
    while i < 5 {
        print(i);
        i = i + 1;
    }
}
```

## Advanced Examples

### Game Logic with Proven Safety

```etch
fn roll_dice() -> int {
    return rand(6, 1);  // 1-6
}

fn random_damage(base: int) -> int {
    let variance: int = rand(5);  // 0-5
    return base + variance;        // Proven: no overflow
}

fn main() -> void {
    let roll1: int = roll_dice();
    let roll2: int = roll_dice();
    print(roll1);
    print(roll2);

    let damage: int = random_damage(20);  // 20-25
    print(damage);
}
```

### Configuration-Driven Code Generation

```etch
fn main() -> void {
    comptime {
        let config: string = readFile("config.txt");

        if config == "debug" {
            inject("LOG_LEVEL", "int", 2);
        } else {
            inject("LOG_LEVEL", "int", 0);
        }
    }

    print(LOG_LEVEL);  // Value depends on config file
}
```

## Tools & Integration

### Command Line Interface

```bash
# Run with verbose output
etch --run --verbose examples/test.etch

# Release mode (optimized, no debug info)
etch --run --release examples/test.etch

# Dump bytecode for inspection
etch --dump-bytecode examples/test.etch

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
just build

# Run all tests
just tests

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

Etch employs a multi-stage compilation pipeline:

1. **Parsing**: Source code → AST
2. **Type Checking**: Static analysis with range propagation
3. **Safety Proofs**: Division-by-zero, overflow, initialization checks
4. **Compile-Time Execution**: `comptime` evaluation and code injection
5. **Bytecode Generation**: AST → register-based bytecode
6. **Bytecode Caching**: Fast re-execution with source hash verification
7. **VM Execution**: Register-based virtual machine with debugging support

## Safety Guarantees

Etch proves the following at compile-time:

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

## Contributing

Contributions are welcome! Key areas for improvement:

- Additional compile-time functions
- More sophisticated range analysis
- Loop support in compile-time execution
- Enhanced type inference
- Performance optimizations

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Etch**: Where safety is proven, not promised.
