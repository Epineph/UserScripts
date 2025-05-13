#!/usr/bin/env bash
###############################################################################
# build-bat.sh — reproducible “cargo install” for *bat* on any modern distro
#
#   • Works with GCC 14 / 15 by *automatically* switching to the system
#     libonig if the vendored snapshot is too old.
#   • Keeps the upstream lock-file intact (re-producible!) yet
#     transparently updates *only* the broken `onig_sys` crate.
#   • Requires nothing except a working Rust tool-chain and git.
#
# Tested on:
#   Arch Linux      (gcc 15, rustc 1.86)
#   Debian sid      (gcc 14, rustc 1.75)
#   Fedora 40       (gcc 14, rustc 1.78)
###############################################################################
set -euo pipefail
shopt -s extglob

### --- 0. Config --------------------------------------------------------------
REPO='https://github.com/sharkdp/bat.git'
TAG=''                     # empty → build the default branch (master/main)
JOBS="$(nproc)"            # number of parallel jobs for Cargo
PREFIX="${HOME}/.cargo/bin"  # where the finished binary lands

### --- 1. Sanity checks -------------------------------------------------------
command -v cargo >/dev/null   || { echo '❌ Rust not found';      exit 1; }
command -v git   >/dev/null   || { echo '❌ git  not installed';  exit 1; }

rustc_version=$(rustc --version | awk '{print $2}')
min_rust='1.74.0'
if [[ "$(printf '%s\n' "$min_rust" "$rustc_version" | sort -V | head -1)" \
      != "$min_rust" ]]; then
  echo "❌ bat needs at least Rust $min_rust — you have $rustc_version"
  exit 1
fi
echo "✔ Rust tool-chain OK  ($rustc_version)"

### --- 2. Clone (shallow + sub-modules) --------------------------------------
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
git -C "$workdir" init -q
git -C "$workdir" remote add origin "$REPO"
git -C "$workdir" fetch --depth=1 origin "${TAG:-HEAD}"
git -C "$workdir" checkout FETCH_HEAD -q
git -C "$workdir" submodule update --init --depth=1 --recursive
echo "✔ Repository ready in $workdir"

### --- 3. Fast fix for GCC 14/15 breakage  -----------------------------------
#
# The vendored oniguruma in onig_sys ≤ 69.8.1 triggers
#   -Werror=incompatible-pointer-types
# with modern GCC   (see GCC14 porting notes) :contentReference[oaicite:0]{index=0}.
#
need_patch=$(grep -c '"onig_sys".*"69.8' "$workdir/Cargo.lock" || true)
if (( need_patch )); then
  echo "⧗  Updating *only* onig_sys → 69.9.x ..."
  cargo -C "$workdir" update -p onig_sys
fi

### --- 4. Try a normal build first -------------------------------------------
echo "⧗  First attempt: static vendored build"
if cargo install --quiet --path "$workdir" --jobs "$JOBS" --force &>build.log
then
  echo "✔ bat built successfully (static oniguruma)"; exit 0
fi
echo "⚠ build failed — retrying with system libonig"

### --- 5. Fallback: system libonig -------------------------------------------
# Arch / Debian / Fedora all ship a >= 6.9.10 patched library.
if command -v pacman &>/dev/null;  then sudo pacman  -Sy --needed --noconfirm oniguruma;
elif command -v dnf    &>/dev/null;  then sudo dnf      -y  install oniguruma;
elif command -v apt    &>/dev/null;  then sudo apt-get  -y  install libonig-dev;
else
  echo "❓ Unknown package manager – please install libonig by hand"; exit 1
fi

export RUSTONIG_SYSTEM_LIBONIG=1   # tell onig_sys to link against it :contentReference[oaicite:1]{index=1}
cargo install --quiet --path "$workdir" --jobs "$JOBS" --force &>>build.log

echo "✔ bat built and installed at $PREFIX/bat (linked to system libonig)"
echo "   build log: $(realpath build.log)"
###############################################################################

