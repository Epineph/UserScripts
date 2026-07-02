#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# secure-7z
# ---------------------------------------------------------------------------
# Safely create encrypted 7z archives with:
#   - encrypted headers
#   - password prompt from 7z itself
#   - temporary archive output
#   - automatic cleanup on failure
#   - optional exclude patterns
#   - optional fzf input selection
#   - preflight output directory and free-space checks
# ---------------------------------------------------------------------------

PROGRAM="$(basename "$0")"

declare -a INPUTS=()
declare -a EXCLUDES=()
declare -a EXCLUDE_FILES=()

OUTPUT=""
LEVEL=""
THREADS="$(nproc 2>/dev/null || printf '8')"

NO_CONFIRM=0
REVIEW=0
VERBOSE=0
FORCE=0
PROGRESS=1
SKIP_SPACE_CHECK=0

TMP_ARCHIVE=""
FINAL_OUTPUT=""
SEVENZ_CMD=()

# ---------------------------------------------------------------------------
# User interface
# ---------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
secure-7z

Create an encrypted .7z archive safely.

Usage:
  secure-7z [options] INPUT [INPUT ...]

Required, unless prompted:
  -o, --output PATH          Final archive path.
  -i, --input PATH           Input path. May be repeated.

Options:
  -x, --exclude PATTERN      Exclude pattern. May be repeated.
  -X, --exclude-file FILE    File containing 7z exclude patterns.
  -l, --level 0..9           Compression level. 0 = none, 9 = maximum.
  -T, --threads N            7z thread count. Default: nproc or 8.
      --no-progress          Disable 7z progress stream.
      --skip-space-check     Skip conservative free-space preflight.
      --force                Replace final output if it already exists.
      --review               Print review and ask before starting.
      --noconfirm            Do not prompt for optional missing values.
  -v, --verbose              Show exact command and wait 10 seconds.
  -h, --help                 Show this help.

Accepted typo aliases:
      --noconfifm            Alias for --noconfirm.
      --verbosd              Alias for --verbose.

Examples:
  secure-7z -o recovery-material.7z recovery-key.txt luks-header-backup.bin

  secure-7z \
    -o /mnt/usb/recovery-material.7z \
    -l 7 \
    -T 8 \
    ./recovery-key.txt \
    ./luks-header-backup.bin

  secure-7z \
    -o backup.7z \
    -x '*.tmp' \
    -x '.git' \
    ./important-dir

  secure-7z \
    --review \
    -o recovery-material.7z \
    ./recovery-key.txt \
    ./luks-header-backup.bin

  secure-7z \
    --noconfirm \
    --force \
    -l 5 \
    -o recovery-material.7z \
    ./recovery-key.txt \
    ./luks-header-backup.bin

Notes:
  - 7z compression levels are -mx=0 through -mx=9.
  - This script uses 7z's own password prompt: -p.
  - It does not place the passphrase in the shell command line.
  - Failed archives are deleted.
  - Input files are never deleted by this script.
EOF
}

function msg() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

function cleanup() {
  if [[ -n "${TMP_ARCHIVE:-}" && -e "$TMP_ARCHIVE" ]]; then
    rm -f -- "$TMP_ARCHIVE" || true
  fi
}

trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

function require_arg() {
  local opt="$1"
  local val="${2:-}"

  [[ -n "$val" ]] || die "Missing argument for ${opt}."
}

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -o|--output)
        require_arg "$1" "${2:-}"
        OUTPUT="$2"
        shift 2
        ;;

      -i|--input)
        require_arg "$1" "${2:-}"
        INPUTS+=("$2")
        shift 2
        ;;

      -x|--exclude)
        require_arg "$1" "${2:-}"
        EXCLUDES+=("$2")
        shift 2
        ;;

      -X|--exclude-file)
        require_arg "$1" "${2:-}"
        EXCLUDE_FILES+=("$2")
        shift 2
        ;;

      -l|--level)
        require_arg "$1" "${2:-}"
        LEVEL="$2"
        shift 2
        ;;

      -T|--threads)
        require_arg "$1" "${2:-}"
        THREADS="$2"
        shift 2
        ;;

      --no-progress)
        PROGRESS=0
        shift
        ;;

      --skip-space-check)
        SKIP_SPACE_CHECK=1
        shift
        ;;

      --force)
        FORCE=1
        shift
        ;;

      --review)
        REVIEW=1
        shift
        ;;

      --noconfirm|--no-confirm|--noconfifm)
        NO_CONFIRM=1
        shift
        ;;

      -v|--verbose|--verbosd)
        VERBOSE=1
        shift
        ;;

      -h|--help)
        usage
        exit 0
        ;;

      --)
        shift
        INPUTS+=("$@")
        break
        ;;

      -*)
        die "Unknown option: $1"
        ;;

      *)
        INPUTS+=("$1")
        shift
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

function prompt_output() {
  local default
  local answer

  default="./encrypted-archive-$(date '+%Y%m%d-%H%M%S').7z"

  printf 'Output archive [%s]: ' "$default"
  read -r answer

  OUTPUT="${answer:-$default}"
}

function prompt_level() {
  local answer

  while true; do
    printf 'Compression level 0..9 [5]: '
    read -r answer
    LEVEL="${answer:-5}"

    if [[ "$LEVEL" =~ ^[0-9]$ ]]; then
      return 0
    fi

    warn "Compression level must be an integer from 0 to 9."
  done
}

function prompt_inputs_manual() {
  local path

  msg "Enter input paths, one per line. Submit an empty line when done."

  while true; do
    printf 'Input path: '
    read -r path

    [[ -z "$path" ]] && break
    INPUTS+=("$path")
  done
}

function prompt_inputs_fzf() {
  local -a picked=()

  if have fd; then
    mapfile -d '' -t picked < <(
      fd -0 --hidden --exclude '.git' --type f --type d . . |
        fzf --read0 --print0 -m --prompt='7z inputs> '
    )
  else
    mapfile -d '' -t picked < <(
      find . -mindepth 1 -print0 |
        fzf --read0 --print0 -m --prompt='7z inputs> '
    )
  fi

  ((${#picked[@]} > 0)) || return 1

  INPUTS+=("${picked[@]}")
}

function prompt_inputs() {
  if have fzf; then
    prompt_inputs_fzf && return 0
    warn "No fzf input selected; falling back to manual input."
  fi

  prompt_inputs_manual
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function validate_level() {
  if [[ -z "$LEVEL" ]]; then
    if ((NO_CONFIRM)); then
      LEVEL=5
    elif is_interactive; then
      prompt_level
    else
      LEVEL=5
    fi
  fi

  [[ "$LEVEL" =~ ^[0-9]$ ]] ||
    die "Compression level must be an integer from 0 to 9."
}

function validate_threads() {
  [[ "$THREADS" =~ ^[1-9][0-9]*$ ]] ||
    die "Thread count must be a positive integer."
}

function validate_inputs() {
  local input
  local bad

  if ((${#INPUTS[@]} == 0)); then
    if ((NO_CONFIRM)); then
      die "No inputs supplied and --noconfirm was used."
    fi

    is_interactive ||
      die "No inputs supplied and no interactive terminal is available."

    prompt_inputs
  fi

  ((${#INPUTS[@]} > 0)) || die "No input paths supplied."

  for input in "${INPUTS[@]}"; do
    [[ -e "$input" ]] || die "Input does not exist: $input"
    [[ -r "$input" ]] || die "Input is not readable: $input"

    if [[ -d "$input" ]]; then
      [[ -x "$input" ]] || die "Directory is not traversable: $input"

      bad="$(find "$input" ! -readable -print -quit 2>/dev/null || true)"

      if [[ -n "$bad" ]]; then
        die "Unreadable file or directory inside input tree: $bad"
      fi
    fi
  done
}

function validate_exclude_files() {
  local file

  for file in "${EXCLUDE_FILES[@]}"; do
    [[ -e "$file" ]] || die "Exclude file does not exist: $file"
    [[ -f "$file" ]] || die "Exclude path is not a regular file: $file"
    [[ -r "$file" ]] || die "Exclude file is not readable: $file"
  done
}

function validate_output() {
  local parent
  local base

  if [[ -z "$OUTPUT" ]]; then
    if ((NO_CONFIRM)); then
      die "No output supplied and --noconfirm was used."
    fi

    is_interactive ||
      die "No output supplied and no interactive terminal is available."

    prompt_output
  fi

  parent="$(dirname -- "$OUTPUT")"
  base="$(basename -- "$OUTPUT")"

  mkdir -p -- "$parent" 2>/dev/null ||
    die "Cannot create output directory: $parent. Permission issue?"

  [[ -d "$parent" ]] ||
    die "Output parent is not a directory: $parent"

  [[ -w "$parent" && -x "$parent" ]] ||
    die "No write/traverse permission for output directory: $parent"

  parent="$(realpath -e -- "$parent")"
  FINAL_OUTPUT="${parent}/${base}"

  if [[ -e "$FINAL_OUTPUT" && "$FORCE" -ne 1 ]]; then
    die "Output already exists: $FINAL_OUTPUT. Use --force to replace it."
  fi

  TMP_ARCHIVE="$(mktemp -p "$parent" ".${base}.tmp.XXXXXX")" ||
    die "Cannot create temporary file in output directory: $parent"

  rm -f -- "$TMP_ARCHIVE" ||
    die "Cannot remove temporary preflight file: $TMP_ARCHIVE"
}

function human_bytes() {
  local bytes="$1"

  numfmt --to=iec --suffix=B "$bytes" 2>/dev/null ||
    printf '%s B' "$bytes"
}

function input_bytes() {
  local input
  local size
  local total=0

  for input in "${INPUTS[@]}"; do
    size="$(du -sb --apparent-size -- "$input" 2>/dev/null |
      awk '{print $1}')" ||
      die "Could not calculate input size for: $input"

    total=$((total + size))
  done

  printf '%s\n' "$total"
}

function check_free_space() {
  local parent
  local available
  local required
  local bytes
  local buffer

  ((SKIP_SPACE_CHECK)) && return 0

  parent="$(dirname -- "$FINAL_OUTPUT")"
  bytes="$(input_bytes)"
  buffer=$((100 * 1024 * 1024))
  required=$((bytes + buffer))

  available="$(df -PB1 -- "$parent" | awk 'NR == 2 {print $4}')" ||
    die "Could not query free space for output directory: $parent"

  [[ "$available" =~ ^[0-9]+$ ]] ||
    die "Could not parse available free space for: $parent"

  if ((available < required)); then
    die "Insufficient free space on output filesystem. Required at least \
$(human_bytes "$required"), available $(human_bytes "$available")."
  fi
}

# ---------------------------------------------------------------------------
# Review and command construction
# ---------------------------------------------------------------------------

function print_mount_info() {
  local parent

  parent="$(dirname -- "$FINAL_OUTPUT")"

  if have findmnt; then
    findmnt -T "$parent" -o SOURCE,FSTYPE,TARGET,OPTIONS
  else
    warn "findmnt not available; cannot print target filesystem details."
  fi
}

function build_command() {
  local pattern
  local file

  SEVENZ_CMD=(
    7z
    a
    -t7z
    -mhe=on
    "-mmt=${THREADS}"
    "-mx=${LEVEL}"
    -p
  )

  if ((PROGRESS)); then
    SEVENZ_CMD+=(-bsp1)
  fi

  for pattern in "${EXCLUDES[@]}"; do
    SEVENZ_CMD+=("-xr!${pattern}")
  done

  for file in "${EXCLUDE_FILES[@]}"; do
    SEVENZ_CMD+=("-xr@${file}")
  done

  SEVENZ_CMD+=(-- "$TMP_ARCHIVE")
  SEVENZ_CMD+=("${INPUTS[@]}")
}

function print_shell_command() {
  printf 'Command:\n  '
  printf '%q ' "${SEVENZ_CMD[@]}"
  printf '\n'
}

function print_plan() {
  local input
  local pattern
  local file

  msg "Archive plan"
  msg "------------"
  msg "Final output:      $FINAL_OUTPUT"
  msg "Temporary output:  $TMP_ARCHIVE"
  msg "Compression level: $LEVEL"
  msg "Threads:           $THREADS"
  msg "Header encrypted:  yes"
  msg "Password source:   7z interactive prompt"
  msg "Progress stream:   $([[ "$PROGRESS" -eq 1 ]] && echo yes || echo no)"
  msg ""

  msg "Inputs:"
  for input in "${INPUTS[@]}"; do
    msg "  - $input"
  done

  if ((${#EXCLUDES[@]} > 0)); then
    msg ""
    msg "Exclude patterns:"
    for pattern in "${EXCLUDES[@]}"; do
      msg "  - $pattern"
    done
  fi

  if ((${#EXCLUDE_FILES[@]} > 0)); then
    msg ""
    msg "Exclude files:"
    for file in "${EXCLUDE_FILES[@]}"; do
      msg "  - $file"
    done
  fi

  msg ""
  msg "Target filesystem:"
  print_mount_info

  msg ""
  print_shell_command
}

function confirm_or_exit() {
  local answer

  printf 'Proceed? [y/N]: '
  read -r answer

  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

function countdown() {
  local i

  for i in 10 9 8 7 6 5 4 3 2 1; do
    printf '\rStarting in %2d seconds. Press Ctrl-C to cancel. ' "$i"
    sleep 1
  done

  printf '\n'
}

# ---------------------------------------------------------------------------
# Archive execution
# ---------------------------------------------------------------------------

function run_archive() {
  local rc

  build_command

  if ((REVIEW)); then
    print_plan
    confirm_or_exit
  fi

  if ((VERBOSE)); then
    print_plan
    countdown
  fi

  set +e
  "${SEVENZ_CMD[@]}"
  rc=$?
  set -e

  if ((rc != 0)); then
    rm -f -- "$TMP_ARCHIVE" || true
    die "7z failed with exit code ${rc}. Temporary archive deleted. \
Inputs were not modified."
  fi

  [[ -s "$TMP_ARCHIVE" ]] ||
    die "7z reported success, but temporary archive is missing or empty."

  mv -f -- "$TMP_ARCHIVE" "$FINAL_OUTPUT" ||
    die "Could not move temporary archive to final output: $FINAL_OUTPUT"

  TMP_ARCHIVE=""

  msg ""
  msg "Archive created successfully:"
  msg "  $FINAL_OUTPUT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main() {
  parse_args "$@"

  have 7z || die "7z was not found on PATH."

  validate_level
  validate_threads
  validate_inputs
  validate_exclude_files
  validate_output
  check_free_space

  run_archive
}

main "$@"
