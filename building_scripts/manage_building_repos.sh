#!/bin/bash

# Display help message
show_help() {
cat << EOF
Usage: manage_build_repos.sh [options]

Options:
  -D, --directory       Specify project directory (default: \$HOME/repos).
  -a, --auto            Use default answers for all prompts.
  -h, --help            Display this help and exit.

Examples:
  manage_build_repos.sh
  manage_build_repos.sh -D /path/to/projects
  manage_build_repos.sh -a
EOF
}

# Function to ask user a yes/no question with a default answer
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

# Function to build the project based on available files
build_project() {
    local dir=$1
    cd "$dir" || return

    if [ -f "CMakeLists.txt" ]; then
        ask_yes_no "Do you want to use cmake?" "y" && {
            mkdir -p build
            cd build || return
            ask_yes_no "Do you want to use Ninja?" "n" && {
                cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/bin -DCMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake ..
                ninja -j$(nproc)
            } || {
                cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/bin -DCMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake ..
                cmake --build . --config Release -j$(nproc)
            }
        }
    elif [ -f "configure" ]; then
        ./configure --prefix=$HOME/bin
        make -j$(nproc)
    elif [ -f "Makefile" ]; then
        make -j$(nproc)
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
            yarn install
            yarn build
        elif command -v npm &> /dev/null; then
            npm install
            npm run build
        fi
    elif [ -f "go.mod" ]; then
        go build ./...
    elif [ -f "Makefile.PL" ]; then
        perl Makefile.PL
        make
    else
        echo "No recognizable build system found in $dir."
        return 1
    fi
}

# Function to install the project based on available files to $HOME/bin
install_project() {
    local dir=$1
    cd "$dir" || return

    local install_dir="$HOME/bin"
    mkdir -p "$install_dir"

    if [ -f "CMakeLists.txt" ]; then
        cd build || return
        make install
    elif [ -f "configure" ]; then
        make install
    elif [ -f "Makefile" ]; then
        make install
    elif [ -f "Cargo.toml" ]; then
        cargo install --path . --root "$install_dir"
        mv "$install_dir/bin/"* "$install_dir/"
        rmdir "$install_dir/bin"
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
        mv "$install_dir/bin/"* "$install_dir/"
        rmdir "$install_dir/bin"
    elif [ -f "go.mod" ]; then
        go install ./... --prefix "$install_dir"
        mv "$install_dir/bin/"* "$install_dir/"
        rmdir "$install_dir/bin"
    elif [ -f "Makefile.PL" ]; then
        make install PREFIX="$install_dir"
    else
        echo "No recognizable installation method found in $dir."
        return 1
    fi
}

# Function to select repositories using FZF
select_repos() {
    local repos=()
    while true; do
        repo=$(find "$project_path" -mindepth 1 -maxdepth 1 -type d | fzf --multi --prompt "Select repositories (press Enter to proceed, Ctrl+C to finish):")
        [ -z "$repo" ] && break
        repos+=("$repo")
    done
    echo "${repos[@]}"
}

# Default values
project_path="$HOME/repos"
auto_mode=false

# Parse command-line arguments
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
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Invalid option"
            show_help
            exit 1
            ;;
    esac
done

# Select repositories
selected_repos=($(select_repos))

# Iterate over each selected repository and build
for repo in "${selected_repos[@]}"; do
    echo "Building $repo..."
    build_project "$repo"
    ask_yes_no "Do you want to install the build in $repo?" "y" && install_project "$repo"
done

# Ask to prepend build path to PATH variable in .zshrc
ask_yes_no "Do you want to prepend the build path to your PATH variable in .zshrc?" "n" && {
    build_path=$(pwd)
    sed -i "1iexport PATH=$build_path:\$PATH" ~/.zshrc
    echo "Updated PATH in .zshrc"
}

echo "Build process completed."

