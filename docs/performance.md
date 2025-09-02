# Etch Performance Benchmarks

**Generated**: 2025-11-24T15:56:03+01:00

**Directory**: `performance`

Each section compares runtimes against the baseline named in the heading. Colored dots show how alternative targets perform relative to that baseline.

## Python Baseline

| Benchmark             | Python | VM     | VM vs Python | C Backend | C vs Python |
| --------------------- | ------ | ------ | ------------ | --------- | ----------- |
| arithmetic_operations | 91.6ms | 23.3ms | 🟢 3.94×    | 4.3ms     | 🟢 21.06×  |
| array_operations      | 47.0ms | 12.1ms | 🟢 3.90×    | 3.8ms     | 🟢 12.51×  |
| for_loop_print        | 44.1ms | 8.7ms  | 🟢 5.05×    | 10.1ms    | 🟢 4.37×   |
| function_calls        | 37.3ms | 15.1ms | 🟢 2.47×    | 3.9ms     | 🟢 9.51×   |
| math_intensive        | 33.0ms | 8.5ms  | 🟢 3.88×    | 4.1ms     | 🟢 8.14×   |
| memory_allocation     | 27.6ms | 4.9ms  | 🟢 5.63×    | 3.4ms     | 🟢 8.05×   |
| nested_loops          | 44.5ms | 13.5ms | 🟢 3.30×    | 3.7ms     | 🟢 12.18×  |
| option_operations     | 43.0ms | 8.3ms  | 🟢 5.15×    | 3.9ms     | 🟢 11.04×  |
| ref_operations        | 34.0ms | 18.9ms | 🟢 1.80×    | 5.4ms     | 🟢 6.28×   |
| result_operations     | 58.3ms | 29.0ms | 🟢 2.01×    | 4.1ms     | 🟢 14.31×  |
| string_operations     | 30.1ms | 7.8ms  | 🟢 3.86×    | 13.3ms    | 🟢 2.26×   |
| tuple_operations      | 28.8ms | 16.9ms | 🟢 1.70×    | 7.7ms     | 🟢 3.75×   |

## Lua Baseline

| Benchmark             | Lua    | VM     | VM vs Lua        | C Backend | C vs Lua         |
| --------------------- | ------ | ------ | ---------------- | --------- | ---------------- |
| arithmetic_operations | 16.0ms | 23.3ms | 🟡 1.46× slower | 4.3ms     | 🟢 3.67×        |
| array_operations      | 7.6ms  | 12.1ms | 🔴 1.59× slower | 3.8ms     | 🟢 2.02×        |
| for_loop_print        | 64.1ms | 8.7ms  | 🟢 7.35×        | 10.1ms    | 🟢 6.37×        |
| function_calls        | 8.2ms  | 15.1ms | 🔴 1.84× slower | 3.9ms     | 🟢 2.10×        |
| math_intensive        | 4.6ms  | 8.5ms  | 🔴 1.83× slower | 4.1ms     | 🟢 1.14×        |
| memory_allocation     | 5.4ms  | 4.9ms  | 🟢 1.10×        | 3.4ms     | 🟢 1.58×        |
| nested_loops          | 10.9ms | 13.5ms | 🟡 1.23× slower | 3.7ms     | 🟢 2.99×        |
| option_operations     | 6.0ms  | 8.3ms  | 🟡 1.39× slower | 3.9ms     | 🟢 1.54×        |
| ref_operations        | 9.0ms  | 18.9ms | 🔴 2.09× slower | 5.4ms     | 🟢 1.67×        |
| result_operations     | 17.7ms | 29.0ms | 🔴 1.64× slower | 4.1ms     | 🟢 4.34×        |
| string_operations     | 5.4ms  | 7.8ms  | 🟡 1.44× slower | 13.3ms    | 🔴 2.46× slower |
| tuple_operations      | 35.7ms | 16.9ms | 🟢 2.11×        | 7.7ms     | 🟢 4.65×        |

**Legend:**
- 🟢 Faster than the section baseline
- 🟡 Slightly slower than the section baseline (< 1.5×)
- 🔴 Much slower than the section baseline (≥ 1.5×)
