#!/usr/bin/env bash
#
# record_gif.sh — Simple toggle wrapper for Wayland screen recording → optimized GIF
#
# Usage:
#   record_gif.sh start    # Begin recording a selected region
#   record_gif.sh stop     # Stop recording, convert to GIF, optimize output
#   record_gif.sh -h|--help  # Show this help text
#
# Description:
#   On "start", calls `slurp` to select a region, then launches wf-recorder in
#   the background, writing its PID to a file. On "stop", kills wf-recorder,
#   waits for it to exit cleanly, and then runs ffmpeg → gifsicle to produce
#   an optimized looping GIF.
#
# Dependencies:
#   wf-recorder, slurp, ffmpeg, gifsicle
#
# Customization:
#   - You may change OUTPUT_DIR to suit your preferred storage path.
#   - Filenames include a timestamp to avoid overwriting previous captures.
#

set -euo pipefail
IFS=$'\n\t'

### Configuration ##############################################################
# Directory to store intermediate and final files.
OUTPUT_DIR="${HOME}/.cache/record_gif"
# PID file for the running wf-recorder process
PID_FILE="${OUTPUT_DIR}/record_gif.pid"

# Ensure output directory exists
mkdir -p "${OUTPUT_DIR}"

### Helper Functions ##########################################################

print_help() {
  cat <<EOF
record_gif.sh — Wayland screen → optimized GIF wrapper

Usage:
  record_gif.sh start    Begin screen recording
  record_gif.sh stop     Stop recording and produce optimized GIF
  record_gif.sh -h|--help  Show this help

Logic overview:
  * start:
      1. Ask slurp to select a region (no extra GUI windows).
      2. Launch wf-recorder in background, writing to a timestamped MP4.
      3. Save its PID for later.
  * stop:
      1. Read the PID file, kill wf-recorder, wait for exit.
      2. Run ffmpeg to convert MP4 → GIF (15 fps, half resolution, Lanczos).
      3. Run gifsicle to perform multi-threaded optimization (-O3).
      4. Output final GIF alongside intermediate files.
      5. Clean up PID file.

EOF
}

error_exit() {
  echo "Error: $1" >&2
  exit 1
}

### Main Logic ###############################################################

if [[ $# -ne 1 ]]; then
  print_help
  exit 1
fi

case "$1" in
  start)
    if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" &>/dev/null; then
      error_exit "Recording is already in progress (PID=$(cat "${PID_FILE}"))."
    fi

    # Ask user to select region; result is WxH+X+Y
    REGION="$(slurp)" || error_exit "Region selection cancelled."
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    MP4_FILE="${OUTPUT_DIR}/record_${TIMESTAMP}.mp4"
    GIF_FILE="${OUTPUT_DIR}/record_${TIMESTAMP}.gif"
    OPT_GIF="${OUTPUT_DIR}/record_${TIMESTAMP}_opt.gif"

    echo "Starting recording of region '${REGION}' to ${MP4_FILE}"
    # Launch wf-recorder and save PID
    wf-recorder -g "${REGION}" -f "${MP4_FILE}" &
    echo $! > "${PID_FILE}"
    echo "Recording PID is $(cat "${PID_FILE}")"
    ;;

  stop)
    if [[ ! -f "${PID_FILE}" ]]; then
      error_exit "No recording in progress (PID file not found)."
    fi

    REC_PID="$(cat "${PID_FILE}")"
    if ! kill -0 "${REC_PID}" &>/dev/null; then
      error_exit "Recorded process (PID=${REC_PID}) is not running."
    fi

    echo "Stopping recording (PID=${REC_PID})..."
    kill "${REC_PID}"
    # Wait for graceful shutdown
    wait "${REC_PID}" || true
    echo "Recording stopped."

    # Determine the latest MP4 file
    MP4_FILE="$(ls -t ${OUTPUT_DIR}/record_*.mp4 | head -n1)"
    if [[ ! -f "${MP4_FILE}" ]]; then
      error_exit "Could not locate recorded MP4 file."
    fi

    GIF_FILE="${MP4_FILE%.mp4}.gif"
    OPT_GIF="${MP4_FILE%.mp4}_opt.gif"

    echo "Converting to GIF (15 fps, half resolution)…"
    ffmpeg -i "${MP4_FILE}" -vf "fps=15,scale=iw/2:ih/2:flags=lanczos" -loop 0 "${GIF_FILE}"

    echo "Optimizing GIF with gifsicle…"
    gifsicle -O3 -j8 "${GIF_FILE}" -o "${OPT_GIF}"

    echo "Output optimized GIF: ${OPT_GIF}"
    # Clean up
    rm -f "${PID_FILE}"
    ;;

  -h|--help)
    print_help
    ;;

  *)
    print_help
    exit 1
    ;;
esac

