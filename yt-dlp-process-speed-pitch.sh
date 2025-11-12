#!/usr/bin/env bash
#
# process_youtube_pitch_speed.sh
#
# Ensures required commands are available, then downloads a video via yt-dlp,
# applies pitch shift and optional speed change in a single ffmpeg pass,
# re-encodes video (x264) and audio (AAC), and outputs a synchronized MP4.
# Designed for Arch Linux (uses pacman or yay for dependency checks).
#
set -euo pipefail
IFS=$'\n\t'

# Default parameters
PITCH_SHIFT="Up"
SEMITONES=0
SPEED_FACTOR=1.0
VIDEO_CRF=18
VIDEO_PRESET="slow"
AUDIO_BITRATE="320k"

usage() {
  cat <<EOF
Usage: $0 \
  -u <url> \
  -o <output_base> \
  -t <title> \
  -n <video_name> [options]

Required:
  -u URL             Video URL (e.g. YouTube link)
  -o OUTPUT          Base name for download (without extension)
  -t TITLE           Audio title metadata
  -n VIDEO_NAME      Base name for final output file

Optional:
  -p Up|Down         Pitch direction (default: Up)
  -s N               Semitones to shift (default: 0)
  -f FACTOR          Speed factor <1 slows, >1 speeds (default: 1.0)
  -c CRF             x264 CRF (0–51, default: 18)
  -P PRESET          x264 preset (e.g. slow, veryslow; default: slow)
  -b BITRATE         AAC bitrate (e.g. 320k; default: 320k)
  -h                 Show this help message
EOF
  exit 1
}

# Parse options
while getopts "u:o:p:s:f:t:n:c:P:b:h" opt; do
  case "$opt" in
    u) URL="$OPTARG" ;;  o) OUTPUT_BASE="$OPTARG" ;;
    p) PITCH_SHIFT="$OPTARG" ;;
    s) SEMITONES="$OPTARG" ;;
    f) SPEED_FACTOR="$OPTARG" ;;
    t) TITLE="$OPTARG" ;;
    n) VIDEO_NAME="$OPTARG" ;;
    c) VIDEO_CRF="$OPTARG" ;;
    P) VIDEO_PRESET="$OPTARG" ;;
    b) AUDIO_BITRATE="$OPTARG" ;;
    h|*) usage ;;
  esac
done

# Check required
: "${URL:?}" "${OUTPUT_BASE:?}" "${TITLE:?}" "${VIDEO_NAME:?}"

# Dependency check helper
dep_check() {
  cmd="$1"; pkg="$2"
  if ! command -v "$cmd" &>/dev/null; then
    echo "Warning: $cmd not found. Install with: sudo pacman -S $pkg  # or yay -S $pkg"
  fi
}

# Check commands
dep_check yt-dlp    "yt-dlp"
dep_check ffmpeg    "ffmpeg"
dep_check rubberband "rubberband"

echo "Dependencies checked. Proceeding..."

# 1. Download via yt-dlp
echo "Downloading $URL to ${OUTPUT_BASE}..."
yt-dlp -f 'bv*[height<=1080]+ba/best' -o "${OUTPUT_BASE}.%(ext)s" "$URL"

# 2. Locate downloaded file
download_file=$(ls -t ${OUTPUT_BASE}.* | head -n1)
echo "Using file: $download_file"

# 3. Compute parameters
if (( SEMITONES == 0 )); then
  pitch_ratio=1.0
else
  if [[ "$PITCH_SHIFT" == "Down" ]]; then
    semitone_shift=$(( -SEMITONES ))
  else
    semitone_shift=$SEMITONES
  fi
  pitch_ratio=$(awk "BEGIN{printf \"%f\",2^($semitone_shift/12)}")
fi
vpts=$(awk "BEGIN{printf \"%f\",1/$SPEED_FACTOR}")
speed_label=$(awk "BEGIN{printf \"%g\",$SPEED_FACTOR}" | sed 's/\./p/')

if (( SEMITONES == 0 )); then
  name_part="speed-${speed_label}"
else
  name_part="shifted-$(echo $PITCH_SHIFT | tr '[:upper:]' '[:lower:]')-${SEMITONES}st-${speed_label}"
fi
out_file="${VIDEO_NAME}-${name_part}.mp4"

echo "Processing and encoding to $out_file..."

# 4. ffmpeg single-pass filter+encode
ffmpeg -y -i "$download_file" \
  -filter_complex \
    "[0:v]setpts=PTS*${vpts}[v];[0:a]rubberband=tempo=${SPEED_FACTOR}:pitch=${pitch_ratio}[a]" \
  -map "[v]" -map "[a]" \
  -c:v libx264 -preset $VIDEO_PRESET -crf $VIDEO_CRF \
  -c:a aac -b:a $AUDIO_BITRATE \
  -metadata:s:a:0 title="$TITLE" \
  "$out_file"

echo "Done: $out_file"
