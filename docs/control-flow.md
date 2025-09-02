# Control Flow

Etch provides powerful control flow constructs including conditionals, loops, and pattern matching.

## Table of Contents

1. [Conditional Statements](#conditional-statements)
2. [Loops](#loops)
3. [Pattern Matching](#pattern-matching)
4. [Control Flow Keywords](#control-flow-keywords)

## Conditional Statements

### if Expressions

```etch
// Basic if
if x > 0 {
    print("positive");
}

// if-else
if x > 0 {
    print("positive");
} else {
    print("non-positive");
}

// if-else if-else chain
if x > 0 {
    print("positive");
} else if x < 0 {
    print("negative");
} else {
    print("zero");
}
```

### if as Expression

```etch
// if can return a value
let sign = if x > 0 {
    "positive"
} else if x < 0 {
    "negative"
} else {
    "zero"
};

// Both branches must return same type
let abs = if x < 0 { -x } else { x };  // int

// Ternary-style
let max = if a > b { a } else { b };
```

### Boolean Operators

```etch
// Logical AND
if x > 0 and x < 10 {
    print("single digit");
}

// Logical OR
if x < 0 or x > 100 {
    print("out of range");
}

// Logical NOT
if not isValid {
    print("invalid");
}

// Comparison operators
if a == b { }  // Equality
if a != b { }  // Inequality
if a < b { }   // Less than
if a <= b { }  // Less or equal
if a > b { }   // Greater than
if a >= b { }  // Greater or equal
```

## Loops

### for Loops

#### Range-based for

```etch
// Inclusive range: 0 to 9
for i in 0 ..< 10 {
    print(i);  // 0, 1, 2, ..., 9
}

// Inclusive range: 1 to 10
for i in 1 .. 10 {
    print(i);  // 1, 2, 3, ..., 10
}

// Iterate with array length
let arr = [1, 2, 3, 4, 5];
for i in 0 ..< #arr {
    print(arr[i]);
}
```

#### Element iteration

```etch
let numbers = [10, 20, 30];

// Iterate over elements directly
for num in numbers {
    print(num);  // 10, 20, 30
}

// Strings
let name = "Alice";
for ch in name {
    print(ch);  // 'A', 'l', 'i', 'c', 'e'
}
```

### while Loops

```etch
// Basic while loop
var count = 0;
while count < 10 {
    print(count);
    count = count + 1;
}

// Condition checked before each iteration
var done = false;
while not done {
    let input = readInput();
    done = processInput(input);
}
```

### Loop Control

```etch
// break - exit loop early
for i in 0 ..< 100 {
    if i == 50 {
        break;  // Exit loop
    }
    print(i);
}

// continue - skip to next iteration
for i in 0 ..< 10 {
    if i % 2 == 0 {
        continue;  // Skip even numbers
    }
    print(i);  // Prints only odd: 1, 3, 5, 7, 9
}

// Works in while loops too
var i = 0;
while i < 10 {
    i = i + 1;
    if i == 5 {
        continue;
    }
    print(i);
}
```

## Pattern Matching

Pattern matching is Etch's most powerful control flow feature. It combines destructuring, type checking, and control flow into one construct.

### Basic match

```etch
// Match on integers
let value = 42;
match value {
    0 => print("zero"),
    1 => print("one"),
    42 => print("answer"),
    _ => print("other"),  // Default case
}
```

### match as Expression

```etch
// match returns a value
let description = match value {
    0 => "zero",
    1 => "one",
    42 => "answer",
    _ => "unknown",
};

// All branches must return same type
let sign = match x {
    0 => 0,
    _ => if x > 0 { 1 } else { -1 },
};
```

### Pattern Matching with option[T]

```etch
fn tryParse(s: string) -> option[int] {
    // Parse implementation
}

// Match on option type
let input = "42";
match tryParse(input) {
    some(value) => {
        print("Parsed: " + string(value));
        // value is available in this scope
    }
    none => {
        print("Parse failed");
    }
}
```

### Pattern Matching with result[T]

```etch
fn divide(a: int, b: int) -> result[int] {
    if b == 0 {
        return error("Division by zero");
    }
    return ok(a / b);
}

// Match on result type
match divide(10, 2) {
    ok(quotient) => {
        print("Result: " + string(quotient));
    }
    error(message) => {
        print("Error: " + message);
    }
}
```

### Nested Pattern Matching

```etch
// Match inside match
match tryGetUser(userId) {
    some(user) => {
        match user.age {
            0 .. 12 => print("child"),
            13 .. 19 => print("teen"),
            _ => print("adult"),
        }
    }
    none => {
        print("User not found");
    }
}

// Return from nested matches
let status = match parseConfig(file) {
    some(config) => {
        match validate(config) {
            ok(_) => "valid",
            error(msg) => "invalid: " + msg,
        }
    }
    none => "config not found",
};
```

### Or-patterns and ranges

You can combine multiple literals (or sub-patterns) with `|` to share the same arm, and you can match integer or character ranges directly in patterns:

```etch
match score {
    0 ..< 60  => "F",   // exclusive upper bound
    60 ..< 70 => "D",
    70 ..< 80 => "C",
    80 ..< 90 => "B",
    90 .. 100 => "A",   // inclusive upper bound
    _ => "invalid",
}

match value {
    0 | 1 => print("tiny"),
    2 | 3 | 5 | 7 => print("prime under 10"),
    _ => print("other"),
}
```

Ranges work for integers and chars (`'a' .. 'z'` matches lowercase letters). You can still add a binding via `as` to capture the matched value:

```etch
match value {
    (1 ..< 10) as v => print("single digit " + string(v)),
    _ => print("other"),
}
```

### Binding sub-patterns with `as`

`pattern as name` binds the value matched by `pattern` to `name`, even if the pattern is deeper in the tree:

```etch
match userAge {
    some(10 ..< 20 as teen) => tagTeen(teen),
    some(age) => tagAdult(age),
    none => warnMissing(),
}
```

### Tuple destructuring (and multi-subject matches)

Tuples pattern-match element-by-element. Matching on multiple subjects is simply matching on a tuple of values:

```etch
let pt = (3, -1)
match pt {
    (0, 0) => print("origin"),
    (x, 0) => print("x-axis at " + string(x)),
    (0, y) => print("y-axis at " + string(y)),
    (x, y) => print("point: " + string(x) + "," + string(y)),
}

match (left, right) {
    (some(a), some(b)) => combine(a, b),
    (some(a), none)    => useLeft(a),
    (none, some(b))    => useRight(b),
    (none, none)       => default(),
}
```

### Array and slice patterns

Fixed-length arrays can be destructured positionally, and you can capture the remainder with a spread (`...`) pattern:

```etch
match arr3 {
    [x, y, z] => x + y + z,
    _ => 0,
}

match nums {
    [] => print("empty"),
    [x] => print("one: " + string(x)),
    [x, ...rest] => {
        print("head " + string(x))
        print("rest size " + string(#rest))
    }
}

match tokens {
    ["GET", path, ...] => handleGet(path),
    ["POST", path, ...] => handlePost(path),
    _ => badRequest(),
}
```

Only the last position in an array pattern may use `...`. If you bind the spread (e.g. `...rest`) you get the remaining elements as a new array.

### Match with Blocks

```etch
// Multiple statements in match arms
match result {
    ok(value) => {
        let doubled = value * 2;
        let formatted = string(doubled);
        print("Success: " + formatted);
    }
    error(msg) => {
        print("Error occurred");
        print(msg);
    }
}
```

## Control Flow Keywords

### return

```etch
fn calculate(x: int) -> int {
    if x < 0 {
        return 0;  // Early return
    }

    let result = x * 2;
    return result;  // Return from function
}

### Result propagation (`?`)

Functions that return `result[T]` (and coroutines whose payload type is `result[T]`) can use the postfix `?` operator to unwrap successful values while automatically propagating errors to the caller. The operator works on any expression of type `result[T]` and lowers to an early return when the value is `error(...)`.

```etch
fn parsePositive(label: string, value: int) -> result[int] {
    if value < 0 {
        return error(label + " must be positive");
    }
    return ok(value);
}

fn sumThree(a: int, b: int, c: int) -> result[int] {
    let first = parsePositive("a", a)?;
    let second = parsePositive("b", b)?;
    let third = parsePositive("c", c)?;
    return ok(first + second + third);
}
```

If any `parsePositive` call returns `error`, the enclosing function immediately returns that same error; otherwise `first`, `second`, and `third` hold the unwrapped ints.

The same operator works with `resume`, so `resume? coro` is parsed as `resume coro` followed by `?`. This lets coroutine consumers propagate resume failures without writing boilerplate:

```etch
fn drainWorker() -> result[int] {
    let worker = spawn produceValues();
    let first = resume? worker;   // unwraps ok values
    let second = resume? worker;  // propagates errors
    return ok(first + second);
}
```

Restrictions:

- `?` may only appear inside a function (or coroutine) whose return type is `result[T]`.
- The operand must itself have type `result[T]`.
- Outside those contexts the operator is rejected during type checking.
- When a function omits `-> result[...]`, the compiler now infers `result[T]` automatically as soon as a postfix `?` appears, even inside `return expr?` statements.

// Return from match
fn sign(x: int) -> string {
    return match x {
        0 => "zero",
        _ => if x > 0 { "positive" } else { "negative" },
    };
}
```

### break and continue

```etch
// break - exit loop
for i in 0 ..< 100 {
    if found {
        break;
    }
    process(i);
}

// continue - next iteration
for i in 0 ..< 100 {
    if shouldSkip(i) {
        continue;
    }
    process(i);
}

// Works in while loops
while condition {
    if shouldExit {
        break;
    }
    if shouldSkip {
        continue;
    }
    doWork();
}
```

## Best Practices

### 1. Prefer match over if-else chains

```etch
// ❌ Verbose if-else
if result.isOk() {
    let value = result.getValue();
    process(value);
} else {
    let error = result.getError();
    handleError(error);
}

// ✅ Clear match
match result {
    ok(value) => process(value),
    error(msg) => handleError(msg),
}
```

### 2. Use for loops with ranges

```etch
// ✅ Clear intent
for i in 0 ..< 10 {
    print(i);
}

// ❌ Manual iteration (error-prone)
var i = 0;
while i < 10 {
    print(i);
    i = i + 1;  // Easy to forget!
}
```

### 3. Handle all cases in match

```etch
// ✅ Exhaustive matching
match value {
    some(x) => process(x),
    none => handleMissing(),  // All cases covered
}

// ⚠️ Use _ for default when appropriate
match status {
    200 => success(),
    404 => notFound(),
    _ => handleOtherCodes(),
}
```

### 4. Use break/continue for clarity

```etch
// ✅ Clear search logic
for item in collection {
    if item == target {
        found = true;
        break;  // Clear: we found it, stop looking
    }
}

// ✅ Clear filtering
for item in collection {
    if not isValid(item) {
        continue;  // Clear: skip invalid items
    }
    process(item);
}
```

### 5. Leverage expression-based control flow

```etch
// ✅ Compact and readable
let category = match score {
    90 .. 100 => "A",
    80 .. 89 => "B",
    70 .. 79 => "C",
    _ => "F",
};

// vs verbose if-else
var category: string;
if score >= 90 {
    category = "A";
} else if score >= 80 {
    category = "B";
} // ...
```

## Advanced Patterns

### State Machines

```etch
var state = "init";
while true {
    match state {
        "init" => {
            initialize();
            state = "running";
        }
        "running" => {
            if shouldPause() {
                state = "paused";
            } else if shouldStop() {
                state = "stopped";
            } else {
                doWork();
            }
        }
        "paused" => {
            if shouldResume() {
                state = "running";
            }
        }
        "stopped" => {
            break;
        }
        _ => {
            print("Unknown state");
            break;
        }
    }
}
```

### Accumulation Pattern

```etch
// Sum array elements
var sum = 0;
for item in numbers {
    sum = sum + item;
}

// Build result array
var evens: array[int] = [];
for num in numbers {
    if num % 2 == 0 {
        evens = evens + [num];
    }
}
```

---

**Next**: Learn about [Modules & FFI](modules.md) to organize code and call C libraries.
