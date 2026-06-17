#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# clean_cache
#
# Unified cache cleaner for Arch/Linux developer workstations.
#
# Default targets:
#   - pacman package cache, safely via paccache if available
#   - npm cache
#   - vcpkg downloads/buildtrees/packages
#   - micromamba cache
#   - Cargo cache via cargo-cache if available
#   - rustup download/tmp cache
#   - fnm download/tmp/cache directories, without deleting installed Node versions
#
# Optional targets:
#   - yay cache or all of ~/.cache
#   - browser caches
#   - micromamba environment backup and deletion
#   - common development caches: pip, uv, pnpm, yarn, bun, Go, ccache
#   - container pruning for podman/docker
#
# Safety model:
#   - destructive environment deletion is opt-in
#   - micromamba environments are exported before deletion by default
#   - browsers are skipped if they appear to be running, unless forced
#   - --dry-run prints the operations without changing files
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob dotglob extglob

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
: "${XDG_CACHE_HOME:=${HOME}/.cache}"
: "${XDG_DATA_HOME:=${HOME}/.local/share}"

ASSUME_YES=0
DRY_RUN=0
VERBOSE=0

VCPKG_ROOT_OPT=""
USER_CACHE_ENABLED=0
USER_CACHE_MODE=""
PURGE_PACMAN_DIR=0
PACMAN_MODE="safe"

BROWSER_TARGETS=()
ALL_BROWSERS=0
BROWSER_FORCE_RUNNING=0

MICROMAMBA_DELETE_ENVS=()
MICROMAMBA_DELETE_ALL_ENVS=0
MICROMAMBA_BACKUP_DIR=""
MICROMAMBA_SKIP_BACKUP=0
MICROMAMBA_CACHE_CLEANED=0

RUSTUP_REMOVE_DOCS=0
EXTRA_DEV_CACHES=0
CONTAINER_PRUNE=0

# -----------------------------------------------------------------------------
# Messaging helpers
# -----------------------------------------------------------------------------
function log_info() {
  printf -- '-> %s\n' "$*"
}

function log_ok() {
  printf -- '[OK] %s\n' "$*"
}

function log_warn() {
  printf -- '[WARN] %s\n' "$*" >&2
}

function log_verbose() {
  [[ "$VERBOSE" -eq 1 ]] || return 0
  printf -- '[VERBOSE] %s\n' "$*"
}

function die() {
  printf -- '[ERROR] %s\n' "$*" >&2
  exit 1
}

function lower() {
  printf '%s\n' "${1,,}"
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
function print_help() {
  cat <<'EOF'
Usage:
  clean_cache [options]

Default cleaning targets:
  pacman, npm, vcpkg, micromamba, Cargo, rustup, and fnm.

Safety options:
  -n, --dry-run              Print planned actions without changing files
  -y, --yes                  Do not ask for confirmation
  -v, --verbose              Print additional detail
  -h, -H, --help             Show this help text and exit

Pacman options:
      --pacman-mode safe     Use paccache if available; fallback to pacman -Sc
      --pacman-mode full     Use pacman -Scc; removes all cached packages
      --purge-pacman-dir     Delete all remaining /var/cache/pacman/pkg items

User cache options:
      --user-cache           Enable user cache cleaning
      --clean-yay            Clean only ~/.cache/yay
      --clean-all            Clean all children in ~/.cache

vcpkg options:
  -r, --vcpkg-root PATH      Explicit vcpkg root directory

Browser cache options:
      --browsers LIST        Clean cache for comma-separated browser commands
      --browser NAME         Clean cache for one browser command; repeatable
      --all-browsers         Try common browser cache locations
      --force-running        Clean browser cache even if browser is running

Supported browser names include:
  firefox, librewolf, floorp, waterfox, chromium, google-chrome, brave,
  vivaldi, opera, microsoft-edge, edge, thorium, ungoogled-chromium

Micromamba environment options:
      --micromamba-delete-env NAME
                              Backup and delete a named environment; repeatable
      --micromamba-delete-all-envs
                              Backup and delete all non-base environments
      --micromamba-backup-dir PATH
                              Backup directory for environment specs
      --micromamba-no-backup  Delete environments without exporting specs

Rust options:
      --rustup-remove-docs   Remove installed rust-docs from each toolchain

Extra optional cache targets:
      --extra-dev            Clean pip, uv, pnpm, yarn, bun, Go, and ccache
      --containers           Prune unused podman/docker data

Examples:
  clean_cache
  clean_cache --dry-run --verbose
  clean_cache --pacman-mode safe
  clean_cache --pacman-mode full --yes
  clean_cache --user-cache --clean-yay
  clean_cache --user-cache --clean-all --yes
  clean_cache --browsers firefox,brave
  clean_cache --browser firefox --browser chromium
  clean_cache --all-browsers
  clean_cache --micromamba-delete-env stats-r --yes
  clean_cache --micromamba-delete-all-envs --yes
  clean_cache --micromamba-delete-env old-env --micromamba-backup-dir ~/envs
  clean_cache --extra-dev --containers --yes

Micromamba restore examples:
  micromamba create -n stats-r -f environment.yml
  micromamba create -n stats-r --file explicit.txt

Notes:
  - --clean-yay and --clean-all require --user-cache.
  - --clean-all, --purge-pacman-dir, and environment deletion ask for
    confirmation unless --yes is used.
  - Run the script as your normal user, not with sudo. It invokes sudo only
    for pacman operations and system-owned cache directories.
EOF
}

function usage() {
  print_help
}

# -----------------------------------------------------------------------------
# Generic command and filesystem helpers
# -----------------------------------------------------------------------------
function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

function confirm_or_die() {
  local message="$1"
  local answer=""

  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ ! -t 0 ]]; then
    die "$message Use --yes in non-interactive shells."
  fi

  printf '%s [y/N] ' "$message" >&2
  read -r answer

  case "$(lower "$answer")" in
    y|yes)
      return 0
      ;;
    *)
      die "Cancelled."
      ;;
  esac
}

function realpath_maybe() {
  local path="$1"

  if [[ -e "$path" ]]; then
    realpath -- "$path"
  else
    printf '%s\n' "$path"
  fi
}

function is_dangerous_path() {
  local path="$1"
  local resolved=""

  resolved="$(realpath_maybe "$path")"

  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/opt|/proc|/root|/run|/srv|/sys|/tmp|/usr|/var)
      return 0
      ;;
    "$HOME"|"$XDG_CACHE_HOME")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function remove_path() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    log_verbose "Path not found; skipping: $path"
    return 0
  fi

  if is_dangerous_path "$path"; then
    die "Refusing to remove dangerous path directly: $path"
  fi

  log_info "Removing: $path"
  run_cmd rm -rf -- "$path"
}

function remove_children() {
  local target="$1"
  local child=""

  if [[ ! -d "$target" ]]; then
    log_warn "Directory not found; skipping: $target"
    return 0
  fi

  if is_dangerous_path "$target" && [[ "$target" != "$XDG_CACHE_HOME" ]]; then
    die "Refusing to remove children from dangerous path: $target"
  fi

  for child in "$target"/*; do
    [[ -e "$child" ]] || continue
    remove_path "$child"
  done
}

function sudo_remove_children() {
  local target="$1"

  if [[ ! -d "$target" ]]; then
    log_warn "Directory not found; skipping: $target"
    return 0
  fi

  log_info "Removing children from: $target"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] sudo find %q -mindepth 1 -maxdepth 1 ' "$target"
    printf -- '-exec rm -rf -- {} +\n'
    return 0
  fi

  sudo find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

function append_csv_values() {
  local raw="$1"
  local value=""
  local old_ifs="$IFS"

  IFS=','
  for value in $raw; do
    value="${value##+([[:space:]])}"
    value="${value%%+([[:space:]])}"
    [[ -n "$value" ]] || continue
    BROWSER_TARGETS+=("$(lower "$value")")
  done
  IFS="$old_ifs"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
function parse_args() {
  local opt=""

  while [[ $# -gt 0 ]]; do
    opt="$(lower "$1")"

    case "$opt" in
      -n|--dry-run)
        DRY_RUN=1
        ;;
      -y|--yes)
        ASSUME_YES=1
        ;;
      -v|--verbose)
        VERBOSE=1
        ;;
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
      --pacman-mode)
        shift
        [[ $# -gt 0 ]] || die "--pacman-mode requires safe or full."
        PACMAN_MODE="$(lower "$1")"
        [[ "$PACMAN_MODE" == "safe" || "$PACMAN_MODE" == "full" ]] || \
          die "--pacman-mode must be safe or full."
        ;;
      --browsers)
        shift
        [[ $# -gt 0 ]] || die "--browsers requires a comma-separated list."
        append_csv_values "$1"
        ;;
      --browser)
        shift
        [[ $# -gt 0 ]] || die "--browser requires a browser command name."
        BROWSER_TARGETS+=("$(lower "$1")")
        ;;
      --all-browsers)
        ALL_BROWSERS=1
        ;;
      --force-running)
        BROWSER_FORCE_RUNNING=1
        ;;
      --micromamba-delete-env)
        shift
        [[ $# -gt 0 ]] || die "--micromamba-delete-env requires a name."
        MICROMAMBA_DELETE_ENVS+=("$1")
        ;;
      --micromamba-delete-all-envs)
        MICROMAMBA_DELETE_ALL_ENVS=1
        ;;
      --micromamba-backup-dir)
        shift
        [[ $# -gt 0 ]] || die "--micromamba-backup-dir requires a path."
        MICROMAMBA_BACKUP_DIR="$1"
        ;;
      --micromamba-no-backup)
        MICROMAMBA_SKIP_BACKUP=1
        ;;
      --rustup-remove-docs)
        RUSTUP_REMOVE_DOCS=1
        ;;
      --extra-dev)
        EXTRA_DEV_CACHES=1
        ;;
      --containers)
        CONTAINER_PRUNE=1
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

# -----------------------------------------------------------------------------
# User identity helpers
# -----------------------------------------------------------------------------
function get_invoking_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf -- '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

function get_invoking_home() {
  local user=""

  user="$(get_invoking_user)"
  getent passwd "$user" | cut -d: -f6
}

# -----------------------------------------------------------------------------
# vcpkg resolution
# -----------------------------------------------------------------------------
function resolve_vcpkg_root() {
  local candidate=""
  local exe=""

  if [[ -n "$VCPKG_ROOT_OPT" ]]; then
    candidate="$VCPKG_ROOT_OPT"
  elif [[ -n "${VCPKG_ROOT:-}" ]]; then
    candidate="$VCPKG_ROOT"
  elif command_exists vcpkg; then
    exe="$(command -v vcpkg)"
    candidate="$(dirname "$(realpath "$exe")")"
  elif [[ -x "$HOME/repos/vcpkg/vcpkg" ]]; then
    candidate="$HOME/repos/vcpkg"
  fi

  [[ -n "$candidate" ]] || return 1

  candidate="$(realpath_maybe "$candidate")"

  if [[ -d "$candidate" && -x "$candidate/vcpkg" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# Cleaning functions: package managers and language tools
# -----------------------------------------------------------------------------
function clean_pacman() {
  if ! command_exists pacman; then
    log_warn "pacman not found; skipping."
    return 0
  fi

  if [[ "$PACMAN_MODE" == "safe" && -x /usr/bin/paccache ]]; then
    log_info "Cleaning pacman cache safely with paccache."
    run_cmd sudo paccache -rk1
    run_cmd sudo paccache -ruk0
    log_ok "Pacman cache cleaned with paccache."
    return 0
  fi

  if [[ "$PACMAN_MODE" == "safe" ]]; then
    log_info "paccache not found; falling back to pacman -Sc."
    run_cmd sudo pacman -Sc --noconfirm
    log_ok "Pacman cache cleaned with pacman -Sc."
    return 0
  fi

  confirm_or_die "pacman -Scc removes all cached packages. Continue?"
  log_info "Cleaning pacman cache aggressively with pacman -Scc."
  run_cmd sudo pacman -Scc --noconfirm
  log_ok "Pacman cache cleaned with pacman -Scc."
}

function purge_pacman_dir() {
  local pacman_cache='/var/cache/pacman/pkg'

  [[ "$PURGE_PACMAN_DIR" -eq 1 ]] || return 0

  confirm_or_die "Delete all remaining files in $pacman_cache?"
  log_info "Purging remaining pacman cache contents."
  sudo_remove_children "$pacman_cache"
  log_ok "Pacman cache directory contents removed."
}

function clean_npm() {
  if ! command_exists npm; then
    log_warn "npm not found; skipping."
    return 0
  fi

  log_info "Verifying npm cache."
  run_cmd npm cache verify || true

  log_info "Cleaning npm cache."
  run_cmd npm cache clean --force
  log_ok "npm cache cleaned."
}

function clean_vcpkg() {
  local root=""
  local path=""

  if ! root="$(resolve_vcpkg_root)"; then
    log_warn "Could not resolve vcpkg root; skipping."
    log_warn "Use --vcpkg-root PATH or export VCPKG_ROOT."
    return 0
  fi

  export VCPKG_ROOT="$root"
  log_info "Cleaning vcpkg cache in: $VCPKG_ROOT"

  for path in downloads buildtrees packages; do
    if [[ -d "$VCPKG_ROOT/$path" ]]; then
      remove_path "$VCPKG_ROOT/$path"
      run_cmd mkdir -p -- "$VCPKG_ROOT/$path"
    fi
  done

  log_ok "vcpkg downloads, buildtrees, and packages cleaned."
}

function clean_micromamba_cache() {
  if ! command_exists micromamba; then
    log_warn "micromamba not found; skipping."
    return 0
  fi

  [[ "$MICROMAMBA_CACHE_CLEANED" -eq 0 ]] || return 0

  log_info "Cleaning micromamba cache and unused packages."
  run_cmd micromamba clean --all --yes
  MICROMAMBA_CACHE_CLEANED=1
  log_ok "Micromamba cache cleaned."
}

function clean_cargo() {
  if command_exists cargo-cache; then
    log_info "Cleaning Cargo cache: autoclean."
    run_cmd cargo-cache --autoclean

    log_info "Cleaning Cargo cache: autoclean-expensive."
    run_cmd cargo-cache --autoclean-expensive

    log_ok "Cargo cache cleaned with cargo-cache."
    return 0
  fi

  log_warn "cargo-cache not found; skipping Cargo cache."
  log_warn "Install with: cargo install cargo-cache"
}

function clean_rustup() {
  local rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  local toolchain=""

  if [[ -d "$rustup_home/downloads" ]]; then
    remove_children "$rustup_home/downloads"
  fi

  if [[ -d "$rustup_home/tmp" ]]; then
    remove_children "$rustup_home/tmp"
  fi

  if [[ "$RUSTUP_REMOVE_DOCS" -eq 1 ]] && command_exists rustup; then
    log_info "Removing rust-docs from installed toolchains."
    while read -r toolchain _; do
      [[ -n "$toolchain" ]] || continue
      run_cmd rustup component remove rust-docs --toolchain "$toolchain" || true
    done < <(rustup toolchain list | sed 's/ (default)//; s/ (override)//')
  fi

  log_ok "rustup download/tmp cache cleaned."
}

function clean_fnm() {
  local fnm_dir="${FNM_DIR:-$XDG_DATA_HOME/fnm}"
  local path=""

  log_info "Cleaning fnm cache without deleting installed Node versions."

  for path in \
    "$XDG_CACHE_HOME/fnm" \
    "$fnm_dir/cache" \
    "$fnm_dir/.cache" \
    "$fnm_dir/downloads" \
    "$fnm_dir/tmp" \
    "$fnm_dir/.tmp"; do
    [[ -e "$path" ]] || continue
    remove_path "$path"
  done

  log_ok "fnm cache cleaned."
}

# -----------------------------------------------------------------------------
# Micromamba environment backup/deletion
# -----------------------------------------------------------------------------
function default_micromamba_backup_dir() {
  local stamp=""

  stamp="$(date '+%Y%m%d-%H%M%S')"
  printf '%s\n' "$HOME/.cache/clean_cache/micromamba-envs/$stamp"
}

function list_micromamba_env_names() {
  local json=""

  if ! command_exists micromamba; then
    return 0
  fi

  if command_exists python3; then
    json="$(micromamba env list --json 2>/dev/null || true)"

    if [[ -n "$json" ]]; then
      python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
root = os.path.realpath(data.get("root_prefix", ""))
for path in data.get("envs", []):
    real = os.path.realpath(path)
    name = "base" if root and real == root else os.path.basename(real)
    if name and name != "base":
        print(name)
' <<< "$json"
      return 0
    fi
  fi

  micromamba env list 2>/dev/null | awk '
    $NF ~ /\/envs\// {
      name=$1
      if (name == "" || name == "*") {
        n=split($NF, parts, "/")
        name=parts[n]
      }
      if (name != "base") print name
    }
  '
}

function backup_micromamba_env() {
  local env_name="$1"
  local backup_root="$2"
  local env_dir=""

  [[ "$MICROMAMBA_SKIP_BACKUP" -eq 0 ]] || return 0

  env_dir="$backup_root/$env_name"

  log_info "Backing up micromamba environment spec: $env_name"
  run_cmd mkdir -p -- "$env_dir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] micromamba env export -n %q > %q\n' \
      "$env_name" "$env_dir/environment.yml"
    printf '[DRY-RUN] micromamba list -n %q --explicit > %q\n' \
      "$env_name" "$env_dir/explicit.txt"
  else
    micromamba env export -n "$env_name" > "$env_dir/environment.yml" || \
      log_warn "Could not export environment.yml for: $env_name"

    micromamba list -n "$env_name" --explicit > "$env_dir/explicit.txt" || \
      log_warn "Could not export explicit.txt for: $env_name"

    cat > "$env_dir/README.md" <<EOF
# Micromamba environment backup: $env_name

Recreate from portable YAML:

\`\`\`sh
micromamba create -n $env_name -f environment.yml
\`\`\`

Recreate from explicit package list:

\`\`\`sh
micromamba create -n $env_name --file explicit.txt
\`\`\`

The explicit file is usually less portable across platforms, but more exact.
EOF
  fi

  log_ok "Micromamba environment spec backed up: $env_name"
}

function delete_micromamba_env() {
  local env_name="$1"

  [[ "$env_name" != "base" ]] || die "Refusing to delete base environment."

  log_info "Deleting micromamba environment: $env_name"
  run_cmd micromamba env remove -n "$env_name" --yes
  log_ok "Micromamba environment deleted: $env_name"
}

function handle_micromamba_env_deletions() {
  local backup_root=""
  local env_name=""
  local envs_to_delete=()

  if [[ "${#MICROMAMBA_DELETE_ENVS[@]}" -eq 0 && \
        "$MICROMAMBA_DELETE_ALL_ENVS" -eq 0 ]]; then
    return 0
  fi

  command_exists micromamba || die "micromamba is required for env deletion."

  if [[ "$MICROMAMBA_DELETE_ALL_ENVS" -eq 1 ]]; then
    readarray -t envs_to_delete < <(list_micromamba_env_names)
  fi

  if [[ "${#MICROMAMBA_DELETE_ENVS[@]}" -gt 0 ]]; then
    envs_to_delete+=("${MICROMAMBA_DELETE_ENVS[@]}")
  fi

  [[ "${#envs_to_delete[@]}" -gt 0 ]] || {
    log_warn "No non-base micromamba environments found to delete."
    return 0
  }

  backup_root="${MICROMAMBA_BACKUP_DIR:-$(default_micromamba_backup_dir)}"
  backup_root="${backup_root/#\~/$HOME}"

  printf 'Micromamba environments selected for deletion:\n' >&2
  printf '  - %s\n' "${envs_to_delete[@]}" >&2

  if [[ "$MICROMAMBA_SKIP_BACKUP" -eq 1 ]]; then
    confirm_or_die "Delete these micromamba environments without backup?"
  else
    confirm_or_die "Backup specs and delete these micromamba environments?"
  fi

  for env_name in "${envs_to_delete[@]}"; do
    backup_micromamba_env "$env_name" "$backup_root"
    delete_micromamba_env "$env_name"
  done

  clean_micromamba_cache

  if [[ "$MICROMAMBA_SKIP_BACKUP" -eq 0 ]]; then
    log_ok "Micromamba backups written under: $backup_root"
  fi
}

# -----------------------------------------------------------------------------
# Browser cleaning
# -----------------------------------------------------------------------------
function browser_process_names() {
  local browser="$1"

  case "$browser" in
    firefox|firefox-developer-edition)
      printf '%s\n' firefox firefox-bin firefox-developer-edition
      ;;
    librewolf)
      printf '%s\n' librewolf librewolf-bin
      ;;
    floorp)
      printf '%s\n' floorp floorp-bin
      ;;
    waterfox)
      printf '%s\n' waterfox waterfox-bin
      ;;
    chromium|ungoogled-chromium)
      printf '%s\n' chromium chromium-browser chrome
      ;;
    google-chrome|chrome|google-chrome-stable)
      printf '%s\n' chrome google-chrome google-chrome-stable
      ;;
    brave|brave-browser)
      printf '%s\n' brave brave-browser chrome
      ;;
    vivaldi)
      printf '%s\n' vivaldi vivaldi-bin
      ;;
    opera)
      printf '%s\n' opera opera-bin
      ;;
    microsoft-edge|edge)
      printf '%s\n' msedge microsoft-edge microsoft-edge-stable
      ;;
    thorium)
      printf '%s\n' thorium thorium-browser
      ;;
    *)
      printf '%s\n' "$browser"
      ;;
  esac
}

function browser_is_running() {
  local browser="$1"
  local proc=""

  while read -r proc; do
    [[ -n "$proc" ]] || continue
    pgrep -x "$proc" >/dev/null 2>&1 && return 0
  done < <(browser_process_names "$browser")

  return 1
}

function clean_firefox_like_browser() {
  local base="$1"
  local profile=""
  local path=""

  [[ -d "$base" ]] || return 0

  for profile in "$base"/*; do
    [[ -d "$profile" ]] || continue
    for path in cache2 startupCache thumbnails; do
      [[ -e "$profile/$path" ]] || continue
      remove_path "$profile/$path"
    done
  done
}

function clean_chromium_like_browser() {
  local base="$1"
  local profile=""
  local path=""

  [[ -d "$base" ]] || return 0

  for profile in "$base"/*; do
    [[ -d "$profile" ]] || continue

    for path in \
      'Cache' \
      'Code Cache' \
      'DawnCache' \
      'GPUCache' \
      'GrShaderCache' \
      'ShaderCache' \
      'blob_storage' \
      'component_crx_cache' \
      'optimization_guide_prediction_model_downloads' \
      'optimization_guide_model_store'; do
      [[ -e "$profile/$path" ]] || continue
      remove_path "$profile/$path"
    done
  done

  for path in \
    'Crash Reports' \
    'ShaderCache' \
    'GrShaderCache' \
    'component_crx_cache'; do
    [[ -e "$base/$path" ]] || continue
    remove_path "$base/$path"
  done
}

function clean_one_browser() {
  local browser="$1"

  if [[ "$BROWSER_FORCE_RUNNING" -eq 0 ]] && browser_is_running "$browser"; then
    log_warn "Browser appears to be running; skipping cache: $browser"
    log_warn "Close it first or use --force-running."
    return 0
  fi

  log_info "Cleaning browser cache: $browser"

  case "$browser" in
    firefox|firefox-developer-edition)
      clean_firefox_like_browser "$XDG_CACHE_HOME/mozilla/firefox"
      clean_firefox_like_browser "$XDG_CACHE_HOME/firefox"
      ;;
    librewolf)
      clean_firefox_like_browser "$XDG_CACHE_HOME/librewolf"
      ;;
    floorp)
      clean_firefox_like_browser "$XDG_CACHE_HOME/floorp"
      ;;
    waterfox)
      clean_firefox_like_browser "$XDG_CACHE_HOME/waterfox"
      ;;
    chromium|ungoogled-chromium)
      clean_chromium_like_browser "$XDG_CACHE_HOME/chromium"
      ;;
    google-chrome|chrome|google-chrome-stable)
      clean_chromium_like_browser "$XDG_CACHE_HOME/google-chrome"
      ;;
    brave|brave-browser)
      clean_chromium_like_browser "$XDG_CACHE_HOME/BraveSoftware/Brave-Browser"
      ;;
    vivaldi)
      clean_chromium_like_browser "$XDG_CACHE_HOME/vivaldi"
      ;;
    opera)
      clean_chromium_like_browser "$XDG_CACHE_HOME/opera"
      ;;
    microsoft-edge|edge)
      clean_chromium_like_browser "$XDG_CACHE_HOME/microsoft-edge"
      ;;
    thorium)
      clean_chromium_like_browser "$XDG_CACHE_HOME/thorium"
      ;;
    *)
      if [[ "$browser" == */* ]]; then
        log_warn "Unsupported browser name with slash: $browser"
        return 0
      fi

      if [[ -d "$XDG_CACHE_HOME/$browser" ]]; then
        remove_children "$XDG_CACHE_HOME/$browser"
      else
        log_warn "Unsupported browser name: $browser"
      fi
      return 0
      ;;
  esac

  log_ok "Browser cache cleaned: $browser"
}

function clean_browser_caches() {
  local browser=""
  local default_browsers=(
    firefox
    librewolf
    floorp
    waterfox
    chromium
    google-chrome
    brave
    vivaldi
    opera
    microsoft-edge
    thorium
    ungoogled-chromium
  )

  if [[ "$ALL_BROWSERS" -eq 1 ]]; then
    BROWSER_TARGETS+=("${default_browsers[@]}")
  fi

  [[ "${#BROWSER_TARGETS[@]}" -gt 0 ]] || return 0

  for browser in "${BROWSER_TARGETS[@]}"; do
    clean_one_browser "$(lower "$browser")"
  done
}

# -----------------------------------------------------------------------------
# Optional user cache cleaning
# -----------------------------------------------------------------------------
function clean_user_cache() {
  local user_home=""

  [[ "$USER_CACHE_ENABLED" -eq 1 ]] || return 0

  user_home="$(get_invoking_home)"

  case "$USER_CACHE_MODE" in
    yay)
      log_info "Cleaning yay cache: $user_home/.cache/yay"
      remove_children "$user_home/.cache/yay"
      log_ok "yay cache cleaned."
      ;;
    all)
      confirm_or_die "Delete all children in $user_home/.cache?"
      log_info "Cleaning full user cache: $user_home/.cache"
      remove_children "$user_home/.cache"
      log_ok "Full user cache cleaned."
      ;;
    *)
      die "Internal error: unsupported USER_CACHE_MODE='$USER_CACHE_MODE'"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Extra optional development caches
# -----------------------------------------------------------------------------
function clean_extra_dev_caches() {
  [[ "$EXTRA_DEV_CACHES" -eq 1 ]] || return 0

  if command_exists python3; then
    log_info "Cleaning pip cache through python3."
    run_cmd python3 -m pip cache purge || true
  elif command_exists pip; then
    log_info "Cleaning pip cache."
    run_cmd pip cache purge || true
  fi

  if command_exists uv; then
    log_info "Cleaning uv cache."
    run_cmd uv cache clean || true
  fi

  if command_exists pnpm; then
    log_info "Pruning pnpm store."
    run_cmd pnpm store prune || true
  fi

  if command_exists yarn; then
    log_info "Cleaning yarn cache."
    run_cmd yarn cache clean || true
  fi

  if command_exists bun; then
    log_info "Cleaning bun cache."
    run_cmd bun pm cache rm || true
  fi

  if command_exists go; then
    log_info "Cleaning Go build, module, test, and fuzz caches."
    run_cmd go clean -cache -modcache -testcache -fuzzcache || true
  fi

  if command_exists ccache; then
    log_info "Cleaning ccache."
    run_cmd ccache --clear || true
  fi

  log_ok "Extra development caches cleaned."
}

function clean_containers() {
  [[ "$CONTAINER_PRUNE" -eq 1 ]] || return 0

  confirm_or_die "Prune unused podman/docker images, containers, and cache?"

  if command_exists podman; then
    log_info "Pruning podman system data."
    run_cmd podman system prune --all --force || true
  fi

  if command_exists docker; then
    log_info "Pruning docker system data."
    run_cmd docker system prune --all --force || true
  fi

  log_ok "Container prune complete."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
function main() {
  parse_args "$@"

  if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    die "Run clean_cache without sudo; the script invokes sudo when needed."
  fi

  printf '=== Starting unified cache cleaning ===\n'

  clean_pacman
  purge_pacman_dir
  clean_npm
  clean_vcpkg
  handle_micromamba_env_deletions
  clean_micromamba_cache
  clean_cargo
  clean_rustup
  clean_fnm
  clean_browser_caches
  clean_user_cache
  clean_extra_dev_caches
  clean_containers

  printf '=== Done. ===\n'
}

main "$@"
