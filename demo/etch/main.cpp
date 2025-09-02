#include <raylib.h>
#include <etch.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <chrono>

// Helper to get last modification time of file
time_t GetScriptModTime(const char* filename) {
    struct stat result;
    if (stat(filename, &result) == 0) {
        return result.st_mtime;
    }
    return 0;
}

// Raylib wrapper functions for Etch

// Window/Drawing
EtchValue host_target_fps(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 1) return etch_value_new_nil();

    int64_t fps;
    if (etch_value_to_int(args[0], &fps) != 0) return etch_value_new_nil();

    SetTargetFPS(static_cast<int>(fps));

    return etch_value_new_nil();
}

EtchValue host_begin_drawing(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)args; (void)numArgs; (void)userData;
    BeginDrawing();
    return etch_value_new_nil();
}

EtchValue host_end_drawing(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)args; (void)numArgs; (void)userData;
    EndDrawing();
    return etch_value_new_nil();
}

EtchValue host_clear_background(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 1) return etch_value_new_nil();

    int64_t color;
    if (etch_value_to_int(args[0], &color) != 0) return etch_value_new_nil();

    ClearBackground(Color{
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    });

    return etch_value_new_nil();
}

EtchValue host_get_screen_width(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)args; (void)numArgs; (void)userData;
    return etch_value_new_int(GetScreenWidth());
}

EtchValue host_get_screen_height(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)args; (void)numArgs; (void)userData;
    return etch_value_new_int(GetScreenHeight());
}

EtchValue host_get_frame_time(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)args; (void)numArgs; (void)userData;
    return etch_value_new_float(GetFrameTime());
}

// Input
EtchValue host_is_key_down(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 1) return etch_value_new_bool(0);

    int64_t key;
    if (etch_value_to_int(args[0], &key) != 0) return etch_value_new_bool(0);

    return etch_value_new_bool(IsKeyDown(static_cast<int>(key)));
}

EtchValue host_is_key_pressed(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 1) return etch_value_new_bool(0);

    int64_t key;
    if (etch_value_to_int(args[0], &key) != 0) return etch_value_new_bool(0);

    return etch_value_new_bool(IsKeyPressed(static_cast<int>(key)));
}

// Drawing primitives
EtchValue host_draw_rectangle(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 5) return etch_value_new_nil();

    int64_t x, y, width, height, color;
    if (etch_value_to_int(args[0], &x) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[1], &y) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[2], &width) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[3], &height) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[4], &color) != 0) return etch_value_new_nil();

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawRectangle(static_cast<int>(x), static_cast<int>(y),
                  static_cast<int>(width), static_cast<int>(height), c);

    return etch_value_new_nil();
}

EtchValue host_draw_circle(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 4) {
        return etch_value_new_nil();
    }

    int64_t x, y, color;
    double radius;
    if (etch_value_to_int(args[0], &x) != 0) {
        return etch_value_new_nil();
    }
    if (etch_value_to_int(args[1], &y) != 0) {
        return etch_value_new_nil();
    }
    if (etch_value_to_float(args[2], &radius) != 0) {
        return etch_value_new_nil();
    }
    if (etch_value_to_int(args[3], &color) != 0) {
        return etch_value_new_nil();
    }

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawCircle(static_cast<int>(x), static_cast<int>(y), static_cast<float>(radius), c);

    return etch_value_new_nil();
}

EtchValue host_draw_text(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 5) return etch_value_new_nil();

    const char* text;
    int64_t x, y, fontSize, color;

    text = etch_value_to_string(args[0]);
    if (text == nullptr) return etch_value_new_nil();
    if (etch_value_to_int(args[1], &x) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[2], &y) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[3], &fontSize) != 0) return etch_value_new_nil();
    if (etch_value_to_int(args[4], &color) != 0) return etch_value_new_nil();

    Color c = {
        static_cast<unsigned char>((color >> 24) & 0xFF),
        static_cast<unsigned char>((color >> 16) & 0xFF),
        static_cast<unsigned char>((color >> 8) & 0xFF),
        static_cast<unsigned char>(color & 0xFF)
    };

    DrawText(text, static_cast<int>(x), static_cast<int>(y), static_cast<int>(fontSize), c);

    return etch_value_new_nil();
}

// Color constants helper
EtchValue host_rgb(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
    (void)ctx; (void)userData;
    if (numArgs != 3 && numArgs != 4) return etch_value_new_int(0);

    int64_t r, g, b, a = 255;
    if (etch_value_to_int(args[0], &r) != 0) return etch_value_new_int(0);
    if (etch_value_to_int(args[1], &g) != 0) return etch_value_new_int(0);
    if (etch_value_to_int(args[2], &b) != 0) return etch_value_new_int(0);
    if (numArgs == 4 && etch_value_to_int(args[3], &a) != 0) return etch_value_new_int(0);

    int64_t color = (r << 24) | (g << 16) | (b << 8) | a;
    return etch_value_new_int(color);
}

// Register raylib host functions
void RegisterHostFunctions(EtchContext ctx) {
    // Window & drawing
    etch_register_function(ctx, "targetFPS", host_target_fps, nullptr);
    etch_register_function(ctx, "beginDrawing", host_begin_drawing, nullptr);
    etch_register_function(ctx, "endDrawing", host_end_drawing, nullptr);
    etch_register_function(ctx, "clearBackground", host_clear_background, nullptr);
    etch_register_function(ctx, "getScreenWidth", host_get_screen_width, nullptr);
    etch_register_function(ctx, "getScreenHeight", host_get_screen_height, nullptr);
    etch_register_function(ctx, "getFrameTime", host_get_frame_time, nullptr);

    // Input
    etch_register_function(ctx, "isKeyDown", host_is_key_down, nullptr);
    etch_register_function(ctx, "isKeyPressed", host_is_key_pressed, nullptr);

    // Drawing primitives
    etch_register_function(ctx, "drawRectangle", host_draw_rectangle, nullptr);
    etch_register_function(ctx, "drawCircle", host_draw_circle, nullptr);
    etch_register_function(ctx, "drawText", host_draw_text, nullptr);

    // Utilities
    etch_register_function(ctx, "rgb", host_rgb, nullptr);
}

// Load or reload the Etch script
bool LoadScript(EtchContext ctx, const char* filename) {
    std::cout << "Registering raylib functions..." << std::endl;
    RegisterHostFunctions(ctx);

    std::cout << "Compiling file..." << std::endl;
    if (etch_compile_file(ctx, filename) != 0) {
        std::cerr << "Failed to compile script: " << etch_get_error(ctx) << std::endl;
        return false;
    }
    std::cout << "Script loaded successfully!" << std::endl;
    return true;
}

int main() {
    // Initialize window
    const int screenWidth = 800;
    const int screenHeight = 600;
    InitWindow(screenWidth, screenHeight, "Etch Arkanoid - Raylib Scripting");

    // Create Etch context
    const EtchContextOptions opts{
        .verbose = false,
        .debug = true,  // Enable debug mode for remote debugging support
        .gcCycleInterval = 0
    };
    EtchContext ctx = etch_context_new_with_options(&opts);
    if (!ctx) {
        std::cerr << "Failed to create Etch context" << std::endl;
        CloseWindow();
        return 1;
    }

    // Load script
    const char* scriptPath = "arkanoid.etch";
    std::cout << "Loading script from: " << scriptPath << std::endl;
    if (!LoadScript(ctx, scriptPath)) {
        std::cout << "Script loading failed, exiting..." << std::endl;
        etch_context_free(ctx);
        CloseWindow();
        return 1;
    }

    // Call <global> to initialize globals and run main()
    // Note: <global> automatically calls main() at the end
    std::cout << "Initializing..." << std::endl;
    EtchValue globalResult = etch_call_function(ctx, "<global>", nullptr, 0);
    if (globalResult == nullptr) {
        std::cerr << "Error during initialization: " << etch_get_error(ctx) << std::endl;
        etch_context_free(ctx);
        CloseWindow();
        return 1;
    }
    etch_value_free(globalResult);

    std::cout << "Entering game loop..." << std::endl;

    // Hot-reload tracking
    time_t lastModTime = GetScriptModTime(scriptPath);
    double timeSinceLastCheck = 0.0;
    const double checkInterval = 1.0;

    // Main game loop - just call Etch!
    while (!WindowShouldClose()) {
        // Hot-reload check
        timeSinceLastCheck += GetFrameTime();
        if (timeSinceLastCheck >= checkInterval) {
            timeSinceLastCheck = 0.0;
            time_t currentModTime = GetScriptModTime(scriptPath);
            if (currentModTime > lastModTime) {
                std::cout << "Script changed, reloading..." << std::endl;
                if (LoadScript(ctx, scriptPath)) {
                    // Re-initialize globals and game after hot-reload (<global> calls main())
                    EtchValue reloadGlobalResult = etch_call_function(ctx, "<global>", nullptr, 0);
                    if (reloadGlobalResult != nullptr) {
                        etch_value_free(reloadGlobalResult);
                        lastModTime = currentModTime;
                        std::cout << "Hot-reload successful!" << std::endl;
                    } else {
                        std::cerr << "Hot-reload failed during initialization" << std::endl;
                    }
                } else {
                    std::cout << "Hot-reload failed, keeping old script" << std::endl;
                }
            }
        }

        BeginDrawing();

        // Call Etch update function (handles both logic and rendering)
        auto start = std::chrono::high_resolution_clock::now();

        {
            EtchValue result = etch_call_function(ctx, "update", nullptr, 0);
            if (result == nullptr) {
                std::cerr << "Error calling update: " << etch_get_error(ctx) << std::endl;
                break;
            }
            etch_value_free(result);
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
    etch_context_free(ctx);
    CloseWindow();

    return 0;
}
