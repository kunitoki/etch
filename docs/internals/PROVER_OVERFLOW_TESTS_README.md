# Overflow Test Suite - README

## Purpose

This directory contains a comprehensive test suite for integer overflow detection. These tests serve dual purposes:

1. **Document expected behavior** - .fail files show what the prover SHOULD report
2. **Track bugs** - Tests that currently fail expose bugs that need fixing

## Test Status

### ✅ Passing Tests (Correct Prover Behavior)

These tests demonstrate the prover working correctly:

- `overflow_chained_operations.etch` - Sequential operations tracked correctly
- `overflow_widening_through_operations.etch` - Range widening tracked
- `overflow_loops_accumulation.etch` - Safe loop accumulation
- `overflow_if_branches_safe.etch` - Safe branch analysis
- `overflow_match_expressions.etch` - Safe match analysis
- `overflow_multiplication_mixed_signs.etch` - Correctly rejects overflow
- `overflow_negation_computed.etch` - Correctly rejects negation overflow
- `overflow_interprocedural_fail.etch` - **NOW WORKING!** Catches interprocedural overflow
- Plus 17+ other existing overflow tests

### ❌ Currently Failing Tests (Exposing ICE Bugs)

These 10 tests currently produce "Internal compiler error" instead of proper prover errors. The .fail files document what SHOULD happen:

**ICE in Constant Folding:**
- `overflow_ice_constant_folding.etch` - ICE during constant evaluation
- `overflow_ice_function_call.etch` - ICE in function constant folding
- `overflow_interprocedural_definite_fail.etch` - ICE with large constants

**ICE in Control Flow:**
- `overflow_ice_in_loop.etch` - ICE in loop body
- `overflow_ice_in_if_branch.etch` - ICE in if branch
- `overflow_ice_in_match.etch` - ICE in match branch

**ICE in Complex Expressions:**
- `overflow_array_index_computation.etch` - ICE in index arithmetic
- `overflow_loops_definite_fail.etch` - ICE or wrong result in loop

**Parsing Issues:**
- `overflow_negation_imin.etch` - Parser can't handle IMin literal
- `overflow_division_imin_by_minus_one.etch` - Caught at wrong stage

## What the .fail Files Mean

Each .fail file contains the **EXPECTED** prover error that SHOULD be produced, not the current ICE:

**Current (Wrong):**
```
Internal compiler error: over- or underflow
```

**Expected (Documented in .fail file):**
```
examples/file.etch:line:col: error: addition overflow
  line-1 | context
  line   | let y = x + 1000;
                      ^
  line+1 | context
```

## How to Use These Tests

### For Developers Fixing ICE Bugs:

1. Pick a failing test
2. Look at its .fail file to see what error SHOULD be produced
3. Fix the code so it produces that error instead of ICE
4. The test will automatically pass once fixed

### For Verifying Prover Correctness:

Run `just tests` - all overflow tests should eventually PASS, meaning:
- Unsafe code is rejected with proper errors (not ICE)
- Safe code compiles successfully

## Root Causes

### Issue #1: ICE Instead of Prover Errors

**Location:** `src/etch.nim:79-84`

When constant folding triggers Nim's OverflowDefect, it's caught and reported as ICE.

**Fix needed:**
- Add checked arithmetic before Nim's runtime catches overflow
- Convert OverflowDefect to ProverError with source location
- Use checked operations in `src/etch/prover/binary_operations.nim`

### Issue #2: Loop Overflow Not Detected

**Location:** `src/etch/prover/expression_analysis.nim:~1795-1830`

Loop analysis doesn't track cumulative effects across iterations.

**Fix needed:**
- Track iteration counts for bounded loops
- Multiply ranges by iteration count
- Detect cumulative overflow

### Issue #3: Parser Can't Handle IMin

**Location:** `src/etch/frontend/parser.nim` or lexer

The literal `-9223372036854775808` can't be parsed.

**Fix needed:**
- Handle IMin as a special case
- Or allow slightly larger range during parsing and check later

## Progress Tracking

**Total overflow tests:** 25+
- ✅ **Passing:** 15+ tests (prover working correctly)
- ❌ **Failing:** 10 tests (exposing bugs, .fail files document expected behavior)

**When all tests pass:** The prover will properly catch ALL overflow scenarios at compile time with clear error messages. No more ICE, no more runtime failures.

## Test Categories

### By Control Flow:
- **Loops:** accumulation, bounded, unbounded
- **Branches:** if/else, nested, refinement
- **Match:** options, disjoint ranges, nested
- **Functions:** inter-procedural, recursive, constant folding

### By Operation:
- **Addition:** direct, chained, accumulation
- **Subtraction:** underflow, negation
- **Multiplication:** mixed signs, large ranges
- **Division:** IMin/-1 edge case
- **Index computation:** overflow before bounds check

### By Range Type:
- **Constants:** compile-time overflow
- **Small ranges:** provably safe
- **Large ranges:** potential overflow
- **Disjoint ranges:** union analysis
- **Widening ranges:** tracking through operations

## See Also

- `PROVER_OVERFLOW_ANALYSIS.md` - Initial overflow analysis
- `PROVER_OVERFLOW_CONTROL_FLOW_ANALYSIS.md` - Comprehensive control flow analysis
- Both documents contain detailed root cause analysis and fix recommendations
