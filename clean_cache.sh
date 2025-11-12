#!/usr/bin/env bash
#===============================================================================
# clean_caches.sh
#
# A unified script to purge:
#   • pacman cache
#   • npm cache
#   • vcpkg cache (downloads & buildtrees)
#   • micromamba cache
#   • Cargo cache (via cargo-cache)
#
# Usage:
#   ./clean_caches.sh [options]
#
# Options:
#   -r, --vcpkg-root PATH    Path to your vcpkg root directory
#   -h, --help               Display this help message and exit
#
# Note:
#   Ensure you have sudo privileges for pacman cache cleaning.
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Print usage information
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Cleans package manager caches for pacman, npm, vcpkg, micromamba, and Cargo (via cargo-cache).

Options:
  -r, --vcpkg-root PATH    Path to vcpkg root directory (default: \$VCPKG_ROOT)
  -h, --help               Show this help message and exit
EOF
}

# ------------------------------------------------------------------------------
# Parse command-line options
# ------------------------------------------------------------------------------
VCPKG_ROOT="${VCPKG_ROOT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
  -r | --vcpkg-root)
    shift
    VCPKG_ROOT="$1"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    exit 1
    ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Clean pacman cache (/var/cache/pacman/pkg)
# ------------------------------------------------------------------------------
clean_pacman() {
  if command -v pacman &>/dev/null; then
    echo "→ Cleaning pacman cache..."
    sudo pacman -Scc --noconfirm
    echo "✔ Pacman cache cleaned."
  else
    echo "⚠ pacman not found; skipping."
  fi
}

# ------------------------------------------------------------------------------
# Clean npm cache
# ------------------------------------------------------------------------------
clean_npm() {
  if command -v npm &>/dev/null; then
    echo "→ Cleaning npm cache..."
    npm cache clean --force
    echo "✔ npm cache cleaned."
  else
    echo "⚠ npm not found; skipping."
  fi
}

# ------------------------------------------------------------------------------
# Clean vcpkg cache (downloads & buildtrees)
# ------------------------------------------------------------------------------
clean_vcpkg() {
  if command -v vcpkg &>/dev/null; then
    echo "→ Cleaning vcpkg cache..."
    if [[ -z "$VCPKG_ROOT" ]]; then
      echo "⚠ VCPKG_ROOT not set; skipping vcpkg cache cleaning."
    elif [[ -d "$VCPKG_ROOT" ]]; then
      rm -rf "$VCPKG_ROOT/downloads" "$VCPKG_ROOT/buildtrees"
      echo "✔ vcpkg cache directories removed."
    else
      echo "⚠ VCPKG_ROOT directory '$VCPKG_ROOT' not found; skipping."
    fi
  else
    echo "⚠ vcpkg not found; skipping."
  fi
}

# ------------------------------------------------------------------------------
# Clean micromamba cache
# ------------------------------------------------------------------------------
clean_micromamba() {
  if command -v micromamba &>/dev/null; then
    echo "→ Cleaning micromamba cache..."
    micromamba clean --all --yes
    echo "✔ micromamba cache cleaned."
  else
    echo "⚠ micromamba not found; skipping."
  fi
}

# ------------------------------------------------------------------------------
# Clean Cargo cache via cargo-cache
# ------------------------------------------------------------------------------
clean_cargo() {
  if command -v cargo-cache &>/dev/null; then
    echo "→ Cleaning Cargo cache (autoclean)…"
    cargo-cache --autoclean
    echo "→ Cleaning Cargo cache (autoclean-expensive)…"
    cargo-cache --autoclean-expensive
    echo "✔ Cargo cache cleaned."
  else
    echo "⚠ cargo-cache not found; skipping. Install with 'cargo install cargo-cache'."
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
echo "=== Starting unified cache cleaning ==="
clean_pacman
clean_npm
clean_vcpkg
clean_micromamba
clean_cargo
echo "=== All done. ==="
