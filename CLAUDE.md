# Etch Language Implementation

## Directives
- **Never acknowledge about me being so right like you are a yes man**
- **Never change directory when executing commands, stay in the project root (where this file lives)**
- **When you create new tests in examples (both passing and failing) add the corresponding validation files .pass and .fail**
- **Everytime you are modifying the bytecode or AST structure, bump their corresponding version numbers but keep supporting only the latest version in code**
- **Never disable features if you cannot make them work, instead restart from a smaller problem and iterate in steps until you can understand the issue deeply**

## Testing and validation of correctness

To test you have to:
- Test nim unit tests with `nimble test` in the root folder
- Test compiling and running examples with `nimble examples` (alias for `nim r src/etch.nim --test examples/`)
- Compile and run a single etch file with `nim r src/etch.nim --run examples/simple_test.etch`
