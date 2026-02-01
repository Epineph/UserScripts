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
# Help paging:
#   - Paging is OFF by default.
#   - If --pager is provided, help output is paged:
#       --pager            => prefer bat; else cat
#       --pager less       => less -R (fallback: cat)
#       --pager bat        => bat (fallback: cat)
#       --pager cat        => cat
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
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function validate_mode() {
  local mode="$1"
  if [[ ! "${mode}" =~ ^0?[0-7]{3,4}$ ]]; then
    die "Invalid --mode '${mode}'. Expected e.g. 0755 or 755."
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

function help_pager_cmd() {
  if [[ "${HELP_PAGING}" -eq 0 ]]; then
    printf '%s' 'cat'
    return 0
  fi

  case "${HELP_PAGER}" in
    auto)
      if have bat; then
        printf '%s' 'bat --paging=always --plain'
      else
        printf '%s' 'cat'
      fi
      ;;
    bat)
      if have bat; then
        printf '%s' 'bat --paging=always --plain'
      else
        warn "bat not found; falling back to cat for help paging."
        printf '%s' 'cat'
      fi
      ;;
    less)
      if have less; then
        printf '%s' 'less -R'
      else
        warn "less not found; falling back to cat for help paging."
        printf '%s' 'cat'
      fi
      ;;
    cat)
      printf '%s' 'cat'
      ;;
    *)
      warn "Unknown pager '${HELP_PAGER}'; falling back to cat."
      printf '%s' 'cat'
      ;;
  esac
}

function print_help() {
  local pager
  pager="$(help_pager_cmd)"

  cat <<'EOF' | eval "${pager}"
Usage:
  install-script [OPTIONS] <file> [file2 ...]

Options:
  -d, --dest DIR            Destination directory (default: /usr/local/bin)
      --owner USER          Owner for installed files (default: root)
      --group GROUP         Group for installed files (default: root)
      --mode MODE           Mode for installed files (default: 0755)
      --[no-]strip-sh       Strip trailing ".sh" from basenames (default: on)
      --conflict POLICY     ask|overwrite|skip|backup (default: ask)
      --dry-run             Print actions, do not change anything

Help output paging:
      --pager [CHOICE]      Page --help output (default: off)
                            CHOICE: auto|bat|cat|less
                            --pager alone acts like: --pager auto
      --no-pager            Do not page --help output (default)

  -h, --help                Show this help

Notes:
  - If not run as root, the script re-execs itself via sudo.
  - "backup" renames any existing destination to:
      <name>.bak.<YYYYMMDD-HHMMSS>

Examples (install):
  1) Install and strip .sh:
     install-script ~/scripts/foo.sh
     # -> /usr/local/bin/foo (root:root 0755)

  2) Install multiple files (mixed extensions):
     install-script ./a.sh ./b ./c.py

  3) Overwrite conflicts non-interactively:
     install-script --conflict overwrite ./tool.sh

  4) Keep existing targets (skip conflicts):
     install-script --conflict skip ./tool.sh

  5) Backup existing targets before installing:
     install-script --conflict backup ./tool.sh

  6) Preserve the ".sh" name (disable stripping):
     install-script --no-strip-sh ./tool.sh
     # -> /usr/local/bin/tool.sh

  7) Install elsewhere and set explicit permissions:
     install-script --dest /usr/local/sbin --mode 0755 ./svc-tool.sh

Examples (help paging):
  8) Help without paging (default):
     install-script --help

  9) Help with auto pager (bat if present, else cat):
     install-script --help --pager

 10) Help explicitly via less:
     install-script --help --pager less
EOF
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

ORIG_ARGS=("$@")

DEST_DIR='/usr/local/bin'
OWNER='root'
GROUP='root'
MODE='0755'
STRIP_SH=1
CONFLICT='ask'
DRY_RUN=0

HELP_PAGING=0
HELP_PAGER='auto'

ARGS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --pager)
      HELP_PAGING=1
      if [[ "${#}" -ge 2 ]]; then
        case "$(lowercase "$2")" in
          auto|bat|cat|less)
            HELP_PAGER="$(lowercase "$2")"
            shift 2
            continue
            ;;
        esac
      fi
      HELP_PAGER='auto'
      shift
      ;;
    --no-pager)
      HELP_PAGING=0
      HELP_PAGER='auto'
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

ensure_root_or_sudo "${ORIG_ARGS[@]}"

for src in "${ARGS[@]}"; do
  dest_name="$(resolve_dest_name "${src}")"
  install_one "${src}" "${dest_name}"
done
