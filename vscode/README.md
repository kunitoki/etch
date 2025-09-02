# Etch Language Support for VSCode

Syntax highlighting and debugging support for the Etch programming language.

## Features

### Syntax Highlighting

- Full syntax highlighting for Etch `.etch` files
- Support for all Etch keywords, operators, and constructs
- Proper highlighting for comments, strings, and numbers

### Standard Debugging

- Set breakpoints in Etch source files
- Step through code (step over, step into, step out)
- Inspect variables and call stack
- Continue execution and pause
- Modify variable values during debugging

## Installation

### From VSIX

```bash
# Build the extension
cd vscode
npm install
npm run build
vsce package

# Install in VSCode
code --install-extension etchlang-*.vsix
```

### From Source (Development)

```bash
cd vscode
npm install
npm run build
```

Then press F5 in VSCode to launch an Extension Development Host.

## Usage

### Basic Debugging

1. Open an Etch source file (`.etch`)
2. Set breakpoints by clicking in the left gutter
3. Press F5 or Run > Start Debugging
4. Select "Etch Debug" configuration
5. Debug your program with standard controls

### Debug Configuration

Add to `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "etch",
      "request": "launch",
      "name": "Debug Etch Program",
      "program": "${workspaceFolder}/main.etch",
      "stopAtEntry": true
    }
  ]
}
```

## Requirements

- VSCode 1.66.0 or higher
- Etch compiler with debug support
- Node.js 14+ (for extension development)

## Development

### Building

```bash
npm install
npm run build
```

### Testing

```bash
npm run typecheck
npm test
```

### Packaging

```bash
npm run package
```

Creates `etchlang-X.X.X.vsix` for distribution.

### Publishing

```bash
# First time: create publisher
vsce create-publisher <publisher-name>

# Publish
npm run publish
```

## Changelog

### 0.1.0 (2025-01-25)

- Syntax highlighting for Etch language
- Standard debugging support (breakpoints, stepping, variables)
- Variable modification during debugging

## Contributing

Issues and pull requests welcome at https://github.com/kunitoki/etch

## License

MIT
