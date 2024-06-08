#!/bin/bash

# Function to display help information
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]... repo_url_or_name
Clone repositories from GitHub or AUR, and optionally build or install AUR packages.

Arguments:
  repo_url_or_name      URL of the repository or the name of the repository (for GitHub or AUR).

Options:
  --help                Show this help message and exit.
  -d target_directory   Directory to clone into (default: $HOME/repos).
  -t type               Type of operation ('clone', 'build', 'install', 'tar'). Default is 'clone'.
  -A, --aur             Specify that the repository is from AUR.
  -b                    Build the repository after cloning.
  -i                    Install the repository after building.

Examples:
  $(basename "$0") github_user/repo_name
  $(basename "$0") -d /path/to/target_directory github_user/repo_name
  $(basename "$0") -t build -A package_name
  $(basename "$0") -t install -A package_name
  $(basename "$0") -t tar -A package_name

EOF
}

# Set default directories
REPOS="$HOME/repos"
BUILD_DIR="$HOME/build_src_dir"
AUR_BASE_URL="https://aur.archlinux.org"

# Function to ask user a yes/no question
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please answer yes or no." ;;
        esac
    done
}

# Function to get the project path from user
get_project_path() {
    read -p "Enter the project path (leave blank to use current directory): " project_path
    if [ -z "$project_path" ]; then
        project_path=$(pwd)
    fi
    cd "$project_path" || exit 1
    echo "Using project path: $project_path"
}

# Function to build and optionally install the project
build_and_install() {
    ask_yes_no "Are you in the project directory you want to build?" || get_project_path

    # Ask to use or create build directory
    if [ -d "build" ]; then
        ask_yes_no "Build directory already exists. Do you want to build from there?" || {
            mkdir -p build
            echo "Created build directory."
        }
    else
        ask_yes_no "Do you want to create a build directory?" && {
            mkdir -p build
            echo "Created build directory."
        }
    fi

    # Ask for build system: cmake or configure/make
    if ask_yes_no "Do you want to use cmake?"; then
        build_system="cmake"
        cd build || exit 1
        if ask_yes_no "Do you want to use Ninja?"; then
            use_ninja="yes"
            sudo cmake -GNinja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake" ..
            sudo ninja -j8
        elif ask_yes_no "Do you want to use Unix Makefiles?"; then
            use_ninja="no"
            sudo cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release "-DCMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake" ..
            sudo make -j8
        else
            use_ninja="no"
            sudo cmake -DCMAKE_BUILD_TYPE=Release "-DCMAKE_TOOLCHAIN_FILE=/home/heini/repos/vcpkg/scripts/buildsystems/vcpkg.cmake" ..
            sudo cmake --build . --config Release -j8
        fi
    else
        build_system="make"
        ./configure
        make -j8
    fi

    # Ask to prepend build path to PATH variable in .zshrc
    ask_yes_no "Do you want to prepend the build path to your PATH variable in .zshrc?" && {
        build_path=$(pwd)
        sed -i "1iexport PATH=$build_path:\$PATH" ~/.zshrc
        echo "Updated PATH in .zshrc"
    }

    # Ask to install the build
    if [ "$install_after_build" = true ]; then
        if ask_yes_no "Do you want to install the build?"; then
            if [ "$build_system" = "cmake" ]; then
                if [ "$use_ninja" = "yes" ]; then
                    sudo ninja install
                else
                    sudo make install
                fi
            else
                sudo make install
            fi
        fi
    fi
}

# Parse command-line options
while getopts "d:t:Abih-:" opt; do
    case $opt in
        d) target_dir=$OPTARG ;;
        t) clone_type=$OPTARG ;;
        A) aur_repo=true ;;
        b) build_after_clone=true ;;
        i) install_after_build=true ;;
        h) show_help; exit 0 ;;
        -)
            case "${OPTARG}" in
                help) show_help; exit 0 ;;
                aur) aur_repo=true ;;
                *) show_help; exit 1 ;;
            esac ;;
        *) show_help; exit 1 ;;
    esac
done

shift $((OPTIND -1))

# Validate input
if [ -z "$1" ]; then
    show_help
    exit 1
fi

repo=$1

# Set default values if not provided
target_dir=${target_dir:-$REPOS}
clone_type=${clone_type:-clone}

# Ensure the build directory exists
mkdir -p "$BUILD_DIR"

# Function to handle AUR repository
handle_aur_repo() {
    local repo=$1
    if [[ $clone_type == "tar" ]]; then
        wget "$AUR_BASE_URL/cgit/aur.git/snapshot/$repo.tar.gz" -O "$BUILD_DIR/$repo.tar.gz"
        tar -xvf "$BUILD_DIR/$repo.tar.gz" -C "$BUILD_DIR"
        repo_name=$(basename "$repo" .tar.gz)
        pushd "$BUILD_DIR/$repo_name" > /dev/null
    else
        git -C "$BUILD_DIR" clone "$AUR_BASE_URL/$repo.git"
        repo_name=$(basename "$repo" .git)
        pushd "$BUILD_DIR/$repo_name" > /dev/null
    fi

    if [[ $clone_type == "build" ]]; then
        makepkg --syncdeps
    elif [[ $clone_type == "install" ]]; then
        makepkg -si
    elif [[ $clone_type == "tar" ]]; then
        makepkg --source
    else
        echo "Unknown clone type: $clone_type"
        show_help
        exit 1
    fi

    popd > /dev/null
}

# Clone the repository
if [[ $aur_repo == true ]]; then
    handle_aur_repo "$repo"
elif [[ $repo == http* ]]; then
    if [[ $repo == *aur.archlinux.org* ]]; then
        handle_aur_repo "$repo"
    else
        git clone "$repo" "$target_dir"
    fi
else
    git -C "$REPOS" clone "https://github.com/$repo.git" --recurse-submodules
fi

# Build and optionally install the project if requested
if [ "$build_after_clone" = true ]; then
    build_and_install
fi
