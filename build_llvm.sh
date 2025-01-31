#!/bin/bash

###############################################################################
# This script demonstrates an end-to-end procedure for building LLVM with
# minimal resource contention. It:
#   1. Switches to multi-user.target (no graphical interface)
#   2. Sets CPU governor to performance (for max CPU throughput)
#   3. Creates a temporary swap file if needed (to avoid OOM or thrashing)
#   4. Builds LLVM with nice + ionice
#   5. Restores the CPU governor, removes swap, and re-enables the graphical UI
#
# Usage:
#   1. Switch to a TTY (e.g., Ctrl + Alt + F3), log in, and place this script in
#      a folder (e.g., ~/repos/UserScripts).
#   2. Make it executable: 
#        chmod +x optimized_llvm_build.sh
#   3. Run it:
#        ./optimized_llvm_build.sh
#
# Make sure you have the following installed: 
#   - cmake
#   - ninja
#   - gcc (which includes g++)
#   - python
#   - git
#   - pkg-config
#   - cpupower
#   (On Arch-based systems: sudo pacman -Syu --needed <packages>)
###############################################################################

set -e  # Exit immediately on error

### USER CONFIGURABLE VARIABLES ###
LLVM_VERSION="16.0.0"                    # The LLVM version to build
LLVM_SOURCE_DIR="$HOME/llvm-project"     # Where to clone/download the LLVM source
LLVM_BUILD_DIR="$HOME/llvm-build"        # Where to place build files
LLVM_INSTALL_DIR="/usr/local"            # Installation prefix
SWAPFILE="/swapfile"                     # Temporary swap file location
SWAP_SIZE_GB=4                           # Size of the temporary swap file in GB
<<<<<<< HEAD
TARGET_PROJECTS="clang"                  # Comma-separated list of LLVM projects to build
=======
TARGET_PROJECTS="clang;lld;libcxx;libcxxabi;compiler-rt;mlir;polly;openmp;bolt"                  # Comma-separated list of LLVM projects to build
>>>>>>> refs/remotes/origin/main
####################################

###############################################################################
# Function: check_prerequisites
# Description: Ensures the script is run from a TTY and that required commands
#              are installed. Optionally warns if run from within a graphical
#              session.
###############################################################################
check_prerequisites() {
  # Check if we are on a TTY (optional check - some TTYs might not show as /dev/tty)
  if [[ "$(tty)" == /dev/tty* ]]; then
    echo "Running on a TTY: OK"
  else
    echo "WARNING: This script is not running on a standard TTY."
    echo "If you are inside a GUI terminal, switching to multi-user.target will end this session!"
    echo "Press Ctrl + C to abort or continue at your own risk."
    sleep 5
  fi

  # Check required commands
  local required_cmds=( cmake ninja gcc g++ python git pkg-config cpupower systemctl fallocate grep bc ionice )
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "Error: Required command '$cmd' is not installed or not in PATH."
      exit 1
    fi
  done
}

###############################################################################
# Function: switch_to_multi_user
# Description: Switches the system to multi-user.target, effectively disabling
#              the graphical environment (sddm, etc.).
###############################################################################
switch_to_multi_user() {
  echo "Switching systemd default to multi-user.target (non-graphical) ..."
  sudo systemctl set-default multi-user.target

  echo "Isolating multi-user.target now..."
  sudo systemctl isolate multi-user.target
  # After this point, the graphical session is stopped (if it was running).
  # We remain in the TTY session.
}

###############################################################################
# Function: setup_performance_governor
# Description: Sets the CPU frequency governor to 'performance' for maximum speed.
###############################################################################
setup_performance_governor() {
  echo "Switching CPU governor to performance..."
  sudo cpupower frequency-set -g performance || true
}

###############################################################################
# Function: setup_swap
# Description: Creates a temporary swap file if the system's total swap is less
#              than SWAP_SIZE_GB. This helps prevent out-of-memory errors
#              during large builds on constrained systems.
###############################################################################
setup_swap() {
  # Check current swap size in GB
  local current_swap_gb
  current_swap_gb=$(free -g | awk '/^Swap:/ {print $2}')

  # If current swap is less than SWAP_SIZE_GB, create a new swap file
  if (( current_swap_gb < SWAP_SIZE_GB )); then
    echo "Creating a ${SWAP_SIZE_GB}GB swap file at $SWAPFILE ..."
    sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
  else
    echo "System already has sufficient swap (>= ${SWAP_SIZE_GB}GB). Skipping creation."
  fi
}

###############################################################################
# Function: clone_llvm
# Description: Clones LLVM from GitHub if not already cloned.
###############################################################################
clone_llvm() {
  if [ ! -d "$LLVM_SOURCE_DIR" ]; then
    echo "Cloning LLVM source (branch llvmorg-$LLVM_VERSION) into $LLVM_SOURCE_DIR ..."
    git clone --depth 1 --branch "llvmorg-$LLVM_VERSION" \
      https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
  else
    echo "LLVM source directory $LLVM_SOURCE_DIR already exists. Skipping clone."
  fi
}

###############################################################################
# Function: configure_llvm_build
# Description: Uses CMake to configure the LLVM build with:
#   - Release build type
#   - Install prefix
#   - Minimal projects (by default 'clang')
#   - Precompiled headers on (optional optimization)
###############################################################################
configure_llvm_build() {
  echo "Configuring LLVM build ..."

  # Create build directory if not present
  mkdir -p "$LLVM_BUILD_DIR"

  cmake -S "$LLVM_SOURCE_DIR/llvm" \
        -B "$LLVM_BUILD_DIR" \
        -G "Ninja" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL_DIR" \
        -DLLVM_ENABLE_PROJECTS="$TARGET_PROJECTS" \
        -DLLVM_USE_PRECOMPILED_HEADERS=ON
  # Remove or add any other flags as needed.
}

###############################################################################
# Function: build_llvm
# Description: Runs Ninja with nice and ionice to reduce resource contention.
#              Also calculates the number of parallel jobs based on CPU cores.
###############################################################################
build_llvm() {
  # Determine number of logical CPU cores
  local cpu_cores
  cpu_cores=$(nproc)

  echo "Building LLVM using $cpu_cores parallel jobs (with nice + ionice)..."
  # -n 10 => lower scheduling priority (less urgent), preventing system choking
  # -c 2 => best-effort I/O scheduling class
  # -n 7 => lowest priority within that class
  nice -n 10 ionice -c 2 -n 7 ninja -C "$LLVM_BUILD_DIR" -j"$cpu_cores"
}

###############################################################################
# Function: install_llvm
# Description: Installs the built LLVM to the chosen prefix directory.
###############################################################################
install_llvm() {
  echo "Installing LLVM to $LLVM_INSTALL_DIR ..."
  sudo ninja -C "$LLVM_BUILD_DIR" install
}

###############################################################################
# Function: reset_swap
# Description: Removes the temporary swap file if it was created.
###############################################################################
reset_swap() {
  if [ -f "$SWAPFILE" ]; then
    echo "Removing temporary swap file $SWAPFILE ..."
    sudo swapoff "$SWAPFILE" || true
    sudo rm -f "$SWAPFILE"
  fi
}

###############################################################################
# Function: reset_governor
# Description: Resets the CPU frequency governor to 'ondemand' (or your distro's
#              default).
###############################################################################
reset_governor() {
  echo "Resetting CPU governor to ondemand (or default)..."
  sudo cpupower frequency-set -g ondemand || true
}

###############################################################################
# Function: switch_to_graphical_target
# Description: Returns the system to the graphical (GUI) target. 
###############################################################################
switch_to_graphical_target() {
  echo "Switching systemd default back to graphical.target ..."
  sudo systemctl set-default graphical.target

  echo "Isolating graphical.target now..."
  sudo systemctl isolate graphical.target
}

###############################################################################
# Function: main
# Description: Orchestrates the entire process.
###############################################################################
main() {
  # 1. Check prerequisites
  check_prerequisites

  # 2. Switch to multi-user.target to disable graphical environment
  switch_to_multi_user

  # 3. Set CPU governor to performance
  setup_performance_governor

  # 4. Setup swap if needed
  setup_swap

  # 5. Clone LLVM if not present
  clone_llvm

  # 6. Configure LLVM
  configure_llvm_build

  # 7. Build LLVM
  build_llvm

  # 8. Install LLVM
  install_llvm

  # 9. Cleanup: remove swap, reset CPU governor, re-enable GUI
  reset_swap
  reset_governor
  switch_to_graphical_target

  echo "LLVM build and installation completed successfully!"
}

###############################################################################
# Main Entry Point
###############################################################################
main

