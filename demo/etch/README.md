# Etch Arkanoid Demo - Hot-Reloadable Game

A complete Arkanoid/Breakout clone demonstrating Etch's embedded VM capabilities with hot-reload support.

## Features

- **Full Game Logic in Etch**: All game physics, collision detection, and state management written in Etch
- **Hot-Reload**: Modify `arkanoid.etch` while the game is running and see changes instantly
- **FFI Integration**: Uses `import ffi` to expose C++ host functions to Etch
- **Raylib Integration**: C++ handles rendering, Etch handles game logic

## Architecture

```
┌─────────────────────────────────────┐
│   C++ (main.cpp)                    │
│   - Windowing (raylib)              │
│   - Game State Storage              │
│   - Host Function Registration      │
│   - Hot-Reload File Monitoring      │
└────────────┬────────────────────────┘
             │ FFI Interface
             │ (etch_register_function)
┌────────────▼────────────────────────┐
│   Etch VM (arkanoid.etch)           │
│   - Game Logic                      │
│   - Physics & Collisions            │
│   - Input Handling                  │
│   - Rendering                       │
│   - Score & Win/Loss Detection      │
└─────────────────────────────────────┘
```

## Building

```bash
# Build the demo (Etch library builds automatically)
cd demo
mkdir -p build
cd build
cmake ..
make
```

The CMake configuration automatically builds the Etch library if it doesn't exist or is out of date, so you don't need to manually run `just build-lib-static release`.

## Running

```bash
./arkanoid
```

### Controls
- **Arrow Keys** or **A/D**: Move paddle
- **ESC**: Exit game
- **P**: Pause game

## Hot-Reload Demo

1. Start the game: `./arkanoid`
2. While playing, edit `arkanoid.etch`:
   - Change paddle speed: Modify `getPaddleSpeed()` multiplier
   - Change ball velocity: Adjust initial velocities or bounce calculations
   - Modify collision detection behavior
   - Change scoring logic
3. Save the file
4. The game automatically reloads within 1 second!

## FFI Integration

Etch's `import host` feature allows declaring external functions:

```etch
import host {
    fn isKeyDown(key: int) -> bool;
    fn getPaddleX() -> float;
    fn setPaddleX(x: float);
    // ... more functions
}
```

These are implemented in C++ and registered via the Etch C API:

```cpp
EtchValue host_get_paddle_x(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    return etch_value_new_float(g_gameState->paddleX);
}

etch_register_function(ctx, "getPaddleX", host_get_paddle_x, nullptr);
```

## Code Structure

```
demo/
├── CMakeLists.txt      # Build configuration with FetchContent for raylib
├── main.cpp            # C++ host: window, rendering, FFI functions
├── arkanoid.etch       # Etch script: game logic
└── build/[Debug|Release]
    └── arkanoid        # Compiled executable
```

## Key Etch Features Demonstrated

### 1. Host Function Declarations
```etch
import host {
    fn functionName(param: type) -> returnType;
}
```

### 2. Mutable vs Immutable Variables
```etch
let immutable: float = 1.0;  // Cannot be reassigned
var mutable: float = 1.0;    // Can be reassigned
```

### 3. Control Flow
```etch
if condition {
    // ...
} elif otherCondition {
    // ...
} else {
    // ...
}
```

### 4. Type Conversions
```etch
let i: int = 10;
let f: float = float(i);  // Explicit conversion
```

### 5. Logical Operators
```etch
if a or b {  // Use 'or', not '||'
    // ...
}
if c and d {  // Use 'and', not '&&'
    // ...
}
```

## Performance

The game runs at 60 FPS with:
- 50 bricks (5 rows × 10 columns)
- Continuous collision detection
- Hot-reload checking every second
- Adaptive GC within frame budget

## Extending the Demo

### Add New Game Features
1. Declare new FFI functions in `arkanoid.etch`
2. Implement them in `main.cpp`
3. Register with `etch_register_function()`
4. Hot-reload to test!

### Example: Adding Power-ups
```cpp
// In main.cpp
EtchValue host_spawn_powerup(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    // Implementation
}
etch_register_function(ctx, "spawnPowerup", host_spawn_powerup, nullptr);
```

```etch
// In arkanoid.etch
import host {
    fn spawnPowerup(x: float, y: float, type: int);
}

// Use in brick collision
if isBrickActive(index) {
    setBrickActive(index, false);
    spawnPowerup(brickX, brickY, 0);  // Spawn power-up
}
```

## Notes

- Hot-reload preserves game state (paddle position, score, etc.)
- Compilation errors are printed to console without crashing
- The Etch VM uses adaptive GC to maintain 60 FPS
- All game logic runs in the VM for memory safety and hot-reload support

## See Also

- [Etch C API Documentation](../docs/c-api.md)
- [Etch Language Examples](../examples/)
- [Raylib Cheat Sheet](https://www.raylib.com/cheatsheet/cheatsheet.html)
