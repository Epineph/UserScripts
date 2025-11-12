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
#   an optimized looping GIF. Additionally, on every invocation, it ensures
#   the necessary Hyprland keybindings are present in your config.
#
# Dependencies:
#   wf-recorder, slurp, ffmpeg, gifsicle
#
# Customization:
#   - Change OUTPUT_DIR to suit preferred storage path.
#   - Adjust CONFIG_FILE if your Hyprland config is elsewhere.
#
set -euo pipefail
IFS=$'\n\t'

### Configuration ##############################################################
OUTPUT_DIR="${HOME}/.cache/record_gif"
PID_FILE="${OUTPUT_DIR}/record_gif.pid"
CONFIG_FILE="${HOME}/.config/hypr/hyprland.conf"

# The Hyprland bindings to ensure
BIND_START="bind = MOD+PRINT, exec, ${HOME}/bin/record_gif.sh start"
BIND_STOP="bind = MOD+SHIFT+PRINT, exec, ${HOME}/bin/record_gif.sh stop"

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

Additionally, this script will check your Hyprland config at each run and
append the necessary bindings if they are missing.
EOF
}

error_exit() {
  echo "Error: $1" >&2
  exit 1
}

ensure_hypr_bindings() {
  # Skip if config doesn't exist
  [[ -f "$CONFIG_FILE" ]] || return

  # Check for start binding
  if ! grep -Fxq "$BIND_START" "$CONFIG_FILE"; then
    echo -e "\n# Added by record_gif.sh" >> "$CONFIG_FILE"
    echo "$BIND_START" >> "$CONFIG_FILE"
    echo "$BIND_STOP" >> "$CONFIG_FILE"
    echo "[record_gif] Keybindings added to $CONFIG_FILE"
  fi
}

### Ensure Hyprland keybindings ################################################
ensure_hypr_bindings

### Main Logic ###############################################################
if [[ $# -ne 1 ]]; then
  print_help
  exit 1
fi

case "$1" in
  start)
    if [[ -f "${PID_FILE}" ]] && kill -0 "$(<"${PID_FILE}")" &>/dev/null; then
      error_exit "Recording is already in progress (PID=$(<"${PID_FILE}"))."
    fi

    REGION="$(slurp)" || error_exit "Region selection cancelled."
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    MP4_FILE="${OUTPUT_DIR}/record_${TIMESTAMP}.mp4"
    GIF_FILE="${OUTPUT_DIR}/record_${TIMESTAMP}.gif"
    OPT_GIF="${OUTPUT_DIR}/record_${TIMESTAMP}_opt.gif"

    echo "Starting recording of region '${REGION}' to ${MP4_FILE}'"
    wf-recorder -g "${REGION}" -f "${MP4_FILE}" &
    echo $! > "${PID_FILE}"
    echo "Recording PID is $(<"${PID_FILE}")"
    ;;

  stop)
    [[ -f "${PID_FILE}" ]] || error_exit "No recording in progress (PID file not found)."
    REC_PID="$(<"${PID_FILE}")"
    if ! kill -0 "${REC_PID}" &>/dev/null; then
      error_exit "Recorded process (PID=${REC_PID}) is not running."
    fi

    echo "Stopping recording (PID=${REC_PID})..."
    kill "${REC_PID}"
    wait "${REC_PID}" || true
    echo "Recording stopped."

    MP4_FILE="$(ls -t ${OUTPUT_DIR}/record_*.mp4 | head -n1)"
    [[ -f "$MP4_FILE" ]] || error_exit "Could not locate recorded MP4 file."

    GIF_FILE="${MP4_FILE%.mp4}.gif"
    OPT_GIF="${MP4_FILE%.mp4}_opt.gif"

    echo "Converting to GIF (15 fps, half resolution)…"
    ffmpeg -i "$MP4_FILE" -vf "fps=15,scale=iw/2:ih/2:flags=lanczos" -loop 0 "$GIF_FILE"

    echo "Optimizing GIF with gifsicle…"
    gifsicle -O3 -j8 "$GIF_FILE" -o "$OPT_GIF"

    echo "Output optimized GIF: $OPT_GIF"
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

