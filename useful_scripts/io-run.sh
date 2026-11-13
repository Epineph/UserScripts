#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# io_run
#
# Run a command with a controlled Linux I/O priority.
#
# Usage:
#   io_run [idle|best|rt] [prio] -- command args...
#
# Examples:
#   io_run -- rsync -a source/ target/
#   io_run best 7 -- find "$HOME" -type f
#   io_run idle -- updatedb
#   io_run rt 0 -- critical-command
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage:
  io_run [idle|best|rt] [prio] -- command args...

Modes:
  idle        Use idle I/O scheduling class. Safest for background work.
  best        Use best-effort I/O scheduling class. Default.
  rt          Use real-time I/O scheduling class. Requires sudo.

Priority:
  prio        Integer from 0 to 7.
              0 = highest priority
              7 = lowest priority

Defaults:
  mode = best
  prio = 5

Examples:
  io_run -- rsync -a source/ target/
  io_run best 7 -- find "$HOME" -type f
  io_run idle -- updatedb
  io_run rt 0 -- critical-command
EOF
}

mode="best"
prio="5"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" != "--" ]]; then
  mode="${1:-best}"
  mode="${mode,,}"
  shift || true
fi

if [[ "${1:-}" != "--" ]]; then
  prio="${1:-5}"
  shift || true
fi

if [[ "${1:-}" == "--" ]]; then
  shift
else
  echo "Error: missing '--' before command." >&2
  usage >&2
  exit 2
fi

if [[ "$#" -eq 0 ]]; then
  echo "Error: missing command." >&2
  usage >&2
  exit 2
fi

case "$mode" in
  idle)
    exec ionice -c 3 -- "$@"
    ;;

  best)
    if ! [[ "$prio" =~ ^[0-7]$ ]]; then
      echo "Error: priority must be an integer from 0 to 7." >&2
      exit 2
    fi

    exec ionice -c 2 -n "$prio" -- "$@"
    ;;

  rt)
    if ! [[ "$prio" =~ ^[0-7]$ ]]; then
      echo "Error: priority must be an integer from 0 to 7." >&2
      exit 2
    fi

    exec sudo ionice -c 1 -n "$prio" -- "$@"
    ;;

  *)
    echo "Error: unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac
