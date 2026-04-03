#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install-script
#
# Purpose:
#   Install one or more scripts into /usr/local/bin with deterministic
#   ownership/mode, optionally stripping a trailing ".sh" extension.
#
# Key behavior:
#   - Destination defaults to: /usr/local/bin
#   - If a source basename ends with ".sh", it is installed without ".sh"
#   - Owner/group/mode default to: root:root 0755
#   - Conflict policy: ask|overwrite|skip|backup (default: ask)
#
# Examples:
#   install-script ~/bin/foo.sh
#   install-script --conflict overwrite --mode 0755 ./myscript.sh ./bar
#   install-script --dest /usr/local/sbin --no-strip-sh ./tool.sh
# -----------------------------------------------------------------------------

set -euo pipefail

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function lowercase() {
  # shellcheck disable=SC2001
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function join_by() {
  local IFS="$1"
  shift
  printf '%s' "$*"
}

function print_help() {
  local pager="${HELP_PAGER:-}"
  local use_pager="${USE_PAGER:-0}"

  if [[ "${use_pager}" -eq 1 ]]; then
    if [[ -z "${pager}" ]]; then
      if have bat; then
        pager='bat --paging=always --plain'
      elif have less; then
        pager='less -R'
      else
        pager='cat'
      fi
    fi
    cat <<'EOF' | eval "${pager}"
Usage:
  install-script [OPTIONS] <file> [file2 ...]

Options:
  -d, --dest DIR          Destination directory (default: /usr/local/bin)
      --owner USER        Owner for installed files (default: root)
      --group GROUP       Group for installed files (default: root)
      --mode MODE         Mode for installed files (default: 0755)
      --[no-]strip-sh     Strip trailing ".sh" from basenames (default: on)
      --conflict POLICY   ask|overwrite|skip|backup (default: ask)
      --dry-run           Print actions, do not change anything
      --pager             Page --help output (uses HELP_PAGER if set)
  -h, --help              Show this help

Notes:
  - If not run as root, the script re-execs itself via sudo.
  - "backup" renames the existing destination to:
      <name>.bak.<YYYYMMDD-HHMMSS>

Examples:
  install-script ~/scripts/foo.sh
  install-script --conflict overwrite ./a.sh ./b.sh
  install-script --dest /usr/local/sbin --no-strip-sh ./tool.sh
EOF
  else
    cat <<'EOF'
Usage:
  install-script [OPTIONS] <file> [file2 ...]

Options:
  -d, --dest DIR          Destination directory (default: /usr/local/bin)
      --owner USER        Owner for installed files (default: root)
      --group GROUP       Group for installed files (default: root)
      --mode MODE         Mode for installed files (default: 0755)
      --[no-]strip-sh     Strip trailing ".sh" from basenames (default: on)
      --conflict POLICY   ask|overwrite|skip|backup (default: ask)
      --dry-run           Print actions, do not change anything
      --pager             Page --help output (uses HELP_PAGER if set)
  -h, --help              Show this help

Notes:
  - If not run as root, the script re-execs itself via sudo.
  - "backup" renames the existing destination to:
      <name>.bak.<YYYYMMDD-HHMMSS>

Examples:
  install-script ~/scripts/foo.sh
  install-script --conflict overwrite ./a.sh ./b.sh
  install-script --dest /usr/local/sbin --no-strip-sh ./tool.sh
EOF
  fi
}

function ensure_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if ! have sudo; then
    die "Must run as root or have sudo available."
  fi

  exec sudo -- "$0" "$@"
}

function validate_mode() {
  local mode="$1"
  if [[ ! "${mode}" =~ ^0?[0-7]{3,4}$ ]]; then
    die "Invalid --mode '${mode}'. Expected e.g. 0755 or 755."
  fi
}

function resolve_dest_name() {
  local src="$1"
  local base
  base="$(basename -- "${src}")"

  if [[ "${STRIP_SH}" -eq 1 && "${base}" == *.sh ]]; then
    printf '%s' "${base%.sh}"
  else
    printf '%s' "${base}"
  fi
}

function install_one() {
  local src="$1"
  local dest_name="$2"
  local dest_path="${DEST_DIR%/}/${dest_name}"

  [[ -e "${src}" ]] || { warn "Missing: ${src} (skipping)"; return 0; }
  [[ -f "${src}" ]] || { warn "Not a regular file: ${src} (skipping)"; return 0; }

  if [[ -e "${dest_path}" ]]; then
    case "${CONFLICT}" in
      overwrite)
        ;;
      skip)
        printf "Skip: %s (exists)\n" "${dest_path}"
        return 0
        ;;
      backup)
        local ts bak
        ts="$(date +%Y%m%d-%H%M%S)"
        bak="${dest_path}.bak.${ts}"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          printf "Would backup: %s -> %s\n" "${dest_path}" "${bak}"
        else
          mv -f -- "${dest_path}" "${bak}"
          printf "Backed up: %s -> %s\n" "${dest_path}" "${bak}"
        fi
        ;;
      ask)
        local ans
        printf "Conflict: %s exists. [o]verwrite/[s]kip/[b]ackup? " "${dest_path}"
        read -r ans
        ans="$(lowercase "${ans}")"
        case "${ans}" in
          o|overwrite) ;;
          s|skip)
            printf "Skip: %s\n" "${dest_path}"
            return 0
            ;;
          b|backup)
            local ts bak
            ts="$(date +%Y%m%d-%H%M%S)"
            bak="${dest_path}.bak.${ts}"
            if [[ "${DRY_RUN}" -eq 1 ]]; then
              printf "Would backup: %s -> %s\n" "${dest_path}" "${bak}"
            else
              mv -f -- "${dest_path}" "${bak}"
              printf "Backed up: %s -> %s\n" "${dest_path}" "${bak}"
            fi
            ;;
          *)
            printf "Skip (unrecognized choice): %s\n" "${dest_path}"
            return 0
            ;;
        esac
        ;;
      *)
        die "Internal: invalid conflict policy '${CONFLICT}'"
        ;;
    esac
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf "Would install: %s -> %s  (%s:%s %s)\n" \
      "${src}" "${dest_path}" "${OWNER}" "${GROUP}" "${MODE}"
    return 0
  fi

  install \
    -m "${MODE}" \
    -o "${OWNER}" \
    -g "${GROUP}" \
    -- "${src}" "${dest_path}"

  printf "Installed: %s\n" "${dest_path}"
}

DEST_DIR='/usr/local/bin'
OWNER='root'
GROUP='root'
MODE='0755'
STRIP_SH=1
CONFLICT='ask'
DRY_RUN=0
USE_PAGER=0

ARGS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --pager)
      USE_PAGER=1
      shift
      ;;
    -d|--dest)
      [[ "${#}" -ge 2 ]] || die "--dest requires a value"
      DEST_DIR="$2"
      shift 2
      ;;
    --owner)
      [[ "${#}" -ge 2 ]] || die "--owner requires a value"
      OWNER="$2"
      shift 2
      ;;
    --group)
      [[ "${#}" -ge 2 ]] || die "--group requires a value"
      GROUP="$2"
      shift 2
      ;;
    --mode)
      [[ "${#}" -ge 2 ]] || die "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --strip-sh)
      STRIP_SH=1
      shift
      ;;
    --no-strip-sh)
      STRIP_SH=0
      shift
      ;;
    --conflict)
      [[ "${#}" -ge 2 ]] || die "--conflict requires a value"
      CONFLICT="$(lowercase "$2")"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --)
      shift
      while [[ "$#" -gt 0 ]]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

validate_mode "${MODE}"

case "${CONFLICT}" in
  ask|overwrite|skip|backup) ;;
  *)
    die "Invalid --conflict '${CONFLICT}'. Use ask|overwrite|skip|backup."
    ;;
esac

[[ "${#ARGS[@]}" -ge 1 ]] || die "No input files. Use --help."

[[ -d "${DEST_DIR}" ]] || die "Destination directory not found: ${DEST_DIR}"

ensure_root_or_sudo "$@"

for src in "${ARGS[@]}"; do
  dest_name="$(resolve_dest_name "${src}")"
  install_one "${src}" "${dest_name}"
done

