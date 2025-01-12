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
    cd "$dir" || exit 1

    ionice -c3 nice -n 19 bash -c "
    if [ -f \"CMakeLists.txt\" ]; then
        cd build || exit 1
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$dir/bin\" ..
        cmake --build . --config Release -j$(nproc)
    elif [ -f \"configure\" ]; then
        ./configure --prefix=\"$dir/bin\"
        make -j$(nproc)
    elif [ -f \"Makefile\" ]; then
        make -j$(nproc)
    elif [ -f \"Cargo.toml\" ]; then
        cargo build --release
    elif [ -f \"setup.py\" ]; then
        python setup.py build
    elif [ -f \"pyproject.toml\" ]; then
        python -m pip install -e . --prefix \"$dir/bin\"
    elif [ -f \"package.json\" ]; then
        npm install && npm run build
    elif [ -f \"go.mod\" ]; then
        go build ./...
    elif [ -f \"Makefile.PL\" ]; then
        perl Makefile.PL
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
    local install_dir="$dir/bin"
    mkdir -p "$install_dir"

    if [ -f "$dir/CMakeLists.txt" ]; then
        cd "$dir/build" || exit 1
        make install
    elif [ -f "$dir/configure" ]; then
        make install
    elif [ -f "$dir/Makefile" ]; then
        make install
    elif [ -f "$dir/Cargo.toml" ]; then
        cargo install --path "$dir" --root "$install_dir"
    elif [ -f "$dir/setup.py" ]; then
        python setup.py install --prefix="$install_dir"
    elif [ -f "$dir/pyproject.toml" ]; then
        python -m pip install --prefix="$install_dir" -e "$dir"
    elif [ -f "$dir/package.json" ]; then
        npm install -g "$dir" --prefix "$install_dir"
    elif [ -f "$dir/go.mod" ]; then
        go install ./... --prefix "$install_dir"
    elif [ -f "$dir/Makefile.PL" ]; then
        make install PREFIX="$install_dir"
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

