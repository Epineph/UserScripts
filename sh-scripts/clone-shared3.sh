#!/usr/bin/env bash
# Auto-generated clone script – 2025-12-02T00:03:43+01:00
set -euo pipefail

# List of repositories as: "<dir-name> <remote-url>"
repos=(
  "Arch-Hyprland https://github.com/JaKooLit/Arch-Hyprland.git"
  "Hyprland-Dots https://github.com/JaKooLit/Hyprland-Dots.git"
  "NutrienTrackeR https://github.com/AndreaRMICL/NutrienTrackeR.git"
  "PersonalScripts https://github.com/Epineph/PersonalScripts.git"
  "UserScripts https://github.com/Epineph/UserScripts.git"
  "bats-mock https://github.com/buildkite-plugins/bats-mock.git"
  "bottom https://github.com/ClementTsang/bottom.git"
  "cargo-cache https://github.com/matthiaskrgr/cargo-cache.git"
  "cargo-fuzz https://github.com/rust-fuzz/cargo-fuzz.git"
  "desktop https://github.com/operasoftware/desktop.git"
  "fzf https://github.com/junegunn/fzf.git"
  "generate_install_command https://github.com/Epineph/generate_install_command.git"
  "jupytext https://github.com/mwouts/jupytext.git"
  "micromamba-releases https://github.com/mamba-org/micromamba-releases.git"
  "onionshare https://github.com/onionshare/onionshare.git"
  "pam-duress https://github.com/nuvious/pam-duress.git"
  "tinty https://github.com/tinted-theming/tinty.git"
  "toolkit https://github.com/operasoftware/toolkit.git"
  "vcpkg https://github.com/microsoft/vcpkg.git"
  "zoxide https://github.com/zoxide/zoxide.git"
)

# Where to clone:
repo_dir="${HOME}/repos"  # modify as desired
mkdir -p "$repo_dir"

for repo in "${repos[@]}"; do
  name=$(cut -d' ' -f1 <<< "$repo")
  url=$(cut -d' ' -f2- <<< "$repo")   # allow spaces in URL if any
  dest="$repo_dir/$name"

  if [[ ! -d "$dest/.git" ]]; then
    echo "Cloning $name from $url…"
    git clone --recurse-submodules "$url" "$dest"
  else
    echo "$name already exists at $dest; skipping."
  fi
done
