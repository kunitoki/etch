# Makefile for building C libraries for Etch FFI testing

CC = clang
LDFLAGS =

# Platform-specific settings
# Detect Windows via OS environment variable (set on Windows)
ifeq ($(OS),Windows_NT)
    # Windows - no -fPIC needed for DLLs, no lib prefix
    CFLAGS = -shared -O2
    XFLAGS =
    LIBEXT = .dll
    LIBPREFIX =
    LIBNAME = mathlib
else
    # Unix-like systems (macOS, Linux) - use lib prefix
    UNAME_S := $(shell uname -s)
    CFLAGS = -shared -fPIC -O2
    LIBPREFIX = lib
    LIBNAME = mathlib

    ifeq ($(UNAME_S),Darwin)
        XFLAGS = -isysroot $(shell xcrun --show-sdk-path)
        LIBEXT = .dylib
    else ifeq ($(UNAME_S),Linux)
        XFLAGS =
        LIBEXT = .so
    else
        # Fallback for other Unix-like systems
        XFLAGS =
        LIBEXT = .so
    endif
endif

LIBFULLNAME = $(LIBPREFIX)$(LIBNAME)$(LIBEXT)

all: $(LIBFULLNAME)

$(LIBFULLNAME): mathlib.c
	$(CC) $(CFLAGS) $(XFLAGS) -o $@ $< $(LDFLAGS)
ifeq ($(UNAME_S),Darwin)
	install_name_tool -id @rpath/$(LIBFULLNAME) $(LIBFULLNAME)
endif

clean:
ifeq ($(OS),Windows_NT)
	del /Q $(LIBFULLNAME) 2>nul || exit 0
else
	rm -f $(LIBFULLNAME)
endif

.PHONY: all clean
