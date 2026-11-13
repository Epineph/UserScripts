#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

### -------- CONFIG -------- ###
LOG_ROOT="$HOME/.logs"
SLURP_REGION="$(slurp)"
TIMESTAMP="$(date '+%Y-%m-%d/%H-%M-%S')"
LOG_DIR="$LOG_ROOT/$TIMESTAMP"
mkdir -p "$LOG_DIR"

VIDEO="$LOG_DIR/session.mp4"
GIF="$LOG_DIR/session.gif"
GIF_OPT="$LOG_DIR/session_optimized.gif"
TEXT_LOG="$LOG_DIR/log.txt"
### ------------------------ ###

# Defaults
REFRESH_MIRRORS=false
FULL_UPGRADE=false
COUNTDOWN_MIN=5
SHUTDOWN_MODE="reboot"

# Help
print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --refresh-mirrors     Run mirror update script (mirror_update.sh)
  --full-upgrade        Run full system upgrade and regenerate initramfs & grub
  --shutdown            Shutdown instead of reboot
  -t, --time MINUTES    Countdown time (default: 5)
  -h, --help            Show this help message
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-mirrors) REFRESH_MIRRORS=true ;;
    --full-upgrade) FULL_UPGRADE=true ;;
    --shutdown) SHUTDOWN_MODE="poweroff" ;;
    -t|--time)
      COUNTDOWN_MIN="$2"
      shift
      ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Unknown option: $1"; print_help; exit 1 ;;
  esac
  shift
done

# Countdown
echo "[INFO] Countdown started for $COUNTDOWN_MIN minute(s)..." | tee -a "$TEXT_LOG"
for ((i=COUNTDOWN_MIN*60; i>0; i--)); do
  printf "\rTime left: %02d:%02d" $((i/60)) $((i%60))
  sleep 1
done
echo -e "\n[INFO] Countdown complete." | tee -a "$TEXT_LOG"

# Start screen recording
echo "[INFO] Starting screen recording..." | tee -a "$TEXT_LOG"
wf-recorder -g "$SLURP_REGION" -f "$VIDEO" &
RECORD_PID=$!

# Execute operations in subshell and wait
(
  set -x
  if $REFRESH_MIRRORS; then
    echo "[INFO] Refreshing mirrors..." | tee -a "$TEXT_LOG"
    bash ~/mirror_update.sh | tee -a "$TEXT_LOG"
    yay -Syy | tee -a "$TEXT_LOG"
  fi

  if $FULL_UPGRADE; then
    echo "[INFO] Performing full system upgrade..." | tee -a "$TEXT_LOG"
    yay -Syu --noconfirm | tee -a "$TEXT_LOG"
    echo "[INFO] Re-generating initramfs and grub..." | tee -a "$TEXT_LOG"
    sudo mkinitcpio -P | tee -a "$TEXT_LOG"
    sudo grub-mkconfig -o /boot/grub/grub.cfg | tee -a "$TEXT_LOG"
  fi
) >> "$TEXT_LOG" 2>&1

# Stop recording
echo "[INFO] Stopping recording..." | tee -a "$TEXT_LOG"
kill "$RECORD_PID"
wait "$RECORD_PID" 2>/dev/null || true

# Convert video
echo "[INFO] Converting video to GIF..." | tee -a "$TEXT_LOG"
ffmpeg -i "$VIDEO" -vf "fps=15,scale=iw/2:ih/2:flags=lanczos" "$GIF" | tee -a "$TEXT_LOG"
gifsicle -O3 -j8 "$GIF" -o "$GIF_OPT"

echo "[INFO] All operations completed. System will now $SHUTDOWN_MODE." | tee -a "$TEXT_LOG"

# Perform final action
sleep 3
sudo systemctl "$SHUTDOWN_MODE"

