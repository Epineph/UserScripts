#!/usr/bin/env bash
#===============================================================================
# clean_cache
#
# Unified cache cleaner for Arch Linux + common developer tooling.
#
# Philosophy:
#   - Default behavior is conservative ("prune" rather than "nuke").
#   - Prefer package-manager commands over rm -rf in system paths.
#   - User caches are removed only in well-known cache locations.
#
# Components (toggle via --only / --skip):
#   pacman, journal, aur, npm, pnpm, yarn, pip, go, cargo, vcpkg, mamba,
#   vscode, browsers, thumbnails, gpu, docker
#
# Examples:
#   clean_cache
#   clean_cache --dry-run --summary
#   clean_cache --only pacman,journal
#   clean_cache --skip browsers
#   clean_cache --journal-time 7d --keep-pkgs 2
#   clean_cache --aggressive --only pacman,aur,cargo
#
# Notes:
#   - --aggressive enables more destructive actions and may prompt unless --yes.
#   - pacman cache: uses paccache (keep N) if available; falls back safely.
#   - journal: vacuums by time/size (defaults to 14d).
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------
DRY_RUN=0
YES=0
AGGRESSIVE=0
KEEP_PKGS=2
JOURNAL_TIME="14d"
JOURNAL_SIZE=""
VCPKG_ROOT="${VCPKG_ROOT:-}"

ONLY=""
SKIP=""
SUMMARY=0

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
function log_info() {
  printf 'INFO: %s\n' "$*"
}

function log_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

function log_ok() {
  printf 'OK:   %s\n' "$*"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function run_cmd() {
  if (( DRY_RUN )); then
    printf 'DRY:  '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

function norm_csv() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '[:space:]'
}

function csv_has() {
  local csv
  local item
  csv="$(norm_csv "${1:-}")"
  item="$(norm_csv "${2:-}")"
  [[ -z "$csv" ]] && return 1
  [[ ",$csv," == *",$item,"* ]]
}

function is_enabled() {
  local comp="$1"
  if [[ -n "${ONLY:-}" ]]; then
    csv_has "$ONLY" "$comp"
    return $?
  fi
  if [[ -n "${SKIP:-}" ]]; then
    if csv_has "$SKIP" "$comp"; then
      return 1
    fi
  fi
  return 0
}

function confirm() {
  local prompt="$1"
  if (( YES )); then
    return 0
  fi
  if ! [[ -t 0 ]]; then
    log_warn "Non-interactive shell; refusing without --yes: $prompt"
    return 1
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

function maybe_du() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  have_cmd du || return 0
  du -sh -- "$path" 2>/dev/null || true
}

function show_help() {
  cat <<'EOF'
Usage: clean_cache [options]

Options:
  -n, --dry-run             Print actions without executing them
  -y, --yes                 Assume "yes" for prompts (use with care)
      --aggressive           Enable more destructive actions
      --keep-pkgs N          pacman: keep last N versions (default: 2)
      --journal-time DUR     Vacuum journal by time (default: 14d)
      --journal-size SIZE    Vacuum journal by size (e.g. 500M, 2G)
  -r, --vcpkg-root PATH      vcpkg root (default: $VCPKG_ROOT)
      --only LIST            Run only these components (CSV)
      --skip LIST            Skip these components (CSV)
      --summary              Print sizes for common cache locations
  -h, --help                 Show this help and exit

Components:
  pacman      pacman cache (paccache preferred)
  journal     systemd journal vacuum
  aur         yay/paru cache cleanup
  npm         npm cache clean
  pnpm        pnpm store prune
  yarn        yarn cache clean
  pip         pip cache purge
  go          go module cache clean
  cargo       cargo-cache autoclean (optional aggressive rm of ~/.cargo)
  vcpkg       rm vcpkg downloads/buildtrees under VCPKG_ROOT
  mamba       micromamba clean --all
  vscode      rm VS Code extension download cache
  browsers    rm well-known browser caches (Chrome/Brave/Edge/Firefox/Tor)
  thumbnails  rm freedesktop thumbnail caches
  gpu         rm Mesa shader cache + common GPU caches
  docker      docker system prune (DISABLED unless explicitly selected)

Examples:
  clean_cache
  clean_cache --dry-run --summary
  clean_cache --only pacman,journal
  clean_cache --skip browsers
  clean_cache --journal-time 7d --keep-pkgs 2
  clean_cache --aggressive --only pacman,aur,cargo
EOF
}

# ------------------------------------------------------------------------------
# Parse options
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      ;;
    -y|--yes)
      YES=1
      ;;
    --aggressive)
      AGGRESSIVE=1
      ;;
    --keep-pkgs)
      shift
      KEEP_PKGS="${1:-}"
      ;;
    --journal-time)
      shift
      JOURNAL_TIME="${1:-}"
      ;;
    --journal-size)
      shift
      JOURNAL_SIZE="${1:-}"
      ;;
    -r|--vcpkg-root)
      shift
      VCPKG_ROOT="${1:-}"
      ;;
    --only)
      shift
      ONLY="${1:-}"
      ;;
    --skip)
      shift
      SKIP="${1:-}"
      ;;
    --summary)
      SUMMARY=1
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_warn "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Summary (optional)
# ------------------------------------------------------------------------------
function print_summary() {
  log_info "Size summary (best-effort; paths may not exist):"
  maybe_du /var/log/journal
  maybe_du "${HOME}/.cache"
  maybe_du "${HOME}/.cache/google-chrome"
  maybe_du "${HOME}/.config/google-chrome/component_crx_cache"
  maybe_du "${HOME}/.config/Code/CachedExtensionVSIXs"
  maybe_du "${HOME}/.cargo/registry"
  maybe_du "${HOME}/go/pkg/mod"
}

# ------------------------------------------------------------------------------
# Component: pacman cache
# ------------------------------------------------------------------------------
function clean_pacman() {
  have_cmd pacman || { log_warn "pacman not found; skipping pacman"; return 0; }

  if (( AGGRESSIVE )); then
    log_info "pacman cache (aggressive): pacman -Scc"
    if confirm "This removes ALL cached packages. Proceed?"; then
      run_cmd sudo pacman -Scc --noconfirm
      log_ok "pacman cache cleaned (aggressive)."
    fi
    return 0
  fi

  if have_cmd paccache; then
    log_info "pacman cache: paccache keep=${KEEP_PKGS}"
    run_cmd sudo paccache -r -k "${KEEP_PKGS}"
    log_ok "pacman cache pruned (paccache)."
    return 0
  fi

  log_info "pacman cache: fallback pacman -Sc (no paccache)"
  run_cmd sudo pacman -Sc --noconfirm
  log_ok "pacman cache pruned (pacman -Sc)."
}

# ------------------------------------------------------------------------------
# Component: systemd journal
# ------------------------------------------------------------------------------
function clean_journal() {
  have_cmd journalctl || { log_warn "journalctl not found; skipping journal"; return 0; }

  log_info "systemd journal: rotating"
  run_cmd sudo journalctl --rotate

  if [[ -n "${JOURNAL_TIME:-}" ]]; then
    log_info "systemd journal: vacuum by time (${JOURNAL_TIME})"
    run_cmd sudo journalctl --vacuum-time="${JOURNAL_TIME}"
  fi

  if [[ -n "${JOURNAL_SIZE:-}" ]]; then
    log_info "systemd journal: vacuum by size (${JOURNAL_SIZE})"
    run_cmd sudo journalctl --vacuum-size="${JOURNAL_SIZE}"
  fi

  log_ok "systemd journal vacuum complete."
}

# ------------------------------------------------------------------------------
# Component: AUR helper caches (yay/paru)
# ------------------------------------------------------------------------------
function clean_aur() {
  local helper=""
  if have_cmd yay; then
    helper="yay"
  elif have_cmd paru; then
    helper="paru"
  else
    log_warn "yay/paru not found; skipping aur"
    return 0
  fi

  if (( AGGRESSIVE )); then
    log_info "AUR helper cache (aggressive): ${helper} -Scc"
    if confirm "This removes ALL ${helper} caches. Proceed?"; then
      run_cmd "${helper}" -Scc --noconfirm
      log_ok "AUR cache cleaned (aggressive)."
    fi
    return 0
  fi

  log_info "AUR helper cache: ${helper} -Sc"
  run_cmd "${helper}" -Sc --noconfirm
  log_ok "AUR cache pruned."
}

# ------------------------------------------------------------------------------
# Component: npm cache
# ------------------------------------------------------------------------------
function clean_npm() {
  have_cmd npm || { log_warn "npm not found; skipping npm"; return 0; }
  log_info "npm cache clean --force"
  run_cmd npm cache clean --force
  log_ok "npm cache cleaned."
}

# ------------------------------------------------------------------------------
# Component: pnpm store
# ------------------------------------------------------------------------------
function clean_pnpm() {
  have_cmd pnpm || { log_warn "pnpm not found; skipping pnpm"; return 0; }
  log_info "pnpm store prune"
  run_cmd pnpm store prune
  log_ok "pnpm store pruned."
}

# ------------------------------------------------------------------------------
# Component: yarn cache
# ------------------------------------------------------------------------------
function clean_yarn() {
  have_cmd yarn || { log_warn "yarn not found; skipping yarn"; return 0; }
  log_info "yarn cache clean"
  run_cmd yarn cache clean || true
  log_ok "yarn cache cleaned (best-effort)."
}

# ------------------------------------------------------------------------------
# Component: pip cache
# ------------------------------------------------------------------------------
function clean_pip() {
  if have_cmd pip; then
    log_info "pip cache purge"
    run_cmd pip cache purge || true
    log_ok "pip cache purged (best-effort)."
    return 0
  fi

  if have_cmd python; then
    log_info "python -m pip cache purge"
    run_cmd python -m pip cache purge || true
    log_ok "pip cache purged via python (best-effort)."
    return 0
  fi

  log_warn "pip/python not found; skipping pip"
}

# ------------------------------------------------------------------------------
# Component: Go module cache
# ------------------------------------------------------------------------------
function clean_go() {
  have_cmd go || { log_warn "go not found; skipping go"; return 0; }
  log_info "go clean -modcache"
  run_cmd go clean -modcache
  log_ok "Go module cache cleaned."
}

# ------------------------------------------------------------------------------
# Component: Cargo caches
# ------------------------------------------------------------------------------
function clean_cargo() {
  if have_cmd cargo-cache; then
    log_info "cargo-cache --autoclean"
    run_cmd cargo-cache --autoclean
    log_info "cargo-cache --autoclean-expensive"
    run_cmd cargo-cache --autoclean-expensive
    log_ok "Cargo cache cleaned (cargo-cache)."
  else
    log_warn "cargo-cache not found; skipping cargo-cache autoclean"
    log_warn "Install with: cargo install cargo-cache"
  fi

  if (( AGGRESSIVE )); then
    local cargo_root="${HOME}/.cargo"
    if [[ -d "$cargo_root" ]]; then
      log_info "cargo (aggressive): removing ~/.cargo/{registry,git}"
      if confirm "Delete ~/.cargo/registry and ~/.cargo/git?"; then
        run_cmd rm -rf -- "${cargo_root}/registry" "${cargo_root}/git"
        log_ok "Cargo registries removed."
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# Component: vcpkg cache
# ------------------------------------------------------------------------------
function clean_vcpkg() {
  have_cmd vcpkg || { log_warn "vcpkg not found; skipping vcpkg"; return 0; }

  if [[ -z "${VCPKG_ROOT:-}" ]]; then
    log_warn "VCPKG_ROOT not set; skipping vcpkg"
    return 0
  fi
  if [[ ! -d "$VCPKG_ROOT" ]]; then
    log_warn "VCPKG_ROOT not found: $VCPKG_ROOT; skipping vcpkg"
    return 0
  fi

  log_info "vcpkg: removing downloads/ and buildtrees/ under $VCPKG_ROOT"
  run_cmd rm -rf -- \
    "${VCPKG_ROOT}/downloads" \
    "${VCPKG_ROOT}/buildtrees"
  log_ok "vcpkg caches removed."
}

# ------------------------------------------------------------------------------
# Component: micromamba cache
# ------------------------------------------------------------------------------
function clean_mamba() {
  have_cmd micromamba || { log_warn "micromamba not found; skipping mamba"; return 0; }
  log_info "micromamba clean --all --yes"
  run_cmd micromamba clean --all --yes
  log_ok "micromamba cache cleaned."
}

# ------------------------------------------------------------------------------
# Component: VS Code cache
# ------------------------------------------------------------------------------
function clean_vscode() {
  local vsix="${HOME}/.config/Code/CachedExtensionVSIXs"
  if [[ -d "$vsix" ]]; then
    log_info "vscode: removing cached VSIX downloads: $vsix"
    run_cmd rm -rf -- "$vsix"
    log_ok "VS Code extension cache removed."
  else
    log_warn "VS Code CachedExtensionVSIXs not found; skipping vscode"
  fi
}

# ------------------------------------------------------------------------------
# Component: Browser caches (well-known, non-profile paths)
# ------------------------------------------------------------------------------
function clean_browsers() {
  log_info "browsers: removing well-known cache paths (non-profile)"

  run_cmd rm -rf -- \
    "${HOME}/.cache/google-chrome" \
    "${HOME}/.cache/chromium" \
    "${HOME}/.cache/microsoft-edge" \
    "${HOME}/.cache/BraveSoftware"

  run_cmd rm -rf -- \
    "${HOME}/.config/google-chrome/Default/Service Worker/CacheStorage" \
    "${HOME}/.config/chromium/Default/Service Worker/CacheStorage" \
    "${HOME}/.config/microsoft-edge/Default/Service Worker/CacheStorage" \
    "${HOME}/.config/BraveSoftware/Brave-Browser/Default/Service Worker/CacheStorage"

  run_cmd rm -rf -- \
    "${HOME}/.config/google-chrome/component_crx_cache" \
    "${HOME}/.config/google-chrome/extensions_crx_cache"

  run_cmd rm -rf -- "${HOME}/.cache/mozilla/firefox"
  run_cmd rm -rf -- "${HOME}/.cache/torbrowser/download"

  run_cmd rm -rf -- \
    "${HOME}/.cache/ZapZap/QtWebEngine" \
    "${HOME}/.cache/ZapZap/QtWebEngine/storage-whats"

  log_ok "Browser caches cleaned (best-effort)."
}

# ------------------------------------------------------------------------------
# Component: Thumbnails
# ------------------------------------------------------------------------------
function clean_thumbnails() {
  log_info "thumbnails: removing ~/.cache/thumbnails"
  run_cmd rm -rf -- "${HOME}/.cache/thumbnails"
  log_ok "Thumbnail caches removed."
}

# ------------------------------------------------------------------------------
# Component: GPU caches (Mesa shader cache etc.)
# ------------------------------------------------------------------------------
function clean_gpu() {
  log_info "gpu: removing common GPU caches"
  run_cmd rm -rf -- \
    "${HOME}/.cache/mesa_shader_cache" \
    "${HOME}/.cache/radv_builtin_shaders64" \
    "${HOME}/.cache/amdvlk"
  log_ok "GPU caches removed (best-effort)."
}

# ------------------------------------------------------------------------------
# Component: Docker (disabled unless explicitly selected)
# ------------------------------------------------------------------------------
function clean_docker() {
  have_cmd docker || { log_warn "docker not found; skipping docker"; return 0; }

  log_warn "docker: potentially destructive; only run when explicitly selected"
  if ! (( AGGRESSIVE )); then
    log_warn "docker: refusing without --aggressive"
    return 0
  fi

  if confirm "Run: docker system prune -a --volumes ?"; then
    run_cmd docker system prune -a --volumes -f
    log_ok "Docker pruned."
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
log_info "Starting cache cleaning"

if (( SUMMARY )); then
  print_summary
fi

if is_enabled pacman; then      clean_pacman;      fi
if is_enabled journal; then     clean_journal;     fi
if is_enabled aur; then         clean_aur;         fi
if is_enabled npm; then         clean_npm;         fi
if is_enabled pnpm; then        clean_pnpm;        fi
if is_enabled yarn; then        clean_yarn;        fi
if is_enabled pip; then         clean_pip;         fi
if is_enabled go; then          clean_go;          fi
if is_enabled cargo; then       clean_cargo;       fi
if is_enabled vcpkg; then       clean_vcpkg;       fi
if is_enabled mamba; then       clean_mamba;       fi
if is_enabled vscode; then      clean_vscode;      fi
if is_enabled browsers; then    clean_browsers;    fi
if is_enabled thumbnails; then  clean_thumbnails;  fi
if is_enabled gpu; then         clean_gpu;         fi
if is_enabled docker; then      clean_docker;      fi

if (( SUMMARY )); then
  print_summary
fi

log_ok "All done"
