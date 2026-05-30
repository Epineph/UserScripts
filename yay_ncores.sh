#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# yay-ncores
#
# Run yay while controlling makepkg's parallel build jobs through MAKEFLAGS.
#
# Examples:
#   yay-ncores 8 -S package-name
#   yay-ncores all -S package-name
#   yay-ncores auto -S package-name
#   yay-ncores keep1 -S package-name
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  yay-ncores CORES [yay arguments...]

CORES:
  N        Use exactly N build jobs.
  all      Use all logical CPU cores.
  auto     Same as all.
  keep1    Use all logical CPU cores minus one.

Examples:
  yay-ncores 8 -S package-name
  yay-ncores all -S package-name
  yay-ncores keep1 -S package-name
  yay-ncores 4 -Syu
EOF
}

function main() {
  local cores="${1:-}"

  if [[ -z "$cores" || "$cores" == "-h" || "$cores" == "--help" ]]; then
    usage
    exit 0
  fi

  shift

  case "${cores,,}" in
    all|auto)
      cores="$(nproc)"
      ;;
    keep1)
      cores="$(( $(nproc) - 1 ))"
      if (( cores < 1 )); then
        cores="1"
      fi
      ;;
    ''|*[!0-9]*)
      printf 'Error: CORES must be a number, all, auto, or keep1.\n' >&2
      exit 1
      ;;
  esac

  MAKEFLAGS="-j${cores}" yay "$@"
}

main "$@"
