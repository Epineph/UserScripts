#!/bin/bash

# Define variables
LLVM_REPO=https://github.com/llvm/llvm-project.git
LLVM_SRC_DIR=$HOME/repos/llvm-project
LLVM_BUILD_DIR=$HOME/build/llvm
CMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake

# Detect system architecture
ARCHITECTURE=$(uname -m)

# Translate architecture to LLVM target
case $ARCHITECTURE in
  x86_64)
    LLVM_TARGETS="X86"
    ;;
  aarch64)
    LLVM_TARGETS="AArch64"
    ;;
  armv*)
    LLVM_TARGETS="ARM"
    ;;
  *)
    echo "Unknown architecture: $ARCHITECTURE"
    exit 1
    ;;
esac

# Prompt the user for installation
read -p "Do you want to install LLVM after building? (yes/no): " INSTALL_CHOICE
if [ "$INSTALL_CHOICE" = "yes" ]; then
    INSTALL_DIR="$HOME/bin"
    INSTALL_PREFIX="-DCMAKE_INSTALL_PREFIX=$INSTALL_DIR"
    INSTALL_COMMAND="sudo ninja install"
else
    INSTALL_PREFIX=""
    INSTALL_COMMAND=""
fi

# Create necessary directories
mkdir -p $LLVM_SRC_DIR
mkdir -p $LLVM_BUILD_DIR

# Clone the LLVM repository if it doesn't exist
if [ ! -d "$LLVM_SRC_DIR/.git" ]; then
    git clone $LLVM_REPO --recurse-submodules $LLVM_SRC_DIR
else
    cd $LLVM_SRC_DIR
    git pull
fi

# Enter the build directory
cd $LLVM_BUILD_DIR

# Configure the build
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE \
    -DLLVM_ENABLE_PROJECTS="all" \
    -DLLVM_ENABLE_BINDINGS="OCaml" \
    -DOCAML_EXECUTABLE=$(which ocaml) \
    -DLLVM_TARGETS_TO_BUILD=$LLVM_TARGETS \
    $INSTALL_PREFIX \
    $LLVM_SRC_DIR/llvm

# Build LLVM and all subprojects
ninja -j8

# Optionally install LLVM
if [ "$INSTALL_COMMAND" != "" ]; then
    $INSTALL_COMMAND
fi

