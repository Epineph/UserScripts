#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install-hypr-env-asus-amd.sh
#
# Install conservative Hyprland/UWSM environment-variable files for an ASUS
# Ryzen 7 3700U / Radeon Vega Mobile laptop.
# -----------------------------------------------------------------------------

set -euo pipefail

function backup_if_exists() {
  local path="$1"

  if [[ -e "$path" ]]; then
    cp -a -- "$path" "${path}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

function install_legacy_conf() {
  local src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local dst_dir="$HOME/.config/hypr/conf"
  local dst_file="$dst_dir/hypr-env-asus-amd.conf"

  mkdir -p -- "$dst_dir"
  backup_if_exists "$dst_file"
  cp -a -- "$src_dir/hypr-env-asus-amd.conf" "$dst_file"

  printf 'Installed: %s\n' "$dst_file"
  printf 'Add this to ~/.config/hypr/hyprland.conf if not already present:\n'
  printf '  source = ~/.config/hypr/conf/hypr-env-asus-amd.conf\n'
}

function install_lua_snippet() {
  local src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local dst_dir="$HOME/.config/hypr"
  local dst_file="$dst_dir/hypr-env-asus-amd.lua"

  mkdir -p -- "$dst_dir"
  backup_if_exists "$dst_file"
  cp -a -- "$src_dir/hypr-env-asus-amd.lua" "$dst_file"

  printf 'Installed: %s\n' "$dst_file"
  printf 'This is a Lua snippet. Paste/source its contents near the top of your hyprland.lua.\n'
}

function install_uwsm_files() {
  local src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local dst_dir="$HOME/.config/uwsm"

  mkdir -p -- "$dst_dir"

  backup_if_exists "$dst_dir/env"
  backup_if_exists "$dst_dir/env-hyprland"

  cp -a -- "$src_dir/uwsm-env-asus-amd" "$dst_dir/env"
  cp -a -- "$src_dir/uwsm-env-hyprland-asus-amd" "$dst_dir/env-hyprland"

  printf 'Installed: %s\n' "$dst_dir/env"
  printf 'Installed: %s\n' "$dst_dir/env-hyprland"
}

function print_help() {
  cat <<'HELP'
Usage:
  ./install-hypr-env-asus-amd.sh [MODE]

Modes:
  --legacy-conf    Install ~/.config/hypr/conf/hypr-env-asus-amd.conf
  --lua-snippet    Install ~/.config/hypr/hypr-env-asus-amd.lua
  --uwsm           Install ~/.config/uwsm/env and ~/.config/uwsm/env-hyprland
  --all            Install all files
  -h, --help       Show this help

Recommended:
  If you still use hyprland.conf/includes:
    ./install-hypr-env-asus-amd.sh --legacy-conf

  If you launch through UWSM:
    ./install-hypr-env-asus-amd.sh --uwsm

  If you are migrating to Hyprland >= 0.55 Lua config:
    ./install-hypr-env-asus-amd.sh --lua-snippet
HELP
}

case "${1:---legacy-conf}" in
  --legacy-conf)
    install_legacy_conf
    ;;
  --lua-snippet)
    install_lua_snippet
    ;;
  --uwsm)
    install_uwsm_files
    ;;
  --all)
    install_legacy_conf
    install_lua_snippet
    install_uwsm_files
    ;;
  -h|--help)
    print_help
    ;;
  *)
    printf 'Error: unknown mode: %s\n\n' "$1" >&2
    print_help >&2
    exit 2
    ;;
esac
