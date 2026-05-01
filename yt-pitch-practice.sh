#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# yt-pitch-practice
#
# Download a video/audio source with yt-dlp, shift pitch with Rubber Band, and
# optionally change tempo. By default, it outputs MKV video with copied video
# stream when possible and lossless FLAC audio after processing.
#
# Intended example:
#   Original song: C# standard
#   Your guitar:   standard tuning
#   Song shift:    +3 semitones
#
# Copyright note:
#   Use only for material you have permission to download/process.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
yt-pitch-practice

Usage:
  yt-pitch-practice --url URL [options]
  yt-pitch-practice URL [options]

Core options:
  -u, --url URL                 URL to download. Mandatory unless positional.
  -o, --out-dir DIR             Output directory. Default: current directory.
  -n, --name NAME               Output basename. Default: downloaded title.
      --audio-only              Output audio only.
      --container mkv|mp4       Video container. Default: mkv.
      --audio-format FORMAT     Audio-only format: flac, wav, opus, m4a, mp3.
                                Default: flac.

Pitch / tempo:
      --pitch-semitones N       Pitch shift in semitones. Default: 0.
                                Use +3 for C# standard tab on standard tuning.
                                Use +1 for C# standard tab on D standard.
      --pitch-up N              Equivalent to --pitch-semitones +N.
      --pitch-down N            Equivalent to --pitch-semitones -N.
      --tempo-percent P         Tempo as percent of original. Default: 100.
                                80 = slower, 125 = faster.

Quality / compatibility:
      --crf N                   Video CRF when video re-encoding is required.
                                Default: 15. Lower is larger/better.
      --preset NAME             x264 preset when re-encoding video.
                                Default: veryslow.
      --no-formant              Disable Rubber Band formant preservation.
      --cookies-from-browser B  Pass browser cookies to yt-dlp, e.g. firefox.
      --keep-temp               Keep temporary working directory.
  -h, --help                    Show help.

Notes:
  * MKV is recommended for maximum quality.
  * With tempo unchanged and MKV output, video is copied without re-encoding.
  * Tempo changes require video re-encoding to keep audio/video sync.
  * MP4 output is treated as compatibility mode and re-encodes video to H.264.

Examples:
  # C# standard tab, guitar in standard tuning:
  yt-pitch-practice URL --pitch-semitones +3

  # C# standard tab, guitar tuned one step down to D standard:
  yt-pitch-practice URL --pitch-semitones +1

  # Standard guitar, slower practice video at 80% tempo:
  yt-pitch-practice URL --pitch-semitones +3 --tempo-percent 80

  # Audio only, lossless FLAC:
  yt-pitch-practice URL --audio-only --pitch-semitones +3

  # Audio only, high-bitrate Opus:
  yt-pitch-practice URL --audio-only --audio-format opus \
    --pitch-semitones +3 --tempo-percent 75

  # MP4 compatibility output:
  yt-pitch-practice URL --container mp4 --pitch-semitones +3
EOF
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function note() {
  printf '==> %s\n' "$*" >&2
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function require_programs() {
  local missing=()
  local program

  for program in yt-dlp ffmpeg ffprobe rubberband awk sed tr date mktemp; do
    have "$program" || missing+=("$program")
  done

  ((${#missing[@]} == 0)) || die "missing programs: ${missing[*]}"
}

function is_number() {
  [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]
}

function is_positive_number() {
  is_number "$1" && awk -v x="$1" 'BEGIN { exit !(x > 0) }'
}

function tempo_changed() {
  awk -v p="$TEMPO_PERCENT" 'BEGIN {
    d = p - 100
    if (d < 0) {
      d = -d
    }
    exit !(d > 0.000001)
  }'
}

function tempo_ratio() {
  awk -v p="$TEMPO_PERCENT" 'BEGIN { printf "%.10g", p / 100 }'
}

function make_safe_stem() {
  local input="$1"
  local stem

  stem="${NAME:-$(basename "$input")}"
  stem="${stem%.*}"

  printf '%s' "$stem" |
    sed -E \
      -e 's/[[:space:]]+/_/g' \
      -e 's/[^A-Za-z0-9._+-]+/_/g' \
      -e 's/_+/_/g' \
      -e 's/^_//' \
      -e 's/_$//'
}

function make_shift_tag() {
  local pitch tempo

  pitch="$(printf '%s' "$PITCH_SEMITONES" |
    sed -e 's/^+//' -e 's/-/m/' -e 's/\./p/g')"

  tempo="$(printf '%s' "$TEMPO_PERCENT" |
    sed -e 's/\./p/g')"

  printf 'pitch_%sst_tempo_%spct' "$pitch" "$tempo"
}

function build_audio_args() {
  local format="$1"
  AUDIO_ARGS=()

  case "$format" in
    flac)
      AUDIO_ARGS=(-c:a flac -compression_level 12)
      ;;
    wav)
      AUDIO_ARGS=(-c:a pcm_f32le)
      ;;
    opus)
      AUDIO_ARGS=(-c:a libopus -b:a 510k -vbr on -compression_level 10)
      ;;
    m4a)
      AUDIO_ARGS=(-c:a aac -b:a 320k)
      ;;
    mp3)
      AUDIO_ARGS=(-c:a libmp3lame -b:a 320k)
      ;;
    *)
      die "unsupported audio format: $format"
      ;;
  esac
}

function download_source() {
  local tmp="$1"
  local url="$2"
  local mode="$3"
  local path_file="$tmp/downloaded-path.txt"
  local -a cmd=()

  cmd=(
    yt-dlp
    --no-simulate
    --no-playlist
    --continue
    --newline
    --embed-metadata
    -o "$tmp/source.%(ext)s"
    --print-to-file "after_move:filepath" "$path_file"
  )

  if [[ "$mode" == "audio" ]]; then
    cmd+=(-f "bestaudio/best")
  else
    cmd+=(
      -f "bestvideo*+bestaudio/best"
      -S "res,fps,hdr:12,vcodec,acodec,br"
      --merge-output-format mkv
      --remux-video mkv
    )
  fi

  if have aria2c; then
    cmd+=(
      --downloader aria2c
      --downloader-args "aria2c:-x 16 -s 16 -k 1M"
    )
  fi

  if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
    cmd+=(--cookies-from-browser "$COOKIES_FROM_BROWSER")
  fi

  note "downloading source media"
  "${cmd[@]}" "$url"

  [[ -s "$path_file" ]] || die "yt-dlp did not report final file path"

  tail -n 1 "$path_file"
}

function extract_audio_to_wav() {
  local source="$1"
  local output="$2"

  note "extracting audio as 32-bit float WAV"

  ffmpeg \
    -hide_banner \
    -y \
    -i "$source" \
    -vn \
    -map 0:a:0 \
    -c:a pcm_f32le \
    "$output"
}

function process_audio() {
  local input="$1"
  local output="$2"
  local ratio
  local -a cmd=()

  ratio="$(tempo_ratio)"

  note "processing audio: pitch=${PITCH_SEMITONES} st, tempo=${TEMPO_PERCENT}%"

  cmd=(
    rubberband
    --fine
    --tempo "$ratio"
    --pitch "$PITCH_SEMITONES"
  )

  if [[ "$FORMANT" -eq 1 ]]; then
    cmd+=(--formant)
  fi

  cmd+=("$input" "$output")

  "${cmd[@]}"
}

function write_audio_only() {
  local processed="$1"
  local output="$2"

  build_audio_args "$AUDIO_FORMAT"

  note "writing audio-only output"

  ffmpeg \
    -hide_banner \
    -y \
    -i "$processed" \
    "${AUDIO_ARGS[@]}" \
    "$output"
}

function write_video_output() {
  local source="$1"
  local processed="$2"
  local output="$3"
  local ratio
  local video_audio_format

  ratio="$(tempo_ratio)"

  if [[ "$CONTAINER" == "mkv" ]]; then
    video_audio_format="flac"
  else
    video_audio_format="m4a"
  fi

  build_audio_args "$video_audio_format"

  if tempo_changed || [[ "$CONTAINER" == "mp4" ]]; then
    note "writing video output with H.264 re-encode"

    ffmpeg \
      -hide_banner \
      -y \
      -i "$source" \
      -i "$processed" \
      -map 0:v:0 \
      -map 1:a:0 \
      -filter:v "setpts=PTS/${ratio}" \
      -c:v libx264 \
      -preset "$PRESET" \
      -crf "$CRF" \
      -pix_fmt yuv420p \
      "${AUDIO_ARGS[@]}" \
      -shortest \
      "$output"
  else
    note "writing video output with copied video stream"

    ffmpeg \
      -hide_banner \
      -y \
      -i "$source" \
      -i "$processed" \
      -map 0:v:0 \
      -map 1:a:0 \
      -map 0:s? \
      -c:v copy \
      -c:s copy \
      "${AUDIO_ARGS[@]}" \
      -shortest \
      "$output"
  fi
}

URL=""
OUT_DIR="$PWD"
NAME=""
AUDIO_ONLY=0
CONTAINER="mkv"
AUDIO_FORMAT="flac"
PITCH_SEMITONES="0"
TEMPO_PERCENT="100"
CRF="15"
PRESET="veryslow"
FORMANT=1
KEEP_TEMP=0
COOKIES_FROM_BROWSER=""

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -u|--url)
      (($# >= 2)) || die "$1 requires an argument"
      URL="$2"
      shift 2
      ;;
    --url=*)
      URL="${1#*=}"
      shift
      ;;
    -o|--out-dir)
      (($# >= 2)) || die "$1 requires an argument"
      OUT_DIR="$2"
      shift 2
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    -n|--name)
      (($# >= 2)) || die "$1 requires an argument"
      NAME="$2"
      shift 2
      ;;
    --name=*)
      NAME="${1#*=}"
      shift
      ;;
    --audio-only)
      AUDIO_ONLY=1
      shift
      ;;
    --container)
      (($# >= 2)) || die "$1 requires an argument"
      CONTAINER="$(lower "$2")"
      shift 2
      ;;
    --container=*)
      CONTAINER="$(lower "${1#*=}")"
      shift
      ;;
    --audio-format)
      (($# >= 2)) || die "$1 requires an argument"
      AUDIO_FORMAT="$(lower "$2")"
      shift 2
      ;;
    --audio-format=*)
      AUDIO_FORMAT="$(lower "${1#*=}")"
      shift
      ;;
    --pitch-semitones|--pitch)
      (($# >= 2)) || die "$1 requires an argument"
      PITCH_SEMITONES="$2"
      shift 2
      ;;
    --pitch-semitones=*|--pitch=*)
      PITCH_SEMITONES="${1#*=}"
      shift
      ;;
    --pitch-up)
      (($# >= 2)) || die "$1 requires an argument"
      PITCH_SEMITONES="+$2"
      shift 2
      ;;
    --pitch-up=*)
      PITCH_SEMITONES="+${1#*=}"
      shift
      ;;
    --pitch-down)
      (($# >= 2)) || die "$1 requires an argument"
      PITCH_SEMITONES="-$2"
      shift 2
      ;;
    --pitch-down=*)
      PITCH_SEMITONES="-${1#*=}"
      shift
      ;;
    --tempo-percent|--tempo)
      (($# >= 2)) || die "$1 requires an argument"
      TEMPO_PERCENT="$2"
      shift 2
      ;;
    --tempo-percent=*|--tempo=*)
      TEMPO_PERCENT="${1#*=}"
      shift
      ;;
    --crf)
      (($# >= 2)) || die "$1 requires an argument"
      CRF="$2"
      shift 2
      ;;
    --crf=*)
      CRF="${1#*=}"
      shift
      ;;
    --preset)
      (($# >= 2)) || die "$1 requires an argument"
      PRESET="$2"
      shift 2
      ;;
    --preset=*)
      PRESET="${1#*=}"
      shift
      ;;
    --cookies-from-browser)
      (($# >= 2)) || die "$1 requires an argument"
      COOKIES_FROM_BROWSER="$2"
      shift 2
      ;;
    --cookies-from-browser=*)
      COOKIES_FROM_BROWSER="${1#*=}"
      shift
      ;;
    --no-formant)
      FORMANT=0
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    http://*|https://*)
      [[ -z "$URL" ]] || die "URL specified more than once"
      URL="$1"
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$URL" ]] || die "missing URL"
[[ "$CONTAINER" =~ ^(mkv|mp4)$ ]] || die "container must be mkv or mp4"
[[ "$AUDIO_FORMAT" =~ ^(flac|wav|opus|m4a|mp3)$ ]] ||
  die "audio format must be flac, wav, opus, m4a, or mp3"

is_number "$PITCH_SEMITONES" ||
  die "pitch must be numeric, e.g. +3, -1, 0, 1.5"

is_positive_number "$TEMPO_PERCENT" ||
  die "tempo percent must be positive, e.g. 80, 100, 125"

is_positive_number "$CRF" ||
  die "CRF must be positive"

require_programs
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d --tmpdir yt-pitch-practice.XXXXXXXX)"

function cleanup() {
  if [[ "$KEEP_TEMP" -eq 1 ]]; then
    note "kept temporary directory: $TMP_DIR"
  else
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

MODE="video"
[[ "$AUDIO_ONLY" -eq 1 ]] && MODE="audio"

SOURCE="$(download_source "$TMP_DIR" "$URL" "$MODE")"
RAW_AUDIO="$TMP_DIR/raw.wav"
PROCESSED_AUDIO="$TMP_DIR/processed.wav"

extract_audio_to_wav "$SOURCE" "$RAW_AUDIO"
process_audio "$RAW_AUDIO" "$PROCESSED_AUDIO"

STEM="$(make_safe_stem "$SOURCE")_$(make_shift_tag)"

if [[ "$AUDIO_ONLY" -eq 1 ]]; then
  OUTPUT="$OUT_DIR/$STEM.$AUDIO_FORMAT"
  write_audio_only "$PROCESSED_AUDIO" "$OUTPUT"
else
  OUTPUT="$OUT_DIR/$STEM.$CONTAINER"
  write_video_output "$SOURCE" "$PROCESSED_AUDIO" "$OUTPUT"
fi

printf 'wrote: %s\n' "$OUTPUT"
