# Etch Tests

This directory contains tests for the Etch language implementation.

## Test Files

- `test_debugger_integration.nim` - Comprehensive debugger integration tests
- `test_debug_basic.nim` - Basic debugger sanity tests
- `test_debugger.nim` - Original debugger test suite (deprecated)
- `test_debugger_simple.nim` - Simplified debugger tests (deprecated)

## Quick Start

```bash
# Run all debugger tests
nimble test_debugger

# Run specific test file
nim c -r tests/test_debugger_integration.nim
```

## Test Coverage

The debugger tests validate:

✅ DAP (Debug Adapter Protocol) communication
✅ Breakpoint functionality
✅ Step over/into/out operations
✅ Variable inspection with names and values
✅ Line number tracking
✅ Stack trace information
✅ Continue/pause operations

## Adding New Tests

See `test_debugger_integration.nim` for examples of how to write new debugger tests.

Each test:
1. Creates a temporary Etch program
2. Sends DAP commands to the debug server
3. Validates the responses
4. Cleans up temporary files

## Troubleshooting

If tests fail, ensure:
1. Etch compiler is built: `nim c src/etch.nim`
2. No cached bytecode interfering: `nimble clean`
3. Debug server is working: `./etch --debug-server <file>`