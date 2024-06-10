#!/bin/bash

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

# Function to get the project path from user
get_project_path() {
    read -p "Enter the project path (leave blank to use current directory): " project_path
    if [ -z "$project_path" ]; then
        project_path=$(pwd)
    fi
    cd "$project_path" || exit 1
    echo "Using project path: $project_path"
}

# Get project path
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
