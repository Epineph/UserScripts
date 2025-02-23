#!/bin/bash

###################################################################
############
# Revised LLVM Build Script
# - Builds LLVM, Clang, LLD, MLIR, Polly, BOLT, and selected
#   runtimes (libc++, libc++abi, compiler-rt, OpenMP).
# - Includes basic testing for clang, lld, libc++, and OpenMP.
# - Does NOT switch to non-graphical (TTY) mode.
#
# Usage:
#   1. chmod +x build_llvm_v2.sh
#   2. ./build_llvm_v2.sh
###################################################################
############

set -e  # Exit on any error

### CONFIGURABLE VARIABLES ###
LLVM_VERSION="16.0.0"  # The LLVM version tag/branch to build
LLVM_SOURCE_DIR="$HOME/llvm-project"
LLVM_BUILD_DIR="$HOME/llvm-build"
LLVM_INSTALL_DIR="/usr/local"

# For creating extra swap during build (optional).
SWAPFILE="/swapfile"
SWAP_SIZE_GB=4

# Which LLVM subprojects to build
# (e.g., "clang;lld;mlir;polly;bolt;clang-tools-extra" if desired)
TARGET_PROJECTS="clang;lld;mlir;polly;bolt"

# Which LLVM runtimes to build
# (compiler-rt, libcxx, libcxxabi, openmp, libunwind, etc.)
TARGET_RUNTIMES="libcxx;libcxxabi;compiler-rt;openmp"
################################

###################################################################
############
# Function: check_prerequisites
###################################################################
############
check_prerequisites() {
  echo "Checking prerequisites..."
  local required_cmds=(cmake ninja gcc g++ python git pkg-config \
                       cpupower fallocate grep bc ionice)
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "Error: Required command '$cmd' is not installed. Please install it and try again."
      exit 1
    fi
  done
  echo "All prerequisites are satisfied."
}

###################################################################
############
# Function: setup_environment
###################################################################
############
setup_environment() {
  echo "Setting CPU governor to performance (if supported)..."
  sudo cpupower frequency-set -g performance || true

  # Check and create swap if necessary
  local current_swap_gb
  current_swap_gb=$(free -g | awk '/^Swap:/ {print $2}')
  if (( current_swap_gb < SWAP_SIZE_GB )); then
    echo "Creating ${SWAP_SIZE_GB}GB swap file at $SWAPFILE..."
    sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
  else
    echo "Sufficient swap space detected. Skipping swap creation."
  fi
}

###################################################################
############
# Function: clone_llvm
###################################################################
############
clone_llvm() {
  if [ ! -d "$LLVM_SOURCE_DIR" ]; then
    echo "Cloning LLVM source (branch llvmorg-$LLVM_VERSION)..."
    git clone --depth 1 --branch "llvmorg-$LLVM_VERSION" \
      https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
  else
    echo "LLVM source directory already exists. Skipping clone."
  fi
}

###################################################################
############
# Function: configure_llvm_build
###################################################################
############
configure_llvm_build() {
  echo "Configuring LLVM build..."
  mkdir -p "$LLVM_BUILD_DIR"

  cmake -S "$LLVM_SOURCE_DIR/llvm" \
        -B "$LLVM_BUILD_DIR" \
        -G "Ninja" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL_DIR" \
        -DLLVM_ENABLE_PROJECTS="$TARGET_PROJECTS" \
        -DLLVM_ENABLE_RUNTIMES="$TARGET_RUNTIMES" \
        -DLLVM_TARGETS_TO_BUILD="X86;ARM" \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_USE_PRECOMPILED_HEADERS=ON
}

###################################################################
############
# Function: build_llvm
###################################################################
############
build_llvm() {
  local cpu_cores
  cpu_cores=$(nproc)
  echo "Building LLVM with $cpu_cores parallel jobs..."
  nice -n 10 ionice -c 2 -n 7 ninja -C "$LLVM_BUILD_DIR" -j"$cpu_cores"
}

###################################################################
############
# Function: install_llvm
###################################################################
############
install_llvm() {
  echo "Installing LLVM to $LLVM_INSTALL_DIR..."
  sudo ninja -C "$LLVM_BUILD_DIR" install
}

###################################################################
############
# Function: cleanup_environment
###################################################################
############
cleanup_environment() {
  echo "Restoring CPU governor to ondemand (if supported)..."
  sudo cpupower frequency-set -g ondemand || true

  if [ -f "$SWAPFILE" ]; then
    echo "Removing swap file..."
    sudo swapoff "$SWAPFILE"
    sudo rm -f "$SWAPFILE"
  fi
}

###################################################################
############
# Function: test_llvm
###################################################################
############
test_llvm() {
  echo "Testing the LLVM installation..."

  echo "Testing clang..."
  if ! clang --version; then
    echo "Error: clang not found."
    exit 1
  fi

  echo "Testing lld (linker)..."
  if ! lld --version; then
    echo "Error: lld not found."
    exit 1
  fi

  echo "Testing libc++ runtime..."
  cat << EOF > test.cpp
#include <iostream>
int main() {
    std::cout << "Hello, libc++!" << std::endl;
    return 0;
}
EOF
  if ! clang++ -stdlib=libc++ test.cpp -o test || ! ./test; then
    echo "Error: libc++ test failed."
    exit 1
  fi

  echo "Testing OpenMP runtime..."
  cat << EOF > omp_test.c
#include <stdio.h>
#include <omp.h>
int main() {
    #pragma omp parallel
    {
        printf("Hello from thread %d\\n", omp_get_thread_num());
    }
    return 0;
}
EOF
  if ! clang -fopenmp omp_test.c -o omp_test || ! ./omp_test; then
    echo "Error: OpenMP test failed."
    exit 1
  fi

  echo "All tests passed successfully!"
}

###################################################################
############
# Main Script
###################################################################
############
main() {
  check_prerequisites
  setup_environment
  clone_llvm
  configure_llvm_build
  build_llvm
  install_llvm
  test_llvm
  cleanup_environment

  echo "LLVM build, installation, and testing completed successfully!"
}

main

