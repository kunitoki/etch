# Type System & Type Inference

Etch has a rich static type system with full type inference. This document covers all types, how inference works, and how to work with complex types.

## Table of Contents

1. [Primitive Types](#primitive-types)
2. [Type Inference](#type-inference)
3. [Compound Types](#compound-types)
4. [Algebraic Data Types](#algebraic-data-types)
5. [Generics](#generics)
6. [Type Annotations](#type-annotations)
7. [Lambda Functions](#lambda-functions)

## Primitive Types

###

 Basic Types

```etch
// Boolean (8-bit)
var flag: bool = true;
var isReady = false;  // Type inferred as bool

// Character (8-bit)
var ch: char = 'A';
var letter = 'x';  // Type inferred as char
var digit = '5';   // Type inferred as char

// Integer (64-bit signed)
var x: int = 42;
var y = -100;  // Type inferred as int

// Floating-point (64-bit)
var pi: float = 3.14159;
var e = 2.718;  // Type inferred as float

// String
var name: string = "Alice";
var greeting = "Hello";  // Type inferred as string

// Void (for functions with no return value)
fn doSomething() -> void {
    print("Done");
}
```

### Numeric Literals

```etch
// Integer literals
var decimal = 42;
var negative = -100;
var large = 1000000;

// Float literals (must have decimal point or exponent)
var f1 = 3.14;
var f2 = 2.0;
var scientific = 1.23e-4;
```

### Character Type

The `char` type represents a single character:

```etch
// Character literals use single quotes
let letter: char = 'a';
let digit: char = '5';
let symbol: char = '@';

// String indexing returns char
let text: string = "Hello";
let first: char = text[0];    // 'H'
let last: char = text[4];     // 'o'

// Character comparison
let ch1: char = 'a';
let ch2: char = 'b';
let ch3: char = 'a';

if ch1 == ch3 {
    print("Equal chars work!");      // This prints
}

if ch1 != ch2 {
    print("Different chars work!");  // This prints
}

// Extract character from string and compare
let str: string = "abc";
let first_char: char = str[0];

if first_char == 'a' {
    print("First character is 'a'");  // This prints
}
```

**Key Points:**
- Char literals use single quotes: `'a'`, `'Z'`, `'5'`
- String indexing with `[]` returns a char
- Chars can be compared with `==` and `!=`
- Chars are distinct from single-character strings

```etch
// ✅ Valid: char type
let ch: char = 'x';

// ✅ Valid: string type
let s: string = "x";

// ❌ Different types - cannot directly compare
if ch == s { }  // Type error: char != string
```

## Type Inference

Etch infers types based on initialization values and usage context:

### Basic Inference

```etch
// No type annotation needed!
var x = 42;              // int
var name = "Alice";      // string
var pi = 3.14;           // float
var flag = true;         // bool
var items = [1, 2, 3];   // array[int]
```

### Inference from Function Returns

```etch
fn getNumber() -> int {
    return 42;
}

// Type inferred from function return type
var value = getNumber();  // int
```

### Inference from Operations

```etch
var a = 10;          // int
var b = 20;          // int
var sum = a + b;     // int (inferred from operands)

var x = 1.5;         // float
var y = 2.0;         // float
var product = x * y; // float (inferred from operands)
```

### Inference in Collections

```etch
// Array type inferred from elements
var numbers = [1, 2, 3, 4];        // array[int]
var names = ["Alice", "Bob"];      // array[string]
var floats = [1.0, 2.5, 3.7];      // array[float]

// All elements must have same type
var mixed = [1, "two"];  // ❌ ERROR: inconsistent types
```

### When Inference Fails

Sometimes the compiler needs help:

```etch
// ❌ ERROR: Cannot infer type from none
var x = none;

// ✅ FIX: Provide type annotation
var x: option[int] = none;

// ❌ ERROR: Cannot infer from empty array
var items = [];

// ✅ FIX: Annotate the type
var items: array[int] = [];
```

## Compound Types

### Arrays

Fixed-size or dynamic sequences of values:

```etch
// Array literal - size inferred from elements
var numbers = [1, 2, 3, 4, 5];     // array[int] with 5 elements

// Array with type annotation
var items: array[int] = [10, 20, 30];

// Empty array requires type annotation
var empty: array[string] = [];

// Array length with # operator
var len = #numbers;  // 5

// Array indexing (0-based)
var first = numbers[0];   // 1
var last = numbers[4];    // 5

// Arrays are bounds-checked at compile time when possible
var item = numbers[10];   // ❌ ERROR: index out of bounds
```

### Array Operations

```etch
// Concatenation
var a = [1, 2];
var b = [3, 4];
var c = a + b;  // [1, 2, 3, 4]

// Array slicing
var slice = numbers[1..3];  // [2, 3, 4]

// Iteration
for item in numbers {
    print(item);
}

// Index-based iteration
for i in 0 ..< #numbers {
    print(numbers[i]);
}
```

## Algebraic Data Types

### Enums

Enums define a closed set of named values with comprehensive features including auto-increment values, explicit custom values, string representations, and full type safety.

```etch
// 1. Basic enum with auto-increment values (0, 1, 2...)
type Color = enum {
    Red;        // auto-assigned int value 0
    Green;      // auto-assigned int value 1
    Blue;       // auto-assigned int value 2
    Yellow;     // auto-assigned int value 3
    Purple;     // auto-assigned int value 4
};

// 2. Enum with explicit custom integer values
type Direction = enum {
    North = 0;
    South = 1;
    East = 2;
    West = 3;
};

// 3. Enum with explicit custom string values
type Status = enum {
    Idle = "IDLE";
    Running = "RUNNING";
    Stopped = "STOPPED";
    Error = "ERROR";
};

// 4. Enum with mixed value types (int and string)
type Priority = enum {
    Low = 1;              // explicit int value
    Normal = 2;           // explicit int value
    High = "HIGH";        // explicit string value
    Critical = "CRITICAL";    // explicit string value
};

// 5. Enum with tuple values (int + custom display string)
type StatusCode = enum {
    Low = (1, "Low Priority");
    Medium = (5, "Medium Priority");
    High = (10, "High Priority");
    Urgent;               // auto-assigned (11, "Urgent")
};

fn main() {
    let favoriteColor = Color.Blue;
    let direction = Direction.North;
    let status = Status.Running;

    // Qualified member access - use type name, not variable
    print("Color: " + string(favoriteColor));     // "Color.Blue"
    print("Direction: " + string(direction));     // "Direction.North"
    print("Status: " + string(status));           // "RUNNING"

    // Explicit casting to int and string
    print("Color.Blue as int: " + string(int(favoriteColor)));  // 2
    print("Status.Running as string: " + string(status));       // "RUNNING"

    // Enum comparisons (only same enum types)
    if favoriteColor == Color.Blue {
        print("This is blue!");
    }

    // Pattern matching (must be exhaustive)
    match direction {
        Direction.North => print("Going North"),
        Direction.South => print("Going South"),
        Direction.East => print("Going East"),
        Direction.West => print("Going West")
    };

    // Enum arrays
    let colors: array[Color] = [Color.Red, Color.Green, Color.Blue];
    for i in 0 ..< #colors {
        print("Color " + string(i) + ": " + string(colors[i]));
    }
}
```

**Key rules**

- **Qualified member access**: Use `Color.Red`, not `variable.Red`. Values don't expose members.
- **Auto-increment**: Members without explicit values get consecutive integers starting from 0.
- **Custom values**: You can specify explicit `int`, `string`, or mixed values.
- **Type safety**: Only equality/inequality comparisons, and only between same enum types.
- **Pattern matching**: Must cover every member (use `_` for catch-all).
- **Casting**: Use `int(value)` and `string(value)` for conversions.

**Error Examples**

```etch
// ❌ Type mismatch - cannot compare different enum types
let dir = Direction.North;
let color = Color.Red;
if dir == color { }  // ERROR: Direction vs Color

// ❌ Pattern matching incomplete
match color {
    Color.Red => print("Red"),    // ERROR: Missing Green, Blue, Yellow, Purple
}

// ❌ Invalid member access
let shade = Color.Red;
if shade == Red { }  // ERROR: Need qualified name Color.Red
```

Enums are perfect for states, directions, status codes, priority levels, and any closed set of related values.

### option[T] - Optional Values

Represents a value that may or may not exist:

```etch
// Creating options
var some_value: option[int] = some(42);
var no_value: option[int] = none;

// Pattern matching to extract values
match some_value {
    some(value) => print("Got: " + string(value)),
    none => print("No value"),
}

// Real-world example: safe array access
fn tryGet(arr: array[int], index: int) -> option[int] {
    if index >= 0 and index < #arr {
        return some(arr[index]);
    }
    return none;
}

var numbers = [10, 20, 30];
match tryGet(numbers, 1) {
    some(val) => print(val),      // Prints 20
    none => print("Out of bounds"),
}
```

### result[T] - Success or Error

Represents a computation that can succeed or fail:

```etch
// Creating results
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("Division by zero");
    }
    return ok(a / b);
}

// Pattern matching to handle success and failure
match divide(10, 2) {
    ok(value) => print("Result: " + string(value)),
    error(msg) => print("Error: " + msg),
}

// Chaining operations
fn safeDivide(a: int, b: int, c: int) -> result[int] {
    match divide(a, b) {
        ok(result1) => {
            return divide(result1, c);
        }
        error(msg) => {
            return error(msg);
        }
    }
}
```

### Why Algebraic Types?

Algebraic types make error handling **explicit** and **safe**:

```etch
// ❌ Bad (in many languages): null can cause crashes
fn find(arr: array[int], target: int) -> int? {
    // What if not found? Return null?
    // Caller might forget to check!
}

// ✅ Good (Etch): Forces caller to handle both cases
fn find(arr: array[int], target: int) -> option[int] {
    for i in 0 ..< #arr {
        if arr[i] == target {
            return some(i);
        }
    }
    return none;  // Explicit: not found
}

// Compiler ensures you handle both cases
match find([1, 2, 3], 2) {
    some(index) => print("Found at " + string(index)),
    none => print("Not found"),  // Must handle this!
}
```

## Generics

Functions and types can be generic over types:

### Generic Functions (WIP)

```etch
// Generic identity function
fn identity[T](value: T) -> T {
    return value;
}

// Type parameter inferred from argument
var x = identity(42);       // T = int
var s = identity("hello");  // T = string

// Generic array operations
fn first[T](arr: array[T]) -> option[T] {
    if #arr > 0 {
        return some(arr[0]);
    }
    return none;
}

var numbers = [1, 2, 3];
var f = first(numbers);  // option[int]

var names = ["Alice", "Bob"];
var n = first(names);    // option[string]
```

### Built-in Generic Types

```etch
// option[T] - generic over any type
var opt_int: option[int] = some(42);
var opt_str: option[string] = some("hello");
var opt_arr: option[array[int]] = some([1, 2, 3]);

// result[T] - generic over any type
var res_int: result[int] = ok(42);
var res_str: result[string] = error("failed");

// array[T] - generic over any type
var int_array: array[int] = [1, 2, 3];
var str_array: array[string] = ["a", "b"];
var nested: array[array[int]] = [[1, 2], [3, 4]];
```

## Type Annotations

### When to Use Type Annotations

#### 1. Required: Ambiguous Situations

```etch
// Empty collections
var items: array[int] = [];
var value: option[int] = none;

// Function parameters
fn add(a: int, b: int) -> int {
    return a + b;
}

// Function return types
fn getNumber() -> int {
    return 42;
}
```

#### 2. Optional: Documentation

```etch
// Clear intent even when inferred
var count: int = 0;
var name: string = "Alice";

// Makes return type explicit
fn calculate() -> float {
    var value = 2.5 * 3.0;  // Could infer, but explicit is clearer
    return value;
}
```

#### 3. Optional: Type Safety

```etch
// Catch mistakes early
var expected: int = someComplexCalculation();

// ❌ ERROR: if someComplexCalculation() accidentally returns float,
//           get a compile error instead of silent conversion
```

### Variables: var vs let

```etch
// var - mutable
var counter = 0;
counter = counter + 1;  // ✅ OK

// let - immutable
let pi = 3.14159;
pi = 3.14;  // ❌ ERROR: cannot reassign immutable variable

// Best practice: Use let by default, var only when needed
let name = "Alice";
var score = 0;

for i in 0 ..< 10 {
    score = score + 1;  // Need var for mutation
}
```

## Type System Rules

### Type Compatibility

```etch
// Exact type match required
var x: int = 42;
var y: float = 3.14;

var z = x + y;  // ❌ ERROR: cannot add int and float

// Explicit conversion needed
var z = float(x) + y;  // ✅ OK
var z = x + int(y);    // ✅ OK
```

### Array Type Compatibility

```etch
// Arrays must have homogeneous types
var numbers = [1, 2, 3];      // array[int]
var mixed = [1, "two", 3.0];  // ❌ ERROR: inconsistent types

// Nested arrays
var matrix = [[1, 2], [3, 4], [5, 6]];  // ✅ OK: array[array[int]]

// All sub-arrays must have same length for safety
var uneven = [[1, 2], [3]];   // ⚠️ Allowed but prover tracks ranges
```

### Function Type Compatibility

```etch
// Function signature must match exactly
fn apply(f: fn(int) -> int, x: int) -> int {
    return f(x);
}

fn double(x: int) -> int {
    return x * 2;
}

var result = apply(double, 5);  // ✅ OK: signatures match
```

## Type Safety Examples

### Preventing Type Errors

```etch
// ❌ String-to-number (many languages silently coerce)
var s = "123";
var n = s + 5;  // ❌ ERROR: cannot add string and int

// ✅ Explicit parsing
match parseInt(s) {
    some(num) => print(num + 5),
    none => print("Not a number"),
};

// ❌ Null pointer (doesn't exist in Etch!)
var x: int = null;  // ❌ ERROR: no null type

// ✅ Optional values
var x: option[int] = none;  // Explicit absence of value
```

### Compile-Time Guarantees

The type system ensures:

1. **No type confusion**: Variables can't change type
2. **No null pointers**: Use `option[T]` instead
3. **No uninitialized variables**: All variables must be initialized
4. **No implicit conversions**: All type conversions are explicit
5. **No array type confusion**: Arrays are homogeneous

## Advanced Topics

### Type Inference Limitations

```etch
// Cannot infer recursive types
fn factorial(n: int) {  // ❌ ERROR: cannot infer return type
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}

// ✅ FIX: Explicit return type
fn factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}
```

### Type Aliases

```etch
type UserId = int;
type Email = string;

fn sendEmail(to: Email, from: Email) -> result[void] {
    // ...
}
```

### Strong Type Aliases

```etch
// Not yet implemented, but planned:
type UserId = distinct int;
type Email = distinct string;

fn sendEmail(to: Email, from: Email) -> result[void] {
    // ...
}

sendEmail("abc", 12); // ❌ ERROR: cannot convert from string to Email, int to UserId,
                      //           needs explicit casting
```

## Best Practices

1. **Use type inference when types are obvious**
   ```etch
   var x = 42;           // ✅ Obvious
   var name = "Alice";   // ✅ Obvious
   ```

2. **Annotate function signatures**
   ```etch
   fn process(data: array[int]) -> result[int] {  // ✅ Clear contract
       // ...
   }
   ```

3. **Use `let` by default, `var` only when mutating**
   ```etch
   let constant = 10;    // ✅ Immutable by default
   var counter = 0;      // ✅ Needs to change
   ```

4. **Leverage algebraic types for safety**
   ```etch
   fn divide(a: int, b: int) -> result[int] {  // ✅ Explicit error handling
       // ...
   }
   ```

5. **Trust the type checker**
   - If code compiles, types are correct
   - Let inference do the work when safe
   - Add annotations for clarity, not just to satisfy compiler

---

## Lambda Functions

Lambda functions (also called anonymous functions or closures) are inline-defined functions that create values you can pass around like any other value. They're perfect for short, one-off functions that don't need a separate definition.

### Why Use Lambdas?

Lambdas shine when you need a function for a specific, localized purpose:

```etch
// ❌ Overkill: defining a named function for one-time use
fn isEven(n: int) -> bool {
    return n % 2 == 0;
}
let evenNumbers = numbers.filter(isEven);

// ✅ Perfect: lambda for the specific operation
let evenNumbers = numbers.filter(|n: int| n % 2 == 0);
```

### Basic Lambda Syntax

Lambdas use pipe syntax `|parameters|` to define parameters:

```etch
// Simple expression (implicit return)
let double = |x: int| x * 2;
let result = double(5);  // 10

// Block body (explicit return)
let add = |a: int, b: int| {
    let sum = a + b;
    return sum * 2;
};
let result = add(3, 4);  // 14

// No parameters
let constant = || { return 42; };
let result = constant();  // 42

// Type inference when context is clear
let numbers = [1, 2, 3, 4];
let doubled = numbers.map(|n| n * 2);  // Type of n inferred as int
```

### Lambda Captures

The most powerful feature of lambdas is their ability to **capture** variables from their surrounding scope, creating closures:

```etch
fn createMultiplier(factor: int) -> fn(int) -> int {
    // This lambda captures 'factor' from the parameter
    return [factor] |value: int| value * factor;
}

fn main() {
    let base = 10;

    // Capture multiple variables
    let calculator = [base] |x: int| {
        return (x + base) * 2;
    };

    let result = calculator(5);  // (5 + 10) * 2 = 30
}
```

**Capture Rules:**
- Use `[variable_name]` syntax to capture variables
- Captured variables are **read-only** from the lambda's perspective
- Captures happen at lambda creation time, not call time
- Multiple variables: `[var1, var2, var3]`

### Working with Higher-Order Functions

Lambdas integrate seamlessly with functions that take other functions as parameters:

```etch
// Custom higher-order function
fn applyTwice(f: fn(int) -> int, value: int) -> int {
    return f(f(value));
}

fn main() {
    // Use lambdas with your higher-order functions
    let increment = |x: int| x + 1;
    let result = applyTwice(increment, 5);  // 7

    // Or inline the lambda
    let result2 = applyTwice(|x: int| x * 2, 3);  // 12
}
```

### Common Patterns

#### 1. Collection Transformations

```etch
let numbers = [1, 2, 3, 4, 5];

// Map: transform each element
let squares = numbers.map(|n| n * n);

// Filter: keep elements that match condition
let evens = numbers.filter(|n| n % 2 == 0);

// Reduce: combine all elements
let sum = numbers.reduce(|acc, n| acc + n);
```

#### 2. Event Handlers and Callbacks

```etch
fn onClick(handler: fn() -> void) -> void {
    // Simulate click event
    handler();
}

fn main() {
    let count = 0;

    // Lambda captures counter and modifies it
    let clickHandler = [count] || {
        count = count + 1;
        print("Clicked " + string(count) + " times");
    };

    onClick(clickHandler);
}
```

#### 3. Function Factories

```etch
fn createAdder(base: int) -> fn(int) -> int {
    return [base] |x: int| base + x;
}

fn createComparator(threshold: int) -> fn(int) -> bool {
    return [threshold] |x: int| x > threshold;
}

fn main() {
    let addFive = createAdder(5);
    let isHighValue = createComparator(100);

    let result1 = addFive(10);        // 15
    let result2 = isHighValue(150);   // true
}
```

### Lambda vs Named Functions

**Use lambdas when:**
- The function is short and specific to one use case
- You want to capture variables from outer scope
- The function is passed as a parameter
- Readability benefits from inline definition

**Use named functions when:**
- The function is complex or long
- The function is reused in multiple places
- You need recursive functions
- Documentation would be helpful

```etch
// ✅ Good lambda use
let doubled = numbers.map(|n| n * 2);

// ❌ Named function would be better
let isComplexCalculation = |data: array[int]| {
    // 20 lines of complex logic...
    return processedData;
};
numbers.map(isComplexCalculation);  // Hard to read!
```

### Integration with Etch Features

#### UFCS with Lambdas

```etch
// You can use lambdas with UFCS-style calls
let result = [1, 2, 3, 4]
    .filter(|n| n % 2 == 0)    // Keep even numbers
    .map(|n| n * n)            // Square them
    .reduce(|acc, n| acc + n); // Sum them
```

#### Type Safety

Lambdas are fully typed and integrate with Etch's type system:

```etch
// Lambda type must match expected function type
fn processNumbers(arr: array[int], transformer: fn(int) -> int) -> array[int] {
    return arr.map(transformer);
}

// ✅ Correct type
let result = processNumbers([1, 2, 3], |n| n * 2);

// ❌ Type error - wrong parameter count
let wrong = processNumbers([1, 2, 3], |a, b| a + b);
```

### Best Practices

1. **Keep lambdas short** - If it spans multiple lines, consider a named function
2. **Use descriptive parameter names** even in short lambdas
3. **Leverage type inference** when the context makes types clear
4. **Capture only what you need** - unnecessary captures add complexity
5. **Consider readability** - inline lambdas vs variables based on context

```etch
// ✅ Good: short, clear lambda
let results = data.filter(|item| item.isValid);

// ✅ Good: complex logic gets a name
let isValidUser = |user: User| -> bool {
    return user.email.isValid() and
           user.age >= 18 and
           user.status == UserStatus.Active;
};
let validUsers = users.filter(isValidUser);
```

Lambdas are a powerful tool for writing clean, expressive code that leverages Etch's functional programming capabilities while maintaining the safety and clarity of its type system.

---

**Next**: Learn about [Functions & UFCS](functions.md) to see how Etch's function system works.
