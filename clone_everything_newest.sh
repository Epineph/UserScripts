#!/usr/bin/env bash

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

# List of repositories to check and clone if not present.
# Each entry is a string with the repo name and the repo URL separated by a space.

repos=(
  "Arch-Hyprland https://github.com/JaKooLit/Arch-Hyprland"
  "asm-lsp https://github.com/bergercookie/asm-lsp.git"
  "autotools-language-server https://github.com/Freed-Wu/autotools-language-server.git"
  "awk-language-server https://github.com/Beaglefoot/awk-language-server.git"
  "backup_scripts https://github.com/Epineph/backup_scripts.git"
  "bacon https://github.com/Canop/bacon.git"
  "bacon-ls https://github.com/crisidev/bacon-ls.git"
  "bash-language-server https://github.com/bash-lsp/bash-language-server.git"
  "bat https://github.com/sharkdp/bat.git"
  "chainer-chemistry https://github.com/chainer/chainer-chemistry.git"
  "CMake https://github.com/Kitware/CMake.git"
  "crowbook https://github.com/lise-henry/crowbook.git"
  "delta https://github.com/dandavison/delta.git"
  "direnv https://github.com/direnv/direnv.git"
  "dotbot https://github.com/anishathalye/dotbot.git"
  "doxide https://github.com/lawmurray/doxide.git"
  "doxygen https://github.com/doxygen/doxygen"
  "dracula.nvim https://github.com/Mofiqul/dracula.nvim.git"
  "fd https://github.com/sharkdp/fd.git"
  "fidget.nvim https://github.com/j-hui/fidget.nvim.git"
  "fzf https://github.com/junegunn/fzf.git"
  "generate_install_command https://github.com/Epineph/generate_install_command"
  "htmx-lsp https://github.com/ThePrimeagen/htmx-lsp.git"
  "hydra-lsp https://github.com/Retsediv/hydra-lsp.git"
  "ipykernel https://github.com/ipython/ipykernel"
  "ipython https://github.com/ipython/ipython"
  "jsoncpp https://github.com/open-source-parsers/jsoncpp.git"
  "jupyter https://github.com/jupyter/jupyter"
  "jupyter_client https://github.com/jupyter/jupyter_client"
  "jupyter_core https://github.com/jupyter/jupyter_core"
  "jupyterlab https://github.com/jupyterlab/jupyterlab"
  "langserver https://github.com/nim-lang/langserver.git"
  "lazygit https://github.com/jesseduffield/lazygit.git"
  "libressl-3.9.2 https://github.com/libressl-portable/portable.git"
  "llvmlite https://github.com/numba/llvmlite.git"
  "LSP https://github.com/sublimelsp/LSP.git"
  "luau-lsp https://github.com/JohnnyMorganz/luau-lsp.git"
  "manage_lvm_space https://github.com/Epineph/manage_lvm_space.git"
  "markdown-oxide https://github.com/Feel-ix-343/markdown-oxide.git"
  "mason.nvim https://github.com/mason-org/mason.nvim.git"
  "mason-registry https://github.com//mason-org/mason-registry.git"
  "MathJax https://github.com/mathjax/MathJax.git"
  "MathJax-demos-node https://github.com/mathjax/MathJax-demos-node.git"
  "MathJax-docs https://github.com/mathjax/MathJax-docs.git"
  "mdBook https://github.com/rust-lang/mdBook.git"
  "meson-python https://github.com/mesonbuild/meson-python.git
"
  "micromamba-releases https://github.com/mamba-org/micromamba-releases.git"
  "move https://github.com/move-language/move.git"
  "mutt-language-server https://github.com/neomutt/mutt-language-server.git"
  "my_R_config https://github.com/Epineph/my_R_config.git"
  "my_zshrc https://github.com/Epineph/my_zshrc"
  "nelua-lsp https://github.com/codehz/nelua-lsp.git"
  "nelua.vim https://github.com/stefanos82/nelua.vim.git"
  "networkx https://github.com/networkx/networkx.git"
  "next-ls https://github.com/elixir-tools/next-ls.git"
  "nickel https://github.com/tweag/nickel.git"
  "nil https://github.com/oxalica/nil.git"
  "nimlsp https://github.com/PMunch/nimlsp.git"
  "ninja https://github.com/ninja-build/ninja.git"
  "nomad-lsp https://github.com//juliosueiras/nomad-lsp.git"
  "numba https://github.com/numba/numba"
  "nushell https://github.com/nushell/nushell.git"
  "nvim_conf https://github.com/Epineph/nvim_conf.git"
  "nvim-dap https://github.com/mfussenegger/nvim-dap.git"
  "nvim-idris2 https://github.com/ShinKage/nvim-idris2.git"
  "nvim-jdtls https://github.com/mfussenegger/nvim-jdtls.git"
  "ocaml https://github.com/ocaml/ocaml"
  "onedrive https://github.com/abraunegg/onedrive.git"
  "oniguruma https://github.com/defuz/oniguruma.git"
  "openbabel https://github.com/openbabel/openbabel.git"
  "openscad-language-server https://github.com/dzhu/openscad-language-server.git"
  "openscad-LSP https://github.com/Leathong/openscad-LSP.git"
  "oxc https://github.com/oxc-project/oxc.git"
  "package_control https://github.com/wbond/package_control.git"
  "Packages https://github.com/sublimehq/Packages.git"
  "pandoc https://github.com/jgm/pandoc.git"
  "papaja https://github.com/crsh/papaja.git"
  "paru https://aur.archlinux.org/paru.git"
  "pascal-language-server https://github.com/genericptr/pascal-language-server.git"
  "PerlNavigator https://github.com/bscan/PerlNavigator.git"
  "pest-ide-tools https://github.com/pest-parser/pest-ide-tools.git"
  "phan https://github.com/phan/phan.git"
  "phpactor https://github.com/phpactor/phpactor.git"
  "please https://github.com/thought-machine/please.git"
  "processing-sublime https://github.com/b-g/processing-sublime.git"
  "qtconsole https://github.com/jupyter/qtconsole"
  "rdkit https://github.com/rdkit/rdkit.git"
  "re2c https://github.com/skvadrik/re2c.git"
  "rhash https://github.com/rhash/RHash.git"
  "ripgrep https://github.com/BurntSushi/ripgrep.git"
  "rmarkdown https://github.com/rstudio/rmarkdown.git"
  "rocks.nvim https://github.com/nvim-neorocks/rocks.nvim.git"
  "rstudio-desktop-bin https://aur.archlinux.org/rstudio-desktop-bin.git"
  "ryacas https://github.com/r-cas/ryacas.git"
  "ScaffoldGraph https://github.com/UCLCheminformatics/ScaffoldGraph.git"
  "semver https://github.com/semver/semver.git"
  "shiny-examples https://github.com/rstudio/shiny-examples.git"
  "slather https://github.com/SlatherOrg/slather.git"
  "sublime https://github.com/JaredCubilla/sublime.git"
  "SublimeAllAutocomplete https://github.com/alienhard/SublimeAllAutocomplete.git"
  "swig https://github.com/swig/swig.git"
  "syntect https://github.com/trishume/syntect.git"
  "terminado https://github.com/jupyter/terminado"
  "thorium-browser-bin https://aur.archlinux.org/thorium-browser-bin.git"
  "tinytex https://github.com/yihui/tinytex.git"
  "tree-sitter-phpdoc https://github.com/claytonrcarter/tree-sitter-phpdoc.git"
  "UserScripts https://github.com/Epineph/UserScripts"
  "vcpkg https://github.com/microsoft/vcpkg.git"
  "vim-lsp https://github.com/prabirshrestha/vim-lsp.git"
  "visual-studio-code-bin https://aur.archlinux.org/visual-studio-code-bin.git"
  "WoeUSB-ng https://github.com/WoeUSB/WoeUSB-ng.git"
  "xcbuild https://github.com/facebook/xcbuild.git"
  "yay https://aur.archlinux.org/yay.git"
  "zfsArch https://github.com/Epineph/zfsArch.git"
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
