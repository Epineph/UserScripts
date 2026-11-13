#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# codex-capture-replay
# Replay, summarize, or inspect a session created by codex-capture.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
if [[ -n "${CODEX_CAPTURE_DIR:-}" ]]; then
  output_root="$CODEX_CAPTURE_DIR"
else
  state_root="${XDG_STATE_HOME:-${HOME}/.local/state}"
  output_root="${state_root}/codex-capture"
fi
session_dir=""
mode="replay"
speed="1"

function show_help()
{
  local capture_command="codex-capture"

  if [[ "$PROGRAM" == *.sh ]]; then
    capture_command+=".sh"
  fi

  cat << EOF
Usage:
  ${PROGRAM} [OPTIONS] [SESSION_DIRECTORY]

Replay the most recent capture from ${capture_command} by default.

Options:
      --speed FACTOR  Playback speed multiplier (default: 1)
      --summary       Show timing/session summary without replaying
      --text          Open searchable terminal.txt with less
      --video         Open screen.mkv with xdg-open
  -h, --help          Show this help

During replay, Space pauses, Up/Down changes speed, and Right advances one step.
EOF
}

function die()
{
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --speed)
      [[ -n "${2:-}" ]] || die "--speed requires a value"
      speed="$2"
      shift
      ;;
    --summary)
      mode="summary"
      ;;
    --text)
      mode="text"
      ;;
    --video)
      mode="video"
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    -*)
      die "unknown option '$1'"
      ;;
    *)
      [[ -z "$session_dir" ]] || die "only one session directory is allowed"
      session_dir="$1"
      ;;
  esac
  shift
done

session_dir="${session_dir:-${output_root}/latest}"
[[ -d "$session_dir" ]] || die "session directory not found: ${session_dir}"

case "$mode" in
  replay)
    command -v scriptreplay > /dev/null 2>&1 \
      || die "scriptreplay is missing; install util-linux"
    [[ -f "${session_dir}/terminal.raw" ]] || die "terminal.raw is missing"
    [[ -f "${session_dir}/terminal.timing" ]] \
      || die "terminal.timing is missing"
    scriptreplay \
      --timing "${session_dir}/terminal.timing" \
      --log-out "${session_dir}/terminal.raw" \
      --divisor "$speed"
    ;;
  summary)
    scriptreplay --summary --timing "${session_dir}/terminal.timing"
    ;;
  text)
    [[ -f "${session_dir}/terminal.txt" ]] \
      || die "terminal.txt is unavailable; inspect terminal.raw instead"
    exec less "${session_dir}/terminal.txt"
    ;;
  video)
    [[ -f "${session_dir}/screen.mkv" ]] || die "screen.mkv is missing"
    command -v xdg-open > /dev/null 2>&1 || die "xdg-open is missing"
    xdg-open "${session_dir}/screen.mkv" > /dev/null 2>&1 &
    ;;
esac
