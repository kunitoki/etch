cmake_minimum_required(VERSION 3.30)
project(EtchArkanoid CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Fetch raylib
include(FetchContent)
FetchContent_Declare(
    raylib
    GIT_REPOSITORY https://github.com/raysan5/raylib.git
    GIT_TAG 5.5
)
FetchContent_MakeAvailable(raylib)

# Etch library
set(ETCH_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(ETCH_INCLUDE_DIR "${ETCH_ROOT}/include")
set(ETCH_LIB_DIR "${ETCH_ROOT}/lib")
set(ETCH_LIB_FILE "${ETCH_LIB_DIR}/libetch.a")

# Build Etch library if it doesn't exist or is out of date
#add_custom_command(
#    OUTPUT ${ETCH_LIB_FILE}
#    COMMAND just build-lib-static release
#    WORKING_DIRECTORY ${ETCH_ROOT}
#    COMMENT "Building Etch library..."
#    VERBATIM
#)

# Create a custom target that depends on the library
#add_custom_target(build_etch_lib DEPENDS ${ETCH_LIB_FILE})

# Add executable
add_executable(arkanoid main.cpp)

# Make sure Etch library is built before the executable
#add_dependencies(arkanoid build_etch_lib)

# Link libraries
target_include_directories(arkanoid PRIVATE ${ETCH_INCLUDE_DIR})
target_link_libraries(arkanoid PRIVATE raylib m ${ETCH_LIB_DIR}/libetch.a)
