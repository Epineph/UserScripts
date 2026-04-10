#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# power-timer.sh
#
# Schedule a reboot or shutdown after a countdown, optionally with a system
# maintenance sequence before or after the timer.
#
# Key behavior:
#   - Ctrl+C during the countdown triggers the power action immediately.
#   - Maintenance failures are reported explicitly.
#   - After a maintenance failure, the user is prompted whether to continue,
#     unless --no-prompt or --noconfirm is used.
# -----------------------------------------------------------------------------

set -uo pipefail

# -----------------------------------------------------------------------------
# Defaults & State
# -----------------------------------------------------------------------------
PROG_NAME="${0##*/}"

MODE=""
HOURS=0
MINUTES=0
SECONDS=0

NOTIFY=0
QUIET=0
RECURRENCE=0

MAINTENANCE=0
TIMER_FIRST=0
NO_PROMPT=0
LATEX_FMT=0

OVERRIDE=0
MAINTENANCE_HAD_ERRORS=0

# -----------------------------------------------------------------------------
# Help
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
  -R, --recur N             Notify every N minutes during countdown
  -q, --quiet               Suppress normal console output; implies --notify

Maintenance:
  -U, --maintenance         Run maintenance sequence:
                              mirror refresh command (auto-detected)
                              yay -Syyy
                              yay -Syyu --noconfirm
                              [optional] fmtutil-user --all
                              [optional] sudo fmtutil-sys --all
                              sudo mkinitcpio -P
                              sudo grub-mkconfig -o /boot/grub/grub.cfg
  --latex-fmt               Valid only with --maintenance. Rebuild TeX formats
                            after upgrades and before mkinitcpio/GRUB.
  --timer-first, --before   Run timer first, then maintenance, then power
                            action. Default is maintenance first.

Failure handling:
  --no-prompt               Continue automatically after maintenance errors
  --noconfirm               Same as --no-prompt

Other:
  -h, --help                Show this help and exit

Ctrl+C override:
  Press Ctrl+C during the countdown to execute reboot/shutdown immediately.
  This skips any maintenance that would otherwise run after the timer.

Notes:
  Maintenance errors often indicate package conflicts, hook failures, or a
  broken /etc/default/grub or custom GRUB script. Investigate before rebooting
  if possible.

Examples:
  1) Reboot in 10 minutes:
       power-timer.sh -r -M 10

  2) Shutdown in 45 seconds, quiet mode:
       power-timer.sh -s -S 45 -q

  3) Reboot in 2 hours, recurring notifications every 15 minutes:
       power-timer.sh -r -H 2 -n -R 15

  4) Run maintenance now, then reboot in 5 minutes:
       power-timer.sh -r -M 5 --maintenance

  5) Timer first, then maintenance, then reboot:
       power-timer.sh -r -H 1 --maintenance --timer-first

  6) Continue automatically even if maintenance fails:
       power-timer.sh -r -M 20 --maintenance --noconfirm

  7) Include TeX format rebuild during maintenance:
       power-timer.sh -r -M 30 --maintenance --latex-fmt
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Messaging helpers
# -----------------------------------------------------------------------------
function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function info() {
  (( QUIET == 0 )) && printf '%s\n' "$*"
}

function send_notification() {
  local message="${1:-}"

  (( NOTIFY == 1 )) || return 0
  command -v notify-send >/dev/null 2>&1 || return 0

  notify-send "power-timer" "$message" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------
function is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

function require_cmd() {
  local cmd="${1:?}"

  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

function humanize_duration() {
  local total_secs="${1:?}"
  local hours=$(( total_secs / 3600 ))
  local minutes=$(( (total_secs % 3600) / 60 ))
  local seconds=$(( total_secs % 60 ))
  local -a parts=()
  local IFS=', '

  if (( hours == 1 )); then
    parts+=("1 hour")
  elif (( hours > 1 )); then
    parts+=("${hours} hours")
  fi

  if (( minutes == 1 )); then
    parts+=("1 minute")
  elif (( minutes > 1 )); then
    parts+=("${minutes} minutes")
  fi

  if (( seconds == 1 )); then
    parts+=("1 second")
  elif (( seconds > 1 )); then
    parts+=("${seconds} seconds")
  fi

  if (( ${#parts[@]} == 0 )); then
    parts+=("0 seconds")
  fi

  printf '%s\n' "${parts[*]}"
}

function select_mirror_cmd() {
  local candidate

  for candidate in generate-mirrorlist generate-mirrors new-mirrors; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

function prompt_yes_no() {
  local prompt="${1:?}"
  local reply=""

  (( NO_PROMPT == 0 )) || return 0

  while true; do
    printf '%s [y/N]: ' "$prompt" >&2

    if [[ -r /dev/tty ]]; then
      IFS= read -r reply < /dev/tty || return 1
    else
      IFS= read -r reply || return 1
    fi

    case "${reply,,}" in
      y | yes)
        return 0
        ;;
      n | no | '')
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Control helpers
# -----------------------------------------------------------------------------
function on_override() {
  OVERRIDE=1
  trap - INT
}

function execute_power_action() {
  require_cmd sudo
  require_cmd systemctl

  if [[ "$MODE" == "reboot" ]]; then
    sudo systemctl reboot
  else
    sudo systemctl poweroff
  fi
}

# -----------------------------------------------------------------------------
# Maintenance
# -----------------------------------------------------------------------------
function handle_maintenance_failure() {
  local step="${1:?}"
  local exit_code="${2:?}"
  local command_display="${3:?}"

  MAINTENANCE_HAD_ERRORS=1

  warn "Maintenance step failed: ${step} (exit code ${exit_code})."
  warn "Command: ${command_display}"
  warn "Investigate the issue before rebooting if possible."
  warn "Common causes include package conflicts, failed hooks,"
  warn "or an invalid /etc/default/grub or custom GRUB script."

  send_notification "Maintenance failed: ${step}"

  if (( NO_PROMPT == 1 )); then
    warn "--no-prompt/--noconfirm was set. Continuing anyway."
    return 0
  fi

  if prompt_yes_no "Continue anyway?"; then
    warn "Continuing despite maintenance failure."
    return 0
  fi

  die "Aborted after maintenance failure."
}

function run_step() {
  local step="${1:?}"
  shift

  local -a cmd=( "$@" )
  local command_display=""
  local exit_code=0

  printf -v command_display '%q ' "${cmd[@]}"

  info "Running: ${step}"
  if "${cmd[@]}"; then
    info "Done: ${step}"
    return 0
  fi

  exit_code=$?
  handle_maintenance_failure "$step" "$exit_code" "$command_display"
}

function run_maintenance_sequence() {
  local mirror_cmd=""

  info "Running maintenance sequence..."
  send_notification "Maintenance: starting"

  require_cmd sudo
  require_cmd yay
  require_cmd mkinitcpio
  require_cmd grub-mkconfig

  mirror_cmd="$(select_mirror_cmd)" || die \
    "No mirror refresh command found. Tried: generate-mirrorlist, " \
    "generate-mirrors, new-mirrors."

  run_step "Refresh mirror list via ${mirror_cmd}" sudo "$mirror_cmd"
  run_step "Force package database refresh" yay -Syyy
  run_step "Full system upgrade" yay -Syyu --noconfirm

  if (( LATEX_FMT == 1 )); then
    require_cmd fmtutil-user
    require_cmd fmtutil-sys

    run_step "Rebuild user TeX formats" fmtutil-user --all
    run_step "Rebuild system TeX formats" sudo fmtutil-sys --all
  fi

  run_step "Regenerate initramfs" sudo mkinitcpio -P
  run_step "Rebuild GRUB config" \
    sudo grub-mkconfig -o /boot/grub/grub.cfg

  if (( MAINTENANCE_HAD_ERRORS == 0 )); then
    info "Maintenance sequence finished successfully."
    send_notification "Maintenance: finished successfully"
  else
    warn "Maintenance sequence finished with one or more errors."
    send_notification "Maintenance: finished with errors"
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
if (( $# == 0 )); then
  usage
fi

while (( $# > 0 )); do
  case "$1" in
    -r | --reboot)
      [[ -z "$MODE" || "$MODE" == "reboot" ]] || \
        die "Choose either reboot or shutdown, not both."
      MODE="reboot"
      shift
      ;;
    -s | --shutdown)
      [[ -z "$MODE" || "$MODE" == "shutdown" ]] || \
        die "Choose either reboot or shutdown, not both."
      MODE="shutdown"
      shift
      ;;
    -H | --hours)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      HOURS="$2"
      shift 2
      ;;
    -M | --minutes)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      MINUTES="$2"
      shift 2
      ;;
    -S | --seconds)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      SECONDS="$2"
      shift 2
      ;;
    -R | --recur)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      RECURRENCE="$2"
      shift 2
      ;;
    -n | --notify)
      NOTIFY=1
      shift
      ;;
    -q | --quiet)
      QUIET=1
      NOTIFY=1
      shift
      ;;
    -U | --maintenance)
      MAINTENANCE=1
      shift
      ;;
    --latex-fmt)
      LATEX_FMT=1
      shift
      ;;
    --timer-first | --before)
      TIMER_FIRST=1
      shift
      ;;
    --no-prompt | --noconfirm)
      NO_PROMPT=1
      shift
      ;;
    -h | --help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      die "Unexpected argument: $1"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------
[[ -n "$MODE" ]] || die "Must specify -r/--reboot or -s/--shutdown."

is_uint "$HOURS" || die "Hours must be a non-negative integer."
is_uint "$MINUTES" || die "Minutes must be a non-negative integer."
is_uint "$SECONDS" || die "Seconds must be a non-negative integer."
is_uint "$RECURRENCE" || die "Recurrence must be a non-negative integer."

(( LATEX_FMT == 0 || MAINTENANCE == 1 )) || \
  die "--latex-fmt is only valid together with --maintenance."

TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
RECURRENCE_SEC=$(( RECURRENCE * 60 ))

(( TOTAL_DELAY > 0 )) || die "Total delay must be greater than 0."

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
info "Mode: ${MODE}"
info "Delay: $(humanize_duration "$TOTAL_DELAY") (${TOTAL_DELAY} seconds)"

if (( MAINTENANCE == 1 )); then
  if (( TIMER_FIRST == 1 )); then
    info "Maintenance: after timer"
  else
    info "Maintenance: before timer"
  fi

  if (( LATEX_FMT == 1 )); then
    info "LaTeX fmt rebuild: enabled"
  fi
fi

if (( NO_PROMPT == 1 )); then
  info "Failure handling: continue automatically after maintenance errors"
else
  info "Failure handling: prompt after maintenance errors"
fi

send_notification "Scheduled ${MODE} in $(humanize_duration "$TOTAL_DELAY")"

# -----------------------------------------------------------------------------
# Optional maintenance before timer
# -----------------------------------------------------------------------------
if (( MAINTENANCE == 1 && TIMER_FIRST == 0 )); then
  run_maintenance_sequence
fi

# -----------------------------------------------------------------------------
# Countdown
# -----------------------------------------------------------------------------
trap 'on_override' INT

remaining=$TOTAL_DELAY
while (( remaining > 0 && OVERRIDE == 0 )); do
  if (( QUIET == 0 )); then
    printf '\rTime left: %02d:%02d:%02d ' \
      $(( remaining / 3600 )) \
      $(( (remaining % 3600) / 60 )) \
      $(( remaining % 60 ))
  fi

  if (( NOTIFY == 1 )); then
    if (( RECURRENCE_SEC > 0 )); then
      if (( remaining != TOTAL_DELAY && remaining % RECURRENCE_SEC == 0 )); then
        send_notification "${MODE} in $(humanize_duration "$remaining")"
      fi
    else
      if (( remaining == TOTAL_DELAY / 2 && TOTAL_DELAY >= 2 )); then
        send_notification \
          "Halfway: ${MODE} in $(humanize_duration "$remaining")"
      fi

      if (( remaining == 300 && TOTAL_DELAY > 300 )); then
        send_notification "${MODE} in 5 minutes"
      fi
    fi
  fi

  sleep 1
  (( remaining-- ))
done

if (( QUIET == 0 )); then
  printf '\n'
fi

# -----------------------------------------------------------------------------
# Finalization
# -----------------------------------------------------------------------------
if (( OVERRIDE == 1 )); then
  info "Override detected. Executing ${MODE} immediately."
  send_notification "Override: executing ${MODE} now"
  execute_power_action
fi

info "Time is up."
send_notification "Time is up: executing ${MODE}"

# -----------------------------------------------------------------------------
# Optional maintenance after timer
# -----------------------------------------------------------------------------
if (( MAINTENANCE == 1 && TIMER_FIRST == 1 )); then
  run_maintenance_sequence
fi

# -----------------------------------------------------------------------------
# Execute power action
# -----------------------------------------------------------------------------
execute_power_action
