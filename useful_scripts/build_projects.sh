#!/usr/bin/env bash
# building_repository_v2.sh
#
# Description:
#   This script automates building (and optionally installing) projects from source.
#   It detects common build systems (CMake, configure/Makefile, Cargo, Python, etc.)
#   and uses default options unless overridden.
#
#   It can either build a single repository (using -D) or, with the -U flag, loop over
#   all subdirectories (assumed to be Git repos) in a parent directory—pulling changes and
#   building each in sequence.
#
#   It also forces an SSH key refresh (via sshkey_timer) for at least 1 hour (3600 seconds)
#   when the corresponding option is given (or automatically in auto mode).
#
# Usage:
#   $(basename "$0") [options]
#
# Options:
#   -D, --directory    Specify project directory (default: current directory).
#   -U, --update-all   Loop over every subdirectory of the project directory,
#                      updating (git pull) and building each repository.
#   -a, --auto         Use default answers for all prompts (noninteractive).
#   -i, --install      Automatically install after building.
#   -S, --force-ssh    Force ssh-key-timer to run with a 1-hour timeout.
#   -h, --help         Display this help message and exit.
#
# Examples:
#   $(basename "$0")
#   $(basename "$0") -D /path/to/project -i
#   $(basename "$0") -a -U -S
#

# Exit on error, treat unset variables as errors, and propagate pipe errors.
set -euo pipefail

###############################################################################
# Functions
###############################################################################

# Display help message.
show_help() {
  cat << EOF
Usage: $(basename "$0") [options]

Options:
  -D, --directory    Specify project directory (default: current directory).
  -U, --update-all   Loop over each subdirectory (Git repository) and update/build.
  -a, --auto         Use default answers for all prompts (noninteractive).
  -i, --install      Automatically install after building.
  -S, --force-ssh    Force ssh-key-timer with a 1-hour timeout.
  -h, --help         Display this help and exit.

Examples:
  $(basename "$0")
  $(basename "$0") -D /path/to/project -i
  $(basename "$0") -a -U -S
EOF
}

# Prompt for a yes/no answer; returns 0 for yes and 1 for no.
# Usage: ask_yes_no "Question" "default"   (default is "y" or "n")
ask_yes_no() {
  local question="$1"
  local default_answer="$2"
  local yn

  if [[ "${auto_mode}" == true ]]; then
    yn="$default_answer"
  else
    while true; do
      read -r -p "$question (y/n): " yn
      yn=${yn:-$default_answer}
      case "$yn" in
        [Yy]* ) return 0 ;;
        [Nn]* ) return 1 ;;
        * ) echo "Please answer yes or no." ;;
      esac
    done
  fi
  return 1
}

# Prompt for a project directory if none is specified.
get_project_path() {
  read -r -p "Enter the project path (leave blank to use current directory): " project_path
  if [[ -z "$project_path" ]]; then
    project_path="$(pwd)"
  fi
  if ! cd "$project_path"; then
    echo "Error: Cannot change directory to '$project_path'."
    exit 1
  fi
  echo "Using project path: $(pwd)"
}

# Force ssh-key timer for at least one hour (3600 seconds) by starting or refreshing ssh-agent.
sshkey_timer() {
  local total_seconds=3600  # One hour
  # Parse options for sshkey_timer if needed in future.
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -t "$total_seconds")"
  fi
  # Force-add the SSH key (adjust the key file as needed)
  if ssh-add "$HOME/.ssh/id_rsa" 2>/dev/null; then
    echo "SSH key added with a timeout of ${total_seconds} seconds."
  else
    echo "Error: Failed to add SSH key." >&2
    return 1
  fi
}

# Build the project in the current directory based on detected build system.
build_project() {
  if [[ -f "CMakeLists.txt" ]]; then
    if ask_yes_no "Use CMake for building?" "y"; then
      # Change into build directory if it exists.
      if [[ -d "build" ]]; then
        cd build || exit 1
      else
        mkdir -p build && cd build || exit 1
      fi
      if ask_yes_no "Use Ninja as generator?" "n"; then
        cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$HOME/bin" \
          -DCMAKE_TOOLCHAIN_FILE="$HOME/repos/vcpkg/scripts/buildsystems/vcpkg.cmake" ..
        ninja -j"$(nproc)"
      else
        cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$HOME/bin" \
          -DCMAKE_TOOLCHAIN_FILE="$HOME/repos/vcpkg/scripts/buildsystems/vcpkg.cmake" ..
        cmake --build . --config Release -j"$(nproc)"
      fi
    fi
  elif [[ -f "configure" ]]; then
    ./configure --prefix="$HOME/bin"
    make -j"$(nproc)"
  elif [[ -f "Makefile" ]]; then
    make -j"$(nproc)"
  elif [[ -f "Cargo.toml" ]]; then
    cargo build
  elif [[ -f "setup.py" ]]; then
    python setup.py build
  elif [[ -f "pyproject.toml" ]]; then
    if [[ -f "hatch.toml" ]]; then
      python -m pip install hatch
      hatch build -t wheel
      python -m pip install dist/*.whl
    else
      python -m pip install -e .
    fi
  elif [[ -f "package.json" ]]; then
    if command -v yarn &>/dev/null; then
      yarn install
      yarn build
    elif command -v npm &>/dev/null; then
      npm install
      npm run build
    else
      echo "No package manager (yarn or npm) found." && exit 1
    fi
  elif [[ -f "go.mod" ]]; then
    go build ./...
  elif [[ -f "Makefile.PL" ]]; then
    perl Makefile.PL
    make
  else
    echo "No recognizable build system found." && exit 1
  fi
}

# Install the project to $HOME/bin.
install_project() {
  local install_dir="$HOME/bin"
  mkdir -p "$install_dir"
  
  if [[ -f "CMakeLists.txt" ]]; then
    cd build || exit 1
    make install
  elif [[ -f "configure" ]]; then
    make install
  elif [[ -f "Makefile" ]]; then
    make install
  elif [[ -f "Cargo.toml" ]]; then
    cargo install --path . --root "$install_dir"
    if [[ -d "$install_dir/bin" ]]; then
      mv "$install_dir/bin/"* "$install_dir/"
      rmdir "$install_dir/bin"
    fi
  elif [[ -f "setup.py" ]]; then
    python setup.py install --prefix="$install_dir"
  elif [[ -f "pyproject.toml" ]]; then
    python -m pip install --prefix="$install_dir" -e .
  elif [[ -f "package.json" ]]; then
    if command -v yarn &>/dev/null; then
      yarn global add . --prefix "$install_dir"
    elif command -v npm &>/dev/null; then
      npm install -g . --prefix "$install_dir"
    fi
    if [[ -d "$install_dir/bin" ]]; then
      mv "$install_dir/bin/"* "$install_dir/"
      rmdir "$install_dir/bin"
    fi
  elif [[ -f "go.mod" ]]; then
    go install ./... --prefix "$install_dir"
    if [[ -d "$install_dir/bin" ]]; then
      mv "$install_dir/bin/"* "$install_dir/"
      rmdir "$install_dir/bin"
    fi
  elif [[ -f "Makefile.PL" ]]; then
    make install PREFIX="$install_dir"
  else
    echo "No recognizable installation method found." && exit 1
  fi
}

# Update (git pull) and build every Git repository found in the given parent directory.
update_and_build_all() {
  local parent_dir="$1"
  local current_dir
  current_dir="$(pwd)"
  echo "Updating and building repositories under: $parent_dir"
  for repo in "$parent_dir"/*/ ; do
    if [[ -d "$repo/.git" ]]; then
      echo "----------------------------------------"
      echo "Updating repository: $repo"
      cd "$repo" || continue
      # Update the repository noninteractively.
      git stash -q && git checkout -q && git pull -q
      # Mark the repository as safe (if needed)
      git config --global --add safe.directory "$repo"
      echo "Building repository: $repo"
      build_project
      cd "$parent_dir" || exit 1
    else
      echo "Skipping non-Git folder: $repo"
    fi
  done
  cd "$current_dir" || exit 1
}

###############################################################################
# Main Script: Parse Options and Execute
###############################################################################

# Default options.
project_path=""
auto_mode=false
auto_install=false
update_all=false
force_ssh=false

# Parse command-line arguments.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -D|--directory)
      project_path="$2"
      shift 2
      ;;
    -U|--update-all)
      update_all=true
      shift
      ;;
    -a|--auto)
      auto_mode=true
      shift
      ;;
    -i|--install)
      auto_install=true
      auto_mode=true  # Force auto mode when install is specified.
      shift
      ;;
    -S|--force-ssh)
      force_ssh=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: Invalid option '$1'."
      show_help
      exit 1
      ;;
  esac
done

# If force_ssh is enabled (or auto_mode is true), force ssh-key timer.
if [[ "$force_ssh" == true || "$auto_mode" == true ]]; then
  sshkey_timer -t 3600
fi

# Determine project directory.
if [[ -z "$project_path" ]]; then
  # If not provided, ask the user (unless in auto mode, then use current directory).
  if [[ "$auto_mode" == true ]]; then
    project_path="$(pwd)"
  else
    if ask_yes_no "Are you already in the project directory you want to build?" "y"; then
      project_path="$(pwd)"
    else
      get_project_path
      project_path="$(pwd)"
    fi
  fi
else
  if ! cd "$project_path"; then
    echo "Error: Cannot change directory to '$project_path'."
    exit 1
  fi
fi

echo "Project path: $(pwd)"

# If update_all is specified, loop over subdirectories.
if [[ "$update_all" == true ]]; then
  update_and_build_all "$(pwd)"
  exit 0
fi

# Otherwise, prompt (unless auto mode) about creating/using a build directory.
if [[ -d "build" ]]; then
  ask_yes_no "Build directory already exists. Build from it?" "y" || \
    echo "Continuing in the current directory."
else
  if ask_yes_no "No build directory found. Create one?" "y"; then
    mkdir -p build
    echo "Created build directory."
  fi
fi

# Build the project.
build_project

# Optionally update PATH in ~/.zshrc (unless auto_install is true).
if [[ "$auto_install" != true ]]; then
  if ask_yes_no "Prepend the current build path ($(pwd)) to your PATH in ~/.zshrc?" "n"; then
    # Prepend the current build path to the beginning of ~/.zshrc.
    sed -i "1iexport PATH=$(pwd):\$PATH" "$HOME/.zshrc"
    echo "Updated PATH in ~/.zshrc."
  fi
fi

# Install the project if requested.
if [[ "$auto_install" == true ]]; then
  install_project
else
  if ask_yes_no "Install the build?" "y"; then
    install_project
  fi
fi

echo "Build process completed."

