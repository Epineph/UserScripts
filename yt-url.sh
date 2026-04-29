#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# yt-url
#
# Thin wrapper around yt-dlp for audio/video downloads with predictable
# path/name handling.
#
# Suggested symlinks:
#   ln -s /usr/local/bin/yt-url /usr/local/bin/yt-audio
#   ln -s /usr/local/bin/yt-url /usr/local/bin/yt-video
#
# Behaviour by invoked name:
#   yt-url   -> default mode: both
#   yt-audio -> default mode: audio
#   yt-video -> default mode: video
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename -- "${0}")"
DEFAULT_MODE="both"
URL=""
OUTPUT_SPEC=""
NAME_SPEC=""
PRESET="high"
EXPLICIT_EXTRACT=0
WANT_AUDIO=0
WANT_VIDEO=0
POSITIONAL_OUTPUT=""

function usage() {
  cat <<'EOF'
Usage:
  yt-url [options] <url> [output]
  yt-url [options] -i <url> [output]
  yt-audio [options] <url> [output]
  yt-video [options] <url> [output]

Description:
  Wrapper around yt-dlp with a simpler interface for:
    - audio only
    - video only
    - both audio + video

  If no URL is supplied, the script tries to read one from the clipboard.

Modes:
  Default mode depends on the command name:
    yt-url   -> both
    yt-audio -> audio
    yt-video -> video

  You may override mode explicitly:
    -a, --audio     audio only
    -v, --video     video only
    -a -v           both

  The -x, --extract flag is accepted for symmetry with your proposed CLI, but
  is functionally optional in this wrapper.

Output resolution rules:
  1. No output path, no name:
       download to current working directory with yt-dlp default naming.

  2. No output path, but --name NAME:
       download to "$(pwd)/NAME.<ext>".

  3. Output path is an existing directory, or ends with '/':
       download there; if --name is supplied, it becomes DIR/NAME.<ext>.

  4. Output path is not a directory and --name is NOT supplied:
       treat output path as a file stem.
       Example: -o ~/dl/lecture  -> ~/dl/lecture.<ext>

  5. Output path is supplied and --name NAME is also supplied:
       treat output path as a directory.
       Example: -o ~/dl -n lecture -> ~/dl/lecture.<ext>

Options:
  -i, --input URL         Input URL.
  -o, --output PATH       Output directory or file stem.
  -n, --name NAME         Output base name without extension.
  -a, --audio             Audio only.
  -v, --video             Video only.
  -x, --extract           Accepted, but optional; kept for interface symmetry.
      --preset LEVEL      low | medium | high  (default: high)
  -h, --help              Show this help and exit.

Preset policy in this wrapper:
  audio + high     -> keep best available audio target
  audio + medium   -> MP3 VBR quality 2
  audio + low      -> MP3 128K
  video + high     -> bestvideo
  video + medium   -> bestvideo[height<=1080]
  video + low      -> bestvideo[height<=720]
  both + high      -> bestvideo*+bestaudio/best
  both + medium    -> bestvideo*[height<=1080]+bestaudio/best[height<=1080]
  both + low       -> bestvideo*[height<=720]+bestaudio/best[height<=720]

Examples:
  yt-audio "https://youtu.be/VIDEO"
  yt-url -a "https://youtu.be/VIDEO"
  yt-url -x -a "https://youtu.be/VIDEO" ~/Music
  yt-url -o ~/Downloads -n lecture "https://youtu.be/VIDEO"
  yt-url "https://youtu.be/VIDEO" ~/Videos
  yt-video --preset medium "https://youtu.be/VIDEO" -o ~/Clips -n demo
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function have_cmd() {
  command -v -- "$1" >/dev/null 2>&1
}

function require_arg() {
  local opt="$1"
  local val="${2-}"
  [[ -n "${val}" ]] || die "${opt} requires an argument"
}

function is_url() {
  local s="${1-}"
  [[ "${s}" =~ ^https?://[^[:space:]]+$ ]]
}

function read_clipboard_url() {
  local clip=""

  if have_cmd wl-paste; then
    clip="$(wl-paste -n 2>/dev/null || true)"
  elif have_cmd xclip; then
    clip="$(xclip -o -selection clipboard 2>/dev/null || true)"
  elif have_cmd xsel; then
    clip="$(xsel --clipboard --output 2>/dev/null || true)"
  fi

  clip="${clip//$'\r'/}"
  clip="${clip//$'\n'/}"

  if is_url "${clip}"; then
    printf '%s\n' "${clip}"
    return 0
  fi

  return 1
}

function infer_default_mode() {
  case "${SCRIPT_NAME,,}" in
    yt-audio|*audio*)
      DEFAULT_MODE="audio"
      ;;
    yt-video|*video*)
      DEFAULT_MODE="video"
      ;;
    *)
      DEFAULT_MODE="both"
      ;;
  esac
}

function parse_short_bundle() {
  local arg="$1"

  case "${arg}" in
    -xa|-ax)
      EXPLICIT_EXTRACT=1
      WANT_AUDIO=1
      return 0
      ;;
    -xv|-vx)
      EXPLICIT_EXTRACT=1
      WANT_VIDEO=1
      return 0
      ;;
    -av|-va)
      WANT_AUDIO=1
      WANT_VIDEO=1
      return 0
      ;;
    -xav|-xva|-axv|-avx|-vax|-vxa)
      EXPLICIT_EXTRACT=1
      WANT_AUDIO=1
      WANT_VIDEO=1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function resolve_mode() {
  local mode="${DEFAULT_MODE}"

  if (( WANT_AUDIO == 1 && WANT_VIDEO == 1 )); then
    mode="both"
  elif (( WANT_AUDIO == 1 )); then
    mode="audio"
  elif (( WANT_VIDEO == 1 )); then
    mode="video"
  fi

  printf '%s\n' "${mode}"
}

function resolve_output() {
  local output_input="$1"
  local name_input="$2"
  local default_dir="$(pwd -P)"
  local dir="${default_dir}"
  local template=""
  local custom_template=0
  local stem=""

  if [[ -n "${name_input}" && "${name_input}" == */* ]]; then
    die "--name must be a plain file name, not a path"
  fi

  if [[ -n "${name_input}" ]]; then
    dir="${output_input:-${default_dir}}"
    mkdir -p -- "${dir}"
    template="${name_input}.%(ext)s"
    custom_template=1
    printf '%s\n%s\n%s\n' "${dir}" "${template}" "${custom_template}"
    return 0
  fi

  if [[ -z "${output_input}" ]]; then
    printf '%s\n%s\n%s\n' "${dir}" "${template}" "${custom_template}"
    return 0
  fi

  if [[ -d "${output_input}" || "${output_input}" == */ ]]; then
    dir="${output_input%/}"
    mkdir -p -- "${dir}"
    printf '%s\n%s\n%s\n' "${dir}" "${template}" "${custom_template}"
    return 0
  fi

  dir="$(dirname -- "${output_input}")"
  stem="$(basename -- "${output_input}")"
  stem="${stem%.*}"

  mkdir -p -- "${dir}"

  template="${stem}.%(ext)s"
  custom_template=1

  printf '%s\n%s\n%s\n' "${dir}" "${template}" "${custom_template}"
}

function build_mode_args() {
  local mode="$1"
  local preset="$2"

  case "${preset,,}" in
    high)
      case "${mode}" in
        audio)
          printf '%s\n' \
            '-f' 'bestaudio/best' \
            '-x' '--audio-format' 'best'
          ;;
        video)
          printf '%s\n' \
            '-f' 'bestvideo'
          ;;
        both)
          printf '%s\n' \
            '-f' 'bestvideo*+bestaudio/best'
          ;;
      esac
      ;;
    medium)
      case "${mode}" in
        audio)
          printf '%s\n' \
            '-f' 'bestaudio/best' \
            '-x' '--audio-format' 'mp3' '--audio-quality' '2'
          ;;
        video)
          printf '%s\n' \
            '-f' 'bestvideo[height<=1080]'
          ;;
        both)
          printf '%s\n' \
            '-f' 'bestvideo*[height<=1080]+bestaudio/best[height<=1080]'
          ;;
      esac
      ;;
    low)
      case "${mode}" in
        audio)
          printf '%s\n' \
            '-f' 'bestaudio/best' \
            '-x' '--audio-format' 'mp3' '--audio-quality' '128K'
          ;;
        video)
          printf '%s\n' \
            '-f' 'bestvideo[height<=720]'
          ;;
        both)
          printf '%s\n' \
            '-f' 'bestvideo*[height<=720]+bestaudio/best[height<=720]'
          ;;
      esac
      ;;
    *)
      die "invalid --preset: ${preset} (expected: low, medium, high)"
      ;;
  esac
}

function main() {
  local mode=""
  local output_triplet=()
  local target_dir=""
  local output_template=""
  local custom_template=0
  local -a mode_args=()
  local -a cmd=()

  infer_default_mode

  while (($# > 0)); do
    if parse_short_bundle "$1"; then
      shift
      continue
    fi

    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -i|--input)
        require_arg "$1" "${2-}"
        URL="$2"
        shift 2
        ;;
      -o|--output)
        require_arg "$1" "${2-}"
        OUTPUT_SPEC="$2"
        shift 2
        ;;
      -n|--name)
        require_arg "$1" "${2-}"
        NAME_SPEC="$2"
        shift 2
        ;;
      --preset)
        require_arg "$1" "${2-}"
        PRESET="${2,,}"
        shift 2
        ;;
      -x|--extract)
        EXPLICIT_EXTRACT=1
        shift
        ;;
      -a|--audio)
        WANT_AUDIO=1
        shift
        ;;
      -v|--video)
        WANT_VIDEO=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "${URL}" ]] && is_url "$1"; then
          URL="$1"
        elif [[ -z "${POSITIONAL_OUTPUT}" ]]; then
          POSITIONAL_OUTPUT="$1"
        else
          die "unexpected positional argument: $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${URL}" ]]; then
    URL="$(read_clipboard_url || true)"
  fi

  [[ -n "${URL}" ]] || die "no URL provided and no valid URL found in clipboard"
  is_url "${URL}" || die "input does not look like a valid http(s) URL"

  if [[ -z "${OUTPUT_SPEC}" && -n "${POSITIONAL_OUTPUT}" ]]; then
    OUTPUT_SPEC="${POSITIONAL_OUTPUT}"
  fi

  have_cmd yt-dlp || die "yt-dlp was not found in PATH"

  mode="$(resolve_mode)"

  if [[ "${mode}" == 'audio' || "${mode}" == 'both' ]]; then
    have_cmd ffmpeg || die "ffmpeg is required for audio extraction/merging"
    have_cmd ffprobe || die "ffprobe is required for audio extraction"
  fi

  mapfile -t output_triplet < <(resolve_output "${OUTPUT_SPEC}" "${NAME_SPEC}")
  target_dir="${output_triplet[0]}"
  output_template="${output_triplet[1]}"
  custom_template="${output_triplet[2]}"

  mapfile -t mode_args < <(build_mode_args "${mode}" "${PRESET}")

  cmd=(yt-dlp)
  cmd+=(-P "${target_dir}")

  if (( custom_template == 1 )); then
    cmd+=(-o "${output_template}")
  fi

  cmd+=("${mode_args[@]}")
  cmd+=("${URL}")

  printf 'Mode      : %s\n' "${mode}"
  printf 'Preset    : %s\n' "${PRESET}"
  printf 'Directory : %s\n' "${target_dir}"

  if (( custom_template == 1 )); then
    printf 'Template  : %s\n' "${output_template}"
  else
    printf 'Template  : yt-dlp default naming\n'
  fi

  printf 'URL       : %s\n\n' "${URL}"
  printf 'Running   : '
  printf '%q ' "${cmd[@]}"
  printf '\n\n'

  "${cmd[@]}"
}

main "$@"
