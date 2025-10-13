# Etch Language Implementation

## Directives
- **Never change directory when executing commands, stay in the project root (where this file lives)**
- **Never ever think about giving up, like "we should do Y but because it's too much, for now we do X" and you end up shortcutting to tech debt and fake implementations**
- **When you create new tests in examples (both passing and failing) add the corresponding validation files .pass and .fail**
- **Everytime you are modifying the bytecode or AST structure, bump their corresponding version numbers but keep supporting only the latest version in code**
- **Never disable features if you cannot make them work, instead restart from a smaller problem and iterate in steps until you can understand the issue deeply**
- **Make all examples grouped by the first word, for example if you are testing a specific feature (like `comptime` or `inference`), use it as first part of the example name like `comptime_inject_test.etch`**
- **When hunting bugs or making changes, add extensive verbose logging protected by the verbose flag, this will help you detect issues**
- **Never swallow nim exceptions, print the exception for debugging purposes**
- **Remember `result` is a valid keyword in nim, so don't create variables with that name if it's not the implicit one**
- **Try to not add too many comments in methods, try to keep it just for method signature, not several inside bodies at every instruction**
- **Never try to write files into /tmp**

## Testing and validation of correctness

For bugfixing and validation, you have to:
- Test compiling and running examples with `just tests` (alias for `nim r src/etch.nim --test examples/`)
- Test compiling and running a single example `just test examples/simple_test.etch` (alias for `nim r src/etch.nim --test examples/simple_test.etch`):
    * If the test is passing, you need to provide a `examples/simple_test.pass` file
    * Otherwise a `examples/simple_test.fail` one when it fails.
- Test the debugger integration with `nimble test`.
- Compile and run a single etch file in verbose mode with `just go examples/simple_test.etch` (alias for `nim r src/etch.nim --run examples/simple_test.etch`)
- Compile and reinstall the VSCode extension with `just vscode`
