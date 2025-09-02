# Global Variables

Etch supports global variables with compile-time initialization and strict safety guarantees.

## Table of Contents

1. [Global Declaration](#global-declaration)
2. [Initialization Rules](#initialization-rules)
3. [Compile-Time Evaluation](#compile-time-evaluation)
4. [Safety Guarantees](#safety-guarantees)
5. [Best Practices](#best-practices)

## Global Declaration

### Basic Globals

```etch
// Global constants
let PI = 3.14159;
let MAX_USERS = 1000;
let APP_NAME = "MyApp";

// Global variables (mutable)
var globalCounter = 0;
var isInitialized = false;

fn main() {
    print(PI);              // Access globals
    globalCounter = globalCounter + 1;  // Modify mutable globals
    print(globalCounter);
}
```

### Syntax

```etch
// Immutable global (preferred)
let CONSTANT_NAME = value;

// Mutable global (use sparingly)
var globalName = value;
```

## Initialization Rules

### Must Be Initialized

All globals must be initialized at declaration:

```etch
// ✅ Valid: initialized
let MAX_SIZE = 100;
var counter = 0;

// ❌ Invalid: uninitialized
let MAX_SIZE;      // ERROR
var counter: int;  // ERROR
```

### Compile-Time Constants

Global initializers must be compile-time constants:

```etch
// ✅ Valid: compile-time constants
let SIZE = 100;
let MESSAGE = "Hello";
let VALUES = [1, 2, 3, 4, 5];

// ❌ Invalid: runtime computation
var input = readLine();        // ERROR: not compile-time
let random = rand();           // ERROR: not compile-time
let computed = calculate(10);  // ERROR: function call not allowed
```

### Simple Expressions Allowed

```etch
// ✅ Valid: simple compile-time expressions
let SIZE = 100;
let DOUBLE_SIZE = SIZE * 2;           // 200
let TOTAL = SIZE + DOUBLE_SIZE;       // 300
let BUFFER_SIZE = 1024 * 1024;        // 1 MB

// String concatenation
let PREFIX = "app";
let VERSION = "1.0";
let APP_ID = PREFIX + "_" + VERSION; // "app_1.0"

// Array operations
let NUMBERS = [1, 2, 3];
let MORE = NUMBERS + [4, 5];  // [1, 2, 3, 4, 5]
```

## Compile-Time Evaluation

### What Gets Evaluated at Compile Time

The Etch compiler evaluates global initializers during compilation:

```etch
// All of these are computed at compile time
let A = 10;
let B = 20;
let SUM = A + B;                    // 30 (computed at compile time)
let PRODUCT = A * B;                // 200 (computed at compile time)
let MESSAGE = "Count: " + string(SUM);  // "Count: 30"
```

**Result**: No runtime overhead for accessing these globals.

### Compile-Time Functions

Some builtin functions can be evaluated at compile time in global context:

```etch
// String operations
let UPPER = "hello";
let TEXT = UPPER;  // String operations TBD

// Array operations
let NUMS = [1, 2, 3];
let SIZE = #NUMS;  // 3 (compile-time)
```

### Limitations

Cannot use runtime operations in global initializers:

```etch
// ❌ Cannot use I/O
let CONFIG = readFile("config.txt");  // ERROR

// ❌ Cannot call non-const functions
var START_TIME = getCurrentTime();    // ERROR

// ❌ Cannot use rand()
var SEED = rand();                    // ERROR
```

## Safety Guarantees

### Initialization Order

Globals are initialized in **dependency order**:

```etch
let A = 10;
let B = A * 2;    // OK: A is available
let C = B + A;    // OK: Both A and B are available
```

### No Circular Dependencies

```etch
let A = B + 1;  // ❌ ERROR: B not yet defined
let B = A + 1;  // ❌ ERROR: circular dependency
```

### Thread Safety

Global variables in Etch are **not thread-safe** by default. If your program uses concurrency (future feature), protect global access with locks.

### Immutability

Use `let` for globals whenever possible:

```etch
// ✅ Preferred: immutable
let CONFIG_PATH = "/etc/app/config";
let MAX_RETRIES = 3;

// ⚠️ Use sparingly: mutable
var requestCount = 0;
var isRunning = false;
```

## Best Practices

### 1. Prefer Constants over Variables

```etch
// ✅ Good: immutable constants
let MAX_CONNECTIONS = 100;
let TIMEOUT_MS = 5000;
let API_VERSION = "v2";

// ❌ Bad: mutable when not needed
var MAX_CONNECTIONS = 100;  // Why mutable?
var TIMEOUT_MS = 5000;      // Should be const
```

### 2. Use UPPER_CASE for Constants

```etch
// ✅ Clear: these are constants
let MAX_SIZE = 1024;
let API_KEY = "secret";
let DEFAULT_PORT = 8080;

// ⚠️ Less clear: looks like variables
let maxSize = 1024;
let apiKey = "secret";
```

### 3. Group Related Constants

```etch
// Configuration
let CONFIG_PATH = "/etc/app/config";
let CONFIG_FORMAT = "json";
let CONFIG_VERSION = 2;

// Limits
let MAX_USERS = 1000;
let MAX_CONNECTIONS = 100;
let MAX_RETRIES = 3;

// Timeouts
let CONNECT_TIMEOUT = 5000;
let READ_TIMEOUT = 10000;
let WRITE_TIMEOUT = 10000;
```

### 4. Minimize Mutable Globals

```etch
// ❌ Bad: too much mutable global state
var userCount = 0;
var connectionCount = 0;
var errorCount = 0;
var successCount = 0;

// ✅ Better: pass state through function parameters
fn processRequest(stats: Stats) -> Stats {
    return {
        userCount: stats.userCount + 1,
        // ...
    };
}
```

### 5. Document Globals

```etch
// Maximum number of concurrent connections allowed
let MAX_CONNECTIONS = 100;

// Path to application configuration file
let CONFIG_PATH = "/etc/app/config.json";

// Global request counter (mutable)
// WARNING: Not thread-safe
var requestCount = 0;
```

### 6. Avoid Complex Initialization

```etch
// ❌ Hard to understand
let COMPUTED = ((A * B) + (C / D)) * E - F + (G % H);

// ✅ Clear and simple
let PRODUCT = A * B;
let QUOTIENT = C / D;
let RESULT = (PRODUCT + QUOTIENT) * E;
```

## Common Patterns

### Configuration Constants

```etch
// Application configuration
let APP_NAME = "MyApp";
let APP_VERSION = "1.0.0";
let APP_ENV = "production";

// Server configuration
let SERVER_HOST = "0.0.0.0";
let SERVER_PORT = 8080;
let SERVER_WORKERS = 4;

// Database configuration
let DB_HOST = "localhost";
let DB_PORT = 5432;
let DB_NAME = "myapp_db";
```

### Magic Numbers Replacement

```etch
// ❌ Bad: magic numbers
fn processBuffer(data: array[int]) -> bool {
    if #data > 4096 {  // What is 4096?
        return false;
    }
    // ...
}

// ✅ Good: named constants
let MAX_BUFFER_SIZE = 4096;

fn processBuffer(data: array[int]) -> bool {
    if #data > MAX_BUFFER_SIZE {
        return false;
    }
    // ...
}
```

### Limits and Boundaries

```etch
// Input validation limits
let MIN_USERNAME_LENGTH = 3;
let MAX_USERNAME_LENGTH = 20;
let MIN_PASSWORD_LENGTH = 8;

// System limits
let MAX_UPLOAD_SIZE = 10485760;  // 10 MB
let MAX_REQUEST_SIZE = 1048576;  // 1 MB
let MAX_RESULTS_PER_PAGE = 100;
```

### State Tracking (Use Sparingly)

```etch
// Minimal mutable global state
var isInitialized = false;

fn initialize() {
    if isInitialized {
        return;
    }
    // ... initialization code
    isInitialized = true;
}

fn main() {
    initialize();
    // ...
}
```

## Advanced: Compile-Time Computation

### Array Construction

```etch
// Build arrays at compile time
let POWERS_OF_TWO = [1, 2, 4, 8, 16, 32, 64, 128];
let FIBONACCI = [1, 1, 2, 3, 5, 8, 13, 21, 34];

// Concatenate arrays
let SMALL = [1, 2, 3];
let LARGE = [4, 5, 6, 7, 8, 9];
let ALL = SMALL + LARGE;  // [1, 2, 3, 4, 5, 6, 7, 8, 9]
```

### String Building

```etch
// Build strings at compile time
let PREFIX = "app";
let VERSION = "v2";
let ENVIRONMENT = "prod";
let FULL_ID = PREFIX + "_" + VERSION + "_" + ENVIRONMENT;
// Result: "app_v2_prod"
```

## Migration from Other Languages

### From C/C++

```c
// C/C++
#define MAX_SIZE 1024
extern int globalCounter;
static const char* APP_NAME = "MyApp";

// Etch equivalent
let MAX_SIZE = 1024;
var globalCounter = 0;
let APP_NAME = "MyApp";
```

### From Python

```python
# Python
MAX_SIZE = 1024
APP_NAME = "MyApp"
counter = 0

# Etch equivalent
let MAX_SIZE = 1024;
let APP_NAME = "MyApp";
var counter = 0;
```

### From Rust

```rust
// Rust
const MAX_SIZE: i32 = 1024;
static mut COUNTER: i32 = 0;

// Etch equivalent
let MAX_SIZE = 1024;
var COUNTER = 0;  // Note: not thread-safe like Rust's static
```

## Limitations

1. **No lazy initialization**: All globals computed at compile time
2. **No complex computations**: Only simple expressions allowed
3. **No I/O**: Cannot read files or network at global scope
4. **No function calls**: Cannot call user-defined functions (most builtins also restricted)
5. **No thread safety**: Mutable globals not protected by locks

---

**Next**: Learn about [Compile-Time Safety](safety.md) to understand how Etch's prover ensures your code is safe.
