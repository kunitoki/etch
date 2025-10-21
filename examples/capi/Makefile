# Makefile for Etch C API examples

# Compiler settings
CC = gcc
CXX = g++
CFLAGS = -Wall -Wextra -I../../include
CXXFLAGS = -Wall -Wextra -std=c++11 -I../../include
LDFLAGS = -L../../lib -letch -lm

# Detect OS for library path
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    # macOS
    LDFLAGS += -Wl,-rpath,@executable_path/../../lib
else ifeq ($(UNAME_S),Linux)
    # Linux
    LDFLAGS += -Wl,-rpath,$$ORIGIN/../../lib
endif

# Targets
TARGETS = simple_example host_functions_example cpp_example vm_inspection_example debug_example

.PHONY: all clean

all: $(TARGETS)

simple_example: simple_example.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

host_functions_example: host_functions_example.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

cpp_example: cpp_example.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

vm_inspection_example: vm_inspection_example.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

debug_example: debug_example.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGETS)

# Help target
help:
	@echo "Etch C API Examples Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all                      - Build all examples"
	@echo "  simple_example           - Build simple example"
	@echo "  host_functions_example   - Build host functions example"
	@echo "  clean                    - Remove built executables"
	@echo ""
	@echo "Note: Make sure to build the Etch library first with 'just build-lib'"
