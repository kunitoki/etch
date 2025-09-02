# Overflow Detection in Etch

Etch provides comprehensive compile-time overflow detection through its safety prover. This document explains how overflow checking works, why it's important, and how to write code that works with the prover.

## Table of Contents

1. [Overview](#overview)
2. [Design Philosophy](#design-philosophy)
3. [How It Works](#how-it-works)
4. [Writing Safe Code](#writing-safe-code)
5. [Common Patterns](#common-patterns)
6. [Debugging Overflow Errors](#debugging-overflow-errors)
7. [Implementation Details](#implementation-details)

## Overview

Integer overflow is a common source of bugs and security vulnerabilities in software. Etch's prover analyzes your code before execution to ensure that all arithmetic operations are safe.

**Key Features:**
- **Compile-time checking**: Overflow is detected before your code runs
- **Range analysis**: Tracks the possible range of values for all variables
- **Zero runtime overhead**: No runtime checks needed after prover verification
- **Conservative but precise**: Flags potential overflows while allowing provably safe operations

## Design Philosophy

### What is "Possible Overflow"?

The prover uses a **conservative** approach: if overflow is mathematically possible given the range of input values, it's an error.

**"Possible overflow" means:**
- Runtime values are not known at compile time (from `rand()`, file I/O, function parameters, user input)
- The range of possible values includes combinations that would cause overflow
- The prover cannot prove all execution paths are safe

**Known constant values:**
- If both operands are compile-time constants, the prover evaluates the exact result
- Only raises an error if the computed constant actually overflows
- Example: `1000 + 2000` is safe, `9223372036854775807 + 1` overflows

### Why Conservative Checking?

Consider this function:
```etch
fn add(a: int, b: int) -> int {
    return a + b;  // ❌ ERROR: addition overflow
}
```

Even though you might call it with safe values like `add(5, 10)`, the function could be called with any int64 values. The prover must assume the worst case: `add(IMax, 1)` would overflow.

## How It Works

### Range Tracking

The prover tracks ranges for every value in your program:

```etch
var x = rand(1, 100);     // x ∈ [1, 100]
var y = rand(1, 50);      // y ∈ [1, 50]
var z = x + y;            // z ∈ [2, 150] ✅ Safe
```

The prover computes:
- **Minimum possible value**: `min(x) + min(y) = 1 + 1 = 2`
- **Maximum possible value**: `max(x) + max(y) = 100 + 50 = 150`
- **Overflow check**: Does `[2, 150]` fit in int64? Yes! ✅

### Array Element Ranges

When you create an array, the prover tracks the range of all elements:

```etch
var arr = [1, 2, 3, 4, 5];  // Elements ∈ [1, 5]
var sum = 0;                 // sum ∈ [0, 0]
for i in 0 ..< #arr {
    sum = sum + arr[i];      // Loop iteration 1: sum ∈ [1, 5]
                             // Loop iteration 2: sum ∈ [2, 10]
                             // Loop iteration 3: sum ∈ [3, 15]
                             // ... etc
}
// Final: sum ∈ [15, 15] ✅ Safe
```

The prover:
1. Analyzes array literal to determine element range: `[1, 5]`
2. Tracks loop bounds: exactly 5 iterations
3. Simulates loop execution to compute accumulating range
4. Verifies no overflow in any iteration

### Loop Analysis

The prover uses **fixed-point iteration** to analyze loops:

```etch
var x = 0;
for i in 0 ..< 10 {
    x = x + 5;  // Prover iterates to find: x ∈ [0, 50] ✅
}
```

For unbounded loops or very large iteration counts, the prover may reach a fixed point where ranges stabilize or hit maximum iterations.

## Writing Safe Code

### Use Bounded Ranges

✅ **Good**: Explicit bounds that the prover can verify
```etch
fn safe_add(a: int, b: int) -> int {
    // Add runtime checks if you can't prove safety at compile time
    if a > IMax - b {
        return IMax;  // Saturating arithmetic
    }
    return a + b;
}
```

✅ **Better**: Use bounded input types
```etch
fn bounded_add(a: int, b: int) -> int {
    // Document preconditions
    // Requires: 0 <= a <= 1000, 0 <= b <= 1000
    return a + b;  // Prover verifies at call sites
}

// Call with bounded values
var x = rand(0, 1000);
var y = rand(0, 1000);
var result = bounded_add(x, y);  // ✅ Safe
```

### Array Operations

✅ **Good**: Bounded element ranges
```etch
fn array_sum(arr: array[int]) -> int {
    var sum = 0;
    for i in 0 ..< #arr {
        sum = sum + arr[i];  // ✅ Safe if elements are bounded
    }
    return sum;
}

// Create array with small values
var data = [rand(1, 10), rand(1, 10), rand(1, 10)];
var total = array_sum(data);  // ✅ Safe: sum ∈ [3, 30]
```

❌ **Bad**: Unbounded accumulation
```etch
fn unsafe_sum(arr: array[int]) -> int {
    var sum = 0;
    for i in 0 ..< #arr {
        sum = sum + arr[i];  // ❌ ERROR: arr[i] has unbounded range
    }
    return sum;
}

// Array elements could be anything
var data = [rand(IMax), rand(IMax), rand(IMax)];
var total = unsafe_sum(data);  // Would overflow!
```

### Function Parameters

When a function takes int parameters without constraints, they have the full int64 range:

```etch
fn add(a: int, b: int) -> int {
    return a + b;  // ❌ ERROR: a ∈ [IMin, IMax], b ∈ [IMin, IMax]
}
```

**Solutions:**

1. **Use smaller types** (if Etch supports them):
```etch
fn add(a: i32, b: i32) -> i32 {
    return a + b;  // ✅ Safe: i32 + i32 won't overflow i32 bounds
}
```

2. **Add explicit bounds checks**:
```etch
fn add_checked(a: int, b: int) -> int {
    if a > 0 and b > IMax - a {
        panic("overflow");
    }
    if a < 0 and b < IMin - a {
        panic("underflow");
    }
    return a + b;
}
```

3. **Use saturating arithmetic**:
```etch
fn add_saturating(a: int, b: int) -> int {
    if a > 0 and b > IMax - a {
        return IMax;
    }
    if a < 0 and b < IMin - a {
        return IMin;
    }
    return a + b;
}
```

## Common Patterns

### Pattern 1: Bounded Accumulation

✅ **Safe**: When loop bounds and element ranges are known
```etch
fn safe_average() -> int {
    var sum = 0;
    for i in 0 ..< 100 {
        sum = sum + rand(1, 10);  // Each iteration: +[1, 10]
    }                              // Final: sum ∈ [100, 1000]
    return sum / 100;              // ✅ Safe
}
```

### Pattern 2: Range Narrowing

✅ **Safe**: Use conditionals to narrow ranges
```etch
fn conditional_add(a: int, b: int) -> int {
    if a < 0 or a > 1000 {
        return 0;
    }
    if b < 0 or b > 1000 {
        return 0;
    }
    // Prover knows: a ∈ [0, 1000], b ∈ [0, 1000]
    return a + b;  // ✅ Safe: result ∈ [0, 2000]
}
```

### Pattern 3: Modulo for Bounded Results

✅ **Safe**: Use modulo to keep values bounded
```etch
fn hash_combine(h1: int, h2: int) -> int {
    // Use modulo to prevent overflow
    return (h1 * 31 + h2) % 1000000007;  // ✅ Result ∈ [0, 1000000006]
}
```

### Pattern 4: Fibonacci with Overflow Prevention

✅ **Safe**: Bound the recursion depth
```etch
fn fibonacci(n: int) -> int {
    if n <= 1 {
        return n;
    }
    if n > 46 {  // fib(46) is max safe value for int64
        return 0;
    }
    var fib1 = fibonacci(n - 1);
    var fib2 = fibonacci(n - 2);
    // Use modulo to prevent overflow
    return (fib1 % 1000000) + (fib2 % 1000000);
}
```

## Debugging Overflow Errors

### Understanding Error Messages

```
examples/test.etch:10:15: error: addition overflow
  9 |     var sum = a + b;
 10 |     var z = x + y;
                   ^
 11 |
```

**What this means:**
- The expression `x + y` could overflow
- Given the ranges of `x` and `y`, their sum might exceed IMax

### Debugging Steps

1. **Check the ranges**: Run with `--verbose` to see range information
   ```bash
   ./etch --verbose test.etch 2>&1 | grep "Variable x\|Variable y"
   ```

2. **Trace the source**: Look at how `x` and `y` are initialized
   ```etch
   var x = rand(1000000000);  // Large range!
   var y = rand(1000000000);  // Large range!
   var z = x + y;             // Could overflow
   ```

3. **Fix the ranges**: Use smaller bounds or add checks
   ```etch
   var x = rand(100);         // Smaller range
   var y = rand(100);         // Smaller range
   var z = x + y;             // ✅ Safe: max is 200
   ```

### Common Mistakes

❌ **Mistake 1**: Assuming small test values mean it's safe
```etch
fn add(a: int, b: int) -> int {
    return a + b;  // ❌ ERROR even though you test with add(1, 2)
}
```
The prover checks ALL possible values, not just your test cases.

❌ **Mistake 2**: Large array accumulation
```etch
var sum = 0;
for i in 0 ..< 1000000 {
    sum = sum + 1000;  // ❌ ERROR: 10^9 iterations * 10^3 = 10^12
}
```

✅ **Fix**: Use bounded accumulation or check the math
```etch
// 1000 iterations * 100 per iteration = 100,000 ✅ Safe
var sum = 0;
for i in 0 ..< 1000 {
    sum = sum + 100;
}
```

## Implementation Details

### File: `src/etch/prover/binary_operations.nim`

#### Addition Overflow Check (lines 56-69)

```nim
# Known constants: check if actual sum overflows
if a.known and b.known:
  let s = a.cval + b.cval
  if (b.cval > 0 and a.cval > IMax - b.cval) or
     (b.cval < 0 and a.cval < IMin - b.cval):
    raise newProverError(e.pos, "addition overflow on constants")
  return infoConst(s)

# Unknown ranges: check if ranges could overflow
if (b.maxv > 0 and a.maxv > IMax - b.maxv) or
   (b.maxv < 0 and a.maxv < IMin - b.maxv):
  raise newProverError(e.pos, "addition overflow")
```

#### Subtraction Overflow Check (lines 72-97)

Similar logic for subtraction, checking both:
- **Underflow**: `a.minv - b.maxv < IMin`
- **Overflow**: `a.maxv - b.minv > IMax`

#### Multiplication Overflow Check (lines 100-182)

Uses division test to detect overflow:
```nim
let product = a * b
if a != 0 and product / a != b:
  raise newProverError(e.pos, "multiplication overflow")
```

For range multiplication, computes all corner products and verifies each is safe.

### File: `src/etch/prover/expression_analysis.nim`

#### Array Indexing (lines 523-612)

When analyzing `arr[i]`, returns the element range:
```nim
# If array has element range information
if arrayInfo.initialized:
  return Info(
    minv: arrayInfo.minv,  # Min element value
    maxv: arrayInfo.maxv   # Max element value
  )
```

This allows the prover to track element bounds through array operations.

## Testing

See `examples/overflow_*.etch` for comprehensive test cases demonstrating:
- Safe operations that pass prover checks
- Unsafe operations that correctly trigger errors
- Edge cases and boundary conditions

Run tests with:
```bash
just test examples/overflow_safe_ranges.etch
just test examples/overflow_fail.etch
```

## Further Reading

- [Safety Prover Architecture](prover.md)
- [Type System](types.md)
- [Range Analysis](range-analysis.md)
