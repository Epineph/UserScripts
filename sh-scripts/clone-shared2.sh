#!/usr/bin/env bash
# Auto-generated clone script – 2025-12-02T00:03:21+01:00
set -euo pipefail

# List of repositories as: "<dir-name> <remote-url>"
repos=(
  "desktop https://github.com/operasoftware/desktop"
  "fzf https://github.com/junegunn/fzf"
  "luksformat https://github.com/Epineph/luksformat"
  "toolkit https://github.com/operasoftware/toolkit"
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
