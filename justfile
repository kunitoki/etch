# Etch Language Implementation - Just commands

default:
    @just -l

[working-directory: 'examples/clib']
libs:
    make

# Test compiling and running all examples
examples:
    @just libs
    nim r src/etch.nim --test examples/

# Test compiling and running a specific example file
test file:
    @just libs
    nim r src/etch.nim --test {{file}}

# Run a specific example file
go file:
    @just libs
    nim r src/etch.nim --run {{file}} --verbose

# Build the project
build:
    nim c -d:danger -o:etch src/etch.nim

# Clean build artifacts
clean:
    find . -name "*.etcx" -delete
    find . -name "*.exe" -delete
    find examples -name "*.c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find examples -name "*_c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find . -name "nimcache" -type d -exec rm -rf {} + 2>/dev/null || true

# Handle performance
perf:
    #hyperfine --warmup 3 './etch --run --release performance/for_loop_print.etch' 'python3 performance/for_loop_print.py'
    #hyperfine --warmup 3 './etch --run --release performance/arithmetic_operations.etch' 'python3 performance/arithmetic_operations.py'
    #hyperfine --warmup 3 './etch --run --release performance/array_operations.etch' 'python3 performance/array_operations.py'
    #hyperfine --warmup 3 './etch --run --release performance/string_operations.etch' 'python3 performance/string_operations.py'
    #hyperfine --warmup 3 './etch --run --release performance/nested_loops.etch' 'python3 performance/nested_loops.py'
    hyperfine --warmup 3 './etch --run --release performance/function_calls.etch' 'python3 performance/function_calls.py'
    @just build

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
vscode:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    tsc -p ./
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
