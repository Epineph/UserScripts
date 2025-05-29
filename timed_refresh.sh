#!/usr/bin/env bash
############################################################################
# monitor-control
#
# Enhanced power scheduling script with optional system refresh and reconfiguration
# Supports:
#   - Ctrl+C override: press Ctrl+C at any point to force immediate reboot/shutdown.
#   - Optional refresh (-u): before final action, update mirrorlist, packages,
#     rebuild initramfs, and regenerate GRUB configuration, then a final 5-minute countdown.
#
# Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [-u] [options]
############################################################################

# ─── Defaults & State ─────────────────────────────────────────────────────
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
REFRESH=0      # flag: perform system refresh before final countdown
override=0     # set when Ctrl+C caught

# ─── Helper: Usage ────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds] [-u] [options]
Options:
  -r               Schedule a reboot
  -s               Schedule a shutdown
  -H hours         Delay in hours (default: 0)
  -M minutes       Delay in minutes (default: 0)
  -S seconds       Delay in seconds (default: 0)
  -u               Refresh system: update mirrors, packages, initramfs, GRUB before final 5-min countdown
  -n               Enable desktop notifications
  -R minutes       Send recurrent notifications every N minutes
  -q               Quiet mode (no console output; implies -n)
  -h               Show this help message and exit
EOF
  exit 1
}

# ─── Helper: Human-readable duration ──────────────────────────────────────
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

# ─── Helper: Send desktop notification ────────────────────────────────────
send_notification() {
  local title="Countdown Power"
  local message="$1"
  command -v notify-send &>/dev/null && notify-send "$title" "$message"
}

# ─── Signal-trap Handler ──────────────────────────────────────────────────
on_override() {
  override=1
  trap - INT
}

# ─── Parse options ───────────────────────────────────────────────────────
while getopts "rsH:M:S:R:nuqh" opt; do
  case "$opt" in
    r) MODE="reboot"    ;;
    s) MODE="shutdown"  ;;
    H) HOURS=$OPTARG     ;;
    M) MINUTES=$OPTARG   ;;
    S) SECONDS=$OPTARG   ;;
    R) RECURRENCE=$OPTARG;;
    n) NOTIFY=1          ;;
    q) QUIET=1; NOTIFY=1 ;;
    u) REFRESH=1         ;;
    h|*) usage           ;;
  esac
done

# ─── Validate inputs ─────────────────────────────────────────────────────
[[ -z "$MODE" ]] && echo "Error: must specify -r or -s." >&2 && usage
for var in HOURS MINUTES SECONDS RECURRENCE; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || { echo "Error: $var must be a non-negative integer." >&2; usage; }
done

TOTAL_DELAY=$(( HOURS*3600 + MINUTES*60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || { echo "Error: total delay must be > 0." >&2; usage; }

HALF_THRESHOLD=$(( TOTAL_DELAY/2 ))
(( TOTAL_DELAY > 300 )) && LAST5_THRESHOLD=$(( TOTAL_DELAY - 300 )) || LAST5_THRESHOLD=-1
RECURRENCE_SEC=$(( RECURRENCE * 60 ))

# ─── Summary ─────────────────────────────────────────────────────────────
(( QUIET == 0 )) && echo "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY) (Total: $TOTAL_DELAY seconds)."
(( NOTIFY == 1 )) && send_notification "Scheduled $MODE in $(humanize_duration $TOTAL_DELAY)"

# ─── Install SIGINT trap for override ─────────────────────────────────────
trap 'on_override' INT

# ─── Countdown Loop ───────────────────────────────────────────────────────
remaining=$TOTAL_DELAY
while (( remaining > 0 && override == 0 )); do
  if (( QUIET == 0 )); then
    printf "\rTime left: %02d:%02d:%02d " $((remaining/3600)) $(((remaining%3600)/60)) $((remaining%60))
  fi
  if (( NOTIFY == 1 )); then
    if (( RECURRENCE_SEC > 0 )); then
      (( remaining % RECURRENCE_SEC == 0 )) && send_notification "$MODE in $(humanize_duration $remaining)"
    else
      (( remaining == HALF_THRESHOLD )) && send_notification "Halfway there: $MODE in $(humanize_duration $remaining)"
      (( LAST5_THRESHOLD >= 0 && remaining == LAST5_THRESHOLD )) && send_notification "$MODE in 5 minutes"
    fi
  fi
  sleep 1
  (( remaining-- ))
done

echo
# ─── Finalize ─────────────────────────────────────────────────────────────
if (( override == 1 )); then
  # Immediate override
  echo "Override detected—executing $MODE immediately!"
  (( NOTIFY == 1 )) && send_notification "Override: executing $MODE now."
  sudo systemctl ${MODE}
  exit
fi

# ─── Optional System Refresh ──────────────────────────────────────────────
perform_refresh() {
  echo "Performing system refresh and configuration..."
  # Define preferred mirror countries
  local countries=(Denmark Germany France Netherlands Sweden Norway Finland Austria Belgium Switzerland United Kingdom Russia Ukraine )
  local countries_list
  countries_list=$(IFS=,; echo "${countries[*]}")

  # Update mirrorlist
  sudo reflector --verbose --country $countries_list --age 12 --latest 400 --fastest 400 \
    --cache-timeout 1600 --download-timeout 5 --connection-timeout 5 \
    --sort rate --protocol https,http --threads 7 --save /etc/pacman.d/mirrorlist && \
  echo "Mirrorlist updated successfully"

  # Synchronize and upgrade packages
  yay -Syy
  yay -Syyu --noconfirm

  # Rebuild initramfs images
  sudo mkinitcpio -P

  # Regenerate GRUB configuration
  sudo grub-mkconfig -o /boot/grub/grub.cfg && \
  echo "GRUB configuration regenerated successfully"

  echo "System refresh complete."
}

# ─── Floor and Countdown for Final Delay ──────────────────────────────────
Floor() {
  local dividend=$1 divisor=$2
  echo $(( (dividend - dividend % divisor) / divisor ))
}

Timecount() {
  local total=$1
  # Compute hours, minutes, seconds
  local h=$(Floor $total 3600)
  local rem=$(( total - h * 3600 ))
  local m=$(Floor $rem 60)
  local s=$(( rem - m * 60 ))

  for (( ; h>=0; h-- )); do
    for (( ; m>=0; m-- )); do
      for (( ; s>=0; s-- )); do
        printf "Final countdown: %02d:%02d:%02d\r" $h $m $s
        sleep 1
      done
      s=59
    done
    m=59
  done
  echo
}

# ─── Execute Refresh Flow or Final Action ─────────────────────────────────
if (( REFRESH == 1 )); then
  perform_refresh
  echo "Starting final 5-minute countdown before $MODE..."
  (( NOTIFY == 1 )) && send_notification "Final 5-minute countdown for $MODE started"
  Timecount 300
  echo "Time is up! Executing $MODE now..."
  (( NOTIFY == 1 )) && send_notification "Executing $MODE now"
  sudo systemctl ${MODE}
else
  # Natural expiration without refresh
  echo "Time is up! Executing $MODE now..."
  (( NOTIFY == 1 )) && send_notification "Time is up! Executing $MODE now"
  sudo systemctl ${MODE}
fi

