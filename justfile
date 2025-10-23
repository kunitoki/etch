# Etch Language Implementation - Just commands

default:
    @just -l

# Build the libraries needed for examples
[working-directory: 'examples/clib']
libs:
    make

# Build the binaries
build-bin:
    mkdir -p bin
    nim c -d:release -o:bin/etch src/etch.nim

build-lib:
    mkdir -p lib
    nim c --app:lib --noMain -d:release -o:lib/libetch.so src/etch_lib.nim

build-lib-static:
    mkdir -p lib
    nim c --app:staticlib --noMain -d:release -o:lib/libetch.a src/etch_lib.nim

build-libs:
    @just build-lib
    @just build-lib-static

build:
    @just build-bin
    @just build-libs

# Run a specific example file
go file:
    @just libs
    nim r src/etch.nim --verbose --run {{file}}

# Test compiling and running all examples + debugger tests
tests:
    @just libs
    nim r src/etch.nim --test examples/
    nimble test

test file OPTS="":
    @just libs
    nim r src/etch.nim --test {{file}} {{OPTS}}

# Test compiling and running all examples + debugger tests (c)
tests-c OPTS="":
    @just libs
    nim r src/etch.nim --test-c examples/ {{OPTS}}

test-c file OPTS="":
    @just libs
    nim r src/etch.nim --test-c {{file}} {{OPTS}}

# Test c api (needs libraries)
[working-directory: 'examples/capi']
test-capi:
    @just build
    make
    ./simple_example
    ./cpp_example
    ./host_functions_example
    ./vm_inspection_example

# Test performance
perf:
    nimble perf

# Clean build artifacts
clean:
    find . -name "*.etcx" -delete
    find . -name "*.exe" -delete
    find examples -name "*.c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find examples -name "*_c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find . -name "nimcache" -type d -exec rm -rf {} + 2>/dev/null || true
    rm -rf ./bin ./lib

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
vscode:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    tsc -p ./
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
