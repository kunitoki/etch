# Compile-Time Evaluation

Most of what your program does happens at runtime. But some computations only need to happen once—when you build. Etch's `comptime` feature lets you execute code during compilation, turning runtime work into compile-time constants.

## Table of Contents

1. [Why Compile-Time Execution?](#why-compile-time-execution)
2. [Comptime Expressions](#comptime-expressions)
3. [Comptime Blocks](#comptime-blocks)
4. [Embedding Files](#embedding-files)
5. [Code Generation](#code-generation)
6. [Practical Applications](#practical-applications)
7. [Best Practices](#best-practices)

## Why Compile-Time Execution?

Imagine you need to compute factorial(10) in your program. You could calculate it every time the program runs, or you could calculate it once during compilation and embed the result (3,628,800) as a constant. That's what `comptime` does.

The benefits:

- **Faster programs** - Expensive computations happen once, at build time
- **Smaller binaries** - No need to ship data files; embed them directly
- **Build-time configuration** - Generate different code based on build settings
- **Metaprogramming** - Code that writes code

Everything in a `comptime` block runs during compilation. The results become constants in your program, with zero runtime overhead.

## Comptime Expressions

The simplest use of `comptime` is wrapping an expression to evaluate it during compilation:

```etch
fn factorial(n: int) -> int {
    if n <= 1 { return 1; }
    return n * factorial(n - 1);
}

let value: int = comptime(factorial(10));
print(value);  // Prints 3628800, computed at compile time
```

The compiler executes `factorial(10)` during the build, replaces `comptime(factorial(10))` with the constant result, and emits code that just prints the number. No recursion at runtime.

### What Can Run at Compile Time?

Any pure function—functions that compute a result from their arguments without side effects—can run at compile time:

```etch
let sq: int = comptime(square(8));              // 64
let sum: int = comptime(add(10, 20));           // 30
let combo: int = comptime(square(3) + add(5, 2));  // 16
```

Note: Simple arithmetic like `5 + 3 * 2` is automatically constant-folded by the compiler, so you don't need `comptime` for literal expressions. Use it when calling functions.

## Comptime Blocks

For multiple statements that should run at compile time, use a `comptime { }` block:

```etch
fn main() {
    comptime {
        print("Building...");
        print("Version 1.0");
    }

    print("Running!");  // Runtime
}
```

**During compilation**, you'll see:
```
Building...
Version 1.0
```

**When you run the program**, you'll see:
```
Running!
```

### Compile-Time Variables

Variables in `comptime` blocks exist only during compilation. They're not part of the final program:

```etch
comptime {
    let build_config = 42;
    print(build_config);  // Prints during build
}
// build_config doesn't exist at runtime
```

### Control Flow at Compile Time

You can use conditionals and loops in `comptime` blocks to make build-time decisions:

```etch
comptime {
    let mode = 1;
    if mode == 1 {
        print("Debug build");
    } else {
        print("Release build");
    }
}
```

This lets you generate different code based on compile-time conditions.

## Embedding Files

One of `comptime`'s most practical features is embedding file contents directly into your binary. No more shipping configuration files, templates, or assets separately—they become part of the executable.

### Basic File Embedding

Use `readFile()` in a `comptime` expression:

```etch
let config: string = comptime(readFile("config.txt"));
print(config);  // Content is in the binary
```

The file is read during compilation and its contents become a string constant in your program. At runtime, there's no file I/O—the data is already there.

### Why Embed Files?

**Single executable deployment** - Ship one file instead of an executable plus data files

**Guaranteed availability** - The file content can't go missing or be corrupted

**Faster startup** - No file system access needed; data is already in memory

**Simpler distribution** - Users don't need to maintain file structures

### Common Uses

**Configuration files:**
```etch
let defaults: string = comptime(readFile("defaults.json"));
```

**HTML templates:**
```etch
let page: string = comptime(readFile("template.html"));
```

**Shader code:**
```etch
let shader: string = comptime(readFile("shader.glsl"));
```

## Code Generation

The most powerful `comptime` feature is `inject()`, which lets you dynamically create variables that exist at runtime, based on compile-time logic.

### Variable Injection

Create runtime variables from compile-time code:

```etch
comptime {
    inject("version", "string", "1.0.0");
    inject("build_num", "int", 42);
}

// Now these variables exist at runtime
print(version);     // "1.0.0"
print(build_num);   // 42
```

The `inject(name, type, value)` function takes:
- **name** - The variable name (as a string)
- **type** - The type ("int", "string", "float", etc.)
- **value** - The compile-time computed value

### Build Configuration

Combine file reading with injection to generate configuration from external files:

```etch
comptime {
    let mode = readFile(".build_mode");

    if mode == "debug" {
        inject("logging_enabled", "int", 1);
        inject("optimization", "int", 0);
    } else {
        inject("logging_enabled", "int", 0);
        inject("optimization", "int", 3);
    }
}

// Use the injected variables
if logging_enabled == 1 {
    initLogging();
}
```

This pattern lets you generate different code for debug vs release builds without preprocessor macros or build system complexity.

## Practical Applications

### Pre-Computed Lookup Tables

When you need constant data, compute it once at compile time:

```etch
let factorial_10: int = comptime(factorial(10));
let factorials = [
    comptime(factorial(0)),
    comptime(factorial(5)),
    comptime(factorial(10))
];
```

Perfect for mathematical constants, hash tables, or any data that doesn't change.

### Version and Build Information

Embed version info from external sources:

```etch
comptime {
    inject("version", "string", readFile("VERSION"));
    inject("commit", "string", readFile(".git/HEAD"));
}

print("v" + version + " (" + commit + ")");
```

### Feature Flags

Enable or disable features at build time:

```etch
comptime {
    let enable_experimental = readFile(".features") == "exp";
    inject("experimental", "int", if enable_experimental { 1 } else { 0 });
}

if experimental == 1 {
    runExperimentalFeature();
}
```

The disabled code path might not even be compiled into the binary, depending on optimization.

### Asset Bundling

Embed all your assets into a single executable:

```etch
let logo: string = comptime(readFile("assets/logo.txt"));
let help: string = comptime(readFile("assets/help.txt"));
let license: string = comptime(readFile("LICENSE"));
```

Ship one file instead of a directory tree.

## Best Practices

### Use Comptime for Constants

If a value never changes, compute it once at build time:

```etch
// ✅ Computed once during compilation
let pi_squared: float = comptime(square(3.14159));

// ❌ Computed every time the program runs
let pi_squared: float = square(3.14159);
```

### Embed Only What You Need

Embedding large files increases binary size. Only embed assets you actually use:

```etch
// ✅ Embed essential config
let config: string = comptime(readFile("config.ini"));

// ❌ Don't embed huge data files unnecessarily
let huge_db: string = comptime(readFile("10GB_database.sql"));  // Bad idea!
```

### Document Injected Variables

Since `inject()` creates variables without explicit declarations, document them:

```etch
comptime {
    // Injects: version (string), build_num (int)
    inject("version", "string", readFile("VERSION"));
    inject("build_num", "int", 42);
}
```

### Remember: Comptime Runs During Build

Side effects in `comptime` blocks happen during compilation, not at runtime:

```etch
comptime {
    print("Building...");  // Prints when you compile, not when you run
}
```

## Limitations

What comptime **can't** do:

- **No network access** - Can't fetch data from URLs
- **No runtime values** - Can't use user input or command-line arguments
- **Files must exist at build time** - readFile() needs the file during compilation
- **Limited to pure functions** - Functions with external dependencies may not work

## Summary

Compile-time evaluation shifts work from runtime to build time:

- **Faster programs** - Expensive computations become constants
- **Single-file deployment** - Embed assets directly into the executable
- **Build-time configuration** - Generate different code for different builds
- **Zero overhead** - Compile-time work has no runtime cost

Use `comptime` whenever you can compute something once instead of repeatedly.

---

**Next**: Explore [Operator Overloading](operator-overloading.md) to customize operators for your types.
