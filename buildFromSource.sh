#!/bin/bash

# Detect and build a project from source.

# Exit on any error
set -e

# Function to detect and build using CMake
build_cmake() {
    echo "Detected CMake project."
    mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release ..
    cmake --build . --config Release -j$(nproc)
    sudo cmake --build . --config Release --target install
}

# Function to build using configure script
build_configure() {
    echo "Detected configure script."
    ./configure
    make -j$(nproc)
    sudo make install
}

# Attempt to detect build system and proceed accordingly
if [[ -f "CMakeLists.txt" ]]; then
    build_cmake
elif [[ -f "configure" ]]; then
    build_configure
else
    echo "Build system not recognized."
    exit 1
fi
