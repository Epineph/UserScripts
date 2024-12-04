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
    "ScaffoldGraph https://github.com/UCLCheminformatics/ScaffoldGraph.git"
    "networkx https://github.com/networkx/networkx.git"
    "coordgenlibs https://github.com/schrodinger/coordgenlibs.git"
    "direnv https://github.com/direnv/direnv.git"
    "yacas https://github.com/grzegorzmazur/yacas.git"
    "chainer-chemistry https://github.com/chainer/chainer-chemistry.git"
    "rdkit https://github.com/rdkit/rdkit.git"
    "azure-sdk-for-python https://github.com/Azure/azure-sdk-for-python.git"
    "openbabel https://github.com/openbabel/openbabel.git"
    "azure-cli https://github.com/Azure/azure-cli.git"
    "swig https://github.com/swig/swig.git"
    "CMake https://github.com/Kitware/CMake.git"
    "ninja https://github.com/ninja-build/ninja.git"
    "re2c https://github.com/skvadrik/re2c.git"
    "vcpkg https://github.com/microsoft/vcpkg.git"
    "bat https://github.com/sharkdp/bat.git"
    "fd https://github.com/sharkdp/fd.git"
    "fzf https://github.com/junegunn/fzf.git"
    "numba https://github.com/numba/numba"
    "ocaml https://github.com/ocaml/ocaml"
    "ipykernel https://github.com/ipython/ipykernel"
    "jupyterlab https://github.com/jupyterlab/jupyterlab"
    "ipython https://github.com/ipython/ipython"
    "jupyter_client https://github.com/jupyter/jupyter_client"
    "qtconsole https://github.com/jupyter/qtconsole"
    "jupyter https://github.com/jupyter/jupyter"
    "terminado https://github.com/jupyter/terminado"
    "jupyter_core https://github.com/jupyter/jupyter_core"
    "doxygen https://github.com/doxygen/doxygen"
    "Arch-Hyprland https://github.com/JaKooLit/Arch-Hyprland.git"
    "backup_scripts https://github.com/Epineph/backup_scripts.git"
    "generate_install_command https://github.com/Epineph/generate_install_command.git"
    "my_zshrc https://github.com/Epineph/my_zshrc.git"
    "UserScripts https://github.com/Epineph/UserScripts.git"
    "zfsArch https://github.com/Epineph/zfsArch.git"
    "thorium-browser-bin https://aur.archlinux.org/thorium-browser-bin.git"
    "visual-studio-code-bin https://aur.archlinux.org/visual-studio-code-bin.git"
    "yay https://aur.archlinux.org/yay.git"
    "paru https://aur.archlinux.org/paru.git"
    "cobalt.rs https://github.com/cobalt-org/cobalt.rs.git"
    "cppdap https://github.com/cppdap/cppdap.git"
    "crowbook https://github.com/lise-henry/crowbook.git"
    "delta https://github.com/dandavison/delta.git"
    "directory https://github.com/yourusername/directory.git"
    "dockerfiles https://github.com/yourusername/dockerfiles.git"
    "dotbot https://github.com/anishathalye/dotbot.git"
    "gradle https://github.com/gradle/gradle.git"
    "iTerm2 https://github.com/gnachman/iTerm2.git"
    "iterm2-shell-integration https://github.com/gnachman/iterm2-shell-integration.git"
    "jsoncpp https://github.com/open-source-parsers/jsoncpp.git"
    "latex2e https://github.com/latex3/latex2e.git"
    "libressl-3.9.2 https://github.com/libressl-portable/portable.git"
    "llvmlite https://github.com/numba/llvmlite.git"
    "manage_lvm_space https://github.com/Epineph/manage_lvm_space.git"
    "MathJax https://github.com/mathjax/MathJax.git"
    "MathJax-demos-node https://github.com/mathjax/MathJax-demos-node.git"
    "MathJax-docs https://github.com/mathjax/MathJax-docs.git"
    "mdBook https://github.com/rust-lang/mdBook.git"
    "meson-python https://github.com/mesonbuild/meson-python.git"
    "my_R_config https://github.com/Epineph/my_R_config.git"
    "nvim_conf https://github.com/Epineph/nvim_conf.git"
    "onedrive https://github.com/abraunegg/onedrive.git"
    "pandoc https://github.com/jgm/pandoc.git"
    "papaja https://github.com/crsh/papaja.git"
    "pipes-extra https://github.com/Gabriel439/Haskell-Pipes-Extra-Library.git"
    "proot-distro https://github.com/proot-me/proot-distro.git"
    "rhash https://github.com/rhash/RHash.git"
    "rmarkdown https://github.com/rstudio/rmarkdown.git"
    "rstudio-desktop https://github.com/rstudio/rstudio.git"
    "rstudio-desktop-bin https://aur.archlinux.org/rstudio-desktop-bin.git"
    "rstudio-desktop-electron https://github.com/yourusername/rstudio-desktop-electron.git"
    "ryacas https://github.com/r-cas/ryacas.git"
    "semver https://github.com/semver/semver.git"
    "shiny-examples https://github.com/rstudio/shiny-examples.git"
    "slather https://github.com/SlatherOrg/slather.git"
    "SublimeAllAutocomplete https://github.com/alienhard/SublimeAllAutocomplete.git"
    "swift-llbuild https://github.com/apple/swift-llbuild.git"
    "syntect https://github.com/trishume/syntect.git"
    "tinytex https://github.com/yihui/tinytex.git"
    "wine https://github.com/wine-mirror/wine.git"
    "winehq https://github.com/wine-mirror/winehq.git"
    "WoeUSB-ng https://github.com/WoeUSB/WoeUSB-ng.git"
    "xaringan https://github.com/yihui/xaringan.git"
    "xcbuild https://github.com/facebook/xcbuild.git"
)

# Directory to store repositories
repo_dir="/home/heini/repos/"
mkdir -p "$repo_dir"

# Check and clone repositories if they do not exist
for repo in "${repos[@]}"; do
    name=$(echo "$repo" | cut -d ' ' -f 1)
    url=$(echo "$repo" | cut -d ' ' -f 2)
    path="$repo_dir/$name"

    if [ ! -d "$path" ]; then
        echo "Cloning $name from $url..."
        git clone --recurse-submodules "$url" "$path"
    else
        echo "$name already exists at $path."
    fi
done

