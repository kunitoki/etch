# Modules & FFI

Etch provides a simple module system for code organization and a Foreign Function Interface (FFI) for calling C libraries.

## Table of Contents

1. [Module Basics](#module-basics)
2. [Importing Modules](#importing-modules)
3. [Exporting Functions](#exporting-functions)
4. [C FFI](#c-ffi-foreign-function-interface)
5. [Best Practices](#best-practices)

## Module Basics

### File Organization

Modules in Etch are based on the file system:

```
project/
├── main.etch              # Main program
├── lib/
│   ├── math.etch          # Math utilities
│   ├── string.etch        # String utilities
│   └── helpers/
│       └── validation.etch # Nested module
```

### Module Names

- Module names are derived from file paths
- Use forward slashes `/` in import paths
- `.etch` extension is implicit

```etch
import lib/math              // Imports lib/math.etch
import lib/helpers/validation // Imports lib/helpers/validation.etch
```

## Importing Modules

### Basic Import

```etch
// Import entire module
import lib/math

fn main() {
    // Use imported functions
    let sum = add(10, 20);
    let product = mul(5, 6);
    print(sum);
    print(product);
}
```

In `lib/math.etch`:
```etch
fn add(a: int, b: int) -> int {
    return a + b;
}

fn mul(a: int, b: int) -> int {
    return a * b;
}

// All functions are automatically exported
```

### Multiple Imports

```etch
// Import multiple modules
import lib/math
import lib/string
import lib/helpers/validation

fn main() {
    let result = add(10, 20);           // from math
    let text = concat("Hello", " World"); // from string
    let valid = isEmail("test@example.com"); // from validation
}
```

### Import Syntax Variations

```etch
// Single import
import lib/math

// Multiple imports on one line (comma-separated)
import lib/math, lib/string, lib/validation

// One per line (recommended for readability)
import lib/math
import lib/string
import lib/validation
```

## Exporting Functions

In Etch, **all top-level functions in a module are automatically exported**:

```etch
// In lib/math.etch

// ✅ Exported (top-level function)
fn add(a: int, b: int) -> int {
    return a + b;
}

// ✅ Exported (top-level function)
fn subtract(a: int, b: int) -> int {
    return helper(a, b);  // Can call other functions in same module
}

// ✅ Exported (helper is also visible to importers)
fn helper(a: int, b: int) -> int {
    return a - b;
}
```

**There is no explicit export keyword** - all module-level functions are part of the module's public API.

### Module Scope

```etch
// Functions can only be defined at module level
// ❌ Cannot define functions inside functions

fn outer() {
    fn inner() {  // ❌ ERROR: nested functions not allowed
        return 42;
    }
}
```

## C FFI (Foreign Function Interface)

Etch can call C libraries directly using FFI imports.

### Basic FFI

```etch
// Import C math library functions
import ffi cmath {
    fn sin(x: float) -> float;
    fn cos(x: float) -> float;
    fn sqrt(x: float) -> float;
    fn pow(base: float, exp: float) -> float;
}

fn main() {
    let angle = 0.0;
    let sine = sin(angle);           // Calls C's sin()
    let cosine = cos(3.14159);       // Calls C's cos()
    let root = sqrt(16.0);           // Calls C's sqrt()
    let power = pow(2.0, 3.0);       // Calls C's pow()

    print(sine);   // 0.0
    print(cosine); // -1.0
    print(root);   // 4.0
    print(power);  // 8.0
}
```

### FFI Syntax

```etch
import ffi <library_name> {
    fn <function_name>(<params>) -> <return_type>;
    fn <function_name>(<params>) -> <return_type>;
    // ... more functions
}
```

### FFI Type Mapping

Etch types map to C types as follows:

| Etch Type | C Type |
|-----------|--------|
| `int` | `int64_t` |
| `float` | `double` |
| `bool` | `bool` (_Bool) |
| `char` | `char` |
| `string` | `const char*` |
| `void` | `void` |

### Multiple FFI Imports

```etch
// Math functions
import ffi cmath {
    fn sin(x: float) -> float;
    fn cos(x: float) -> float;
}

// Standard library functions
import ffi cstdlib {
    fn abs(x: int) -> int;
    fn rand() -> int;
}

fn main() {
    let angle = sin(0.0);
    let random = rand();
}
```

### FFI Requirements

1. **Explicit type signatures**: All FFI functions must have explicit parameter and return types
2. **No type inference**: Cannot infer types from C headers
3. **Library must be available**: The C library must be linked at compile time
4. **Name matching**: Function names must match exactly (no mangling)

```etch
// ✅ Correct: explicit types
import ffi cmath {
    fn sqrt(x: float) -> float;
}

// ❌ Wrong: cannot use type inference
import ffi cmath {
    sqrt  // ERROR: needs full signature
}
```

### FFI Safety

FFI calls bypass Etch's safety guarantees:

```etch
import ffi cstring {
    fn strlen(s: string) -> int;
}

// ⚠️ FFI calls are unsafe!
// - No null pointer checking
// - No bounds checking
// - No overflow checking

// Wrap FFI in safe Etch functions
fn safeStrLen(s: string) -> int {
    // Add safety checks
    if s == "" {
        return 0;
    }
    return strlen(s);
}
```

## Best Practices

### 1. Organize Code into Modules

```
project/
├── main.etch
├── models/
│   ├── user.etch
│   └── product.etch
├── services/
│   ├── database.etch
│   └── api.etch
└── utils/
    ├── string.etch
    └── validation.etch
```

### 2. Group Related Functionality

```etch
// lib/string_utils.etch - string-related utilities
fn trim(s: string) -> string { /* ... */ }
fn toLowerCase(s: string) -> string { /* ... */ }
fn split(s: string, delim: string) -> array[string] { /* ... */ }

// lib/math_utils.etch - math-related utilities
fn clamp(x: int, min: int, max: int) -> int { /* ... */ }
fn abs(x: int) -> int { /* ... */ }
```

### 3. Minimize Module Dependencies

```etch
// ✅ Good: minimal dependencies
import lib/math
import lib/validation

// ❌ Bad: importing everything
import lib/math
import lib/string
import lib/array
import lib/helpers/a
import lib/helpers/b
import lib/helpers/c
// ... (if you need this many, refactor!)
```

### 4. Wrap FFI for Safety

```etch
// internal_ffi.etch - FFI wrappers
import ffi cmath {
    fn sqrt(x: float) -> float;
}

// Safe wrapper
fn safeSqrt(x: float) -> result[float] {
    if x < 0.0 {
        return error("Cannot take square root of negative number");
    }
    return ok(sqrt(x));
}
```

### 5. Name Modules Clearly

```etch
// ✅ Clear module names
import lib/user_validation
import lib/email_service
import lib/database_connection

// ❌ Unclear names
import lib/utils      // Too generic
import lib/stuff      // Meaningless
import lib/helpers    // What kind of helpers?
```

### 6. Document Module Purpose

```etch
// lib/validation.etch
// Email and user input validation utilities
// Provides functions for validating common input formats

fn isEmail(s: string) -> bool {
    return s.contains("@") and s.contains(".");
}

fn isPhoneNumber(s: string) -> bool {
    // Validates US phone number format
    return #s == 10 and isAllDigits(s);
}
```

## Module Patterns

### Facade Pattern

Create a single module that re-exports from multiple modules:

```etch
// lib/api.etch - Public API facade
import lib/internal/user
import lib/internal/product
import lib/internal/order

// All functions from imported modules are available
// Consumers only import lib/api
```

### Utility Module Pattern

```etch
// lib/string_utils.etch
fn trim(s: string) -> string { /* ... */ }
fn split(s: string, delim: string) -> array[string] { /* ... */ }
fn join(parts: array[string], delim: string) -> string { /* ... */ }

// Usage
import lib/string_utils

let parts = split("a,b,c", ",");
let joined = join(parts, ";");
```

### Service Module Pattern

```etch
// lib/database.etch
fn connect(url: string) -> result[Connection] { /* ... */ }
fn query(conn: Connection, sql: string) -> result[Results] { /* ... */ }
fn close(conn: Connection) -> void { /* ... */ }

// Usage
import lib/database

match connect("localhost:5432") {
    ok(conn) => {
        match query(conn, "SELECT * FROM users") {
            ok(results) => processResults(results),
            error(msg) => print("Query failed: " + msg),
        }
        close(conn);
    }
    error(msg) => print("Connection failed: " + msg),
}
```

## Limitations

### No Circular Imports

```etch
// a.etch
import b  // ❌ ERROR if b imports a

// b.etch
import a  // ❌ ERROR if a imports b
```

**Solution**: Refactor shared code into a third module:

```etch
// shared.etch
fn commonFunction() { /* ... */ }

// a.etch
import shared

// b.etch
import shared
```

### No Selective Imports

Etch imports all functions from a module:

```etch
// ❌ Cannot import only specific functions
import lib/math { add, mul }  // Not supported

// ✅ Import entire module
import lib/math
// All functions available: add, mul, sub, div, etc.
```

### No Re-exports

```etch
// lib/internal.etch
fn helper() { /* ... */ }

// lib/public.etch
import lib/internal

// Cannot re-export internal.helper()
// Consumers must import lib/internal directly if they need it
```

---

**Next**: Learn about [Global Variables](globals.md) and [Compile-Time Safety](safety.md).
