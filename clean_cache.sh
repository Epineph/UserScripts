#!/usr/bin/env bash
#===============================================================================
# clean_cache
#
# Unified cache cleaning for:
#   - pacman
#   - npm
#   - vcpkg
#   - micromamba
#   - Cargo (via cargo-cache)
#
# Optional user cache cleaning:
#   - ~/.cache/yay
#   - ~/.cache
#
# Notes:
#   - PATH and VCPKG_ROOT are different concerns.
#   - The script attempts to resolve the vcpkg root automatically.
#   - User caches are cleaned as the current user, not with sudo.
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------
VCPKG_ROOT_OPT=""
USER_CACHE_ENABLED=0
USER_CACHE_MODE=""
PURGE_PACMAN_DIR=0

# ------------------------------------------------------------------------------
# Messaging helpers
# ------------------------------------------------------------------------------
function log_info() {
  printf -- '-> %s\n' "$*"
}

function log_ok() {
  printf -- '[OK] %s\n' "$*"
}

function log_warn() {
  printf -- '[WARN] %s\n' "$*" >&2
}

function die() {
  printf -- '[ERROR] %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
function usage() {
  cat <<'EOF'
Usage:
  clean_cache [options]

Cleans caches for:
  pacman, npm, vcpkg, micromamba, and Cargo (via cargo-cache).

Options:
  -r, --vcpkg-root PATH   Explicit vcpkg root directory
      --user-cache        Enable cleaning of user cache locations
      --clean-yay         Clean only ~/.cache/yay
      --clean-all         Clean all of ~/.cache
      --purge-pacman-dir  Additionally delete all contents of
                          /var/cache/pacman/pkg after pacman -Scc
  -h, --help              Show this help text and exit

Examples:
  clean_cache
  clean_cache --vcpkg-root "$HOME/repos/vcpkg"
  clean_cache --user-cache --clean-yay
  clean_cache --user-cache --clean-all
  clean_cache --purge-pacman-dir
  clean_cache --user-cache --clean-yay --purge-pacman-dir

Notes:
  - --clean-yay and --clean-all require --user-cache.
  - Do not use sudo for ~/.cache or ~/.cache/yay.
  - pacman -Scc is the preferred pacman-native cleaning method.
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--vcpkg-root)
        shift
        [[ $# -gt 0 ]] || die "--vcpkg-root requires a path."
        VCPKG_ROOT_OPT="$1"
        ;;
      --user-cache)
        USER_CACHE_ENABLED=1
        ;;
      --clean-yay)
        [[ -z "$USER_CACHE_MODE" ]] || \
          die "Use only one of --clean-yay or --clean-all."
        USER_CACHE_MODE="yay"
        ;;
      --clean-all)
        [[ -z "$USER_CACHE_MODE" ]] || \
          die "Use only one of --clean-yay or --clean-all."
        USER_CACHE_MODE="all"
        ;;
      --purge-pacman-dir)
        PURGE_PACMAN_DIR=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  if [[ "$USER_CACHE_ENABLED" -eq 0 && -n "$USER_CACHE_MODE" ]]; then
    die "--clean-yay or --clean-all requires --user-cache."
  fi

  if [[ "$USER_CACHE_ENABLED" -eq 1 && -z "$USER_CACHE_MODE" ]]; then
    die "--user-cache requires either --clean-yay or --clean-all."
  fi
}

# ------------------------------------------------------------------------------
# Filesystem helpers
# ------------------------------------------------------------------------------
function remove_children() {
  local target="$1"

  if [[ ! -d "$target" ]]; then
    log_warn "Directory not found; skipping: $target"
    return 0
  fi

  find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

function sudo_remove_children() {
  local target="$1"

  if [[ ! -d "$target" ]]; then
    log_warn "Directory not found; skipping: $target"
    return 0
  fi

  sudo find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

# ------------------------------------------------------------------------------
# vcpkg resolution
# ------------------------------------------------------------------------------
function resolve_vcpkg_root() {
  local candidate=""
  local exe=""

  if [[ -n "$VCPKG_ROOT_OPT" ]]; then
    candidate="$VCPKG_ROOT_OPT"
  elif [[ -n "${VCPKG_ROOT:-}" ]]; then
    candidate="$VCPKG_ROOT"
  elif command -v vcpkg >/dev/null 2>&1; then
    exe="$(command -v vcpkg)"
    candidate="$(dirname "$(realpath "$exe")")"
  elif [[ -x "$HOME/repos/vcpkg/vcpkg" ]]; then
    candidate="$HOME/repos/vcpkg"
  fi

  [[ -n "$candidate" ]] || return 1

  candidate="$(realpath "$candidate")"

  if [[ -d "$candidate" && -x "$candidate/vcpkg" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# Cleaning functions
# ------------------------------------------------------------------------------
function clean_pacman() {
  if command -v pacman >/dev/null 2>&1; then
    log_info "Cleaning pacman cache via pacman -Scc..."
    sudo pacman -Scc --noconfirm
    log_ok "Pacman cache cleaned."
  else
    log_warn "pacman not found; skipping."
  fi
}

function purge_pacman_dir() {
  local pacman_cache='/var/cache/pacman/pkg'

  if [[ "$PURGE_PACMAN_DIR" -ne 1 ]]; then
    return 0
  fi

  log_info "Purging remaining contents of $pacman_cache ..."
  sudo_remove_children "$pacman_cache"
  log_ok "Pacman cache directory contents removed."
}

function clean_npm() {
  if command -v npm >/dev/null 2>&1; then
    log_info "Cleaning npm cache..."
    npm cache clean --force
    log_ok "npm cache cleaned."
  else
    log_warn "npm not found; skipping."
  fi
}

function clean_vcpkg() {
  local root=""

  if ! root="$(resolve_vcpkg_root)"; then
    log_warn \
      "Could not resolve vcpkg root; skipping. Use --vcpkg-root or export VCPKG_ROOT."
    return 0
  fi

  export VCPKG_ROOT="$root"

  log_info "Cleaning vcpkg cache in: $VCPKG_ROOT"

  if [[ -d "$VCPKG_ROOT/downloads" ]]; then
    rm -rf -- "$VCPKG_ROOT/downloads"
    mkdir -p -- "$VCPKG_ROOT/downloads"
  fi

  if [[ -d "$VCPKG_ROOT/buildtrees" ]]; then
    rm -rf -- "$VCPKG_ROOT/buildtrees"
    mkdir -p -- "$VCPKG_ROOT/buildtrees"
  fi

  log_ok "vcpkg downloads/ and buildtrees/ cleaned."
}

function clean_micromamba() {
  if command -v micromamba >/dev/null 2>&1; then
    log_info "Cleaning micromamba cache..."
    micromamba clean --all --yes
    log_ok "Micromamba cache cleaned."
  else
    log_warn "micromamba not found; skipping."
  fi
}

function clean_cargo() {
  if command -v cargo-cache >/dev/null 2>&1; then
    log_info "Cleaning Cargo cache: autoclean..."
    cargo-cache --autoclean

    log_info "Cleaning Cargo cache: autoclean-expensive..."
    cargo-cache --autoclean-expensive

    log_ok "Cargo cache cleaned."
  else
    log_warn \
      "cargo-cache not found; skipping. Install with: cargo install cargo-cache"
  fi
}

function get_invoking_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf -- '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

function get_invoking_home() {
  local user
  user="$(get_invoking_user)"
  getent passwd "$user" | cut -d: -f6
}

function clean_user_cache() {
  local user_home=""

  if [[ "$USER_CACHE_ENABLED" -ne 1 ]]; then
    return 0
  fi

  user_home="$(get_invoking_home)"

  case "$USER_CACHE_MODE" in
    yay)
      log_info "Cleaning user yay cache: $user_home/.cache/yay"
      remove_children "$user_home/.cache/yay"
      log_ok "User yay cache cleaned."
      ;;
    all)
      log_info "Cleaning full user cache: $user_home/.cache"
      remove_children "$user_home/.cache"
      log_ok "Full user cache cleaned."
      ;;
    *)
      die "Internal error: unsupported USER_CACHE_MODE='$USER_CACHE_MODE'"
      ;;
  esac
}
# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
function main() {
  parse_args "$@"

  printf '=== Starting unified cache cleaning ===\n'
  clean_pacman
  purge_pacman_dir
  clean_npm
  clean_vcpkg
  clean_micromamba
  clean_cargo
  clean_user_cache
  printf '=== Done. ===\n'
}

main "$@"
