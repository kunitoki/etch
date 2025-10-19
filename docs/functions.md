# Functions & UFCS

Etch has a powerful and flexible function system with first-class UFCS (Uniform Function Call Syntax) support, making code more readable and composable.

## Table of Contents

1. [Function Basics](#function-basics)
2. [UFCS (Uniform Function Call Syntax)](#ufcs-uniform-function-call-syntax)
3. [Function Overloading](#function-overloading)
4. [Higher-Order Functions](#higher-order-functions)
5. [Recursion](#recursion)
6. [Best Practices](#best-practices)

## Function Basics

### Function Declaration

```etch
// Basic function
fn greet(name: string) -> void {
    print("Hello, " + name);
}

// Function with return value
fn add(a: int, b: int) -> int {
    return a + b;
}

// Multiple statements
fn calculate(x: int) -> int {
    let doubled = x * 2;
    let result = doubled + 10;
    return result;
}
```

### Function Parameters

```etch
// Parameters must have type annotations
fn multiply(a: int, b: int) -> int {
    return a * b;
}

// Multiple parameters of different types
fn formatMessage(prefix: string, value: int, suffix: string) -> string {
    return prefix + toString(value) + suffix;
}

// No parameters
fn getCurrentTime() -> int {
    return 12345;  // Placeholder
}
```

### Return Types

```etch
// Explicit return type
fn square(x: int) -> int {
    return x * x;
}

// Void (no return value)
fn logMessage(msg: string) -> void {
    print(msg);
}

// Return statement required for non-void functions
fn getValue() -> int {
    // return statement must be present
    return 42;
}
```

### Early Returns

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("Division by zero");  // Early return
    }
    return ok(a / b);
}

fn sign(x: int) -> int {
    if x < 0 {
        return -1;
    }
    if x > 0 {
        return 1;
    }
    return 0;
}
```

## UFCS (Uniform Function Call Syntax)

UFCS is one of Etch's most powerful features. It allows calling functions using method syntax, making code read naturally left-to-right.

### Basic UFCS

```etch
// Define a function
fn double(x: int) -> int {
    return x * 2;
}

// Traditional function call
let result1 = double(5);     // 10

// UFCS: call as if it were a method
let result2 = 5.double();    // 10

// Both are exactly equivalent!
```

### How UFCS Works

When you write `x.func(args)`, Etch rewrites it as `func(x, args)`:

```etch
fn add(a: int, b: int) -> int {
    return a + b;
}

// These are equivalent:
let r1 = add(5, 3);     // Traditional
let r2 = 5.add(3);      // UFCS

// UFCS transforms: 5.add(3) → add(5, 3)
```

### Chaining Operations

UFCS makes function chaining beautiful:

```etch
fn double(x: int) -> int {
    return x * 2;
}

fn add(x: int, y: int) -> int {
    return x + y;
}

fn square(x: int) -> int {
    return x * x;
}

// Traditional: deeply nested, hard to read
let result = square(add(double(5), 3));

// UFCS: reads left-to-right like a story
let result = 5.double().add(3).square();  // (5*2 + 3)² = 169

// Each step:
// 5.double()           → 10
// 10.add(3)           → 13
// 13.square()         → 169
```

### UFCS with Different Types

UFCS works with any type:

```etch
// String operations
fn append(s: string, suffix: string) -> string {
    return s + suffix;
}

"Hello".append(" World");  // "Hello World"

// Array operations
fn first[T](arr: array[T]) -> option[T] {
    if #arr > 0 {
        return some(arr[0]);
    }
    return none;
}

[1, 2, 3].first();  // some(1)
```

### Real-World UFCS Example

```etch
fn trim(s: string) -> string { /* ... */ }
fn toLowerCase(s: string) -> string { /* ... */ }
fn split(s: string, delimiter: string) -> array[string] { /* ... */ }

// Process user input with clear, readable pipeline
let words = input
    .trim()
    .toLowerCase()
    .split(" ");

// Without UFCS (hard to read):
let words = split(toLowerCase(trim(input)), " ");
```

### UFCS with Print

```etch
fn print_value(x: int) -> void {
    print(x);
}

// Traditional
print_value(42);

// UFCS - reads naturally
42.print_value();

// Chaining
(10 + 5).double().print_value();  // Prints: 30
```

### When UFCS Doesn't Apply

UFCS only works when the first parameter matches:

```etch
fn greet(name: string, age: int) -> void {
    print(name + " is " + toString(age));
}

// ✅ Works: first parameter is string
"Alice".greet(30);

// ❌ Doesn't work: first parameter is int
30.greet("Alice");  // Type error!

// ✅ Use traditional call instead
greet("Alice", 30);
```

## Function Overloading

Etch supports function overloading based on parameter types:

```etch
// Same function name, different parameter types
fn process(x: int) -> int {
    return x * 2;
}

fn process(s: string) -> string {
    return s + "!";
}

let i = process(42);      // Calls int version → 84
let s = process("hi");    // Calls string version → "hi!"
```

### Overloading with Generics

```etch
// Generic function
fn identity[T](value: T) -> T {
    return value;
}

// Works with any type
let x = identity(42);       // int
let s = identity("hello");  // string
let a = identity([1, 2]);   // array[int]
```

## Higher-Order Functions

Functions that take other functions as parameters:

```etch
// Function that takes a function as parameter
fn apply(f: fn(int) -> int, x: int) -> int {
    return f(x);
}

fn double(x: int) -> int {
    return x * 2;
}

fn square(x: int) -> int {
    return x * x;
}

// Pass functions as arguments
let r1 = apply(double, 5);  // 10
let r2 = apply(square, 5);  // 25
```

### Map Pattern (Common Higher-Order Pattern)

```etch
fn map_array(arr: array[int], f: fn(int) -> int) -> array[int] {
    var result: array[int] = [];
    for item in arr {
        result = result + [f(item)];
    }
    return result;
}

fn triple(x: int) -> int {
    return x * 3;
}

let numbers = [1, 2, 3, 4];
let tripled = map_array(numbers, triple);  // [3, 6, 9, 12]
```

## Recursion

Etch supports recursive functions:

### Basic Recursion

```etch
fn factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}

let result = factorial(5);  // 120
```

### Mutual Recursion

```etch
fn isEven(n: int) -> bool {
    if n == 0 {
        return true;
    }
    return isOdd(n - 1);
}

fn isOdd(n: int) -> bool {
    if n == 0 {
        return false;
    }
    return isEven(n - 1);
}

let even = isEven(4);  // true
let odd = isOdd(4);    // false
```

### Tail Recursion

```etch
// Tail-recursive factorial (last operation is recursive call)
fn factorialTail(n: int, acc: int) -> int {
    if n <= 1 {
        return acc;
    }
    return factorialTail(n - 1, n * acc);
}

fn factorial(n: int) -> int {
    return factorialTail(n, 1);
}
```

### Recursion with Safety Bounds

The prover requires you to bound recursion to prevent stack overflow:

```etch
fn fibonacci(n: int) -> int {
    if n <= 1 {
        return n;
    }

    // Prover needs to know recursion depth is bounded
    if n > 46 {  // fib(46) is max safe value for int64
        return 0;
    }

    let fib1 = fibonacci(n - 1);
    let fib2 = fibonacci(n - 2);

    // Use modulo to prevent overflow
    return (fib1 % 1000000) + (fib2 % 1000000);
}
```

## Best Practices

### 1. Use UFCS for Readability

```etch
// ❌ Hard to read: nested function calls
let result = process(filter(transform(getData())));

// ✅ Easy to read: left-to-right pipeline
let result = getData()
    .transform()
    .filter()
    .process();
```

### 2. Name Functions Descriptively

```etch
// ❌ Unclear
fn proc(x: int) -> int { return x * 2; }

// ✅ Clear intent
fn double(x: int) -> int { return x * 2; }
fn doubleValue(x: int) -> int { return x * 2; }
```

### 3. Keep Functions Small and Focused

```etch
// ✅ Single responsibility
fn isValid(email: string) -> bool {
    return email.contains("@") and email.contains(".");
}

fn sanitizeInput(input: string) -> string {
    return input.trim().toLowerCase();
}

fn validateAndSanitize(email: string) -> option[string] {
    let cleaned = sanitizeInput(email);
    if isValid(cleaned) {
        return some(cleaned);
    }
    return none;
}
```

### 4. Use Result Types for Error Handling

```etch
// ✅ Explicit error handling
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("Division by zero");
    }
    return ok(a / b);
}

// Caller must handle errors
match divide(10, 2) {
    ok(value) => print(value),
    error(msg) => print("Error: " + msg),
}
```

### 5. Leverage Type Inference

```etch
// Function parameters and return types must be annotated
fn add(a: int, b: int) -> int {
    return a + b;
}

// But local variables can use inference
fn calculate(x: int) -> int {
    let doubled = x * 2;        // Inferred as int
    let increased = doubled + 5; // Inferred as int
    return increased;
}
```

### 6. Design Functions for UFCS

```etch
// ✅ Design functions with UFCS in mind
// Put the primary "subject" as the first parameter
fn validate(email: string) -> result[string] { /* ... */ }
fn send(email: string, message: string) -> result[void] { /* ... */ }

// Enables natural chaining
input
    .validate()
    .send("Welcome!");

// ❌ Less natural: subject not first
fn send(message: string, email: string) -> result[void] { /* ... */ }
input.send("Welcome!");  // Reads awkwardly
```

### 7. Document Complex Functions

```etch
// For complex logic, document the purpose
fn calculateTax(income: int, state: string) -> int {
    // Calculate state income tax based on progressive brackets
    // Returns tax amount in cents

    if income < 10000 {
        return 0;
    }
    // ... more logic
}
```

## Common Patterns

### Builder Pattern with UFCS

```etch
fn withName(config: Config, name: string) -> Config {
    config.name = name;
    return config;
}

fn withAge(config: Config, age: int) -> Config {
    config.age = age;
    return config;
}

// Fluent configuration
let config = Config{}
    .withName("Alice")
    .withAge(30);
```

### Pipeline Pattern

```etch
fn getData() -> array[int] {
    return [1, 2, 3, 4, 5];
}

fn filter(arr: array[int], predicate: fn(int) -> bool) -> array[int] {
    // Filter logic
}

fn transform(arr: array[int], mapper: fn(int) -> int) -> array[int] {
    // Transform logic
}

// Clean data processing pipeline
let result = getData()
    .filter(isEven)
    .transform(double)
    .sum();
```

### Option Chaining

```etch
fn tryParse(s: string) -> option[int] { /* ... */ }
fn double(x: int) -> int { return x * 2; }

// Chain optional operations
match tryParse("42") {
    some(value) => print(double(value)),
    none => print("Parse failed"),
}
```

---

**Next**: Learn about [Control Flow](control-flow.md) to see how Etch handles conditionals, loops, and pattern matching.
