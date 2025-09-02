#include <raylib.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <chrono>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

// Helper to get last modification time of file
time_t GetScriptModTime(const char* filename) {
    struct stat result;
    if (stat(filename, &result) == 0) {
        return result.st_mtime;
    }
    return 0;
}

// Raylib wrapper functions for Lua

int host_target_fps(lua_State* L) {
    int fps = luaL_checkinteger(L, 1);
    SetTargetFPS(fps);
    return 0;
}

int host_begin_drawing(lua_State* L) {
    (void)L;
    BeginDrawing();
    return 0;
}

int host_end_drawing(lua_State* L) {
    (void)L;
    EndDrawing();
    return 0;
}

int host_clear_background(lua_State* L) {
    int color = luaL_checkinteger(L, 1);
    ClearBackground(Color{
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    });
    return 0;
}

int host_get_screen_width(lua_State* L) {
    lua_pushinteger(L, GetScreenWidth());
    return 1;
}

int host_get_screen_height(lua_State* L) {
    lua_pushinteger(L, GetScreenHeight());
    return 1;
}

int host_get_frame_time(lua_State* L) {
    lua_pushnumber(L, GetFrameTime());
    return 1;
}

int host_is_key_down(lua_State* L) {
    int key = luaL_checkinteger(L, 1);
    lua_pushboolean(L, IsKeyDown(key));
    return 1;
}

int host_is_key_pressed(lua_State* L) {
    int key = luaL_checkinteger(L, 1);
    lua_pushboolean(L, IsKeyPressed(key));
    return 1;
}

int host_draw_rectangle(lua_State* L) {
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int width = luaL_checkinteger(L, 3);
    int height = luaL_checkinteger(L, 4);
    int color = luaL_checkinteger(L, 5);

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawRectangle(x, y, width, height, c);
    return 0;
}

int host_draw_circle(lua_State* L) {
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    float radius = luaL_checknumber(L, 3);
    int color = luaL_checkinteger(L, 4);

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawCircle(x, y, radius, c);
    return 0;
}

int host_draw_text(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int fontSize = luaL_checkinteger(L, 4);
    int color = luaL_checkinteger(L, 5);

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawText(text, x, y, fontSize, c);
    return 0;
}

int host_rgb(lua_State* L) {
    int r = luaL_checkinteger(L, 1);
    int g = luaL_checkinteger(L, 2);
    int b = luaL_checkinteger(L, 3);
    int a = lua_gettop(L) == 4 ? luaL_checkinteger(L, 4) : 255;

    int color = (r << 24) | (g << 16) | (b << 8) | a;
    lua_pushinteger(L, color);
    return 1;
}

// Register raylib host functions
void RegisterHostFunctions(lua_State* L) {
    lua_register(L, "targetFPS", host_target_fps);
    lua_register(L, "beginDrawing", host_begin_drawing);
    lua_register(L, "endDrawing", host_end_drawing);
    lua_register(L, "clearBackground", host_clear_background);
    lua_register(L, "getScreenWidth", host_get_screen_width);
    lua_register(L, "getScreenHeight", host_get_screen_height);
    lua_register(L, "getFrameTime", host_get_frame_time);
    lua_register(L, "isKeyDown", host_is_key_down);
    lua_register(L, "isKeyPressed", host_is_key_pressed);
    lua_register(L, "drawRectangle", host_draw_rectangle);
    lua_register(L, "drawCircle", host_draw_circle);
    lua_register(L, "drawText", host_draw_text);
    lua_register(L, "rgb", host_rgb);
}

// Load or reload the Lua script
bool LoadScript(lua_State* L, const char* filename) {
    std::cout << "Registering raylib functions..." << std::endl;
    RegisterHostFunctions(L);

    std::cout << "Loading script..." << std::endl;
    if (luaL_dofile(L, filename) != LUA_OK) {
        std::cerr << "Failed to load script: " << lua_tostring(L, -1) << std::endl;
        lua_pop(L, 1);
        return false;
    }
    std::cout << "Script loaded successfully!" << std::endl;
    return true;
}

int main() {
    // Initialize window
    const int screenWidth = 800;
    const int screenHeight = 600;
    InitWindow(screenWidth, screenHeight, "Lua Arkanoid - Raylib Scripting");

    // Create Lua state
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    // Load script
    const char* scriptPath = "arkanoid.lua";
    std::cout << "Loading script from: " << scriptPath << std::endl;
    if (!LoadScript(L, scriptPath)) {
        std::cout << "Script loading failed, exiting..." << std::endl;
        lua_close(L);
        CloseWindow();
        return 1;
    }

    // Call main() to initialize
    std::cout << "Initializing..." << std::endl;
    lua_getglobal(L, "main");
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        std::cerr << "Error during initialization: " << lua_tostring(L, -1) << std::endl;
        lua_close(L);
        CloseWindow();
        return 1;
    }

    std::cout << "Entering game loop..." << std::endl;

    // Hot-reload tracking
    time_t lastModTime = GetScriptModTime(scriptPath);
    double timeSinceLastCheck = 0.0;
    const double checkInterval = 1.0;

    // Main game loop - just call Lua!
    while (!WindowShouldClose()) {
        // Hot-reload check
        timeSinceLastCheck += GetFrameTime();
        if (timeSinceLastCheck >= checkInterval) {
            timeSinceLastCheck = 0.0;
            time_t currentModTime = GetScriptModTime(scriptPath);
            if (currentModTime > lastModTime) {
                std::cout << "Script changed, reloading..." << std::endl;
                lua_close(L);
                L = luaL_newstate();
                luaL_openlibs(L);
                if (LoadScript(L, scriptPath)) {
                    // Re-initialize after hot-reload
                    lua_getglobal(L, "main");
                    if (lua_pcall(L, 0, 0, 0) == LUA_OK) {
                        lastModTime = currentModTime;
                        std::cout << "Hot-reload successful!" << std::endl;
                    } else {
                        std::cerr << "Hot-reload failed during initialization: " << lua_tostring(L, -1) << std::endl;
                        lua_pop(L, 1);
                    }
                } else {
                    std::cout << "Hot-reload failed, keeping old script" << std::endl;
                }
            }
        }

        BeginDrawing();

        // Call Lua update function (handles both logic and rendering)
        auto start = std::chrono::high_resolution_clock::now();

        {
            lua_getglobal(L, "update");
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                std::cerr << "Error calling update: " << lua_tostring(L, -1) << std::endl;
                lua_pop(L, 1);
                break;
            }
        }

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> duration = end - start;
        double scriptTime = duration.count() * 1000.0; // in milliseconds

        // Draw performance stats in bottom left
        DrawText(TextFormat("FPS: %d", GetFPS()), 10, screenHeight - 60, 20, GREEN);
        DrawText(TextFormat("Frame Time: %.2f ms", GetFrameTime() * 1000.0), 10, screenHeight - 40, 20, GREEN);
        DrawText(TextFormat("Script Time: %.2f ms", scriptTime), 10, screenHeight - 20, 20, GREEN);

        EndDrawing();
    }

    // Cleanup
    lua_close(L);
    CloseWindow();

    return 0;
}