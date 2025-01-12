#!/bin/bash

# Display help message
show_help() {
cat << EOF
Usage: build [options]

Options:
  -t, --target DIR    Specify target directories for build and install (comma-separated or space-separated).
  -i, --install       Automatically install after building.
  -h, --help          Display this help and exit.

Examples:
  build --target /path/to/dir1,/path/to/dir2
  build --target /path/to/dir1 /path/to/dir2
  build -t /path/to/dir1 -i
EOF
}

# Function to build the project in a given directory
build_project() {
    local dir="$1"
    echo "Building in directory: $dir"
    mkdir -p "$dir/build"
    cd "$dir/build" || exit 1

    ionice -c3 nice -n 19 bash -c "
    if [ -f ../CMakeLists.txt ]; then
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$HOME/bin\" ..
        cmake --build . --config Release -j$(nproc)
    elif [ -f ../configure ]; then
        ../configure --prefix=\"$HOME/bin\"
        make -j$(nproc)
    elif [ -f ../Makefile ]; then
        make -C .. -j$(nproc)
    elif [ -f ../Cargo.toml ]; then
        cargo build --manifest-path ../Cargo.toml --release
    elif [ -f ../setup.py ]; then
        python ../setup.py build
    elif [ -f ../pyproject.toml ]; then
        python -m pip install -e .. --prefix \"$HOME/bin\"
    elif [ -f ../package.json ]; then
        npm install --prefix .. && npm run build --prefix ..
    elif [ -f ../go.mod ]; then
        go build -o build ../...
    elif [ -f ../Makefile.PL ]; then
        perl ../Makefile.PL
        make
    else
        echo \"No recognizable build system found in $dir. Skipping.\"
        return 1
    fi
    "
    echo "Build completed in $dir"
}

# Function to install the project in a given directory
install_project() {
    local dir="$1"
    echo "Installing from directory: $dir"
    cd "$dir/build" || exit 1

    if [ -f ../CMakeLists.txt ]; then
        make install
    elif [ -f ../configure ]; then
        make install
    elif [ -f ../Makefile ]; then
        make -C .. install
    elif [ -f ../Cargo.toml ]; then
        cargo install --path .. --root "$HOME/bin"
    elif [ -f ../setup.py ]; then
        python ../setup.py install --prefix="$HOME/bin"
    elif [ -f ../pyproject.toml ]; then
        python -m pip install --prefix="$HOME/bin" -e ..
    elif [ -f ../package.json ]; then
        npm install -g .. --prefix "$HOME/bin"
    elif [ -f ../go.mod ]; then
        go install ../...
    elif [ -f ../Makefile.PL ]; then
        make install PREFIX="$HOME/bin"
    else
        echo "No recognizable installation method found in $dir. Skipping."
        return 1
    fi
    echo "Installation completed in $dir"
}

# Parse command-line arguments
target_dirs=""
auto_install=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target)
            target_dirs+="$2 "
            shift 2
            ;;
        -i|--install)
            auto_install=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Invalid option $1"
            show_help
            exit 1
            ;;
    esac
done

if [ -z "$target_dirs" ]; then
    echo "Error: No target directories specified."
    show_help
    exit 1
fi

IFS=', ' read -r -a dirs <<< "$target_dirs"

for dir in "${dirs[@]}"; do
    dir=$(echo "$dir" | xargs) # Trim whitespace
    if [ -d "$dir" ]; then
        build_project "$dir"
        if [ "$auto_install" = true ]; then
            install_project "$dir"
        fi
    else
        echo "Directory $dir does not exist. Skipping."
    fi
done

echo "Build process completed."

