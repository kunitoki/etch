# Compile-Time Safety Checks

Before your Etch program ever runs, the prover analyzes every line to guarantee safety properties that most languages either check at runtime or don't check at all. This document explains what the prover guarantees and how to work with it effectively.

## Table of Contents

1. [The Core Idea](#the-core-idea)
2. [Safety Guarantees](#safety-guarantees)
3. [How the Prover Works](#how-the-prover-works)
4. [Working with the Prover](#working-with-the-prover)
5. [Best Practices](#best-practices)

## The Core Idea

Most languages force a choice: either pay runtime overhead for safety checks, or skip the checks and hope nothing goes wrong. Etch takes a different approach—**prove safety at compile time, then generate fast code with zero checks**.

The prover uses static analysis to track value ranges, follow control flow, and verify array accesses. If it can't prove your code is safe, compilation fails with a clear explanation of why. If it compiles, you get mathematical certainty that entire bug classes cannot occur.

### The "If It Compiles, It's Safe" Guarantee

When your program compiles successfully:

- **Array accesses** are mathematically proven to be in bounds
- **Integer arithmetic** is proven not to overflow or underflow
- **Division operations** are proven safe from division by zero
- **Variables** are proven to be initialized before use
- **Null dereferences** cannot happen (there are no null pointers)

All of this verification happens at compile time. The generated code contains **no runtime checks** and runs at full native speed.

```etch
fn process(arr: array[int]) -> int {
    var sum = 0;
    for i in 0 ..< #arr {
        sum = sum + arr[i];
    }
    return sum;
}
```

When this compiles, you're guaranteed the array access is safe, the loop bounds are correct, and the sum operation won't overflow (given bounded input).

## Safety Guarantees

### 1. Memory Safety

Buffer overruns are a classic source of security vulnerabilities and crashes. Etch eliminates them entirely through compile-time bounds checking.

The prover tracks array lengths and verifies every index is within bounds:

```etch
let arr = [1, 2, 3, 4, 5];
let x = arr[2];    // ✅ Compiles: index 2 is valid
let y = arr[10];   // ❌ Error: index 10 out of bounds [0, 4]
```

In loops, the prover understands the relationship between loop variables and array bounds:

```etch
for i in 0 ..< #arr {
    let item = arr[i];  // ✅ Safe: i proven to be in [0, 4]
}
```

The range `0 ..< #arr` produces values from 0 to length-1, so the prover knows every access is safe.

### 2. Integer Overflow and Underflow

Integer overflow is subtle and dangerous—values silently wrap around, turning positive numbers negative or producing garbage. Many languages ignore this problem entirely. Etch catches it at compile time through range analysis.

The prover tracks the range of every integer variable and verifies arithmetic operations stay within bounds:

```etch
let a = rand(1, 100);   // Prover knows: a is in [1, 100]
let b = rand(1, 50);    // Prover knows: b is in [1, 50]
let sum = a + b;        // ✅ Safe: result is in [2, 150]
```

If an operation might overflow, the compiler stops you:

```etch
let x = rand(9223372036854775000);  // Near int64 max
let overflow = x + 1000;            // ❌ Error: addition might overflow
```

For a deep dive on how overflow detection works, see [Overflow Detection](overflow.md).

### 3. Null Safety

Tony Hoare called null references his "billion-dollar mistake." They cause crashes, security vulnerabilities, and countless debugging hours. Etch solves this problem by not having null pointers at all.

Instead of allowing null, Etch provides the `option[T]` type to explicitly represent "might not be present":

```etch
let x: option[int] = none;  // Explicitly no value

match x {
    some(value) => print(value),    // Handle the value case
    none => print("no value"),      // Handle the absence case
}
```

The type system forces you to handle both cases. You can't accidentally dereference a null pointer because they don't exist.

For reference types, the prover tracks initialization:

```etch
let cell = new[ref[string]](nil);   // Cell initially nil
@cell = new[string]("hello");       // Now initialized
print(@(@cell));                    // ✅ Safe: prover knows it's initialized
```

Attempting to use an uninitialized reference is a compile error, not a runtime crash.

### 4. Division by Zero

Division by zero crashes programs or produces undefined behavior in most languages. Etch's prover verifies divisors are never zero before allowing the code to compile.

```etch
let x = 10 / 0;  // ❌ Error: division by zero
```

When the prover can't determine if a divisor is safe, you need to prove it explicitly:

```etch
fn safeDivide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);  // ✅ Safe: b proven non-zero here
}
```

The conditional establishes that `b != 0` in the success path, allowing the division to proceed.

### 5. Uninitialized Variables

Reading uninitialized memory leads to unpredictable behavior and security vulnerabilities. Etch requires every variable to be initialized before use.

```etch
var x: int;
print(x);  // ❌ Error: x used before initialization
```

This applies even across control flow branches:

```etch
var result: int;
if condition {
    result = 42;
}
print(result);  // ❌ Error: result might be uninitialized
```

The prover requires initialization on *all* paths, not just some paths.

### 6. Type Safety and Explicit Conversions

Implicit type conversions hide bugs. JavaScript's `"5" - 3 === 2` is infamous. Etch requires all type conversions to be explicit, making data flow obvious.

```etch
let x: int = 42;
let y: float = 3.14;
let z = x + y;  // ❌ Error: cannot mix int and float
```

Make your intent explicit:

```etch
let z = float(x) + y;  // ✅ Clear: convert to float, then add
```

This catches bugs where you accidentally mix incompatible types.

### 7. Unreachable Code Detection

Dead code is often a sign of logic bugs—conditions that can never be true, or branches that can never execute. The prover identifies these automatically.

```etch
if x > 100 and x < 50 {
    // ⚠️ Warning: unreachable (x can't be both >100 and <50)
    print("impossible");
}
```

This catches:
- Logic errors in conditionals
- Copy-paste mistakes
- Code that became unreachable after refactoring
- Redundant branches that should be removed

### 8. Unused Variables

Unused variables often indicate incomplete refactoring or forgotten error handling. The prover requires every variable to be read at least once.

```etch
fn compute() -> result[int] {
    let value = calculate()?;
    let forgotten = prepare()?;  // ❌ Error: unused variable
    return ok(value);
}
```

If you genuinely need to ignore a value, make it explicit:

```etch
let _ = expression;      // Deliberately ignored
discard expression;      // Also acceptable
```

## How the Prover Works

The prover uses three main techniques to verify safety:

### 1. Range Analysis

Every integer variable has an associated range of possible values. The prover tracks these ranges through arithmetic operations:

```etch
let x = rand(1, 10);     // x ∈ [1, 10]
let y = rand(5, 15);     // y ∈ [5, 15]
let sum = x + y;         // sum ∈ [6, 25]
```

When you add `x` and `y`, the prover computes the result range: minimum is 1+5=6, maximum is 10+15=25.

### 2. Control Flow Analysis

Conditionals refine ranges. When you check `if x < 0`, the prover narrows the range of `x` in each branch:

```etch
let x = rand(-100, 100);  // x ∈ [-100, 100]

if x < 0 {
    // Here: x ∈ [-100, -1]
    let abs = -x;  // abs ∈ [1, 100]
} else {
    // Here: x ∈ [0, 100]
}
```

### 3. Loop and Function Analysis

The prover unrolls loops (up to a limit) to track how values evolve:

```etch
var sum = 0;
for i in 0 ..< 3 {
    sum = sum + 10;
}
// After iteration 1: sum = 10
// After iteration 2: sum = 20
// After iteration 3: sum = 30
```

For functions, the prover analyzes the body to determine output ranges from input ranges.


## Working with the Prover

When the prover can't verify safety, you'll get a clear error explaining why. Here are strategies for fixing common issues.

### Strategy 1: Narrow Input Ranges

The most common issue is ranges that are too large for the operation:

```etch
// ❌ Problem: could overflow
let x = rand(1000000000);
let sum = x + x;

// ✅ Solution: use reasonable bounds
let x = rand(100);
let sum = x + x;  // Max is 200, clearly safe
```

### Strategy 2: Add Explicit Guards

When you can't narrow inputs, add conditional checks to prove safety:

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);  // ✅ b proven non-zero
}
```

The conditional establishes a fact the prover uses in the success branch.

### Strategy 3: Use Modulo for Accumulation

When accumulating values in a loop, use modulo to keep results bounded:

```etch
var sum = 0;
for item in items {
    sum = (sum + item) % 1000000007;  // Stays bounded
}
```

### Strategy 4: Early Return for Out-of-Range

Filter out-of-range inputs early to narrow the range for subsequent operations:

```etch
fn process(x: int) -> int {
    if x < 0 or x > 1000 {
        return 0;
    }
    // Now: x ∈ [0, 1000]
    return x * x;  // ✅ Safe: max 1,000,000
}
```

### Debugging with --verbose

When the prover rejects your code, use `--verbose` to see its reasoning:

```bash
./etch --verbose myfile.etch
```

The output shows the ranges the prover computed:

```
[PROVER] Variable x initialized with range [0..100]
[PROVER] Variable y initialized with range [0..50]
[PROVER] Addition: [0..100] + [0..50] = [0..150] ✅
```

This helps you understand why the prover accepted or rejected an operation.

## Best Practices

### Trust the Prover

Once your code compiles, the prover has verified it's safe. Don't add redundant runtime checks—they're unnecessary and slow things down.

```etch
// ❌ Redundant: prover already proved this
if i < #arr {
    let x = arr[i];
}

// ✅ Trust the compiler
let x = arr[i];  // If this compiles, it's safe
```

### Use Appropriate Ranges

Don't use unnecessarily large ranges. They make the prover's job harder and may cause false positives:

```etch
// ❌ Overly broad
let count = rand(2147483647);

// ✅ Realistic bounds
let count = rand(1, 100);
```

### Leverage Algebraic Types

Use `result[T]` and `option[T]` to make fallibility explicit:

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);
}
```

This forces callers to handle errors explicitly, catching bugs at compile time.

## Summary

Etch's prover eliminates entire bug categories before your code runs:

- **No buffer overruns** - Array accesses proven in bounds
- **No integer overflow** - Arithmetic operations proven safe
- **No null dereferences** - Null pointers don't exist
- **No uninitialized reads** - Variables proven initialized before use
- **No division by zero** - Divisors proven non-zero
- **Zero runtime overhead** - All verification at compile time

**If it compiles, these bugs literally cannot happen.**

---

**Continue learning:**
- [Overflow Detection](overflow.md) - Deep dive on integer safety
- [Type System](types.md) - How types enforce correctness
- [Functions](functions.md) - Writing safe, composable code
