#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# codex-capture-stop-video
# Stop the newest active wf-recorder started by codex-capture.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
runtime_root="${XDG_RUNTIME_DIR:-/tmp}/codex-capture-${UID}"
stop_all=false

function show_help()
{
  local capture_command="codex-capture"

  if [[ "$PROGRAM" == *.sh ]]; then
    capture_command+=".sh"
  fi

  cat << EOF
Usage:
  ${PROGRAM} [--all]

Send SIGINT to the newest active wf-recorder started by ${capture_command}.
SIGINT lets wf-recorder finalize its Matroska file. Codex and terminal logging
continue.

Options:
      --all   Stop every active video capture owned by this user
  -h, --help  Show this help
EOF
}

function is_recorder()
{
  local pid="$1"
  local process_name=""

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -r "/proc/${pid}/comm" ]] || return 1
  IFS= read -r process_name < "/proc/${pid}/comm" || return 1
  [[ "$process_name" == wf-recorder ]]
}

function stop_from_file()
{
  local pid_file="$1"
  local pid=""
  local session_dir=""

  IFS=$'\t' read -r pid session_dir < "$pid_file" || true

  if ! is_recorder "$pid"; then
    rm -f -- "$pid_file"
    return 1
  fi

  kill -INT "$pid"
  printf 'Stopping video capture for:\n  %s\n' "$session_dir"
  return 0
}

while (($# > 0)); do
  case "$1" in
    --all)
      stop_all=true
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      printf '%s: error: unknown option %s\n' "$PROGRAM" "$1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ -d "$runtime_root" ]] || {
  printf '%s: no active Codex video capture found\n' "$PROGRAM" >&2
  exit 1
}

mapfile -d '' -t pid_files < <(
  find "$runtime_root" -maxdepth 1 -type f -name '*.pid' -print0
)

((${#pid_files[@]} > 0)) || {
  printf '%s: no active Codex video capture found\n' "$PROGRAM" >&2
  exit 1
}

if [[ "$stop_all" == true ]]; then
  stopped=0
  for pid_file in "${pid_files[@]}"; do
    stop_from_file "$pid_file" && ((stopped += 1))
  done
  ((stopped > 0)) || exit 1
  exit 0
fi

newest_file=""
newest_time=0
for pid_file in "${pid_files[@]}"; do
  IFS=$'\t' read -r candidate_pid _ < "$pid_file" || true
  if ! is_recorder "$candidate_pid"; then
    rm -f -- "$pid_file"
    continue
  fi

  modified="$(stat -c '%Y' "$pid_file" 2> /dev/null || printf '0')"
  if ((modified >= newest_time)); then
    newest_time="$modified"
    newest_file="$pid_file"
  fi
done

[[ -n "$newest_file" ]] || {
  printf '%s: no active Codex video capture found\n' "$PROGRAM" >&2
  exit 1
}
stop_from_file "$newest_file"
