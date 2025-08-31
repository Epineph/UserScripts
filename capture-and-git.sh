#!/usr/bin/env bash
# capture-and-gif.sh
# Record a region with wf-recorder -> make a GIF with ffmpeg -> optimize with gifsicle
# Keeps:   captureN.mp4  and  output_optimizedN.gif
# Removes: outputN.gif (the intermediate, unoptimized GIF)
#
# Default directory is: $HOME/Videos/gifs
# The next index N is computed as (max existing N among capture*.mp4, output*.gif, output_optimized*.gif) + 1

set -euo pipefail
IFS=$'\n\t'

show_help() {
  cat <<'EOF'
Usage:
  capture-and-gif.sh [OPTIONS]

Description:
  Records a Wayland region using wf-recorder, converts the result to a GIF via ffmpeg,
  optimizes the GIF using gifsicle, and removes the unoptimized intermediate GIF.
  Files follow these names in the target directory:
    - captureN.mp4
    - outputN.gif               (temporary; deleted on success)
    - output_optimizedN.gif     (final, kept)

Options:
  -d, --dir DIR     Target directory (default: "$HOME/Videos/gifs")
  --fps N           GIF frame rate (default: 15)
  --scale DIV       Downscale by integer DIV (width/height divided by DIV; default: 2)
  --full            Record the full screen (skips slurp region selection)
  -h, --help        Show this help and exit

Dependencies:
  wf-recorder, ffmpeg, gifsicle, and (unless --full) slurp.

Examples:
  # Default directory ($HOME/Videos/gifs), region selection, 15 FPS, half-size
  capture-and-gif.sh

  # Custom directory, full-screen capture, 12 FPS, one-third size
  capture-and-gif.sh -d /tmp/caps --full --fps 12 --scale 3
EOF
}

# ---------- argument parsing ----------
DIR="${HOME}/Videos/gifs"
FPS=15
SCALE_DIV=2
FULL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)
      [[ $# -ge 2 ]] || { echo "Error: --dir needs a value" >&2; exit 2; }
      DIR=$2; shift 2 ;;
    --fps)
      [[ $# -ge 2 ]] || { echo "Error: --fps needs a value" >&2; exit 2; }
      FPS=$2; shift 2 ;;
    --scale)
      [[ $# -ge 2 ]] || { echo "Error: --scale needs a value" >&2; exit 2; }
      SCALE_DIV=$2; shift 2 ;;
    --full)
      FULL=1; shift ;;
    -h|--help)
      show_help; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage." >&2
      exit 2 ;;
  esac
done

# ---------- dependency checks ----------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 127
  }
}
need_cmd wf-recorder
need_cmd ffmpeg
need_cmd gifsicle
if [[ $FULL -eq 0 ]]; then need_cmd slurp; fi

# ---------- directory prep ----------
mkdir -p -- "$DIR"

# ---------- compute next index N ----------
# Strategy: scan capture*.mp4, output*.gif, output_optimized*.gif; extract trailing integer; N = max + 1
next_index() {
  shopt -s nullglob
  local max=0 n base f
  for f in "$DIR"/capture*.mp4 "$DIR"/output_optimized*.gif "$DIR"/output*.gif; do
    [[ -e $f ]] || continue
    base=${f##*/}  # strip path
    if   [[ $base =~ ^capture([0-9]+)\.mp4$ ]]; then n=${BASH_REMATCH[1]}
    elif [[ $base =~ ^output_optimized([0-9]+)\.gif$ ]]; then n=${BASH_REMATCH[1]}
    elif [[ $base =~ ^output([0-9]+)\.gif$ ]]; then n=${BASH_REMATCH[1]}
    else continue
    fi
    (( n > max )) && max=$n
  done
  echo $((max + 1))
}
N="$(next_index)"

# ---------- filenames ----------
MP4="$DIR/capture${N}.mp4"
GIF="$DIR/output${N}.gif"
GIF_OPT="$DIR/output_optimized${N}.gif"

# ---------- recording ----------
if [[ $FULL -eq 1 ]]; then
  echo "Recording full screen to: $MP4"
  wf-recorder -f "$MP4"
else
  echo "Select a region; recording to: $MP4"
  wf-recorder -g "$(slurp)" -f "$MP4"
fi

# ---------- mp4 -> gif ----------
# Build the vf string carefully; integer downscale to preserve aspect, lanczos for quality
VF="fps=${FPS},scale=iw/${SCALE_DIV}:ih/${SCALE_DIV}:flags=lanczos"
echo "Converting to GIF: $GIF  (vf: $VF)"
ffmpeg -hide_banner -loglevel error -y -i "$MP4" -vf "$VF" -loop 0 "$GIF"

# ---------- optimize gif ----------
echo "Optimizing GIF -> $GIF_OPT"
if gifsicle -O3 "$GIF" -o "$GIF_OPT"; then
  echo "Optimization succeeded; removing intermediate GIF: $GIF"
  rm -- "$GIF"
else
  echo "Warning: optimization failed; keeping unoptimized GIF: $GIF" >&2
fi

echo "Done."
echo "Saved:"
printf '  %s\n' "$MP4" "$GIF_OPT"
