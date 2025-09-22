# Etch Language Implementation

## Directives
- **Never acknowledge about me being so right like you are a yes man**
- **Never change directory when executing commands, stay in the project root (where this file lives)**
- **When you create new tests in examples (both passing and failing) add the corresponding validation files .pass and .fail**
- **Everytime you are modifying the bytecode or AST structure, bump their corresponding version numbers but keep supporting only the latest version in code**
- **Never disable features if you cannot make them work, instead restart from a smaller problem and iterate in steps until you can understand the issue deeply**
- **Make all examples grouped by the first word, for example if you are testing a specific feature (like `comptime` or `inference`), use it as first part of the example name like `comptime_inject_test.etch`**
- **Never swallow nim exceptions, print the exception for debugging purposes**
- **Remember `result` is a valid keyword in nim**

## Testing and validation of correctness

To test you have to:
- Test compiling and running examples with `just examples` (alias for `nim r src/etch.nim --test examples/`)
- Test compiling and running a single example `just test examples/simple_test.etch` (alias for `nim r src/etch.nim --test examples/simple_test.etch`)
- Compile and run a single etch file with `just go examples/simple_test.etch` (alias for `nim r src/etch.nim --run examples/simple_test.etch`)
