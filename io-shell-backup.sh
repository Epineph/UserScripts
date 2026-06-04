#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# io-shell.sh
#
# Sourceable shell helpers for setting the current shell's Linux I/O priority.
#
# Intended use:
#   source io-shell.sh
#   io_shell best 7
#   io_shell idle
#   io_shell show
#   io_shell reset
#
# Important:
#   This file must be sourced. Executing it as ./io-shell.sh cannot modify the
#   parent interactive shell.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Capture the original shell I/O priority when the file is sourced.
# -----------------------------------------------------------------------------

function _io_shell_capture_original() {
  local out

  if ! command -v ionice >/dev/null 2>&1; then
    return 0
  fi

  out="$(ionice -p "$$" 2>/dev/null || true)"

  case "$out" in
    idle*)
      IO_SHELL_ORIG_CLASS="3"
      IO_SHELL_ORIG_PRIO=""
      ;;

    realtime:*)
      IO_SHELL_ORIG_CLASS="1"
      IO_SHELL_ORIG_PRIO="${out##*prio }"
      ;;

    best-effort:*)
      IO_SHELL_ORIG_CLASS="2"
      IO_SHELL_ORIG_PRIO="${out##*prio }"
      ;;

    none:*)
      IO_SHELL_ORIG_CLASS="0"
      IO_SHELL_ORIG_PRIO=""
      ;;

    *)
      IO_SHELL_ORIG_CLASS="2"
      IO_SHELL_ORIG_PRIO="4"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Print help.
# -----------------------------------------------------------------------------

function io_shell_help() {
  cat <<'EOF'
Usage:
  io_shell MODE [PRIO]
  io_shell show
  io_shell reset
  io_shell help

Modes:
  idle        Set current shell to idle I/O priority.
  best        Set current shell to best-effort I/O priority.
  rt          Set current shell to real-time I/O priority. Usually needs sudo.
  reset       Restore priority captured when io-shell.sh was sourced.
  show        Show current shell I/O priority.
  help        Show this help text.

Priority:
  PRIO must be an integer from 0 to 7.

  0 = highest priority
  7 = lowest priority

Defaults:
  io_shell best      uses priority 5
  io_shell rt        uses priority 5
  io_shell idle      ignores priority

Examples:
  source ./io-shell.sh

  io_shell show
  io_shell best 7
  io_shell idle
  io_shell reset

  # All commands started after this inherit the shell's I/O priority:
  io_shell best 7
  find "$HOME" -xdev -type f -print

  # Return to the original priority:
  io_shell reset
EOF
}

# -----------------------------------------------------------------------------
# Validate priority.
# -----------------------------------------------------------------------------

function _io_shell_validate_prio() {
  local prio="${1:-}"

  if [[ ! "$prio" =~ ^[0-7]$ ]]; then
    echo "Error: priority must be an integer from 0 to 7." >&2
    return 2
  fi
}

# -----------------------------------------------------------------------------
# Show current shell I/O priority.
# -----------------------------------------------------------------------------

function io_shell_show() {
  ionice -p "$$"
}

# -----------------------------------------------------------------------------
# Restore original I/O priority.
# -----------------------------------------------------------------------------

function io_shell_reset() {
  case "${IO_SHELL_ORIG_CLASS:-2}" in
    0)
      ionice -c 0 -p "$$"
      ;;

    1)
      sudo ionice -c 1 -n "${IO_SHELL_ORIG_PRIO:-4}" -p "$$"
      ;;

    2)
      ionice -c 2 -n "${IO_SHELL_ORIG_PRIO:-4}" -p "$$"
      ;;

    3)
      ionice -c 3 -p "$$"
      ;;

    *)
      ionice -c 2 -n 4 -p "$$"
      ;;
  esac

  io_shell_show
}

# -----------------------------------------------------------------------------
# Set current shell I/O priority.
# -----------------------------------------------------------------------------

function io_shell() {
  local mode="${1:-help}"
  local prio="${2:-5}"

  mode="${mode,,}"

  if ! command -v ionice >/dev/null 2>&1; then
    echo "Error: ionice was not found." >&2
    return 127
  fi

  case "$mode" in
    help|-h|--help)
      io_shell_help
      ;;

    show|status)
      io_shell_show
      ;;

    reset|restore)
      io_shell_reset
      ;;

    idle)
      ionice -c 3 -p "$$"
      io_shell_show
      ;;

    best|be|best-effort)
      _io_shell_validate_prio "$prio" || return "$?"
      ionice -c 2 -n "$prio" -p "$$"
      io_shell_show
      ;;

    rt|realtime|real-time)
      _io_shell_validate_prio "$prio" || return "$?"
      sudo ionice -c 1 -n "$prio" -p "$$"
      io_shell_show
      ;;

    *)
      echo "Error: unknown mode: $mode" >&2
      io_shell_help >&2
      return 2
      ;;
  esac
}

_io_shell_capture_original
