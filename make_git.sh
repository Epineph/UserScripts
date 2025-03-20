#!/bin/bash
# record_and_convert.sh
# -----------------------------------------------------------------------------
# Description:
#   This script records a screen region to a video file using wf-recorder
#   and then converts that video to a GIF using ffmpeg. The user may provide
#   the video output directory, video base name, and GIF output directory as
#   command-line arguments. If not provided, the script prompts the user interactively.
#
# Usage:
#   ./record_and_convert.sh [OPTIONS]
#
# Options:
#   --video-dir   Directory where the video will be saved.
#   --video-name  Base name for the video file (without extension).
#   --gif-dir     Directory where the GIF will be saved.
#   --help        Display this help message and exit.
#
# Example:
#   ./record_and_convert.sh --video-dir ~/Videos --video-name mycapture --gif-dir ~/Gifs
#
# -----------------------------------------------------------------------------

# Display help if --help is supplied
if [[ "$1" == "--help" ]]; then
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --video-dir   Directory where the video will be saved.
  --video-name  Base name for the video file (without extension).
  --gif-dir     Directory where the GIF will be saved.
  --help        Display this help message and exit.

Example:
  $(basename "$0") --video-dir ~/Videos --video-name mycapture --gif-dir ~/Gifs

If any of these options are omitted, the script will prompt you interactively.
EOF
    exit 0
fi

# Initialize variables (empty means interactive prompt)
VIDEO_DIR=""
VIDEO_NAME=""
GIF_DIR=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --video-dir)
            VIDEO_DIR="$2"
            shift 2
            ;;
        --video-name)
            VIDEO_NAME="$2"
            shift 2
            ;;
        --gif-dir)
            GIF_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Prompt the user if arguments are missing
if [ -z "$VIDEO_DIR" ]; then
    read -p "Enter directory for video output: " VIDEO_DIR
fi

if [ -z "$VIDEO_NAME" ]; then
    read -p "Enter base name for the video file (without extension): " VIDEO_NAME
fi

if [ -z "$GIF_DIR" ]; then
    read -p "Enter directory for GIF output: " GIF_DIR
fi

# Create output directories if they do not exist
mkdir -p "$VIDEO_DIR"
mkdir -p "$GIF_DIR"

# Define file paths for the video and the GIF
VIDEO_FILE="$VIDEO_DIR/$VIDEO_NAME.mp4"
GIF_FILE="$GIF_DIR/$VIDEO_NAME.gif"

# Start recording: wf-recorder uses slurp to select a screen region interactively.
echo "Recording video to $VIDEO_FILE..."
wf-recorder -g "$(slurp)" -f "$VIDEO_FILE"

# Convert the recorded video to a GIF with ffmpeg.
echo "Converting video to GIF at $GIF_FILE..."
ffmpeg -i "$VIDEO_FILE" -vf "fps=15,scale=iw/2:ih/2:flags=lanczos" -loop 0 "$GIF_FILE"

echo "Conversion complete."

