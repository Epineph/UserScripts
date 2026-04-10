#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# power-timer.sh
#
# Schedule a reboot/shutdown after a countdown, with optional maintenance steps.
#
# Features:
#   - Ctrl+C override: at any time during the countdown, press Ctrl+C to execute
#     reboot/shutdown immediately (skips any "after-timer" maintenance).
#   - Optional maintenance sequence:
#       sudo new-mirrors
#       yay -Syyy
#       yay -Syyu --noconfirm
#       sudo mkinitcpio -P
#       sudo grub-mkconfig -o /boot/grub/grub.cfg
#
# Why the maintenance option exists:
#   If you intend to reboot anyway, doing a mirror refresh + full sync update and
#   then regenerating initramfs + GRUB config reduces the odds of rebooting into
#   a stale initramfs or outdated boot config after updates.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults & State
# -----------------------------------------------------------------------------
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

MAINTENANCE=0
TIMER_FIRST=0

override=0

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function usage() {
  cat <<'EOF'
Usage:
  power-timer.sh -r|-s [-H hours] [-M minutes] [-S seconds] [options]

Primary mode:
  -r, --reboot              Schedule a reboot
  -s, --shutdown            Schedule a shutdown

Delay:
  -H, --hours N             Delay in hours   (default: 0)
  -M, --minutes N           Delay in minutes (default: 0)
  -S, --seconds N           Delay in seconds (default: 0)

Notifications:
  -n, --notify              Enable desktop notifications (notify-send)
  -R, --recur N             Send recurrent notifications every N minutes
  -q, --quiet               No console chatter (implies --notify)

Maintenance (optional):
  -U, --maintenance         Run system maintenance sequence:
                              sudo new-mirrors
                              yay -Syyy
                              yay -Syyu --noconfirm
                              sudo mkinitcpio -P
                              sudo grub-mkconfig -o /boot/grub/grub.cfg
  --timer-first, --before   Run the timer first; then maintenance; then power
                            action (reboot/shutdown). Default is maintenance
                            first, then timer, then power action.

Other:
  -h, --help                Show this help and exit

Ctrl+C override:
  Press Ctrl+C during the countdown to execute reboot/shutdown immediately.

Examples:
  1) Reboot in 10 minutes:
       power-timer.sh -r -M 10

  2) Shutdown in 45 seconds (quiet + notifications):
       power-timer.sh -s -S 45 -q

  3) Reboot in 2 hours, notify every 15 minutes:
       power-timer.sh -r -H 2 -n -R 15

  4) Maintenance now, then reboot in 5 minutes:
       power-timer.sh -r -M 5 --maintenance

  5) Timer first (e.g., finish a long job), then maintenance, then reboot:
       power-timer.sh -r -H 1 --maintenance --timer-first

  6) Maintenance now, then shutdown in 20 minutes:
       power-timer.sh -s -M 20 -U
EOF
  exit 0
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

function humanize_duration() {
  local secs="$1"
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  local parts=()

  (( h > 0 )) && parts+=("$h hour$([ "$h" -ne 1 ] && echo "s")")
  (( m > 0 )) && parts+=("$m minute$([ "$m" -ne 1 ] && echo "s")")
  (( s > 0 )) && parts+=("$s second$([ "$s" -ne 1 ] && echo "s")")

  [[ ${#parts[@]} -eq 0 ]] && parts+=( "0 seconds" )
  IFS=", "
  printf '%s\n' "${parts[*]}"
}

function send_notification() {
  local title="Countdown Power"
  local message="$1"

  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "$title" "$message" || true
}

function on_override() {
  override=1
  trap - INT
}

function require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

function run_maintenance_sequence() {
  (( QUIET == 0 )) && echo "Running maintenance sequence..."
  (( NOTIFY == 1 )) && send_notification "Maintenance: starting"

  require_cmd sudo
  require_cmd yay
  require_cmd new-mirrors
  require_cmd mkinitcpio
  require_cmd grub-mkconfig

  sudo new-mirrors
  yay -Syyy
  yay -Syyu --noconfirm
  sudo mkinitcpio -P
  sudo grub-mkconfig -o /boot/grub/grub.cfg

  (( QUIET == 0 )) && echo "Maintenance sequence finished."
  (( NOTIFY == 1 )) && send_notification "Maintenance: finished"
}

function execute_power_action() {
  if [[ "$MODE" == "reboot" ]]; then
    sudo systemctl reboot
  else
    sudo systemctl poweroff
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing (short + long)
# -----------------------------------------------------------------------------
if (( $# == 0 )); then
  usage
fi

while (( $# > 0 )); do
  case "$1" in
    -r|--reboot)
      MODE="reboot"
      shift
      ;;
    -s|--shutdown)
      MODE="shutdown"
      shift
      ;;
    -H|--hours)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      HOURS="$2"
      shift 2
      ;;
    -M|--minutes)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      MINUTES="$2"
      shift 2
      ;;
    -S|--seconds)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      SECONDS="$2"
      shift 2
      ;;
    -R|--recur)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      RECURRENCE="$2"
      shift 2
      ;;
    -n|--notify)
      NOTIFY=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
      NOTIFY=1
      shift
      ;;
    -U|--maintenance)
      MAINTENANCE=1
      shift
      ;;
    --timer-first|--before)
      TIMER_FIRST=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *)
      die "Unexpected argument: $1 (try --help)"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------
[[ -n "$MODE" ]] || die "Must specify -r/--reboot or -s/--shutdown."

is_uint "$HOURS"      || die "Hours must be a non-negative integer."
is_uint "$MINUTES"    || die "Minutes must be a non-negative integer."
is_uint "$SECONDS"    || die "Seconds must be a non-negative integer."
is_uint "$RECURRENCE" || die "Recurrence must be a non-negative integer."

TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
(( TOTAL_DELAY > 0 )) || die "Total delay must be > 0."

HALF_THRESHOLD=$(( TOTAL_DELAY / 2 ))
if (( TOTAL_DELAY > 300 )); then
  LAST5_THRESHOLD=$(( TOTAL_DELAY - 300 ))
else
  LAST5_THRESHOLD=-1
fi
RECURRENCE_SEC=$(( RECURRENCE * 60 ))

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
if (( QUIET == 0 )); then
  echo "Mode: $MODE"
  echo "Delay: $(humanize_duration "$TOTAL_DELAY") ($TOTAL_DELAY seconds)"
  if (( MAINTENANCE == 1 )); then
    if (( TIMER_FIRST == 1 )); then
      echo "Maintenance: after timer (timer first)"
    else
      echo "Maintenance: before timer (default)"
    fi
  fi
fi

if (( NOTIFY == 1 )); then
  send_notification "Scheduled $MODE in $(humanize_duration "$TOTAL_DELAY")"
fi

# -----------------------------------------------------------------------------
# Optional maintenance BEFORE timer (default behavior)
# -----------------------------------------------------------------------------
if (( MAINTENANCE == 1 && TIMER_FIRST == 0 )); then
  run_maintenance_sequence
fi

# -----------------------------------------------------------------------------
# Install SIGINT trap for override
# -----------------------------------------------------------------------------
trap 'on_override' INT

# -----------------------------------------------------------------------------
# Countdown loop
# -----------------------------------------------------------------------------
remaining="$TOTAL_DELAY"
while (( remaining > 0 && override == 0 )); do
  if (( QUIET == 0 )); then
    printf "\rTime left: %02d:%02d:%02d " \
      $((remaining / 3600)) \
      $(((remaining % 3600) / 60)) \
      $((remaining % 60))
  fi

  if (( NOTIFY == 1 )); then
    if (( RECURRENCE_SEC > 0 )); then
      (( remaining % RECURRENCE_SEC == 0 )) && \
        send_notification "$MODE in $(humanize_duration "$remaining")"
    else
      (( remaining == HALF_THRESHOLD )) && \
        send_notification "Halfway: $MODE in $(humanize_duration "$remaining")"
      (( LAST5_THRESHOLD >= 0 && remaining == LAST5_THRESHOLD )) && \
        send_notification "$MODE in 5 minutes"
    fi
  fi

  sleep 1
  (( remaining-- ))
done

echo

# -----------------------------------------------------------------------------
# Finalize
# -----------------------------------------------------------------------------
require_cmd sudo
if (( override == 1 )); then
  echo "Override detected — executing $MODE immediately!"
  (( NOTIFY == 1 )) && send_notification "Override: executing $MODE now."
  execute_power_action
fi

if (( QUIET == 0 )); then
  echo "Time is up!"
fi
(( NOTIFY == 1 )) && send_notification "Time is up!"

# -----------------------------------------------------------------------------
# Optional maintenance AFTER timer (timer-first behavior)
# -----------------------------------------------------------------------------
if (( MAINTENANCE == 1 && TIMER_FIRST == 1 )); then
  run_maintenance_sequence
fi

# -----------------------------------------------------------------------------
# Execute power action
# -----------------------------------------------------------------------------
execute_power_action

