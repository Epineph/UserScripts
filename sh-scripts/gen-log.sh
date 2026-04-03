#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# gen_log
#
# Run a command interactively and log stdout+stderr to LOG_DIR/output_N.txt
# using util-linux 'script(1)'. Also writes a sidecar metadata file:
#   output_N.meta
#
# Defaults:
#   - LOG_DIR:  $GEN_LOG_DIR or ~/repos/generate_install_command
#   - Paging:   off (only used for --help / --show-last if --paging is set)
# -----------------------------------------------------------------------------

LOG_DIR="${GEN_LOG_DIR:-$HOME/repos/generate_install_command}"

PAGING=0
CHECK_AUR="auto"      # auto | 0 | 1
STRICT_AUR=0
DRY_RUN=0
PRINT_LAST=0
SHOW_LAST=0

function die() {
  printf 'gen_log: %s\n' "$*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function pager() {
  if [[ "$PAGING" -eq 1 ]] && have bat; then
    bat --paging=always --plain
  else
    cat
  fi
}

function show_help() {
  cat <<'EOF' | pager
gen_log — run a command interactively and log output.

Usage:
  gen_log [OPTIONS] -- <command> [args...]
  gen_log [OPTIONS] <command> [args...]

Options:
  -h, --help              Show this help and exit
  -d, --dir DIR           Log directory (default: $GEN_LOG_DIR or
                          ~/repos/generate_install_command)
  --paging                Page help / show output via bat if available
  --dry-run               Print what would happen, but do nothing
  --print-last            Print the latest output_*.txt path and exit
  --show-last             Display the latest output_*.txt (uses --paging)
  --check-aur             Force AUR RPC/GIT checks before running
  --no-check-aur          Disable AUR checks
  --strict-check-aur      Abort if AUR checks fail

Notes:
  - Logs are stored as output_N.txt plus output_N.meta.
  - Uses util-linux 'script(1)' so interactive output is captured faithfully.

Examples:
  gen_log pacman -Syu
  gen_log --check-aur yay --needed -S python-black ufmt
  gen_log --dir ~/logs -- dry-run echo hello
  gen_log --print-last
  gen_log --show-last --paging
EOF
}

function latest_output_file() {
  local f bn num
  local max=0
  local latest=""

  shopt -s nullglob
  for f in "$LOG_DIR"/output_*.txt; do
    bn="${f##*/}"
    num="${bn#output_}"
    num="${num%.txt}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if (( num > max )); then
      max="$num"
      latest="$f"
    fi
  done
  shopt -u nullglob

  printf '%s\n' "$latest"
}

function next_output_file() {
  local f bn num
  local max=0

  shopt -s nullglob
  for f in "$LOG_DIR"/output_*.txt; do
    bn="${f##*/}"
    num="${bn#output_}"
    num="${num%.txt}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    (( num > max )) && max="$num"
  done
  shopt -u nullglob

  printf '%s/output_%d.txt\n' "$LOG_DIR" $((max + 1))
}

function is_aur_helper() {
  local x="${1##*/}"
  case "$x" in
    yay|paru|pikaur|aura) return 0 ;;
    *) return 1 ;;
  esac
}

function aur_check() {
  have curl || {
    printf 'AUR check: curl not found; skipping.\n' >&2
    return 0
  }

  local curl_ip=()
  if have ip; then
    if ! ip -6 route show default 2>/dev/null | grep -q .; then
      curl_ip=(-4)
    fi
  fi

  local fail=0
  local code=""

  code="$(
    curl "${curl_ip[@]}" -sS --retry 3 --retry-all-errors \
      -o /dev/null -w '%{http_code}' \
      'https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=yay' \
    || true
  )"

  if [[ "$code" == "200" ]]; then
    printf 'AUR RPC: OK\n' >&2
  else
    printf 'AUR RPC: FAIL (HTTP %s)\n' "${code:-?}" >&2
    fail=1
  fi

  if have git; then
    if git ls-remote https://aur.archlinux.org/yay.git HEAD \
      >/dev/null 2>&1; then
      printf 'AUR GIT: OK\n' >&2
    else
      printf 'AUR GIT: FAIL\n' >&2
      fail=1
    fi
  else
    printf 'AUR check: git not found; skipping git probe.\n' >&2
  fi

  return "$fail"
}

function script_supports_exitcode() {
  have script || return 1
  script --help 2>&1 | grep -Eq '(^|[[:space:]])-e([[:space:]]|,)' \
    || return 1
}

function main() {
  local dir_arg=""
  local cmd_argv=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -d|--dir)
        [[ $# -ge 2 ]] || die "--dir requires a value"
        dir_arg="$2"
        shift 2
        ;;
      --paging)
        PAGING=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --print-last)
        PRINT_LAST=1
        shift
        ;;
      --show-last)
        SHOW_LAST=1
        shift
        ;;
      --check-aur)
        CHECK_AUR=1
        shift
        ;;
      --no-check-aur)
        CHECK_AUR=0
        shift
        ;;
      --strict-check-aur)
        CHECK_AUR=1
        STRICT_AUR=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  [[ -n "$dir_arg" ]] && LOG_DIR="$dir_arg"

  mkdir -p -- "$LOG_DIR"

  if [[ "$PRINT_LAST" -eq 1 ]]; then
    latest_output_file
    exit 0
  fi

  if [[ "$SHOW_LAST" -eq 1 ]]; then
    local last
    last="$(latest_output_file)"
    [[ -n "$last" ]] || die "No output_*.txt files in $LOG_DIR"
    if [[ "$PAGING" -eq 1 ]] && have bat; then
      bat --paging=always --plain "$last"
    else
      cat "$last"
    fi
    exit 0
  fi

  if [[ $# -lt 1 ]]; then
    show_help
    exit 1
  fi

  cmd_argv=("$@")

  local cmd0="${cmd_argv[0]##*/}"
  if [[ "$CHECK_AUR" == "auto" ]]; then
    if is_aur_helper "$cmd0"; then
      CHECK_AUR=1
    else
      CHECK_AUR=0
    fi
  fi

  if [[ "$CHECK_AUR" -eq 1 ]]; then
    if ! aur_check; then
      if [[ "$STRICT_AUR" -eq 1 ]]; then
        die "AUR checks failed (strict mode)."
      fi
      printf 'Warning: AUR checks failed; continuing anyway.\n' >&2
    fi
  fi

  have script || die "'script' not found (package: util-linux)."

  # Lock numbering to avoid collisions.
  local output_file=""
  if have flock; then
    exec 9>"$LOG_DIR/.gen_log.lock"
    flock -x 9
    output_file="$(next_output_file)"
    flock -u 9
  else
    output_file="$(next_output_file)"
  fi

  local meta_file="${output_file%.txt}.meta"

  # Build a shell-safe command string for script -c.
  local cmd_str=""
  cmd_str="$(printf '%q ' "${cmd_argv[@]}")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Would run: %s\n' "$cmd_str"
    printf 'Would log: %s\n' "$output_file"
    exit 0
  fi

  {
    printf 'date: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'cwd: %s\n' "$(pwd -P)"
    printf 'host: %s\n' "$(uname -a)"
    printf 'cmd: %s\n' "$cmd_str"
  } >"$meta_file"

  printf 'Running command: %s\n' "$cmd_str"
  printf 'Logging to: %s\n' "$output_file"

  local script_args=(-q -f)
  if script_supports_exitcode; then
    script_args+=(-e)
  fi

  set +e
  script "${script_args[@]}" -c "$cmd_str" "$output_file"
  local rc=$?
  set -e

  printf 'exit_code: %s\n' "$rc" >>"$meta_file"
  printf 'Output has been logged to: %s\n' "$output_file"

  return "$rc"
}

main "$@"

