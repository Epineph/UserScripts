#!/bin/bash

# Ensure the PATH is set correctly
# export PATH="$HOME/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Debugging statement to print the PATH
echo "PATH is: $PATH"

# Ensure that the necessary commands are available
for cmd in git cut; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd could not be found. Please install $cmd."
        exit 1
    fi
done

# List of repositories to check and clone if not present
repos=(
    "swig https://github.com/swig/swig.git"
    "CMake https://github.com/Kitware/CMake.git"
    "ninja https://github.com/ninja-build/ninja.git"
    "re2c https://github.com/skvadrik/re2c.git"
    "vcpkg https://github.com/microsoft/vcpkg.git"
    "bat https://github.com/sharkdp/bat.git"
    "fd https://github.com/sharkdp/fd.git"
    "fzf https://github.com/junegunn/fzf.git"
    "ocaml https://github.com/ocaml/ocaml"
    "doxygen https://github.com/doxygen/doxygen"
)

# Directory to store repositories
repo_dir="/home/heini/repos/"
mkdir -p "$repo_dir"

# Check and clone repositories if they do not exist
for repo in "${repos[@]}"; do
    name=$(echo $repo | cut -d ' ' -f 1)
    url=$(echo $repo | cut -d ' ' -f 2)
    path="$repo_dir/$name"

    if [ ! -d "$path" ]; then
        echo "Cloning $name from $url..."
        git clone --recurse-submodules "$url" "$path"
    else
        echo "$name already exists at $path."
    fi
done
