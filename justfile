# Etch Language Implementation - Just commands

VERBOSITY := "0"

default:
    @just -l

# Build the libraries needed for examples
[working-directory: 'examples/clib']
libs:
    make

# Demos
[working-directory: 'demo/etch']
demo TARGET="debug":
    @just build-lib-static {{ if TARGET == "release" { "deploy" } else { "debug" } }}
    cmake -G Xcode -B build -Wno-dev .
    cmake --build build --config {{capitalize(TARGET)}}
    ./build/{{capitalize(TARGET)}}/arkanoid

[working-directory: 'demo/lua']
demo-lua TARGET="debug":
    cmake -G Xcode -B build -Wno-dev .
    cmake --build build --config {{capitalize(TARGET)}}
    ./build/{{capitalize(TARGET)}}/arkanoid

# Build the binaries
build-bin TARGET="release":
    mkdir -p bin
    nim c --verbosity:{{VERBOSITY}} -d:{{TARGET}} -o:bin/etch src/etch.nim

build-bin-perfetto TARGET="release":
    mkdir -p bin
    nim c --verbosity:{{VERBOSITY}} -d:{{TARGET}} -d:perfetto -o:bin/etch_perfetto src/etch.nim

build-lib TARGET="release":
    mkdir -p lib
    nim c --app:lib --noMain --verbosity:{{VERBOSITY}} -d:{{TARGET}} -o:lib/libetch.so src/etch_lib.nim

build-lib-static TARGET="release":
    mkdir -p lib
    nim c --app:staticlib --noMain --verbosity:{{VERBOSITY}} -d:{{TARGET}} -o:lib/libetch.a src/etch_lib.nim
    libtool -static -o lib/libetch_merged.a lib/libetch.a /opt/homebrew/opt/libffi/lib/libffi.a
    mv lib/libetch_merged.a lib/libetch.a

build-libs TARGET="release":
    @just build-lib {{TARGET}}
    @just build-lib-static {{TARGET}}

build TARGET="release":
    @just build-bin {{TARGET}}
    @just build-libs {{TARGET}}

# Run a specific example file
go-quiet file OPTS="" TARGET="debug":
    @just libs
    @just build-bin {{TARGET}}
    ./bin/etch {{OPTS}} --run {{file}}

go-compiler file OPTS="" TARGET="debug":
    @just libs
    @just build-bin {{TARGET}}
    ./bin/etch --verbose co {{OPTS}} --run {{file}}

go-verbose file OPTS="" TARGET="debug":
    @just libs
    @just build-bin {{TARGET}}
    ./bin/etch --verbose {{OPTS}} --run {{file}}

# Dump a specific file
dump file OPTS="" TARGET="debug":
    @just libs
    nim r --verbosity:{{VERBOSITY}} -d:{{TARGET}} src/etch.nim --verbose {{OPTS}} --dump {{file}}

# Test compiling and running all examples + debugger tests
tests OPTS="" TARGET="release":
    @just libs
    nim r --verbosity:{{VERBOSITY}} -d:{{TARGET}} src/etch.nim {{OPTS}} --test examples/

test file OPTS="" TARGET="release":
    @just libs
    nim r --verbosity:{{VERBOSITY}} -d:{{TARGET}} src/etch.nim {{OPTS}} --test {{file}}

# Test compiling and running all examples + debugger tests (c)
tests-c OPTS="" TARGET="release":
    @just libs
    nim r --verbosity:{{VERBOSITY}} -d:{{TARGET}} src/etch.nim {{OPTS}} --test-c examples/

test-c file OPTS="" TARGET="release":
    @just libs
    nim r --verbosity:{{VERBOSITY}} -d:{{TARGET}} src/etch.nim {{OPTS}} --test-c {{file}}

# Nim tests
tests-nim:
    nimble test

# Test c api (needs libraries)
[working-directory: 'examples/capi']
tests-capi TARGET="release":
    @just build {{TARGET}}
    make
    ./simple_example
    ./cpp_example
    ./host_functions_example
    ./vm_inspection_example

# Test all
test-all:
    @just clean
    @just build
    @just tests
    @just tests-c
    @just tests-nim
    @just tests-capi

# Test performance
perf:
    mkdir -p bin
    nim c -d:deploy -d:release --verbosity:{{VERBOSITY}} \
        --threads:off --mm:arc --panics:off --checks:off --overflowChecks:off \
        -o:bin/etch_perf src/etch.nim
    ./bin/etch_perf --perf

# Clean build artifacts
clean:
    find . -name "*.etcx" -delete
    find . -name "*.replay" -delete
    find . -name "*.exe" -delete
    rm -rf .nimcache/*
    rm -rf __etch__
    rm -rf examples/__etch__
    rm -rf performance/__etch__
    rm -rf ./bin/* ./lib/*

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
vscode:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    tsc -p ./
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
