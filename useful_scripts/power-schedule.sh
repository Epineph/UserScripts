#!/usr/bin/env bash
############################################################################
# schedule_power.sh
#
# This script displays a live countdown timer and then performs a power
# operation (reboot or shutdown). It supports:
#   - Countdown display
#   - Optional quiet mode (no console output)
#   - Desktop notifications at key intervals or recurrently
#   - Notifications at 50% elapsed and 5 minutes remaining (default)
#   - Recurrent notifications every N minutes
#
# Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [options]
#
# Options:
#   -r                 Reboot after countdown
#   -s                 Shutdown after countdown
#   -H hours           Delay in hours (default: 0)
#   -M minutes         Delay in minutes (default: 0)
#   -S seconds         Delay in seconds (default: 0)
#   -n                 Enable desktop notifications (default thresholds)
#   -R minutes         Recurrent notifications every N minutes
#   -q                 Quiet mode (no console output; implies -n)
#   -h                 Show this help message and exit
#
# Examples:
#   $(basename "$0") -r -H 1 -M 30 -S 0
#       Reboot after 1h30 countdown, console countdown only
#   $(basename "$0") -s -M 10 -n
#       Shutdown after 10m, notifications at 5m remaining and halfway
#   $(basename "$0") -r -M 60 -R 15 -q
#       Reboot after 1h, notifications every 15m, no console output
############################################################################

default_hours=0
default_minutes=0
default_seconds=0
MODE=""
HOURS=$default_hours
MINUTES=$default_minutes
SECONDS=$default_seconds
NOTIFY=0
QUIET=0
RECURRENCE=0

# Print usage and exit
usage() {
  cat <<EOF
Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [options]
Options:
  -r               Reboot after countdown
  -s               Shutdown after countdown
  -H hours         Delay in hours (default: 0)
  -M minutes       Delay in minutes (default: 0)
  -S seconds       Delay in seconds (default: 0)
  -n               Enable desktop notifications at 50% and 5m remaining
  -R minutes       Recurrent notifications every N minutes
  -q               Quiet mode (no console output; implies -n)
  -h               Show this help message and exit
EOF
  exit 1
}

# Human-readable duration
humanize_duration() {
  local secs=$1
  local h=$((secs/3600))
  local m=$(((secs%3600)/60))
  local s=$((secs%60))
  local parts=()
  (( h > 0 )) && parts+=("$h hour$([ "$h" -ne 1 ] && echo "s")")
  (( m > 0 )) && parts+=("$m minute$([ "$m" -ne 1 ] && echo "s")")
  (( s > 0 )) && parts+=("$s second$([ "$s" -ne 1 ] && echo "s")")
  [[ ${#parts[@]} -eq 0 ]] && parts+=("0 seconds")
  IFS=", "; echo "\${parts[*]}"
}

# Send a desktop notification
send_notification() {
  local title="Countdown Power"
  local message="$1"
  command -v notify-send >/dev/null 2>&1 && \
    notify-send "$title" "$message"
}

# Parse options
while getopts "rsH:M:S:R:nqh" opt; do
  case "$opt" in
    r)
      MODE="reboot";;
    s)
      MODE="shutdown";;
    H)
      HOURS=$OPTARG;;
    M)
      MINUTES=$OPTARG;;
    S)
      SECONDS=$OPTARG;;
    R)
      RECURRENCE=$OPTARG;;
    n)
      NOTIFY=1;;
    q)
      QUIET=1; NOTIFY=1;;
    h|*)
      usage;;
  esac
done

# Validate mode
[[ -z "$MODE" ]] && echo "Error: must specify -r or -s." >&2 && usage
# Validate numeric args
for var in HOURS MINUTES SECONDS RECURRENCE; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || { echo "Error: $var must be a non-negative integer." >&2; usage; }
done

# Calculate total delay
TOTAL_DELAY=$(( HOURS*3600 + MINUTES*60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || { echo "Error: total delay must be > 0." >&2; usage; }

# Precompute thresholds
HALF_THRESHOLD=$(( TOTAL_DELAY/2 ))
(( TOTAL_DELAY > 300 )) && LAST5_THRESHOLD=$(( TOTAL_DELAY - 300 )) || LAST5_THRESHOLD=-1
RECURRENCE_SEC=$(( RECURRENCE * 60 ))

# Summary
if (( QUIET == 0 )); then
  echo "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY) (Total: $TOTAL_DELAY seconds)."
fi
if (( NOTIFY == 1 )); then
  send_notification "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY)"
fi

# Countdown loop
remaining=$TOTAL_DELAY
previous_notified=()
while (( remaining > 0 )); do
  # Display countdown
  if (( QUIET == 0 )); then
    printf "\rTime left: %02d:%02d:%02d " \
      $((remaining/3600)) \
      $(((remaining%3600)/60)) \
      $((remaining%60))
  fi

  # Check notifications
  if (( NOTIFY == 1 )); then
    # Recurrent notifications
    if (( RECURRENCE_SEC > 0 )); then
      if (( remaining % RECURRENCE_SEC == 0 )); then
        send_notification "$MODE in \$(humanize_duration $remaining)"
      fi
    else
      # Default notifications: half-time
      if (( remaining == HALF_THRESHOLD )); then
        send_notification "Halfway there: $MODE in \$(humanize_duration $remaining)"
      fi
      # 5-minute warning
      if (( LAST5_THRESHOLD >= 0 && remaining == LAST5_THRESHOLD )); then
        send_notification "$MODE in 5 minutes"
      fi
    fi
  fi

  sleep 1
  (( remaining-- ))
done

echo
# Final message
if (( QUIET == 0 )); then
  echo "Time is up! Executing $MODE now..."
fi
if (( NOTIFY == 1 )); then
  send_notification "Time is up! Executing $MODE now."
fi

# Execute the action
if [[ "$MODE" == "reboot" ]]; then
  sudo systemctl reboot
else
  sudo systemctl poweroff
fi

