#!/usr/bin/env bash

# download_and_process.sh
#
# Download a YouTube video at the best available ≤1080p resolution with top-quality audio.
# Always outputs an original MP4 (or other extension) copy. Optionally produces:
#   • Pitched-only version (audio pitch-shifted)
#   • Slowed/sped version (tempo-changed) without pitch change
#   • Combined pitched & tempo-changed version
# All intermediate .mkv and .wav files are removed upon script completion.
#
# ---------------------------------------------------------------------------------------------------------------------
# USAGE SUMMARY
# ---------------------------------------------------------------------------------------------------------------------
#   download_and_process.sh [options] URL [SPEED_FACTOR]
#
#   URL           YouTube video URL (required)
#   SPEED_FACTOR  Optional decimal speed ratio:
#                 <1 = slower (e.g., 0.75 = 75% speed)
#                 >1 = faster (e.g., 1.25 = 125% speed)
#
# OPTIONS
#   -h, --help             Show this help message and exit
#   -t, --target DIR       Output directory (default: current directory)
#   -n, --name NAME        Base filename for all outputs (required)
#   -e, --ext EXT          Output extension (default: mp4)
#   -P, --pitch SEMITONES  Pitch shift in semitones (positive = up, negative = down). Default: 0 (no pitch shift)
#
# EXAMPLES using cat << 'EOF' style help
#   download_and_process.sh -n song https://youtu.be/ID
#     -> song.mp4
#
#   download_and_process.sh -n song -P -5 https://youtu.be/ID
#     -> song.mp4           (original)
#     -> song-pitched-5.mp4 (audio pitch down 5 semitones)
#
#   download_and_process.sh -n song -P -5 https://youtu.be/ID 0.75
#     -> song.mp4                     (original)
#     -> song-pitched-5.mp4           (pitch only)
#     -> song-pitched-5-slowed25.mp4  (pitch & slow, 25% slower)
#
#   download_and_process.sh -n lesson -t out https://youtu.be/ID 1.1
#     -> out/lesson.mp4           (original)
#     -> out/lesson-slowed-10.mp4 (10% faster)
#
#   download_and_process.sh --help
#
# ---------------------------------------------------------------------------------------------------------------------
set -euo pipefail

# Default option values
TARGET_DIR="."
OUT_NAME=""
OUT_EXT="mp4"
PITCH_SEMITONES=0
POSITIONAL=()

# --- Parse options ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat << 'EOF'
download_and_process.sh - Download YouTube & create pitch/tempo variants

Usage:
  download_and_process.sh [options] URL [SPEED_FACTOR]

Arguments:
  URL           YouTube video URL (required)
  SPEED_FACTOR  Optional decimal speed ratio (<1 slower, >1 faster)

Options:
  -h, --help             Show this help and exit
  -t, --target DIR       Output directory (default: current)
  -n, --name NAME        Base filename for outputs (required)
  -e, --ext EXT          Output extension (default: mp4)
  -P, --pitch SEMITONES  Pitch shift in semitones (±); default 0 (no shift)

Examples:
  # Download only original:
  download_and_process.sh -n song https://youtu.be/ID

  # Pitch down 5 semitones:
  download_and_process.sh -n song -P -5 https://youtu.be/ID

  # Pitch down 5 and slow to 75%:
  download_and_process.sh -n song -P -5 https://youtu.be/ID 0.75

  # Speed up 10% only, output to 'out' folder:
  download_and_process.sh -t out -n lesson https://youtu.be/ID 1.1
EOF
      exit 0
      ;;
    -t|--target)
      TARGET_DIR="$2"; shift 2
      ;;
    -n|--name|--name-video)
      OUT_NAME="$2"; shift 2
      ;;
    -e|--ext)
      OUT_EXT="$2"; shift 2
      ;;
    -P|--pitch)
      PITCH_SEMITONES="$2"; shift 2
      ;;
    -* )
      echo "Unknown option: $1" >&2; echo "Use --help for usage." >&2; exit 1
      ;;
    *)
      POSITIONAL+=("$1"); shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

# Validate arguments
if [[ -z "$OUT_NAME" ]]; then
  echo "Error: --name NAME is required." >&2; exit 1
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Error: URL and optional SPEED_FACTOR required." >&2; exit 1
fi
URL="$1"
SPEED="${2:-}"

# Prepare target directory
mkdir -p "$TARGET_DIR"
BASE_PATH="$TARGET_DIR/$OUT_NAME"

# 1) Download best streams to MKV
MKV_FILE="${BASE_PATH}.mkv"
yt-dlp -f "bv*[height<=1080]+ba/best" -o "$MKV_FILE" "$URL"

# 2) Always remux original to desired extension
ORIG_FILE="${BASE_PATH}.${OUT_EXT}"
echo "Creating original file: $ORIG_FILE"
ffmpeg -y -i "$MKV_FILE" -c copy "$ORIG_FILE"

# Extract audio for further processing only if pitch or speed requested
if [[ "$PITCH_SEMITONES" -ne 0 || -n "$SPEED" ]]; then
  WAV_FILE="${BASE_PATH}.wav"
  SHIFT_WAV="${BASE_PATH}-proc.wav"

  # 3) Extract to WAV
  ffmpeg -y -i "$MKV_FILE" -vn -acodec pcm_s16le "$WAV_FILE"

  # 4) Apply pitch and/or tempo
  if [[ -n "$SPEED" && "$PITCH_SEMITONES" -ne 0 ]]; then
    rubberband -t "$SPEED" -p "$PITCH_SEMITONES" "$WAV_FILE" "$SHIFT_WAV"
  elif [[ -n "$SPEED" ]]; then
    rubberband -t "$SPEED" "$WAV_FILE" "$SHIFT_WAV"
  else
    rubberband -p "$PITCH_SEMITONES" "$WAV_FILE" "$SHIFT_WAV"
  fi

  # 5) Generate output variants
  # Pitch-only
  if [[ "$PITCH_SEMITONES" -ne 0 && -z "$SPEED" ]]; then
    OUT_PITCHED="${BASE_PATH}-pitched${PITCH_SEMITONES}.${OUT_EXT}"
    echo "Creating pitched-only file: $OUT_PITCHED"
    ffmpeg -y -i "$MKV_FILE" -i "$SHIFT_WAV" -c:v copy -c:a aac -b:a 192k -map 0:v -map 1:a "$OUT_PITCHED"
  fi

  # Speed-only
  if [[ -n "$SPEED" && "$PITCH_SEMITONES" -eq 0 ]]; then
    PERCENT=$(awk -v s="$SPEED" 'BEGIN{printf "%d", (1 - s)*100}')
    OUT_SLOW="${BASE_PATH}-slowed${PERCENT}.${OUT_EXT}"
    echo "Creating speed-only file: $OUT_SLOW"
    ffmpeg -y -i "$MKV_FILE" -i "$SHIFT_WAV" -c:v copy -c:a aac -b:a 192k -map 0:v -map 1:a "$OUT_SLOW"
  fi

  # Combined pitch & speed
  if [[ -n "$SPEED" && "$PITCH_SEMITONES" -ne 0 ]]; then
    PERCENT=$(awk -v s="$SPEED" 'BEGIN{printf "%d", (1 - s)*100}')
    OUT_BOTH="${BASE_PATH}-pitched${PITCH_SEMITONES}-slowed${PERCENT}.${OUT_EXT}"
    echo "Creating pitched+speed file: $OUT_BOTH"
    ffmpeg -y -i "$MKV_FILE" -i "$SHIFT_WAV" -c:v copy -c:a aac -b:a 192k -map 0:v -map 1:a "$OUT_BOTH"
  fi

  # Cleanup WAVs
  rm -f "$WAV_FILE" "$SHIFT_WAV"
fi

# Cleanup MKV
rm -f "$MKV_FILE"

echo "Done. Files in $TARGET_DIR:"  
echo "  • $ORIG_FILE"  
[[ -n "${OUT_PITCHED:-}" ]] && echo "  • $OUT_PITCHED"
[[ -n "${OUT_SLOW:-}" ]]   && echo "  • $OUT_SLOW"
[[ -n "${OUT_BOTH:-}" ]]   && echo "  • $OUT_BOTH"

