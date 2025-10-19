# Compile-Time Evaluation

Etch supports powerful compile-time code execution, allowing you to run code during compilation rather than at runtime. This enables metaprogramming, conditional compilation, and embedding external resources directly into your binary.

## Table of Contents

1. [Overview](#overview)
2. [Comptime Expressions](#comptime-expressions)
3. [Comptime Blocks](#comptime-blocks)
4. [File Embedding](#file-embedding)
5. [Code Injection](#code-injection)
6. [Use Cases](#use-cases)
7. [Best Practices](#best-practices)

## Overview

Compile-time evaluation in Etch allows you to:
- Execute functions at compile time
- Embed file contents directly into your binary
- Generate code dynamically based on compile-time conditions
- Perform computations once at build time instead of every run
- Inject variables and code into the runtime scope

**Key Principle**: Code in `comptime` blocks runs during compilation and produces values or side effects that affect the compiled program.

## Comptime Expressions

### Basic Comptime

Use `comptime(expression)` to evaluate an expression at compile time:

```etch
fn add(a: int, b: int) -> int {
    return a + b;
}

fn main() {
    // Evaluated at compile time
    let sum: int = comptime(add(10, 20));
    print(sum);  // Prints: 30
}
```

The compiler:
1. Evaluates `add(10, 20)` during compilation
2. Replaces the `comptime()` call with the constant `30`
3. No function call happens at runtime!

### Function Evaluation

Any pure function can be evaluated at compile time:

```etch
fn square(x: int) -> int {
    return x * x;
}

fn factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}

fn main() {
    let sq: int = comptime(square(8));          // 64
    let fact: int = comptime(factorial(5));     // 120

    // Nested expressions work too
    let combined: int = comptime(square(3) + factorial(4));  // 9 + 24 = 33

    print(sq);
    print(fact);
    print(combined);
}
```

### Arithmetic Optimization

Simple arithmetic expressions are automatically constant-folded without needing `comptime`:

```etch
fn main() {
    // These are automatically evaluated at compile time
    let basic: int = 5 + 3 * 2;           // 11
    let complex: int = (4 + 6) * (3 - 1) / 2;  // 10

    print(basic);
    print(complex);
}
```

However, `comptime()` is required for function calls:

```etch
// ❌ Without comptime - function called at runtime
let result = add(10, 20);

// ✅ With comptime - evaluated at compile time
let result: int = comptime(add(10, 20));
```

## Comptime Blocks

### Basic Blocks

Use `comptime { }` blocks to execute multiple statements at compile time:

```etch
fn main() {
    comptime {
        print(10);
        print(20);
        print(30);
    }

    // This prints at runtime
    print(42);
}
```

**Output** (during compilation):
```
10
20
30
```

**Output** (at runtime):
```
42
```

### Variables in Comptime Blocks

Variables declared in comptime blocks exist only at compile time:

```etch
fn main() {
    comptime {
        let ct_var: int = 100;
        print(ct_var);         // Prints during compilation

        let ct_calc: int = 7 * 8;
        print(ct_calc);        // Prints 56 during compilation
    }

    // ct_var is not accessible here - it only existed at compile time
    print(42);  // Prints at runtime
}
```

### Control Flow in Comptime

Conditionals and loops work in comptime blocks:

```etch
fn main() {
    comptime {
        // Compile-time conditional
        let debug_mode: int = 1;
        if debug_mode == 1 {
            print(777);  // Executed at compile time
        } else {
            print(888);
        }
    }
}
```

### Comptime Loops

Loops can execute at compile time:

```etch
fn main() {
    comptime {
        let i: int = 1;
        while i <= 3 {
            print(i);

            // Nested loop
            let j: int = 1;
            while j <= 2 {
                let product: int = i * j;
                print(product);
                j = j + 1;
            }

            i = i + 1;
        }
    }

    print(42);  // Runtime
}
```

**Compile-time output**:
```
1
1
2
2
2
4
3
3
6
```

**Runtime output**:
```
42
```

## File Embedding

### Reading Files at Compile Time

Use `readFile()` in comptime blocks to embed file contents into your binary:

```etch
fn main() {
    // Read file at compile time and store as string constant
    let config: string = comptime(readFile("config.txt"));
    print(config);  // File contents embedded in binary
}
```

**Benefits:**
- No runtime file I/O - file is embedded in the binary
- No need to distribute separate config files
- Guaranteed file availability at runtime

### Comptime Block File Reading

```etch
fn main() {
    comptime {
        let file_content: string = readFile("test_file.txt");
        print(file_content);  // Prints during compilation
    }

    // File content available at runtime too
    let embedded: string = comptime(readFile("test_file.txt"));
    print(embedded);  // Prints at runtime (from embedded data)
}
```

### Use Cases for File Embedding

#### Configuration Files

```etch
fn main() {
    let config: string = comptime(readFile("app_config.json"));
    // Parse config at runtime (already in memory)
    processConfig(config);
}
```

#### HTML Templates

```etch
let homepage_template: string = comptime(readFile("templates/index.html"));
let error_template: string = comptime(readFile("templates/error.html"));

fn serveHomepage() {
    return homepage_template;  // No disk I/O!
}
```

#### Shader Code

```etch
let vertex_shader: string = comptime(readFile("shaders/vertex.glsl"));
let fragment_shader: string = comptime(readFile("shaders/fragment.glsl"));
```

## Code Injection

### The inject() Function

`inject()` allows you to dynamically create variables in the runtime scope from comptime blocks:

```etch
fn main() {
    comptime {
        // Inject variables into runtime scope
        inject("my_var", "string", "Hello from comptime!");
        inject("my_num", "int", 42);
    }

    // These variables are now available at runtime
    print(my_var);  // "Hello from comptime!"
    print(my_num);  // 42
}
```

**Syntax**: `inject(name, type, value)`
- `name`: Variable name as string
- `type`: Type as string ("int", "string", "float", etc.)
- `value`: The value to inject

### Dynamic Code Generation

Combine file reading and injection for powerful metaprogramming:

```etch
fn main() {
    comptime {
        let config_content: string = readFile("config.txt");

        // Inject configuration as compile-time constant
        inject("embedded_config", "string", config_content);

        // Generate version info
        inject("build_number", "int", 42);
        inject("debug_mode", "int", 1);
    }

    // Use injected variables
    print(embedded_config);
    print(build_number);

    if debug_mode == 1 {
        print("Debug mode enabled");
    }
}
```

### Conditional Injection

```etch
fn main() {
    comptime {
        let enable_feature: int = 1;

        if enable_feature == 1 {
            inject("feature_enabled", "int", 1);
        } else {
            inject("feature_enabled", "int", 0);
        }
    }

    if feature_enabled == 1 {
        // Feature code only compiled if enabled
        enableAdvancedFeatures();
    }
}
```

## Use Cases

### 1. Embedding Resources

Embed text files, configuration, templates directly into binary:

```etch
let license_text: string = comptime(readFile("LICENSE.txt"));
let help_text: string = comptime(readFile("help.txt"));
let default_config: string = comptime(readFile("default_config.toml"));

fn showLicense() {
    print(license_text);  // No file I/O!
}
```

### 2. Build-Time Configuration

```etch
fn main() {
    comptime {
        let build_type: string = readFile(".build_type");

        if build_type == "debug" {
            inject("optimization_level", "int", 0);
            inject("enable_logging", "int", 1);
        } else {
            inject("optimization_level", "int", 3);
            inject("enable_logging", "int", 0);
        }
    }

    if enable_logging == 1 {
        initializeLogging();
    }
}
```

### 3. Pre-computed Lookup Tables

```etch
fn computeFactorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * computeFactorial(n - 1);
}

fn main() {
    // Compute factorials at compile time
    let fact_0: int = comptime(computeFactorial(0));
    let fact_1: int = comptime(computeFactorial(1));
    let fact_5: int = comptime(computeFactorial(5));
    let fact_10: int = comptime(computeFactorial(10));

    // Create lookup table (computed once at compile time)
    let factorials = [fact_0, fact_1, fact_5, fact_10];

    // Fast runtime lookup
    print(factorials[2]);  // 120
}
```

### 4. Version Information

```etch
fn main() {
    comptime {
        let version_file: string = readFile("VERSION");
        inject("app_version", "string", version_file);

        let commit_hash: string = readFile(".git/HEAD");
        inject("git_commit", "string", commit_hash);
    }

    print("Version: " + app_version);
    print("Commit: " + git_commit);
}
```

### 5. Feature Flags

```etch
fn main() {
    comptime {
        let features: string = readFile("features.txt");

        // Parse features and inject flags
        if features == "experimental" {
            inject("experimental_features", "int", 1);
        } else {
            inject("experimental_features", "int", 0);
        }
    }

    if experimental_features == 1 {
        enableExperimentalFeatures();
    }
}
```

## Best Practices

### 1. Use Comptime for Expensive Computations

```etch
// ✅ Good: Expensive computation done once at compile time
let precomputed: int = comptime(expensiveCalculation());

// ❌ Bad: Computed every time the program runs
let computed = expensiveCalculation();
```

### 2. Embed Static Resources

```etch
// ✅ Good: File embedded, no runtime I/O
let template: string = comptime(readFile("template.html"));

// ❌ Bad: File read every time program runs
let template = readFile("template.html");
```

### 3. Keep Comptime Blocks Simple

```etch
// ✅ Good: Clear, focused comptime block
comptime {
    let config: string = readFile("config.txt");
    inject("app_config", "string", config);
}

// ❌ Bad: Complex logic in comptime
comptime {
    // Too much computation and logic
    // Hard to understand what's happening at compile time
}
```

### 4. Document Injected Variables

```etch
fn main() {
    comptime {
        // Inject build configuration
        // Variables: build_date (string), build_number (int)
        inject("build_date", "string", "2024-01-15");
        inject("build_number", "int", 42);
    }

    // Clear that these come from comptime
    print("Build: " + build_date);
    print("Number: #" + toString(build_number));
}
```

### 5. Use for Platform-Specific Code

```etch
comptime {
    let platform: string = readFile(".platform");

    if platform == "linux" {
        inject("path_separator", "string", "/");
    } else if platform == "windows" {
        inject("path_separator", "string", "\\");
    }
}

fn buildPath(dir: string, file: string) -> string {
    return dir + path_separator + file;
}
```

### 6. Avoid Side Effects in Comptime

```etch
// ✅ Good: Comptime used for data
comptime {
    let data: string = readFile("data.txt");
    inject("embedded_data", "string", data);
}

// ⚠️ Careful: Side effects during compilation
comptime {
    print("Compiling...");  // This prints during build, not at runtime
}
```

## Limitations

1. **No network I/O**: Can't fetch data from network at compile time
2. **Limited to pure functions**: Functions with side effects may behave unexpectedly
3. **File paths must exist at compile time**: Files must be present when compiling
4. **No runtime input**: Can't use user input in comptime blocks

## Summary

Compile-time evaluation in Etch provides:

✅ **Zero runtime overhead** - Code runs during compilation
✅ **Resource embedding** - Embed files directly in binary
✅ **Code generation** - Dynamically inject variables and code
✅ **Build-time configuration** - Conditional compilation based on files
✅ **Pre-computation** - Calculate expensive values once at compile time

**Comptime makes your programs faster by moving work from runtime to compile time.**

---

**Next**: Learn about [Operator Overloading](operator-overloading.md) for custom operators.
