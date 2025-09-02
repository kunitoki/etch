# Lua Arkanoid Demo - Hot-Reloadable Game

A complete Arkanoid/Breakout clone demonstrating Lua's embedded scripting capabilities with hot-reload support.

## Features

- **Full Game Logic in Lua**: All game physics, collision detection, and state management written in Lua
- **Hot-Reload**: Modify `arkanoid.lua` while the game is running and see changes instantly
- **FFI Integration**: Uses Lua C API to expose C++ host functions to Lua
- **Raylib Integration**: C++ handles rendering, Lua handles game logic

## Architecture

```
┌─────────────────────────────────────┐
│   C++ (main.cpp)                    │
│   - Windowing (raylib)              │
│   - Game State Storage              │
│   - Host Function Registration      │
│   - Hot-Reload File Monitoring      │
└────────────┬────────────────────────┘
             │ Lua C API
             │ (lua_register)
┌────────────▼────────────────────────┐
│   Lua VM (arkanoid.lua)            │
│   - Game Logic                      │
│   - Physics & Collisions            │
│   - Input Handling                  │
│   - Rendering                       │
│   - Score & Win/Loss Detection      │
└─────────────────────────────────────┘
```

## Building

```bash
# Build the demo
cd demo2
mkdir -p build
cd build
cmake ..
make
```

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
2. While playing, edit `arkanoid.lua`:
   - Change paddle speed: Modify `PADDLE_SPEED` multiplier
   - Change ball velocity: Adjust initial velocities or bounce calculations
   - Modify collision detection behavior
   - Change scoring logic
3. Save the file
4. The game automatically reloads within 1 second!

## Lua Integration

Lua's C API allows registering C functions as global Lua functions:

```cpp
int host_get_screen_width(lua_State* L) {
    lua_pushinteger(L, GetScreenWidth());
    return 1;  // Number of return values
}

lua_register(L, "getScreenWidth", host_get_screen_width);
```

These are called from Lua like regular functions:

```lua
local width = getScreenWidth()
```

## Code Structure

```
demo2/
├── CMakeLists.txt      # Build configuration with FetchContent for raylib and lua
├── main.cpp            # C++ host: window, rendering, Lua functions
├── arkanoid.lua        # Lua script: game logic
└── build/[Debug|Release]
    └── arkanoid        # Compiled executable
```

## Key Lua Features Demonstrated

### 1. Global Functions
```lua
function update()
    -- Game update logic
end
```

### 2. Local vs Global Variables
```lua
local localVar = 1  -- Local scope
globalVar = 2       -- Global scope (accessible from C++)
```

### 3. Control Flow
```lua
if condition then
    -- ...
elseif otherCondition then
    -- ...
else
    -- ...
end
```

### 4. Type Conversions
```lua
local i = 10
local f = i  -- Automatic conversion
local s = tostring(i)
```

### 5. Logical Operators
```lua
if a or b then
    -- ...
end
if c and d then
    -- ...
end
```

## Performance

The game runs at 60 FPS with:
- 50 bricks (5 rows × 10 columns)
- Continuous collision detection
- Hot-reload checking every second

## Extending the Demo

### Add New Game Features
1. Declare new functions in `arkanoid.lua`
2. Implement them in `main.cpp`
3. Register with `lua_register()`
4. Hot-reload to test!

### Example: Adding Power-ups
```cpp
// In main.cpp
int host_spawn_powerup(lua_State* L) {
    float x = luaL_checknumber(L, 1);
    float y = luaL_checknumber(L, 2);
    int type = luaL_checkinteger(L, 3);
    // Implementation
    return 0;
}
lua_register(L, "spawnPowerup", host_spawn_powerup);
```

```lua
-- In arkanoid.lua
-- Use in brick collision
if bricks[index] then
    bricks[index] = false
    spawnPowerup(brickX, brickY, 0)  -- Spawn power-up
end
```

## Notes

- Hot-reload preserves game state (paddle position, score, etc.)
- Script errors are printed to console without crashing
- All game logic runs in the Lua VM for safety and hot-reload support

## See Also

- [Lua Reference Manual](https://www.lua.org/manual/5.4/)
- [Raylib Cheat Sheet](https://www.raylib.com/cheatsheet/cheatsheet.html)