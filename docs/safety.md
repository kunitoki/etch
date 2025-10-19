# Compile-Time Safety Checks

Etch's safety prover analyzes your entire program at compile time to guarantee it's free from common programming errors. This document provides an overview of all safety checks.

## Table of Contents

1. [Overview](#overview)
2. [Safety Guarantees](#safety-guarantees)
3. [How the Prover Works](#how-the-prover-works)
4. [Safety Checks](#safety-checks)
5. [Working with the Prover](#working-with-the-prover)

## Overview

Etch's safety prover performs **static program analysis** before your code compiles. If the prover can't verify your program is safe, compilation fails with a helpful error message.

**Key Principle**: If it compiles, it's safe.

### What This Means

```etch
// ✅ If this compiles...
fn main() {
    let arr = [1, 2, 3];
    let x = arr[0];
    print(x);
}

// ...then you are GUARANTEED:
// - No array bounds violations
// - No integer overflow
// - No uninitialized variables
// - No division by zero
// - All at ZERO runtime cost!
```

### Zero Runtime Overhead

All safety checks happen at compile time. The generated code has **no runtime checks** and runs at native speed.

## Safety Guarantees

### 1. Memory Safety

```etch
// ✅ All array accesses are bounds-checked at compile time
let arr = [1, 2, 3, 4, 5];
let x = arr[2];    // ✅ Safe: index 2 is valid
let y = arr[10];   // ❌ ERROR: index out of bounds [0, 4]

// Range tracking through loops
for i in 0 ..< #arr {
    let item = arr[i];  // ✅ Safe: i is proven to be in bounds
}
```

### 2. Integer Overflow/Underflow

```etch
// ✅ Overflow detected at compile time
let a = rand(1, 100);         // a ∈ [1, 100]
let b = rand(1, 50);          // b ∈ [1, 50]
let sum = a + b;              // ✅ Safe: sum ∈ [2, 150]

let x = rand(9223372036854775000);  // Near int64 max
let y = rand(1000);
let overflow = x + y;         // ❌ ERROR: addition overflow
```

See [Overflow Detection](overflow.md) for detailed documentation.

### 3. Null Safety

```etch
// ❌ No null pointers in Etch!
let x: int = null;  // ERROR: null doesn't exist

// ✅ Use option[T] for optional values
let x: option[int] = none;

match x {
    some(value) => print(value),  // Safe: value exists
    none => print("no value"),    // Explicit handling
}
```

### 4. Division by Zero

```etch
// ✅ Division by zero caught at compile time
let x = 10;
let y = 0;
let result = x / y;  // ❌ ERROR: division by zero

// ✅ Safe: divisor is non-zero
let a = rand(1, 100);  // Range: [1, 100] - never zero!
let safe = 100 / a;    // ✅ Safe
```

### 5. Uninitialized Variables

```etch
// ❌ Must initialize all variables
var x: int;
print(x);  // ERROR: use of uninitialized variable

// ✅ All variables must be initialized
var x: int = 0;
print(x);  // Safe
```

### 6. Type Safety

```etch
// ❌ No implicit type conversions
let x: int = 42;
let y: float = 3.14;
let z = x + y;  // ERROR: cannot add int and float

// ✅ Explicit conversions required
let z = toFloat(x) + y;  // Safe (if toFloat exists)
```

## How the Prover Works

### Range Analysis

The prover tracks value ranges for all variables:

```etch
let x = rand(1, 10);     // Prover knows: x ∈ [1, 10]
let y = rand(5, 15);     // Prover knows: y ∈ [5, 15]
let sum = x + y;         // Prover computes: sum ∈ [6, 25]
let product = x * y;     // Prover computes: product ∈ [5, 150]
```

### Control Flow Analysis

The prover understands conditionals:

```etch
let x = rand(-100, 100);  // x ∈ [-100, 100]

if x < 0 {
    // Prover narrows: x ∈ [-100, -1]
    let abs = -x;         // abs ∈ [1, 100]
} else {
    // Prover narrows: x ∈ [0, 100]
    let identity = x;     // identity ∈ [0, 100]
}
```

### Loop Analysis

The prover simulates loop execution:

```etch
var sum = 0;              // sum ∈ [0, 0]
for i in 0 ..< 5 {        // i ∈ [0, 4]
    sum = sum + 10;       // Iteration 1: sum ∈ [10, 10]
                          // Iteration 2: sum ∈ [20, 20]
                          // ...
                          // Iteration 5: sum ∈ [50, 50]
}
// Prover proves: sum ∈ [50, 50] ✅ No overflow!
```

### Function Analysis

The prover analyzes function bodies:

```etch
fn square(x: int) -> int {
    return x * x;
}

// When analyzing calls:
let y = square(100);     // Prover checks: 100 * 100 = 10000 ✅ Safe

let z = rand(10000000);
let big = square(z);     // ❌ ERROR: multiplication overflow
```

## Safety Checks

### Array Bounds Checking

```etch
// Static bounds checks
let arr = [1, 2, 3];
let x = arr[5];          // ❌ ERROR: index 5 out of bounds [0, 2]

// Dynamic range checking
fn getItem(arr: array[int], i: int) -> option[int] {
    if i >= 0 and i < #arr {
        return some(arr[i]);  // ✅ Prover knows this is safe
    }
    return none;
}
```

### Arithmetic Safety

```etch
// Addition
let a = rand(1, 100);
let b = rand(1, 100);
let sum = a + b;         // ✅ Safe: max is 200

// Subtraction
let x = rand(1, 10);
let y = rand(15, 20);
let diff = x - y;        // ✅ Safe: result ∈ [-19, -5]

// Multiplication
let small = rand(1, 10);
let product = small * small;  // ✅ Safe: max is 100

// Division
let dividend = rand(1, 100);
let divisor = rand(1, 10);
let quotient = dividend / divisor;  // ✅ Safe: divisor never zero
```

### Option and Result Safety

```etch
// ✅ Must handle all cases
match parseValue(input) {
    some(v) => process(v),
    none => handleError(),     // Compiler ensures you handle this
}

// ❌ Cannot ignore errors
let x = parseValue(input);     // ERROR: cannot use option[int] as int

// ✅ Explicit unwrapping required
match parseValue(input) {
    some(value) => {
        // value is safe to use here
        print(value);
    }
    none => print("parse failed"),
}
```

## Working with the Prover

### Understanding Prover Errors

```etch
let x = rand(1000000000);
let y = rand(1000000000);
let sum = x + y;
// ❌ ERROR: addition overflow
//   Explanation: x ∈ [0, 10^9], y ∈ [0, 10^9]
//                sum could be up to 2*10^9, which might overflow
```

### Fixing Prover Errors

#### Strategy 1: Reduce Ranges

```etch
// ❌ Too large
let x = rand(1000000000);
let sum = x + x;  // ERROR: overflow

// ✅ Bounded
let x = rand(100);
let sum = x + x;  // Safe: max is 200
```

#### Strategy 2: Add Explicit Checks

```etch
// ❌ Unbounded division
fn divide(a: int, b: int) -> int {
    return a / b;  // ERROR: division by zero
}

// ✅ Explicit safety check
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);  // Safe: prover knows b != 0 here
}
```

#### Strategy 3: Use Modulo to Bound Results

```etch
// ❌ Accumulation can overflow
fn sumLarge(arr: array[int]) -> int {
    var sum = 0;
    for item in arr {
        sum = sum + item;  // ERROR: might overflow
    }
    return sum;
}

// ✅ Use modulo to keep bounded
fn sumMod(arr: array[int]) -> int {
    var sum = 0;
    for item in arr {
        sum = (sum + item) % 1000000007;  // Always stays bounded
    }
    return sum;
}
```

#### Strategy 4: Narrow Ranges with Conditionals

```etch
fn processValue(x: int) -> int {
    // x has full int64 range here

    if x < 0 or x > 1000 {
        return 0;  // Early exit for out-of-range
    }

    // Prover now knows: x ∈ [0, 1000]
    return x * x;  // ✅ Safe: max is 1000000
}
```

### Prover-Friendly Patterns

#### Pattern 1: Guard Clauses

```etch
fn safeDivide(a: int, b: int) -> result[int] {
    // Guard against zero
    if b == 0 {
        return error("div by zero");
    }

    // Prover knows b != 0 here
    return ok(a / b);
}
```

#### Pattern 2: Bounded Loops

```etch
// ✅ Fixed iteration count
for i in 0 ..< 100 {
    // Prover knows exactly how many iterations
}

// ⚠️ Unbounded (prover may give up)
var i = 0;
while someCondition() {
    i = i + 1;  // Prover may reach iteration limit
}
```

#### Pattern 3: Result Types for Fallibility

```etch
// ✅ Explicit error handling
fn readConfig() -> result[Config] {
    match tryReadFile("config.txt") {
        ok(contents) => parseConfig(contents),
        error(msg) => error("Cannot read config: " + msg),
    }
}
```

### Debug with --verbose

```bash
# See what the prover is thinking
./etch --verbose myfile.etch 2>&1 | grep "Variable x"
```

Output shows ranges:
```
[PROVER] Variable x initialized with range [0..100]
[PROVER] Variable x assigned range [1..100]
[PROVER] Variable y initialized with range [0..50]
[PROVER] Addition: [1..100] + [0..50] = [1..150] ✅
```

## Best Practices

### 1. Trust the Prover

If code compiles, it's safe. Don't add redundant runtime checks:

```etch
// ❌ Unnecessary check - prover already verified this
let arr = [1, 2, 3];
if i < #arr {  // Redundant if prover proved i is in bounds
    let x = arr[i];
}

// ✅ Trust the prover
let x = arr[i];  // If this compiles, it's safe
```

### 2. Keep Ranges Reasonable

```etch
// ❌ Unnecessarily large ranges
let x = rand(2147483647);  // Why so large?

// ✅ Use appropriate bounds
let count = rand(1, 100);  // Reasonable for a count
```

### 3. Leverage Type System

```etch
// ✅ Use result[T] for operations that can fail
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("division by zero");
    }
    return ok(a / b);
}

// ✅ Use option[T] for optional values
fn findIndex(arr: array[int], target: int) -> option[int] {
    for i in 0 ..< #arr {
        if arr[i] == target {
            return some(i);
        }
    }
    return none;
}
```

### 4. Write Prover-Friendly Code

```etch
// ✅ Clear bounds make prover happy
if x >= 0 and x < 100 {
    // Prover knows: x ∈ [0, 99]
    let safe = x * x;  // Safe: max is 9801
}

// ✅ Use constants for limits
let MAX_SIZE = 100;
if x >= 0 and x < MAX_SIZE {
    let safe = x * x;
}
```

## Summary

Etch's compile-time safety checking provides:

✅ **Memory safety** - No buffer overruns
✅ **Arithmetic safety** - No overflow/underflow
✅ **Null safety** - No null pointer dereferences
✅ **Initialization safety** - No uninitialized variables
✅ **Type safety** - No type confusion
✅ **Zero runtime cost** - All checks at compile time

**If your Etch program compiles, it's guaranteed to be free from these entire classes of bugs.**

---

**See Also:**
- [Overflow Detection](overflow.md) - Detailed overflow checking documentation
- [Type System](types.md) - How types ensure safety
- [Functions](functions.md) - Safe function patterns
