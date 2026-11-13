#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# codex-capture
# Record an interactive Codex CLI session as a replayable terminal transcript.
# Optionally record the focused Wayland output with wf-recorder.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
umask 077

readonly PROGRAM="${0##*/}"
readonly VERSION="1.0.0"

video_enabled=false
audio_enabled=false
region_enabled=false
plain_text_enabled=true
use_alt_screen=false
reasoning_mode="best"

audio_device=""
video_output=""
video_codec="libx264"
video_device=""
video_framerate=""
video_pixel_format=""
session_label=""
video_pid=""
video_pid_file=""
session_dir=""

declare -a codec_params=()
declare -a codex_args=()

if [[ -n "${CODEX_CAPTURE_DIR:-}" ]]; then
  output_root="$CODEX_CAPTURE_DIR"
else
  state_root="${XDG_STATE_HOME:-${HOME}/.local/state}"
  output_root="${state_root}/codex-capture"
fi
runtime_root="${XDG_RUNTIME_DIR:-/tmp}/codex-capture-${UID}"

# -----------------------------------------------------------------------------
# Help and validation
# -----------------------------------------------------------------------------

function show_help()
{
  cat << EOF
Usage:
  ${PROGRAM} [CAPTURE OPTIONS] [-- CODEX OPTIONS...]

Record an interactive Codex CLI session. Terminal output is always saved in
raw, replayable form. Video recording is optional.

Capture options:
      --video                 Record the focused Wayland output
      --region                Select a region with slurp; implies --video
      --audio                 Include the default audio source; implies --video
      --audio-device DEVICE   Record a specific PipeWire/PulseAudio source
      --output MONITOR        Wayland output, for example DP-1 or eDP-1
      --codec CODEC           Video codec (default: libx264)
      --device DEVICE         Encoding device, for example a VAAPI render node
      --codec-param KEY=VALUE Repeatable wf-recorder codec parameter
      --framerate FPS         Force constant video frame rate
      --pixel-format FORMAT   Input pixel format, for example yuv420p
      --dir DIRECTORY         Root directory for captured sessions
      --name LABEL            Add a short label to the session directory
      --alt-screen            Preserve Codex alternate-screen mode
      --configured-reasoning  Do not override reasoning-display configuration
      --no-plain-text         Do not create best-effort terminal.txt
  -h, --help                  Show this help
  -V, --version               Show version

Codex options must follow -- so that capture options remain unambiguous.

Examples:
  ${PROGRAM}
  ${PROGRAM} --video
  ${PROGRAM} --video --region --name auth-refactor
  ${PROGRAM} --video --audio-device alsa_output.pci.monitor
  ${PROGRAM} -- --model gpt-5.6-sol --sandbox workspace-write
  ${PROGRAM} --video -- --cd "\$HOME/repos/my-project"

By default, Codex is launched with detailed reasoning summaries requested and
raw reasoning enabled when the selected model/provider emits it. This cannot
expose private reasoning that Codex does not emit.
EOF
}

function die()
{
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

function require_command()
{
  local command_name="$1"
  local package_hint="${2:-$1}"

  command -v "$command_name" > /dev/null 2>&1 \
    || die "missing '${command_name}'; install package '${package_hint}'"
}

function require_value()
{
  local option="$1"
  local value="${2:-}"

  [[ -n "$value" ]] || die "${option} requires a value"
}

function sanitize_label()
{
  local value="$1"

  value="${value// /-}"
  value="$(printf '%s' "$value" | tr -cs '[:alnum:]_.-' '-')"
  value="${value#-}"
  value="${value%-}"
  printf '%.48s' "$value"
}

function quote_command()
{
  local argument
  local -a quoted=()

  for argument in "$@"; do
    printf -v argument '%q' "$argument"
    quoted+=("$argument")
  done
  printf '%s' "${quoted[*]}"
}

# -----------------------------------------------------------------------------
# Terminal and video helpers
# -----------------------------------------------------------------------------

function detect_focused_output()
{
  local detected=""

  if [[ -n "$video_output" ]]; then
    printf '%s' "$video_output"
    return 0
  fi

  if command -v hyprctl > /dev/null 2>&1 \
    && command -v jq > /dev/null 2>&1; then
    detected="$(
      hyprctl -j monitors 2> /dev/null \
        | jq -er '.[] | select(.focused == true) | .name' 2> /dev/null \
        | head -n 1
    )" || true
  fi

  if [[ -z "$detected" ]] && command -v swaymsg > /dev/null 2>&1 \
    && command -v jq > /dev/null 2>&1; then
    detected="$(
      swaymsg -t get_outputs -r 2> /dev/null \
        | jq -er '.[] | select(.focused == true) | .name' 2> /dev/null \
        | head -n 1
    )" || true
  fi

  [[ -n "$detected" ]] || return 1
  printf '%s' "$detected"
}

function make_plain_text()
{
  local raw_file="${session_dir}/terminal.raw"
  local text_file="${session_dir}/terminal.txt"

  [[ "$plain_text_enabled" == true && -s "$raw_file" ]] || return 0
  command -v perl > /dev/null 2>&1 || return 0

  # Remove common ANSI/OSC/DCS control sequences. A TUI overwrites screen
  # positions, so this is searchable best-effort text, not an exact rendering.
  perl -0pe '
    s/\e\][^\a]*(?:\a|\e\\)//gs;
    s/\eP.*?\e\\//gs;
    s/\e\[[0-?]*[ -\/]*[@-~]//g;
    s/\e[@-_]//g;
    s/\x08.//g;
    s/\r/\n/g;
    s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
  ' "$raw_file" > "$text_file" 2> /dev/null || rm -f -- "$text_file"
}

function stop_video()
{
  local attempt

  [[ -n "$video_pid" ]] || return 0

  if kill -0 "$video_pid" 2> /dev/null; then
    kill -INT "$video_pid" 2> /dev/null || true

    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$video_pid" 2> /dev/null || break
      sleep 0.1
    done

    if kill -0 "$video_pid" 2> /dev/null; then
      printf '%s: wf-recorder did not finalize; sending SIGTERM\n' \
        "$PROGRAM" >&2
      kill -TERM "$video_pid" 2> /dev/null || true
    fi
  fi

  wait "$video_pid" 2> /dev/null || true
  [[ -n "$video_pid_file" ]] && rm -f -- "$video_pid_file"
  video_pid=""
}

function finalize_session()
{
  local exit_status="${1:-0}"
  local ended_at

  trap - EXIT HUP INT TERM
  stop_video

  if [[ -n "$session_dir" && -d "$session_dir" ]]; then
    make_plain_text
    ended_at="$(date --iso-8601=seconds)"
    {
      printf 'ended_at=%q\n' "$ended_at"
      printf 'exit_status=%q\n' "$exit_status"
    } >> "${session_dir}/session.meta"

    printf '\nCapture saved to:\n  %s\n' "$session_dir" >&2
  fi
}

function start_video()
{
  local focused_output
  local geometry=""
  local parameter
  local stop_video_command="codex-capture-stop-video"
  local -a recorder_command

  if [[ "$PROGRAM" == *.sh ]]; then
    stop_video_command+=".sh"
  fi

  require_command wf-recorder wf-recorder

  focused_output="$(detect_focused_output)" || die \
    "cannot detect the focused output; supply --output MONITOR"

  if [[ "$region_enabled" == true ]]; then
    require_command slurp slurp
    geometry="$(slurp)" || die "region selection was cancelled"
    [[ -n "$geometry" ]] || die "region selection was empty"
  fi

  if ((${#codec_params[@]} == 0)) && [[ "$video_codec" == libx264 ]]; then
    codec_params=("preset=veryfast" "crf=23")
  fi

  recorder_command=(
    wf-recorder
    --file "${session_dir}/screen.mkv"
    --codec "$video_codec"
    --output "$focused_output"
    --overwrite
  )

  [[ -z "$video_framerate" ]] \
    || recorder_command+=(--framerate "$video_framerate")
  [[ -z "$video_device" ]] || recorder_command+=(--device "$video_device")
  [[ -z "$video_pixel_format" ]] \
    || recorder_command+=(--pixel-format "$video_pixel_format")
  [[ -z "$geometry" ]] || recorder_command+=(--geometry "$geometry")

  if [[ "$audio_enabled" == true ]]; then
    if [[ -n "$audio_device" ]]; then
      recorder_command+=("--audio=${audio_device}")
    else
      recorder_command+=(--audio)
    fi
  fi

  for parameter in "${codec_params[@]}"; do
    recorder_command+=(--codec-param "$parameter")
  done

  printf 'video_command=%q\n' \
    "$(quote_command "${recorder_command[@]}")" \
    >> "${session_dir}/session.meta"

  "${recorder_command[@]}" \
    > "${session_dir}/wf-recorder.log" 2>&1 &
  video_pid=$!
  video_pid_file="${runtime_root}/${BASHPID}.pid"
  printf '%s\t%s\n' "$video_pid" "$session_dir" > "$video_pid_file"

  sleep 0.4
  if ! kill -0 "$video_pid" 2> /dev/null; then
    wait "$video_pid" 2> /dev/null || true
    sed -n '1,80p' "${session_dir}/wf-recorder.log" >&2 || true
    video_pid=""
    rm -f -- "$video_pid_file"
    die "wf-recorder failed to start"
  fi

  printf 'Recording video from output %s.\n' "$focused_output" >&2
  printf 'Stop video only: %s\n\n' "$stop_video_command" >&2
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while (($# > 0)); do
  case "$1" in
    --video)
      video_enabled=true
      ;;
    --region)
      video_enabled=true
      region_enabled=true
      ;;
    --audio)
      video_enabled=true
      audio_enabled=true
      ;;
    --audio-device)
      require_value "$1" "${2:-}"
      video_enabled=true
      audio_enabled=true
      audio_device="$2"
      shift
      ;;
    --output)
      require_value "$1" "${2:-}"
      video_output="$2"
      shift
      ;;
    --codec)
      require_value "$1" "${2:-}"
      video_codec="$2"
      shift
      ;;
    --device)
      require_value "$1" "${2:-}"
      video_device="$2"
      shift
      ;;
    --codec-param)
      require_value "$1" "${2:-}"
      codec_params+=("$2")
      shift
      ;;
    --framerate)
      require_value "$1" "${2:-}"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "framerate must be an integer"
      video_framerate="$2"
      shift
      ;;
    --pixel-format)
      require_value "$1" "${2:-}"
      video_pixel_format="$2"
      shift
      ;;
    --dir)
      require_value "$1" "${2:-}"
      output_root="$2"
      shift
      ;;
    --name)
      require_value "$1" "${2:-}"
      session_label="$2"
      shift
      ;;
    --alt-screen)
      use_alt_screen=true
      ;;
    --configured-reasoning)
      reasoning_mode="configured"
      ;;
    --no-plain-text)
      plain_text_enabled=false
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    -V | --version)
      printf '%s %s\n' "$PROGRAM" "$VERSION"
      exit 0
      ;;
    --)
      shift
      codex_args=("$@")
      break
      ;;
    *)
      die "unknown capture option '$1'; place Codex arguments after --"
      ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Session setup and execution
# -----------------------------------------------------------------------------

require_command codex codex
require_command script util-linux
require_command scriptreplay util-linux

install -d -m 700 -- "$output_root" "$runtime_root"

timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
project_label="$(sanitize_label "${session_label:-${PWD##*/}}")"
[[ -n "$project_label" ]] || project_label="codex"
session_dir="${output_root}/${timestamp}_${project_label}_${BASHPID}"
install -d -m 700 -- "$session_dir"
ln -sfn -- "$session_dir" "${output_root}/latest"

declare -a codex_command=(codex)

if [[ "$use_alt_screen" != true ]]; then
  codex_command+=(--no-alt-screen)
fi

if [[ "$reasoning_mode" == best ]]; then
  codex_command+=(
    --config 'hide_agent_reasoning=false'
    --config 'show_raw_agent_reasoning=true'
    --config 'model_reasoning_summary="detailed"'
  )
fi

codex_command+=("${codex_args[@]}")

started_at="$(date --iso-8601=seconds)"
{
  printf 'format_version=%q\n' '1'
  printf 'started_at=%q\n' "$started_at"
  printf 'working_directory=%q\n' "$PWD"
  printf 'terminal=%q\n' "${TERM:-unknown}"
  printf 'codex_path=%q\n' "$(command -v codex)"
  printf 'codex_command=%q\n' "$(quote_command "${codex_command[@]}")"
  printf 'reasoning_capture=%q\n' "$reasoning_mode"
  printf 'video_enabled=%q\n' "$video_enabled"
} > "${session_dir}/session.meta"

runner="${session_dir}/run-codex.bash"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exec '
  printf '%q ' "${codex_command[@]}"
  printf '\n'
} > "$runner"
chmod 700 -- "$runner"

trap 'finalize_session "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$video_enabled" == true ]]; then
  start_video
fi

printf 'Recording terminal session. Exit Codex normally to finalize it.\n'
printf 'Session directory: %s\n\n' "$session_dir"

set +e
script \
  --quiet \
  --flush \
  --return \
  --log-out "${session_dir}/terminal.raw" \
  --log-timing "${session_dir}/terminal.timing" \
  --command "$runner"
codex_status=$?
set -e

exit "$codex_status"
