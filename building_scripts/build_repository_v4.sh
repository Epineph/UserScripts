#!/bin/bash

###############################################################################
# A script to build and optionally install projects with various build systems.
# Supports auto mode, custom project directories, and installation.
# Includes robust error handling, logging, and user-friendly features.
###############################################################################

# Logging setup
LOGFILE="$(pwd)/build.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Logging to $LOGFILE"

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
RESET="\033[0m"

# Function to display help message
show_help() {
    bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme-light="Dracula" << EOF
Usage: build_repo [options]

Options:
  -D, --directory       Specify project directory (default: current directory).
  -j, --jobs            Specify the number of parallel jobs (default: all cores).
  -a, --auto            Use default answers for all prompts.
  -i, --install         Automatically install after building.
  --no-path             Skip appending the build path to .zshrc.
  -h, --help            Display this help and exit.

Examples:
  build_repo
  build_repo -D /path/to/project
  build_repo -a -i
  build_repo -j 4 --no-path

Logs are written to build.log in the current directory.
EOF
}

# Function to ask a yes/no question with a default answer
ask_yes_no() {
    local question="$1"
    local default_answer="$2"

    if [ "$auto_mode" = true ]; then
        yn=$default_answer
    else
        while true; do
            read -p "$question (y/n): " yn
            yn=${yn:-$default_answer}
            case $yn in
                [Yy]* ) return 0;;
                [Nn]* ) return 1;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi
}

# Function to check dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${RESET}"
    local deps=("cmake" "ninja" "make" "cargo" "python" "go")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "${RED}Error: $dep is not installed. Install it and try again.${RESET}"
            exit 1
        fi
    done
    echo -e "${GREEN}All required dependencies are installed.${RESET}"
}

# Function to get the project directory
get_project_directory() {
    if [ -z "$project_path" ]; then
        ask_yes_no "Are you in the project directory you want to build?" "y" || {
            read -p "Enter the project path (leave blank to use current directory): " project_path
            project_path=${project_path:-$(pwd)}
        }
    fi
    cd "$project_path" || { echo -e "${RED}Error: Unable to access $project_path.${RESET}"; exit 1; }
    echo "Using project directory: $project_path"
}

# Function to create or use a build directory
prepare_build_directory() {
    if [ -d "build" ];then
        ask_yes_no "Build directory already exists. Do you want to build from there?" "y" || rm -rf build
    else
        ask_yes_no "Do you want to create a build directory?" "y" && mkdir -p build
    fi
}

# Function to build the project
build_project() {
    echo -e "${YELLOW}Starting the build process...${RESET}"
    if [ -f "CMakeLists.txt" ]; then
        echo "Detected CMake build system."
        prepare_build_directory
        cd build || exit 1
        ask_yes_no "Do you want to use Ninja?" "n" && {
            cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/bin ..
            ninja -j"$parallel_jobs"
        } || {
            cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/bin ..
            cmake --build . --config Release -j"$parallel_jobs"
        }
    elif [ -f "configure" ]; then
        echo "Detected Autotools build system."
        ./configure --prefix=$HOME/bin
        make -j"$parallel_jobs"
    elif [ -f "Makefile" ]; then
        echo "Detected Makefile build system."
        make -j"$parallel_jobs"
    elif [ -f "Cargo.toml" ]; then
        echo "Detected Rust/Cargo build system."
        cargo build
    elif [ -f "setup.py" ]; then
        echo "Detected Python setuptools."
        python setup.py build
    elif [ -f "pyproject.toml" ]; then
        echo "Detected Python pyproject.toml."
        if [ -f "hatch.toml" ]; then
            python -m pip install hatch
            hatch build -t wheel
            python -m pip install dist/*.whl
        else
            python -m pip install -e .
        fi
    elif [ -f "package.json" ]; then
        echo "Detected Node.js package.json."
        if command -v yarn &> /dev/null; then
            yarn install && yarn build
        elif command -v npm &> /dev/null; then
            npm install && npm run build
        fi
    elif [ -f "go.mod" ]; then
        echo "Detected Go module."
        go build ./...
    elif [ -f "Makefile.PL" ]; then
        echo "Detected Perl Makefile.PL."
        perl Makefile.PL
        make
    else
        echo -e "${RED}No recognizable build system found.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Build completed successfully!${RESET}"
}

# Function to install the project
install_project() {
    echo -e "${YELLOW}Starting the installation process...${RESET}"
    local install_dir="$HOME/bin"
    mkdir -p "$install_dir"

    if [ -f "CMakeLists.txt" ]; then
        cd build || exit 1
        make install
    elif [ -f "configure" ]; then
        make install
    elif [ -f "Makefile" ]; then
        make install
    elif [ -f "Cargo.toml" ]; then
        cargo install --path . --root "$install_dir"
    elif [ -f "setup.py" ]; then
        python setup.py install --prefix="$install_dir"
    elif [ -f "pyproject.toml" ]; then
        python -m pip install --prefix="$install_dir" -e .
    elif [ -f "package.json" ]; then
        if command -v yarn &> /dev/null; then
            yarn global add . --prefix "$install_dir"
        elif command -v npm &> /dev/null; then
            npm install -g . --prefix "$install_dir"
        fi
    elif [ -f "go.mod" ]; then
        go install ./... --prefix "$install_dir"
    elif [ -f "Makefile.PL" ]; then
        make install PREFIX="$install_dir"
    else
        echo -e "${RED}No recognizable installation method found.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Installation completed successfully!${RESET}"
}

# Main script logic
auto_mode=false
auto_install=false
skip_path_append=false
project_path=""
parallel_jobs=$(nproc)

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -D|--directory)
            project_path="$2"
            shift 2
            ;;
        -j|--jobs)
            parallel_jobs="$2"
            shift 2
            ;;
        -a|--auto)
            auto_mode=true
            shift
            ;;
        -i|--install)
            auto_install=true
            auto_mode=true
            shift
            ;;
        --no-path)
            skip_path_append=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Invalid option $1${RESET}"
            show_help
            exit 1
            ;;
    esac
done

# Execute the workflow
check_dependencies
get_project_directory
build_project

# Handle PATH modification if not skipped
if [ "$skip_path_append" != true ]; then
    if [ "$auto_install" != true ]; then
        ask_yes_no "Do you want to prepend the build path to your PATH variable in .zshrc?" "n" && {
            build_path=$(pwd)
            if ! grep -q "export PATH=$build_path" ~/.zshrc; then
                echo "export PATH=$build_path:\$PATH" >> ~/.zshrc
                echo "Updated PATH in .zshrc"
            fi
        }
    fi
fi

# Install if requested
if [ "$auto_install" = true ]; then
    install_project
else
    ask_yes_no "Do you want to install the build?" "y" && install_project
fi

echo -e "${GREEN}Build process completed successfully!${RESET}"

