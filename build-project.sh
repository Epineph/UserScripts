#!/usr/bin/env bash
# =============================================================================
#  build_repo — Non-interactive project builder & installer (with ionice & Ninja)
#
#  Behaviour:
#    • Use -D/--directory to set project path (defaults to $PWD).
#    • Use -n/--ninja to force Ninja generator (if installed).
#    • Detects CMake projects, Autotools, Make, Cargo, Python, Node, Go, Perl.
#    • Applies ionice (best-effort, highest priority) if available to speed I/O.
#    • Builds with all CPU cores and installs to $HOME/bin.
#    • Exits non-zero on failure.
#
#  Usage:
#      build_repo [ -D <path> ] [ -n | --ninja ] [ -h | --help ]
#
#  Author: <your name> — <date>
# =============================================================================

set -euo pipefail    # strict-mode Bash
IFS=$'\n\t'

# -------------- Configuration Defaults --------------------------------------
INSTALL_PREFIX="$HOME/bin"
VCPKG_TOOLCHAIN="$HOME/repos/vcpkg/scripts/buildsystems/vcpkg.cmake"
BUILD_DIR="build"

#  Detect and configure ionice (best-effort, highest-priority I/O)
if command -v ionice &>/dev/null; then
  IONICE_CMD="ionice -c2 -n0"
else
  IONICE_CMD=""
fi

# -------------- Help & Usage ------------------------------------------------
show_help() {
  cat <<EOF
build_repo — non-interactive build helper

Options:
  -D, --directory <path>   Build the project located at <path>.
  -n, --ninja              Use Ninja generator (falls back to Unix Makefiles).
  -h, --help               Show this help message.
EOF
}

# -------- Argument parsing: -D, -n/--ninja, -h/--help ------------------------
project_path=""
USE_NINJA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -D|--directory)
      project_path="$2"
      shift 2
      ;;
    -n|--ninja)
      USE_NINJA=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      show_help
      exit 1
      ;;
  esac
done

# Default to current directory if none supplied
project_path="${project_path:-$(pwd)}"
cd "$project_path" || {
  echo "Error: cannot cd into '$project_path'" >&2
  exit 1
}

# Ensure install prefix exists
mkdir -p "$INSTALL_PREFIX"

# -------- Build logic -------------------------------------------------------
build_project() {
  # CMake-based projects
  if [[ -f CMakeLists.txt ]]; then
    # Choose generator: Ninja if requested & installed, else Makefiles
    if $USE_NINJA && command -v ninja &>/dev/null; then
      GENERATOR="Ninja"
    else
      GENERATOR="Unix Makefiles"
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configure (only once)
    if [[ ! -f CMakeCache.txt ]]; then
      $IONICE_CMD cmake -G "$GENERATOR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DCMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" \
        ..
    fi

    # Build (parallel across all cores)
    $IONICE_CMD cmake --build . --parallel "$(nproc)"

    # Install
    $IONICE_CMD cmake --build . --target install --parallel
    return
  fi

  # Autotools
  if [[ -f configure ]]; then
    $IONICE_CMD ./configure --prefix="$INSTALL_PREFIX"
    $IONICE_CMD make -j"$(nproc)"
    $IONICE_CMD make install
    return
  fi

  # Simple Makefile
  if [[ -f Makefile ]]; then
    $IONICE_CMD make -j"$(nproc)"
    $IONICE_CMD make install
    return
  fi

  # Cargo (Rust)
  if [[ -f Cargo.toml ]]; then
    $IONICE_CMD cargo install --path . --root "$INSTALL_PREFIX"
    return
  fi

  # Python setup.py
  if [[ -f setup.py ]]; then
    python setup.py build
    python setup.py install --prefix="$INSTALL_PREFIX"
    return
  fi

  # PEP 517/518 projects
  if [[ -f pyproject.toml ]]; then
    if [[ -f hatch.toml ]]; then
      python -m pip install --quiet hatch
      hatch build -t wheel
      python -m pip install --prefix="$INSTALL_PREFIX" dist/*.whl
    else
      python -m pip install --prefix="$INSTALL_PREFIX" -e .
    fi
    return
  fi

  # Node.js
  if [[ -f package.json ]]; then
    if command -v yarn &>/dev/null; then
      $IONICE_CMD yarn install --silent
      $IONICE_CMD yarn build
      $IONICE_CMD yarn global add . --prefix "$INSTALL_PREFIX"
    else
      $IONICE_CMD npm install --silent
      $IONICE_CMD npm run build --silent
      $IONICE_CMD npm install -g . --prefix "$INSTALL_PREFIX" --silent
    fi
    return
  fi

  # Go modules
  if [[ -f go.mod ]]; then
    $IONICE_CMD go install ./... --prefix "$INSTALL_PREFIX"
    return
  fi

  # Perl Makefile.PL
  if [[ -f Makefile.PL ]]; then
    $IONICE_CMD perl Makefile.PL PREFIX="$INSTALL_PREFIX"
    $IONICE_CMD make
    $IONICE_CMD make install
    return
  fi

  # No recognized build system
  echo "Error: no recognised build system in '$project_path'." >&2
  exit 1
}

# ------------------------ Execute -------------------------------------------
echo "==> Building and installing project in '$project_path' ..."
build_project
echo "==> Done — artefacts installed to '$INSTALL_PREFIX'."

