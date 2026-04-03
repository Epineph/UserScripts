#!/usr/bin/env bash
# ======================================================================
#  build_repo — Non-interactive project builder & installer
#
#  Behaviour (no flags needed):
#    • If -D/--directory is given, that path is used; otherwise PWD.
#    • For CMake-based projects:
#          – ensures ./build exists
#          – runs CMake (Makefile generator) in Release mode
#          – builds with all CPU cores
#          – installs to $HOME/bin
#    • For other recognised build systems (GNU Autotools, plain Make,
#      Cargo, Python, Node, Go, Perl), the canonical build + install
#      commands are executed.
#    • Exits with a non-zero status if the project cannot be built.
#
#  Usage:
#      build_repo               # build & install current directory
#      build_repo -D /path/to/project
#
#  Author: <your name> — <date>
# ======================================================================

set -euo pipefail # strict-mode Bash
IFS=$'\n\t'

# -------------- Configuration -----------------------------------------
INSTALL_PREFIX="$HOME/bin"
VCPKG_TOOLCHAIN="$HOME/repos/vcpkg/scripts/buildsystems/vcpkg.cmake"
BUILD_DIR="build"
# ----------------------------------------------------------------------

show_help() {
  cat <<EOF
build_repo  –  non-interactive build helper

Options:
  -D, --directory <path>  Build the project located at <path>.
  -h, --help              Show this help message.

All other behaviour is automatic and non-interactive.
EOF
}

# -------- Argument parsing (only -D and -h are accepted) --------------
project_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -D | --directory)
    project_path="$2"
    shift 2
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  *)
    echo "Error: unknown option '$1'"
    show_help
    exit 1
    ;;
  esac
done

# If no path supplied, default to current directory
project_path="${project_path:-$(pwd)}"
cd "$project_path" || {
  echo "Error: cannot cd into '$project_path'"
  exit 1
}

# -------- Helper: generic install dir ---------------------------------
mkdir -p "$INSTALL_PREFIX"

# -------- Build logic --------------------------------------------------
build_project() {
  if [[ -f CMakeLists.txt ]]; then
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    # Configure only if cache does not exist (idempotent)
    [[ -f CMakeCache.txt ]] || cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
      -DCMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" \
      ..
    cmake --build . --config Release -- -j"$(nproc)"
    cmake --install .
  elif [[ -f configure ]]; then
    ./configure --prefix="$INSTALL_PREFIX"
    make -j"$(nproc)"
    make install
  elif [[ -f Makefile ]]; then
    make -j"$(nproc)"
    make install
  elif [[ -f Cargo.toml ]]; then
    cargo install --path . --root "$INSTALL_PREFIX"
  elif [[ -f setup.py ]]; then
    python setup.py build
    python setup.py install --prefix="$INSTALL_PREFIX"
  elif [[ -f pyproject.toml ]]; then
    # Hatch or editable install fallback
    if [[ -f hatch.toml ]]; then
      python -m pip install --quiet hatch
      hatch build -t wheel
      python -m pip install --prefix="$INSTALL_PREFIX" dist/*.whl
    else
      python -m pip install --prefix="$INSTALL_PREFIX" -e .
    fi
  elif [[ -f package.json ]]; then
    if command -v yarn &>/dev/null; then
      yarn install --silent
      yarn build
      yarn global add . --prefix "$INSTALL_PREFIX"
    else
      npm install --silent
      npm run build --silent
      npm install -g . --prefix "$INSTALL_PREFIX" --silent
    fi
  elif [[ -f go.mod ]]; then
    go install ./... --prefix "$INSTALL_PREFIX"
  elif [[ -f Makefile.PL ]]; then
    perl Makefile.PL PREFIX="$INSTALL_PREFIX"
    make
    make install
  else
    echo "Error: no recognised build system in '$project_path'." >&2
    exit 1
  fi
}

# ---------------- Execute ----------------------------------------------
echo "==> Building and installing project in '$project_path' ..."
build_project
echo "==> Done – artefacts installed to '$INSTALL_PREFIX'."
