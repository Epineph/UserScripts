#!/usr/bin/env bash
#
# build_proj — build, install, and optionally register a dummy pacman package
#
# Usage:
#   build_proj [options]
#
# Options:
#   -D, --directory       Specify project directory (default: current directory).
#   -a, --auto            Use default answers for all prompts.
#   -i, --install         Automatically install after building.
#   -F, --fake-pkg        After install, register a dummy pacman package so
#                         pacman thinks the real package is installed.
#   -h, --help            Display this help and exit.
#
# Examples:
#   build_proj
#   build_proj -D /path/to/project -i
#   build_proj -i -F
#

set -euo pipefail

# ----------------------------------------------------------------------------
# 1) Show help
# ----------------------------------------------------------------------------
show_help() {
  cat << EOF
Usage: build_proj [options]

Options:
  -D, --directory       Specify project directory (default: current directory).
  -a, --auto            Use default answers for all prompts.
  -i, --install         Automatically install after building.
  -F, --fake-pkg        After install, register a dummy pacman package so
                        pacman thinks the real package is installed.
  -h, --help            Display this help and exit.
EOF
}

# ----------------------------------------------------------------------------
# 2) Prompt helper: yes/no with default
# ----------------------------------------------------------------------------
ask_yes_no() {
  local question="$1"
  local default_answer="$2"
  local yn

  if [ "$auto_mode" = true ]; then
    yn=$default_answer
  else
    while true; do
      read -p "$question (y/n): " yn
      yn=${yn:-$default_answer}
      case $yn in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) echo "Please answer y or n." ;;
      esac
    done
  fi
}

# ----------------------------------------------------------------------------
# 3) Prompt helper: get project path
# ----------------------------------------------------------------------------
get_project_path() {
  read -p "Enter the project path (leave blank for current directory): " project_path
  if [ -z "$project_path" ]; then
    project_path=$(pwd)
  fi
  echo "Using project path: $project_path"
}

# ----------------------------------------------------------------------------
# 4) Defaults & flags
# ----------------------------------------------------------------------------
project_path=""
auto_mode=false
auto_install=false
fake_pkg=false

# ----------------------------------------------------------------------------
# 5) Parse command-line arguments
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    -D|--directory)
      project_path="$2"
      shift 2
      ;;
    -a|--auto)
      auto_mode=true
      shift
      ;;
    -i|--install)
      auto_install=true
      auto_mode=true   # install implies auto_mode
      shift
      ;;
    -F|--fake-pkg)
      fake_pkg=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: Invalid option '$1'" >&2
      show_help
      exit 1
      ;;
  esac
done

# ----------------------------------------------------------------------------
# 6) Validate or ask for project directory
# ----------------------------------------------------------------------------
if [ -z "$project_path" ]; then
  ask_yes_no "Are you in the project directory you want to build?" "y" && \
    project_path=$(pwd) || get_project_path
fi

if [ ! -d "$project_path" ]; then
  echo "Error: Directory '$project_path' does not exist." >&2
  exit 1
fi

cd "$project_path"

# ----------------------------------------------------------------------------
# 7) Build logic
# ----------------------------------------------------------------------------
build_project() {
  if [ -f "CMakeLists.txt" ]; then
    ask_yes_no "Use CMake?" "y" && {
      mkdir -p build && cd build
      ask_yes_no "Use Ninja?" "n" && \
        cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/bin" .. && ninja -j"$(nproc)" || \
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/bin" .. && cmake --build . --config Release -j"$(nproc)"
      cd "$project_path"
    }
  elif [ -f "configure" ]; then
    ./configure --prefix="$HOME/bin" && make -j"$(nproc)"
  elif [ -f "Makefile" ]; then
    make -j"$(nproc)"
  elif [ -f "Cargo.toml" ]; then
    cargo build
  elif [ -f "setup.py" ]; then
    python setup.py build
  elif [ -f "pyproject.toml" ]; then
    if [ -f "hatch.toml" ]; then
      python -m pip install hatch
      hatch build -t wheel
      python -m pip install dist/*.whl
    else
      python -m pip install -e .
    fi
  elif [ -f "package.json" ]; then
    if command -v yarn &> /dev/null; then
      yarn install && yarn build
    else
      npm install && npm run build
    fi
  elif [ -f "go.mod" ]; then
    go build ./...
  elif [ -f "Makefile.PL" ]; then
    perl Makefile.PL && make
  else
    echo "No recognizable build system found." >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# 8) Install logic
# ----------------------------------------------------------------------------
install_project() {
  local install_dir="$HOME/bin"
  mkdir -p "$install_dir"

  if [ -f "CMakeLists.txt" ]; then
    cd build && make install && cd "$project_path"
  elif [ -f "configure" ] || [ -f "Makefile" ]; then
    make install
  elif [ -f "Cargo.toml" ]; then
    cargo install --path . --root "$install_dir"
    mv "$install_dir/bin/"* "$install_dir/" && rmdir "$install_dir/bin"
  elif [ -f "setup.py" ]; then
    python setup.py install --prefix="$install_dir"
  elif [ -f "pyproject.toml" ]; then
    python -m pip install --prefix="$install_dir" -e .
  elif [ -f "package.json" ]; then
    ( command -v yarn &> /dev/null && yarn global add . --prefix "$install_dir" || npm install -g . --prefix "$install_dir" )
    mv "$install_dir/bin/"* "$install_dir/" && rmdir "$install_dir/bin"
  elif [ -f "go.mod" ]; then
    go install ./... --prefix "$install_dir"
    mv "$install_dir/bin/"* "$install_dir/" && rmdir "$install_dir/bin"
  elif [ -f "Makefile.PL" ]; then
    make install PREFIX="$install_dir"
  else
    echo "No recognizable installation method found." >&2
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# 9) Build then (optionally) install
# ----------------------------------------------------------------------------
build_project

if [ "$auto_install" = true ]; then
  install_project
else
  ask_yes_no "Do you want to install the build?" "y" && install_project
fi

# ----------------------------------------------------------------------------
# 10) If requested, register a “fake” pacman package
# ----------------------------------------------------------------------------
if [ "$fake_pkg" = true ]; then
  pkgname="$(basename "$project_path")"

  cat <<EOF > PKGBUILD
pkgname=${pkgname}-dead
pkgver=0.0.1
pkgrel=1
pkgdesc="Dummy package for ${pkgname} (no files)"
arch=('any')
provides=('${pkgname}')
conflicts=('${pkgname}')
license=('none')
source=()
sha256sums=()

package() {
  # Intentionally empty: this dummy package owns no files
  :
}
EOF

  makepkg -fci --noconfirm
  echo "✔ Registered dummy package '${pkgname}-dead' in pacman database."
fi

echo "✔ Build process completed."

