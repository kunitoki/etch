# Etch Language Implementation

## Directives
- **Never change directory when executing commands, stay in the project root (where this file lives)**
- **Never commit or stash code using git, use it only to inspect previous commits or changed files only**
- **Never ever think about giving up, like "we should do Y but because it's too much, for now we do X" and you end up shortcutting to tech debt and fake implementations**
- **When you create new tests in examples (both passing and failing) add the corresponding validation files .pass and .fail**
- **Everytime you are modifying the bytecode or AST structure, bump their corresponding version numbers but keep supporting only the latest version in code**
- **Never disable features if you cannot make them work, instead restart from a smaller problem and iterate in steps until you can understand the issue deeply**
- **Make all examples grouped by the first word, for example if you are testing a specific feature (like `comptime` or `inference`), use it as first part of the example name like `comptime_inject_test.etch`**
- **When hunting bugs or making changes, add extensive verbose logging protected by the verbose flag, this will help you detect issues**
- **Never swallow nim exceptions, print the exception for debugging purposes**
- **Keep updated the documentation in @docs/ (and the developers docs in @docs/internal/) as we keep iterating changes**
- **Remember `result` is a valid keyword in nim, so don't create variables with that name if it's not the implicit one**
- **Try to not add too many comments in methods, try to keep it just for method signature, not several inside bodies at every instruction**
- **Never try to write files into /tmp**

## Testing and validation of correctness

For bugfixing and validation, you have to:
- **Primary testing workflow**: test compiling and running examples + debugger tests with `just tests`
- Test compiling and running a single example `just test examples/simple_test.etch` (alias for `nim r src/etch.nim --test examples/simple_test.etch`):
    * If the test is passing, you need to provide a `examples/simple_test.pass` file
    * Otherwise a `examples/simple_test.fail` one when it fails.
- To test **only** the debugger integration, use `nimble test`.
- Compile and run a single etch file in verbose mode with `just go examples/simple_test.etch`.
- Compile and reinstall the VSCode extension with `just vscode`

## Improvement plan

Etch Language/Compiler/Prover/Interpreter Improvement Plan

Based on the comprehensive VM architecture analysis document, here's a prioritized plan to improve Etch:

Phase 1: Bytecode Optimization Infrastructure (HIGH PRIORITY)

1.1 Re-enable and Fix Bytecode Optimizer

File: src/etch/interpreter/regvm_compiler.nim:1665-1800
- The optimizer is currently commented out due to "variant object field access" issues
- Fix the optimizer to properly handle the RegInstruction variant type
- Enable at least optimization level 1 by default
- Impact: Immediate performance gains from constant folding and dead code elimination

1.2 Integrate Prover Information into Optimizer

Files: src/etch/interpreter/regvm_compiler.nim, src/etch/prover/expression_analysis.nim
- Use range analysis results from the prover to eliminate runtime checks
- Add dead code elimination based on evaluateCondition() results
- Remove bounds checks when prover proves safety
- Remove division-by-zero checks when prover proves divisor is non-zero
- Impact: Major performance boost, cleaner bytecode

1.3 Enhanced Constant Folding

File: src/etch/interpreter/regvm_compiler.nim
- Extend constant folding to work with prover's range information
- Fold comparisons when ranges don't overlap (e.g., [5,10] < [20,30] → always true)
- Fold arithmetic when results are compile-time determinable
- Impact: Smaller bytecode, faster execution

Phase 2: Instruction Set Improvements (MEDIUM PRIORITY)

2.1 Add Jump Target Table

File: src/etch/interpreter/regvm.nim
- Create explicit jump target table for each function
- Validate jumps only go to valid targets
- Enable "switch out data tables" optimization mentioned in the document
- Impact: Safer bytecode, enables advanced optimizations

2.2 Add ARG Instructions for Function Calls

Files: src/etch/interpreter/regvm.nim, src/etch/interpreter/regvm_compiler.nim
- Add ropArg and ropArgImm instructions
- Replace current "allocate consecutive registers" approach
- Simplify function call codegen
- Impact: Cleaner bytecode, easier to optimize

2.3 Add Reversed Arithmetic Operations

File: src/etch/interpreter/regvm.nim
- Add ropRSub, ropRDiv, ropRMod for when operands are swapped
- Update compiler to use these when beneficial
- Impact: Slightly better code generation in some cases

Phase 3: Advanced Optimizations (MEDIUM-HIGH PRIORITY)

3.1 Peephole Optimization Passes

File: src/etch/interpreter/regvm_compiler.nim
- Pattern: LoadK + LoadK + Arithmetic → single LoadK with folded result
- Pattern: Test + Jmp → TestJmp (fused instruction - already exists!)
- Pattern: Jmp to Jmp → Jmp to target
- Pattern: Move + Move → single Move
- Impact: Faster execution, smaller bytecode

3.2 Common Subexpression Elimination (CSE)

File: src/etch/interpreter/regvm_compiler.nim:1748-1776
- Fix and enhance existing CSE implementation
- Track expressions across basic blocks
- Invalidate cache on control flow merge
- Impact: Fewer redundant computations

3.3 Dead Store Elimination

File: src/etch/interpreter/regvm_compiler.nim
- Use regvm_lifetime.nim data to eliminate stores to dead registers
- Remove writes that are never read
- Impact: Smaller bytecode, faster execution

3.4 Loop Optimizations

File: src/etch/interpreter/regvm_compiler.nim:866-1033
- Loop-invariant code motion (hoist invariants out of loops)
- Strength reduction (replace expensive ops with cheaper ones)
- Induction variable elimination
- Impact: Significantly faster loops

Phase 4: Type-Aware Optimizations (HIGH IMPACT)

4.1 Static Type Specialization

Files: src/etch/interpreter/regvm.nim, src/etch/interpreter/regvm_exec.nim
- Add type-specialized instruction variants (e.g., ropAddInt, ropAddFloat)
- Generate specialized code when types are statically known
- Eliminate runtime type checks from templates like doAdd, doSub, etc.
- Impact: Major performance improvement (20-40% faster arithmetic)

4.2 Inline Small Functions

Files: src/etch/interpreter/regvm_compiler.nim, src/etch/prover/function_evaluation.nim
- Detect pure functions with compile-time constant arguments
- Inline small functions (< 10 instructions) at call sites
- Use prover's tryEvaluatePureFunction() more aggressively
- Impact: Eliminates call overhead, enables more optimizations

4.3 Monomorphization for Generic Code

File: src/etch/typechecker/types.nim
- Generate specialized versions of generic functions
- Eliminates dynamic dispatch where possible
- Impact: Better optimization opportunities

Phase 5: Register Allocation Improvements (MEDIUM PRIORITY)

5.1 Better Register Reuse

Files: src/etch/interpreter/regvm.nim:299-332, src/etch/interpreter/regvm_compiler.nim
- Implement proper liveness analysis using regvm_lifetime.nim
- Reuse registers more aggressively when safe
- Reduce register pressure
- Impact: Better cache utilization, supports more complex functions

5.2 Register Coalescing

File: src/etch/interpreter/regvm_compiler.nim
- Eliminate unnecessary ropMove instructions
- Merge registers with non-overlapping lifetimes
- Impact: Smaller bytecode, fewer memory operations

Phase 6: Instruction Fusion (MEDIUM PRIORITY)

6.1 Expand Fused Operations

Files: src/etch/interpreter/regvm.nim:89-96, src/etch/interpreter/regvm_compiler.nim:92-130
- Current fusions: AddAdd, MulAdd, CmpJmp, IncTest, LoadAddStore, GetAddSet
- Add more patterns:
  - Load + Test + Jump → LoadTestJump
  - Compare + Store → already have EqStore, LtStore, etc. - good!
  - Load + Cast → LoadCast
  - Array operations: GetIndex + Arithmetic + SetIndex
- Impact: Fewer instructions, faster execution

6.2 Pattern-Based Fusion Framework

File: src/etch/interpreter/regvm_compiler.nim
- Create declarative pattern matching system
- Make it easy to add new fusion patterns
- Impact: Extensible optimization framework

Phase 7: Immediate Variants (LOW PRIORITY)

7.1 More Immediate Instructions

File: src/etch/interpreter/regvm.nim
- Already have: AddI, SubI, MulI, EqI, LtI, LeI
- Add: DivI, ModI, AndI, OrI, GetIndexI (already exists!)
- Impact: Smaller bytecode for common patterns

Phase 8: Debugging and Tooling (ONGOING)

8.1 Bytecode Verifier

New file: src/etch/interpreter/regvm_verifier.nim
- Verify bytecode before execution
- Check jump targets are valid
- Verify register usage doesn't exceed limits
- Validate instruction operands
- Impact: Catch compiler bugs, safer execution

8.2 Better Bytecode Dumper

File: src/etch/interpreter/regvm_dump.nim
- Show register liveness information
- Show optimization opportunities
- Annotate with prover analysis results
- Impact: Better debugging and optimization visibility

8.3 Optimization Statistics

New feature: Add --optimization-report flag
- Show which optimizations were applied
- Show bytecode size before/after
- Show estimated performance improvement
- Impact: Better understanding of optimization effectiveness

Testing Strategy

- Run `just tests` after each change
- Use `just perf` to benchmark improvements
- Create regression tests for each optimization
- Ensure prover still catches all safety violations
