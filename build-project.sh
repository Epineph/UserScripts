#!/usr/bin/env bash
# =============================================================================
#  build_repo — non-interactive builder & installer (with Ninja & ionice)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
#  Defaults
# -----------------------------------------------------------------------------
INSTALL_PREFIX="$HOME/bin"
VCPKG_TOOLCHAIN="$HOME/repos/vcpkg/scripts/buildsystems/vcpkg.cmake"
BUILD_DIR="build"

# -----------------------------------------------------------------------------
#  Detect ionice and store for correct splitting
# -----------------------------------------------------------------------------
if command -v ionice &>/dev/null; then
  IONICE_CMD=(ionice -c2 -n0)
else
  IONICE_CMD=()
fi

# -----------------------------------------------------------------------------
#  run_cmd: prefix with ionice if present
# -----------------------------------------------------------------------------
run_cmd() {
  "${IONICE_CMD[@]}" "$@"
}

# -----------------------------------------------------------------------------
#  Help text
# -----------------------------------------------------------------------------
show_help() {
  cat <<EOF
build_repo — build & install helper

Usage:
  build_repo [ -D <path> ] [ -n | --ninja ] [ -h | --help ]

Options:
  -D, --directory <path>   Project directory (default: \$PWD)
  -n, --ninja              Force CMake Ninja generator
  -h, --help               Show this message
EOF
}

# -----------------------------------------------------------------------------
#  Parse arguments
# -----------------------------------------------------------------------------
project_path=""
USE_NINJA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  -D | --directory)
    project_path="$2"
    shift 2
    ;;
  -n | --ninja)
    USE_NINJA=true
    shift
    ;;
  -h | --help)
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

project_path="${project_path:-$(pwd)}"
cd "$project_path"

mkdir -p "$INSTALL_PREFIX"

# -----------------------------------------------------------------------------
#  Build logic
# -----------------------------------------------------------------------------
build_project() {
  # --- CMake projects ---
  if [[ -f CMakeLists.txt ]]; then
    # if forcing Ninja, wipe old build dir so CMake reconfigures
    if $USE_NINJA && [[ -d "$BUILD_DIR" ]]; then
      echo "==> -n passed: clearing '$BUILD_DIR' to reconfigure with Ninja"
      rm -rf "$BUILD_DIR"
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # pick the generator
    if $USE_NINJA && command -v ninja &>/dev/null; then
      GENERATOR="Ninja"
    else
      GENERATOR="Unix Makefiles"
    fi

    # configure
    run_cmd cmake -G "$GENERATOR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
      -DCMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" \
      ..

    # build & install
    if [[ "$GENERATOR" == "Ninja" ]]; then
      run_cmd ninja -j"$(nproc)"
      run_cmd ninja install
    else
      run_cmd cmake --build . --parallel "$(nproc)"
      run_cmd cmake --build . --target install --parallel
    fi

    return
  fi

  # --- Autotools ---
  if [[ -f configure ]]; then
    run_cmd ./configure --prefix="$INSTALL_PREFIX"
    run_cmd make -j"$(nproc)"
    run_cmd make install
    return
  fi

  # --- Simple Makefile ---
  if [[ -f Makefile ]]; then
    run_cmd make -j"$(nproc)"
    run_cmd make install
    return
  fi

  # --- Rust / Cargo ---
  if [[ -f Cargo.toml ]]; then
    run_cmd cargo install --path . --root "$INSTALL_PREFIX"
    return
  fi

  # --- Python setup.py ---
  if [[ -f setup.py ]]; then
    run_cmd python setup.py build
    run_cmd python setup.py install --prefix="$INSTALL_PREFIX"
    return
  fi

  # --- PEP 517/518 (pyproject.toml) ---
  if [[ -f pyproject.toml ]]; then
    if [[ -f hatch.toml ]]; then
      run_cmd python -m pip install --quiet hatch
      run_cmd hatch build -t wheel
      run_cmd python -m pip install --prefix="$INSTALL_PREFIX" dist/*.whl
    else
      run_cmd python -m pip install --prefix="$INSTALL_PREFIX" -e .
    fi
    return
  fi

  # --- Node.js ---
  if [[ -f package.json ]]; then
    if command -v yarn &>/dev/null; then
      run_cmd yarn install --silent
      run_cmd yarn build
      run_cmd yarn global add . --prefix "$INSTALL_PREFIX"
    else
      run_cmd npm install --silent
      run_cmd npm run build --silent
      run_cmd npm install -g . --prefix "$INSTALL_PREFIX" --silent
    fi
    return
  fi

  # --- Go ---
  if [[ -f go.mod ]]; then
    run_cmd go install ./... --prefix "$INSTALL_PREFIX"
    return
  fi

  # --- Perl ---
  if [[ -f Makefile.PL ]]; then
    run_cmd perl Makefile.PL PREFIX="$INSTALL_PREFIX"
    run_cmd make
    run_cmd make install
    return
  fi

  echo "Error: no recognized build system in '$project_path'." >&2
  exit 1
}

# -----------------------------------------------------------------------------
#  Run it
# -----------------------------------------------------------------------------
echo "==> Building and installing project in '$project_path' ..."
build_project
echo "==> Done — artefacts in '$INSTALL_PREFIX'."
