#!/bin/bash

# Display help message
show_help() {
cat << EOF
Usage: clone [options] <repository_url_or_name>

Options:
  -G, --git             Clone a Git repository (default behavior).
  -A, --aur             Clone an AUR package.
  -D, --directory       Specify destination directory (default: \$REPOS or current directory).
  -T, --tar             Download the .tar.gz for AUR package.
  -B, --build-pkg       Build the package after cloning.
  -I, --install         Install the package after building.
  -h, --help            Display this help and exit.

Examples:
  clone -G https://github.com/user/repo
  clone -A https://aur.archlinux.org/package
  clone -A package_name -T
  clone -G user/repo -D /path/to/dir -B -I
EOF
}

# Function to ask user a yes/no question
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Default values
REPOS=${REPOS:-$HOME/repos}
destination_dir=""
repo_type="git"
tar_option=""
build_pkg=0
install_pkg=0

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -G|--git)
            repo_type="git"
            shift
            ;;
        -A|--aur)
            repo_type="aur"
            shift
            ;;
        -D|--directory|--destination)
            destination_dir="$2"
            shift 2
            ;;
        -T|--tar)
            tar_option=1
            shift
            ;;
        -B|--build-pkg)
            build_pkg=1
            shift
            ;;
        -I|--install)
            install_pkg=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            repo_url="$1"
            shift
            ;;
    esac
done

# Validate input
if [[ -z "$repo_url" ]]; then
    echo "Error: No repository URL or name specified."
    show_help
    exit 1
fi

# Determine destination directory
if [[ -z "$destination_dir" ]]; then
    destination_dir="$REPOS"
fi

# Create destination directory if it does not exist
mkdir -p "$destination_dir"

# Clone Git repository
clone_git_repo() {
    local url="$1"
    git clone --recurse-submodules "$url" "$destination_dir/$(basename "$url" .git)"
}

# Clone AUR package
clone_aur_package() {
    local pkg_name="$1"
    git clone "https://aur.archlinux.org/$pkg_name.git" "$destination_dir/$pkg_name"
}

# Download AUR tarball
download_aur_tarball() {
    local pkg_name="$1"
    wget "https://aur.archlinux.org/cgit/aur.git/snapshot/$pkg_name.tar.gz" -P "$destination_dir"
    tar -xvf "$destination_dir/$pkg_name.tar.gz" -C "$destination_dir"
    mv "$destination_dir/$pkg_name/"* "$destination_dir"
    rmdir "$destination_dir/$pkg_name"
    rm "$destination_dir/$pkg_name.tar.gz"
}

# Build package
build_package() {
    cd "$destination_dir/$(basename "$repo_url" .git)" || exit 1
    if [ -f "CMakeLists.txt" ]; then
        if ask_yes_no "Do you want to use cmake?"; then
            mkdir -p build && cd build || exit 1
            if ask_yes_no "Do you want to use Ninja?"; then
                cmake -GNinja -DCMAKE_BUILD_TYPE=Release ..
                ninja -j$(nproc)
            else
                cmake -DCMAKE_BUILD_TYPE=Release ..
                make -j$(nproc)
            fi
        else
            ./configure
            make -j$(nproc)
        fi
    elif [ -f "PKGBUILD" ]; then
        makepkg -si
    elif [ -f "Cargo.toml" ]; then
        cargo build
    fi
}

# Install package
install_package() {
    cd "$destination_dir/$(basename "$repo_url" .git)/build" || exit 1
    if [ -f "CMakeLists.txt" ]; then
        sudo make install
    elif [ -f "Cargo.toml" ]; then
        cargo install --path .
    fi
}

# Main logic
case $repo_type in
    git)
        if [[ "$repo_url" == https://github.com/* ]]; then
            repo_url="${repo_url%.git}"
            repo_url="https://github.com/${repo_url#https://github.com/}"
        fi
        clone_git_repo "$repo_url"
        ;;
    aur)
        if [[ "$repo_url" == https://aur.archlinux.org/* ]]; then
            repo_name="${repo_url#https://aur.archlinux.org/}"
        else
            repo_name="$repo_url"
        fi
        if [[ -n "$tar_option" ]]; then
            download_aur_tarball "$repo_name"
        else
            clone_aur_package "$repo_name"
        fi
        ;;
esac

if [[ $build_pkg -eq 1 ]]; then
    build_package
fi

if [[ $install_pkg -eq 1 ]]; then
    install_package
fi

echo "Process completed."
