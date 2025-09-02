// mathlib.c - Simple C math library for testing Etch C FFI

#include <stdint.h>

// Platform-specific DLL export macro
#ifdef _WIN32
    #define MATHLIB_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) && __GNUC__ >= 4
    #define MATHLIB_EXPORT __attribute__((visibility("default")))
#else
    #define MATHLIB_EXPORT
#endif

MATHLIB_EXPORT int64_t c_abs(int64_t x) {
    return x < 0 ? -x : x;
}

MATHLIB_EXPORT int64_t c_add(int64_t a, int64_t b) {
    return a + b;
}

MATHLIB_EXPORT int64_t c_multiply(int64_t a, int64_t b) {
    return a * b;
}

MATHLIB_EXPORT int64_t c_power(int64_t base, int64_t exp) {
    int64_t result = 1;
    for (int64_t i = 0; i < exp; i++) {
        result *= base;
    }
    return result;
}

MATHLIB_EXPORT int64_t c_factorial(int64_t n) {
    if (n <= 1) return 1;
    int64_t result = 1;
    for (int64_t i = 2; i <= n; i++) {
        result *= i;
    }
    return result;
}
