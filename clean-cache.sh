#!/usr/bin/env bash
#===============================================================================
# clean_caches.sh
#
# Unified cache cleaner for common tools on an Arch-based system.
#
# Cleans:
#   • pacman cache
#   • pacman orphaned packages     (optional, --remove-orphans)
#   • npm cache
#   • pip cache
#   • pipx cache
#   • yarn cache
#   • pnpm store
#   • vcpkg cache (downloads & buildtrees)
#   • micromamba cache
#   • Cargo cache (via cargo-cache)
#   • AUR helper caches (yay, paru, ...) in ~/.cache/<helper>
#
# Usage:
#   ./clean_caches.sh [options]
#
# Options:
#   -r, --vcpkg-root PATH     Path to vcpkg root directory
#                             (default: inferred from 'vcpkg' if possible)
#   -a, --aur-helper NAMES    AUR helper(s) whose cache to wipe in ~/.cache.
#                             Accepts comma/space separated list, e.g.:
#                               --aur-helper yay
#                               --aur-helper "yay,paru"
#                               --aur-helper "yay paru"
#   -o, --remove-orphans      Remove pacman orphaned packages
#       --noconfirm           Do not prompt for confirmations; assume "no
#                             questions asked" for supported operations
#   -h, --help                Show this help message and exit
#
# Note:
#   • You need sudo for pacman operations (cache and orphan removal).
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Print usage information
#------------------------------------------------------------------------------
function usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Cleans caches for pacman, npm, pip, pipx, yarn, pnpm, vcpkg, micromamba,
Cargo (via cargo-cache), and optionally AUR helpers and pacman orphans.

Options:
  -r, --vcpkg-root PATH
      Path to vcpkg root directory. If omitted, the script tries to infer it
      from the location of the 'vcpkg' executable.

  -a, --aur-helper NAMES
      AUR helper(s) whose cache in ~/.cache/<helper> should be removed.
      NAMES can be a single name or a comma/space separated list:
        -a yay
        -a "yay,paru"
        -a "yay paru"

  -o, --remove-orphans
      Remove pacman orphaned packages (pacman -Qtdq, then -Rns).

      --noconfirm
      Skip confirmation prompts for potentially destructive actions
      (AUR cache wipe and orphan removal). Pacman operations already use
      --noconfirm internally.

  -h, --help
      Show this help message and exit.
EOF
}

#------------------------------------------------------------------------------
# Globals / option defaults
#------------------------------------------------------------------------------
VCPKG_ROOT="${VCPKG_ROOT:-}"
declare -a AUR_HELPERS_RAW=()
REMOVE_ORPHANS=0
NOCONFIRM=0

#------------------------------------------------------------------------------
# Parse command-line options
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
  -r | --vcpkg-root)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Missing argument for --vcpkg-root" >&2
      exit 1
    fi
    VCPKG_ROOT="$1"
    ;;
  -a | --aur-helper)
    shift
    if [[ $# -eq 0 ]]; then
      echo "Missing argument for --aur-helper" >&2
      exit 1
    fi
    AUR_HELPERS_RAW+=("$1")
    ;;
  -o | --remove-orphans | --orphans)
    REMOVE_ORPHANS=1
    ;;
  --noconfirm)
    NOCONFIRM=1
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    exit 1
    ;;
  esac
  shift
done

#------------------------------------------------------------------------------
# Normalise AUR helper list: split on commas and spaces, deduplicate
#------------------------------------------------------------------------------
declare -a AUR_HELPERS=()
if ((${#AUR_HELPERS_RAW[@]} > 0)); then
  declare -a tmp_list=()
  for raw in "${AUR_HELPERS_RAW[@]}"; do
    raw="${raw//,/ }"
    for h in "${raw[@]}"; do
      [[ -n "$h" ]] && tmp_list+=("$h")
    done
  done

  if ((${#tmp_list[@]} > 0)); then
    declare -A seen=()
    for h in "${tmp_list[@]}"; do
      if [[ -z "${seen[$h]:-}" ]]; then
        seen["$h"]=1
        AUR_HELPERS+=("$h")
      fi
    done
  fi
fi

#------------------------------------------------------------------------------
# Clean pacman cache (/var/cache/pacman/pkg)
#------------------------------------------------------------------------------
function clean_pacman() {
  if ! command -v pacman >/dev/null 2>&1; then
    echo "⚠ pacman not found; skipping pacman cache."
    return
  fi

  echo "→ Cleaning pacman cache..."
  if ! sudo pacman -Scc --noconfirm; then
    echo "⚠ pacman -Scc failed; check pacman configuration."
    return
  fi
  echo "✔ pacman cache cleaned."
}

#------------------------------------------------------------------------------
# Remove pacman orphaned packages (optional)
#------------------------------------------------------------------------------
function clean_pacman_orphans() {
  if ! command -v pacman >/dev/null 2>&1; then
    echo "⚠ pacman not found; skipping orphan removal."
    return
  fi

  echo "→ Checking for pacman orphaned packages..."
  # Pacman prints nothing if there are none; ignore exit code.
  local orphans
  orphans="$(pacman -Qtdq 2>/dev/null || true)"

  if [[ -z "$orphans" ]]; then
    echo "✔ No orphaned packages found."
    return
  fi

  echo "Found the following orphaned packages:"
  printf '  %s\n' "$orphans"

  if ((NOCONFIRM == 0)); then
    read -r -p "Remove these orphaned packages? [y/N] " reply
    case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
      echo "→ Skipping orphan removal."
      return
      ;;
    esac
  fi

  echo "→ Removing pacman orphaned packages..."
  if ! sudo pacman -Rns --noconfirm "$orphans"; then
    echo "⚠ Failed to remove some orphans; inspect manually."
    return
  fi
  echo "✔ Orphaned packages removed."
}

#------------------------------------------------------------------------------
# Clean npm cache
#------------------------------------------------------------------------------
function clean_npm() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "⚠ npm not found; skipping npm cache."
    return
  fi

  echo "→ Cleaning npm cache..."
  if ! npm cache clean --force; then
    echo "⚠ npm cache clean failed; skipping."
    return
  fi
  echo "✔ npm cache cleaned."
}

#------------------------------------------------------------------------------
# Clean pip cache
#------------------------------------------------------------------------------
function clean_pip() {
  if ! command -v pip >/dev/null 2>&1; then
    echo "⚠ pip not found; skipping pip cache."
    return
  fi

  echo "→ Cleaning pip cache..."
  local cache_dir
  cache_dir="$(pip cache dir 2>/dev/null || true)"

  if [[ -z "$cache_dir" || ! -d "$cache_dir" ]]; then
    echo "⚠ Could not determine pip cache dir; skipping."
    return
  fi

  if ! rm -rf "${cache_dir:?}/"*; then
    echo "⚠ Failed to remove pip cache in '$cache_dir'."
    return
  fi
  echo "✔ pip cache cleaned ($cache_dir)."
}

#------------------------------------------------------------------------------
# Clean pipx cache
#------------------------------------------------------------------------------
function clean_pipx() {
  if ! command -v pipx >/dev/null 2>&1; then
    echo "⚠ pipx not found; skipping pipx cache."
    return
  fi

  # pipx keeps transient downloads in ~/.cache/pipx by default
  local cache_dir="${PIPX_CACHE_DIR:-$HOME/.cache/pipx}"

  if [[ ! -d "$cache_dir" ]]; then
    echo "⚠ pipx cache dir '$cache_dir' not found; skipping."
    return
  fi

  echo "→ Cleaning pipx cache in '$cache_dir'..."
  if ! rm -rf "${cache_dir:?}/"*; then
    echo "⚠ Failed to clean pipx cache."
    return
  fi
  echo "✔ pipx cache cleaned."
}

#------------------------------------------------------------------------------
# Clean yarn cache
#------------------------------------------------------------------------------
function clean_yarn() {
  if ! command -v yarn >/dev/null 2>&1; then
    echo "⚠ yarn not found; skipping yarn cache."
    return
  fi

  echo "→ Cleaning yarn cache..."
  # Yarn 1 vs Yarn modern: try --all, fall back to legacy command.
  if ! yarn cache clean --all 2>/dev/null; then
    if ! yarn cache clean 2>/dev/null; then
      echo "⚠ yarn cache clean failed; skipping."
      return
    fi
  fi
  echo "✔ yarn cache cleaned."
}

#------------------------------------------------------------------------------
# Clean pnpm store
#------------------------------------------------------------------------------
function clean_pnpm() {
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "⚠ pnpm not found; skipping pnpm store."
    return
  fi

  echo "→ Pruning pnpm store..."
  if ! pnpm store prune; then
    echo "⚠ pnpm store prune failed; skipping."
    return
  fi
  echo "✔ pnpm store pruned."
}

#------------------------------------------------------------------------------
# Clean vcpkg cache (downloads & buildtrees)
#------------------------------------------------------------------------------
function clean_vcpkg() {
  if ! command -v vcpkg >/dev/null 2>&1; then
    echo "⚠ vcpkg not found; skipping vcpkg cache."
    return
  fi

  local root="$VCPKG_ROOT"
  if [[ -z "$root" ]]; then
    local vcpkg_bin
    vcpkg_bin="$(command -v vcpkg)"
    root="$(dirname "$vcpkg_bin")"
    echo "  VCPKG_ROOT not provided; inferring '$root'."
  fi

  if [[ ! -d "$root" ]]; then
    echo "⚠ vcpkg root '$root' does not exist; skipping."
    return
  fi

  echo "→ Cleaning vcpkg cache under '$root'..."
  if [[ -d "$root/downloads" ]]; then
    if ! rm -rf "$root/downloads"; then
      echo "⚠ Failed to remove '$root/downloads'."
    fi
  fi
  if [[ -d "$root/buildtrees" ]]; then
    if ! rm -rf "$root/buildtrees"; then
      echo "⚠ Failed to remove '$root/buildtrees'."
    fi
  fi
  echo "✔ vcpkg cache directories removed."
}

#------------------------------------------------------------------------------
# Clean micromamba cache
#------------------------------------------------------------------------------
function clean_micromamba() {
  if ! command -v micromamba >/dev/null 2>&1; then
    echo "⚠ micromamba not found; skipping micromamba cache."
    return
  fi

  echo "→ Cleaning micromamba cache..."
  if ! micromamba clean --all --yes; then
    echo "⚠ micromamba clean failed; skipping."
    return
  fi
  echo "✔ micromamba cache cleaned."
}

#------------------------------------------------------------------------------
# Clean Cargo cache via cargo-cache
#------------------------------------------------------------------------------
function clean_cargo() {
  if ! command -v cargo-cache >/dev/null 2>&1; then
    echo "⚠ cargo-cache not found; skipping Cargo cache."
    echo "   Install with: cargo install cargo-cache"
    return
  fi

  echo "→ Cleaning Cargo cache (autoclean)..."
  if ! cargo-cache --autoclean; then
    echo "⚠ 'cargo-cache --autoclean' failed."
  fi

  echo "→ Cleaning Cargo cache (autoclean-expensive)..."
  if ! cargo-cache --autoclean-expensive; then
    echo "⚠ 'cargo-cache --autoclean-expensive' failed."
  fi

  echo "✔ Cargo cache cleanup attempted."
}

#------------------------------------------------------------------------------
# Clean AUR helper caches in ~/.cache/<helper>
#------------------------------------------------------------------------------
function clean_aur_helpers() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  for helper in "$@"; do
    if [[ -z "$helper" ]]; then
      continue
    fi

    local found=0
    if command -v "$helper" >/dev/null 2>&1; then
      found=1
    fi

    local cache_dir="$HOME/.cache/$helper"
    if [[ -d "$cache_dir" ]]; then
      found=1
    fi

    if ((found == 0)); then
      echo "⚠ AUR helper '$helper' not found (no binary, no '$cache_dir'); skipping."
      continue
    fi

    if [[ ! -d "$cache_dir" ]]; then
      echo "⚠ Cache directory '$cache_dir' does not exist; skipping '$helper'."
      continue
    fi

    if ((NOCONFIRM == 0)); then
      echo "About to wipe ALL cache for '$helper' in:"
      echo "  $cache_dir"
      read -r -p "Proceed? [y/N] " reply
      case "$reply" in
      [yY] | [yY][eE][sS]) ;;
      *)
        echo "→ Skipping cache for '$helper'."
        continue
        ;;
      esac
    fi

    echo "→ Removing cache for '$helper' in '$cache_dir'..."
    (
      shopt -s dotglob nullglob
      cd "$cache_dir"
      rm -rf ./*
    ) || {
      echo "⚠ Failed to clean cache for '$helper'."
      continue
    }
    echo "✔ Cache for '$helper' cleaned."
  done
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
echo "=== Starting unified cache cleaning ==="

clean_pacman

if ((REMOVE_ORPHANS == 1)); then
  clean_pacman_orphans
fi

clean_npm
clean_pip
clean_pipx
clean_yarn
clean_pnpm
clean_vcpkg
clean_micromamba
clean_cargo

if ((${#AUR_HELPERS[@]} > 0)); then
  clean_aur_helpers "${AUR_HELPERS[@]}"
fi

echo "=== All done. ==="
