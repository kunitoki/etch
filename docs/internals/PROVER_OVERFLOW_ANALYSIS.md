# Integer Overflow Behavior Analysis

## Summary

This document analyzes the Etch prover's integer overflow detection capabilities and identifies several issues and weaknesses.

## Tests Created

### Passing Tests (Prover working correctly)
1. **overflow_chained_operations.etch** - Tests multiple operations in sequence
2. **overflow_widening_through_operations.etch** - Tests range tracking through operations
3. **overflow_multiplication_mixed_signs.etch** - Tests mixed-sign multiplication (properly fails)
4. **overflow_negation_computed.etch** - Tests negation near IMin (properly fails)

### Failing Tests (Exposing Issues)
1. **overflow_interprocedural_fail.etch** - Inter-procedural overflow NOT caught
2. **overflow_interprocedural_definite_fail.etch** - **INTERNAL COMPILER ERROR**
3. **overflow_array_index_computation.etch** - **INTERNAL COMPILER ERROR**
4. **overflow_negation_imin.etch** - **INTERNAL COMPILER ERROR** (parsing issue)
5. **overflow_division_imin_by_minus_one.etch** - Caught at wrong stage

## Issues Identified

### Critical Issue #1: Internal Compiler Errors Instead of Proper Prover Errors

**Files affected:**
- `overflow_interprocedural_definite_fail.etch`
- `overflow_array_index_computation.etch`
- `overflow_negation_imin.etch`

**Problem:** When overflow occurs in constant folding or evaluation, the compiler crashes with "Internal compiler error: over- or underflow" instead of reporting a proper prover error with source location.

**Expected behavior:** The prover should catch these overflows during analysis and report them with:
```
examples/file.etch:line:col: error: addition overflow
```

**Actual behavior:**
```
Internal compiler error: over- or underflow
```

**Root cause:** The overflow checking is happening in Nim's runtime (when evaluating constant expressions) rather than being caught proactively by the prover's range analysis.

**Location in code:** src/etch.nim:79-81
```nim
except OverflowDefect as e:
  echo "Internal compiler error: ", e.msg
  quit 1
```

### Critical Issue #2: Inter-procedural Overflow Not Detected

**File:** `overflow_interprocedural_fail.etch`

**Problem:** When a function takes a parameter and performs arithmetic on it, the prover does not infer preconditions on that parameter to prevent overflow.

**Example:**
```etch
fn addLarge(x: int) -> int {
  return x + 1000;  // No check that x <= IMax - 1000
}

fn main() -> void {
  let large = rand(9223372036854774807);  // [0, IMax - 1000]
  let result = addLarge(large);  // Compiles but could overflow!
}
```

**Expected behavior:** The prover should:
1. Infer from `addLarge` that it requires `x <= IMax - 1000`
2. Check at the call site that the argument satisfies this precondition
3. Fail with an overflow error if the precondition cannot be proven

**Actual behavior:** The code compiles and runs, potentially producing incorrect results due to overflow.

**Relation to WP implementation:** This is related to the weakest precondition calculator I just implemented. The WP calculator currently focuses on safety properties (array bounds, division by zero, nil dereference) but should also extract overflow constraints from arithmetic operations.

### Issue #3: Parsing Very Large Negative Constants

**File:** `overflow_negation_imin.etch`

**Problem:** Cannot parse IMin directly as a literal:
```etch
let min_val = -9223372036854775808;  // Fails to parse
```

**Error:**
```
Internal compiler error: Parsed integer outside of valid range
```

**Workaround:** Must compute IMin:
```etch
let min_val = -9223372036854775807 - 1;
```

### Issue #4: Division Edge Cases Not Fully Handled

**File:** `overflow_division_imin_by_minus_one.etch`

**Problem:** The special case of `IMin / -1` (which would produce `IMax + 1`) is not explicitly checked for overflow. The test fails at an earlier stage (subtraction overflow), so this edge case couldn't be properly tested.

**Potential issue:** If a value with range containing IMin is divided by a value with range containing -1, the division overflow might not be caught.

## Overflow Detection Coverage

### ✅ Well-Handled Cases
- Addition overflow with explicit ranges
- Subtraction underflow with explicit ranges
- Multiplication overflow with range analysis
- Negation overflow when range includes IMin
- Constant folding overflow (though with poor error messages)

### ⚠️ Partially Handled Cases
- Chained operations (works but could be more precise)
- Mixed-sign multiplication (conservative, may reject safe code)
- Range narrowing through control flow (works but could be stronger)

### ❌ Poorly Handled Cases
- Inter-procedural overflow (not caught at all)
- Division of IMin by -1 (edge case not tested due to earlier failures)
- Overflow during constant folding (internal errors instead of prover errors)
- Power operations (no overflow checking found in code)
- Very large literal constants (parsing errors)

## Recommendations

### Priority 1: Fix Internal Compiler Errors
1. Add explicit overflow checking in constant evaluation before Nim's runtime catches it
2. Convert OverflowDefect exceptions into proper ProverError with source locations
3. Add overflow checking in all constant folding operations

**Suggested fix location:** `src/etch/prover/expression_analysis.nim` - add overflow checks in constant folding before performing operations.

### Priority 2: Enhance WP Calculator for Overflow
1. Extend `extractPreconditionsFromExpr()` to infer overflow constraints from arithmetic
2. Add constraints like `ckMaxValue` and `ckMinValue` to `ConstraintKind`
3. Propagate overflow constraints through function calls

**Example:** For `x + 1000`, infer constraint: `x <= IMax - 1000`

### Priority 3: Add Power Operation Overflow Checking
1. Implement `analyzeBinaryPower()` in `src/etch/prover/binary_operations.nim`
2. Check for overflow in exponentiation operations
3. Handle edge cases: negative bases, large exponents

### Priority 4: Improve Division Overflow Detection
1. Add explicit check for `IMin / -1` case
2. Check for this pattern in range analysis when:
   - Dividend range includes IMin
   - Divisor range includes -1

### Priority 5: Better Constant Parsing
1. Handle IMin literal directly: `-9223372036854775808`
2. Improve error messages for out-of-range integer literals
3. Consider using BigInt for parsing and then checking range

## Test Suite Status

Created 9 new overflow tests:
- 4 passing tests demonstrating working overflow detection
- 5 tests exposing issues (3 with internal errors, 2 with missed overflows)

All tests are in `examples/overflow_*.etch`

## Conclusion

The Etch prover has a solid foundation for overflow detection in direct arithmetic operations, but has critical gaps:

1. **Internal errors instead of user-friendly error messages** (most critical)
2. **No inter-procedural overflow analysis** (defeats purpose of prover for library code)
3. **Missing checks for some edge cases** (division, power, etc.)

The recently implemented weakest precondition calculator provides a good foundation to address issue #2, but needs to be extended to track arithmetic constraints in addition to safety properties.
