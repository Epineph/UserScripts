#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# io-session
#
# Start an interactive shell with a chosen Linux I/O priority.
#
# This does not try to mutate the parent shell. Instead, it starts a new shell
# inside the current terminal. Commands launched inside that shell inherit the
# selected I/O priority.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  io-session [MODE] [PRIO] [-- SHELL_ARGS...]

Modes:
  idle        Use idle I/O class. Best for heavy background work.
  best        Use best-effort I/O class. Default.
  rt          Use real-time I/O class. Usually requires sudo.
  show        Show current shell I/O priority.
  help        Show this help text.

Priority:
  PRIO must be an integer from 0 to 7.

  0 = highest priority
  7 = lowest priority

Defaults:
  MODE = best
  PRIO = 7

Examples:
  io-session
  io-session best 7
  io-session idle
  io-session rt 4

  # Then run heavy commands inside the opened shell:
  find "$HOME" -xdev -type f -print
  rsync -aHAX source/ target/

  # Leave the I/O-prioritised shell:
  exit
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

function validate_prio() {
  local prio="${1:-}"

  [[ "$prio" =~ ^[0-7]$ ]] || {
    die "priority must be an integer from 0 to 7"
  }
}

function show_current_priority() {
  ionice -p "$$"
}

function detect_shell() {
  if [[ -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
    printf '%s\n' "$SHELL"
    return 0
  fi

  if command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$(command -v zsh)"
    return 0
  fi

  if command -v bash >/dev/null 2>&1; then
    printf '%s\n' "$(command -v bash)"
    return 0
  fi

  die "could not detect a usable shell"
}

function start_session() {
  local mode="$1"
  local prio="$2"
  shift 2

  local shell_path
  shell_path="$(detect_shell)"

  export IO_SESSION_ACTIVE="1"
  export IO_SESSION_MODE="$mode"
  export IO_SESSION_PRIO="$prio"

  printf 'Starting I/O-prioritised shell:\n' >&2
  printf '  mode:  %s\n' "$mode" >&2
  printf '  prio:  %s\n' "$prio" >&2
  printf '  shell: %s\n' "$shell_path" >&2
  printf '\nType "exit" to return to the previous shell.\n\n' >&2

  case "$mode" in
    idle)
      exec ionice -c 3 -- "$shell_path" -i "$@"
      ;;

    best)
      validate_prio "$prio"
      exec ionice -c 2 -n "$prio" -- "$shell_path" -i "$@"
      ;;

    rt)
      validate_prio "$prio"
      exec sudo ionice -c 1 -n "$prio" -- "$shell_path" -i "$@"
      ;;

    *)
      die "unknown mode: $mode"
      ;;
  esac
}

mode="${1:-best}"
prio="${2:-7}"

mode="${mode,,}"

case "$mode" in
  help|-h|--help)
    usage
    exit 0
    ;;

  show|status)
    show_current_priority
    exit 0
    ;;

  idle)
    shift || true
    start_session "$mode" "$prio" "$@"
    ;;

  best|rt)
    shift || true

    if [[ "${1:-}" =~ ^[0-7]$ ]]; then
      prio="$1"
      shift || true
    else
      prio="7"
    fi

    if [[ "${1:-}" == "--" ]]; then
      shift
    fi

    start_session "$mode" "$prio" "$@"
    ;;

  *)
    die "unknown mode: $mode"
    ;;
esac
