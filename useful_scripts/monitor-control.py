#!/usr/bin/env bash
############################################################################
# power-schedule
#
# Like schedule_power.sh, but now supports:
#   - Ctrl+C override: press Ctrl+C at any point to force immediate reboot/shutdown.
#
# Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [options]
# (same options as before, see usage() below)
############################################################################

# ─── Defaults & State ────────────────────────────────────────────────────────
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

override=0   # flag set when Ctrl+C (SIGINT) is caught

# ─── Helper: Usage ───────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [options]
Options:
  -r               Schedule a reboot
  -s               Schedule a shutdown
  -H hours         Delay in hours (default: 0)
  -M minutes       Delay in minutes (default: 0)
  -S seconds       Delay in seconds (default: 0)
  -n               Enable desktop notifications
  -R minutes       Send recurrent notifications every N minutes
  -q               Quiet mode (no console output; implies -n)
  -h               Show this help message and exit
EOF
  exit 1
}

# ─── Helper: Human-readable duration ──────────────────────────────────────────
humanize_duration() {
  local secs=$1
  local h=$((secs/3600))
  local m=$(((secs%3600)/60))
  local s=$((secs%60))
  local parts=()
  (( h > 0 )) && parts+=("$h hour$([ "$h" -ne 1 ] && echo "s")")
  (( m > 0 )) && parts+=("$m minute$([ "$m" -ne 1 ] && echo "s")")
  (( s > 0 )) && parts+=("$s second$([ "$s" -ne 1 ] && echo "s")")
  [[ ${#parts[@]} -eq 0 ]] && parts+=( "0 seconds" )
  IFS=", " ; echo "${parts[*]}"
}

# ─── Helper: Send desktop notification (if installed) ────────────────────────
send_notification() {
  local title="Countdown Power"
  local message="$1"
  command -v notify-send &>/dev/null && notify-send "$title" "$message"
}

# ─── Signal-trap Handler ─────────────────────────────────────────────────────
# Called on SIGINT (Ctrl+C).  Sets override flag and jumps out of the loop.
on_override() {
  override=1
  # remove the trap so we don't re-enter if another SIGINT arrives
  trap - INT
}

# ─── Parse options ───────────────────────────────────────────────────────────
while getopts "rsH:M:S:R:nqh" opt; do
  case "$opt" in
    r) MODE="reboot"   ;;
    s) MODE="shutdown" ;;
    H) HOURS=$OPTARG   ;;
    M) MINUTES=$OPTARG ;;
    S) SECONDS=$OPTARG ;;
    R) RECURRENCE=$OPTARG ;;
    n) NOTIFY=1        ;;
    q) QUIET=1; NOTIFY=1 ;;
    h|*) usage         ;;
  esac
done

# ─── Validate inputs ─────────────────────────────────────────────────────────
[[ -z "$MODE" ]] && echo "Error: must specify -r or -s." >&2 && usage
for var in HOURS MINUTES SECONDS RECURRENCE; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || { 
    echo "Error: $var must be a non-negative integer." >&2
    usage
  }
done

TOTAL_DELAY=$(( HOURS*3600 + MINUTES*60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || {
  echo "Error: total delay must be > 0." >&2
  usage
}

HALF_THRESHOLD=$(( TOTAL_DELAY/2 ))
(( TOTAL_DELAY > 300 )) && LAST5_THRESHOLD=$(( TOTAL_DELAY - 300 )) || LAST5_THRESHOLD=-1
RECURRENCE_SEC=$(( RECURRENCE * 60 ))

# ─── Summary ─────────────────────────────────────────────────────────────────
(( QUIET == 0 )) && \
  echo "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY) (Total: $TOTAL_DELAY seconds)."
(( NOTIFY == 1 )) && \
  send_notification "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY)"

# ─── Install SIGINT trap for override ────────────────────────────────────────
trap 'on_override' INT

# ─── Countdown Loop ─────────────────────────────────────────────────────────
remaining=$TOTAL_DELAY
while (( remaining > 0 && override == 0 )); do
  # on-screen timer
  if (( QUIET == 0 )); then
    printf "\rTime left: %02d:%02d:%02d " \
      $((remaining/3600)) \
      $(((remaining%3600)/60)) \
      $((remaining%60))
  fi

  # notifications
  if (( NOTIFY == 1 )); then
    if (( RECURRENCE_SEC > 0 )); then
      (( remaining % RECURRENCE_SEC == 0 )) && \
        send_notification "$MODE in $(humanize_duration $remaining)"
    else
      (( remaining == HALF_THRESHOLD )) && \
        send_notification "Halfway there: $MODE in $(humanize_duration $remaining)"
      (( LAST5_THRESHOLD >= 0 && remaining == LAST5_THRESHOLD )) && \
        send_notification "$MODE in 5 minutes"
    fi
  fi

  sleep 1
  (( remaining-- ))
done

# ─── Finalize ────────────────────────────────────────────────────────────────
echo
if (( override == 1 )); then
  # User pressed Ctrl+C
  echo "Override detected—executing $MODE immediately!"
  (( NOTIFY == 1 )) && send_notification "Override: executing $MODE now."
else
  # Countdown naturally expired
  (( QUIET == 0 )) && echo "Time is up! Executing $MODE now..."
  (( NOTIFY == 1 )) && send_notification "Time is up! Executing $MODE now."
fi

# ─── Execute ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "reboot" ]]; then
  sudo systemctl reboot
else
  sudo systemctl poweroff
fi

