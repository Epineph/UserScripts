#!/bin/bash

###############################################################################
# Optimized LLVM Build Script
# This script builds LLVM, its projects (like clang, lld), and runtimes
# (like libcxx, libcxxabi) efficiently. It also includes testing commands to
# verify the installation.
#
# Features:
#   - Disables unnecessary components for faster builds.
#   - Builds selected projects and runtimes.
#   - Verifies installation with key tools and runtimes.
#
# Usage:
#   1. Make the script executable: chmod +x build_and_test_llvm.sh
#   2. Run it: ./build_and_test_llvm.sh
###############################################################################

set -e  # Exit on any error

### CONFIGURABLE VARIABLES ###
LLVM_VERSION="16.0.0"                    # The LLVM version to build
LLVM_SOURCE_DIR="$HOME/llvm-project"     # Source directory
LLVM_BUILD_DIR="$HOME/llvm-build"        # Build directory
LLVM_INSTALL_DIR="/usr/local"            # Installation prefix
SWAPFILE="/swapfile"                     # Temporary swap file
SWAP_SIZE_GB=4                           # Size of the swap file
TARGET_PROJECTS="clang;lld;mlir;polly;bolt"  # LLVM projects to build
TARGET_RUNTIMES="libcxx;libcxxabi;compiler-rt"  # LLVM runtimes to build
################################

###############################################################################
# Function: check_prerequisites
###############################################################################
check_prerequisites() {
  echo "Checking prerequisites..."
  local required_cmds=(cmake ninja gcc g++ python git pkg-config cpupower systemctl fallocate grep bc ionice)
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "Error: Required command '$cmd' is not installed. Install it and try again."
      exit 1
    fi
  done
  echo "All prerequisites are satisfied."
}

###############################################################################
# Function: setup_environment
###############################################################################
setup_environment() {
  echo "Switching to non-graphical mode (multi-user.target)..."
  sudo systemctl set-default multi-user.target
  sudo systemctl isolate multi-user.target

  echo "Setting CPU governor to performance..."
  sudo cpupower frequency-set -g performance || true

  # Check and create swap if necessary
  local current_swap_gb=$(free -g | awk '/^Swap:/ {print $2}')
  if (( current_swap_gb < SWAP_SIZE_GB )); then
    echo "Creating ${SWAP_SIZE_GB}GB swap file..."
    sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
  else
    echo "Sufficient swap space detected. Skipping swap creation."
  fi
}

###############################################################################
# Function: clone_llvm
###############################################################################
clone_llvm() {
  if [ ! -d "$LLVM_SOURCE_DIR" ]; then
    echo "Cloning LLVM source (branch llvmorg-$LLVM_VERSION)..."
    git clone --depth 1 --branch "llvmorg-$LLVM_VERSION" \
      https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
  else
    echo "LLVM source directory already exists. Skipping clone."
  fi
}

###############################################################################
# Function: configure_llvm_build
###############################################################################
configure_llvm_build() {
  echo "Configuring LLVM build..."

  # Create build directory
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

###############################################################################
# Function: build_llvm
###############################################################################
build_llvm() {
  local cpu_cores=$(nproc)
  echo "Building LLVM with $cpu_cores parallel jobs..."
  nice -n 10 ionice -c 2 -n 7 ninja -C "$LLVM_BUILD_DIR" -j"$cpu_cores"
}

###############################################################################
# Function: install_llvm
###############################################################################
install_llvm() {
  echo "Installing LLVM to $LLVM_INSTALL_DIR..."
  sudo ninja -C "$LLVM_BUILD_DIR" install
}

###############################################################################
# Function: cleanup_environment
###############################################################################
cleanup_environment() {
  echo "Restoring system settings..."
  sudo cpupower frequency-set -g ondemand || true
  sudo systemctl set-default graphical.target
  sudo systemctl isolate graphical.target

  if [ -f "$SWAPFILE" ]; then
    echo "Removing swap file..."
    sudo swapoff "$SWAPFILE"
    sudo rm -f "$SWAPFILE"
  fi
}

###############################################################################
# Function: test_llvm
###############################################################################
test_llvm() {
  echo "Testing the LLVM installation..."

  # Test LLVM core tools
  echo "Testing clang..."
  clang --version || { echo "Error: clang not found."; exit 1; }

  echo "Testing lld (linker)..."
  lld --version || { echo "Error: lld not found."; exit 1; }

  echo "Testing libc++ runtime..."
  cat << EOF > test.cpp
#include <iostream>
int main() {
    std::cout << "Hello, libc++!" << std::endl;
    return 0;
}
EOF
  clang++ -stdlib=libc++ test.cpp -o test && ./test || { echo "Error: libc++ test failed."; exit 1; }

  echo "Testing OpenMP runtime..."
  cat << EOF > omp_test.c
#include <stdio.h>
#include <omp.h>
int main() {
    #pragma omp parallel
    {
        printf("Hello from thread %d\n", omp_get_thread_num());
    }
    return 0;
}
EOF
  clang -fopenmp omp_test.c -o omp_test && ./omp_test || { echo "Error: OpenMP test failed."; exit 1; }

  echo "All tests passed successfully!"
}

###############################################################################
# Main Script
###############################################################################
main() {
  check_prerequisites
  setup_environment
  clone_llvm
  configure_llvm_build
  build_llvm
  install_llvm
  cleanup_environment
  test_llvm
  echo "LLVM build, installation, and testing completed successfully!"
}

main

