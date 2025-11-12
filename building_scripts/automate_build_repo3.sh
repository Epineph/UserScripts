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
    pushd "$dir" > /dev/null || exit 1

    mkdir -p build
    ionice -c3 nice -n 19 bash -c "
    if [ -f CMakeLists.txt ]; then
        cd build
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=\"$HOME/bin\" ..
        cmake --build . --config Release -j$(nproc)
    elif [ -f configure ]; then
        ./configure --prefix=\"$HOME/bin\"
        make -j$(nproc)
    elif [ -f Makefile ]; then
        make -j$(nproc)
    else
        echo \"No recognizable build system found in $dir. Skipping.\"
        popd > /dev/null
        return 1
    fi
    "
    popd > /dev/null
    echo "Build completed in $dir"
}

# Function to install the project in a given directory
install_project() {
    local dir="$1"
    echo "Installing from directory: $dir"
    pushd "$dir" > /dev/null || exit 1

    if [ -d build ]; then
        cd build
    fi

    if [ -f ../CMakeLists.txt ] || [ -f CMakeLists.txt ]; then
        make install
    elif [ -f ../configure ] || [ -f configure ]; then
        make install
    elif [ -f ../Makefile ] || [ -f Makefile ]; then
        make install
    else
        echo "No recognizable installation method found in $dir. Skipping."
        popd > /dev/null
        return 1
    fi
    popd > /dev/null
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

