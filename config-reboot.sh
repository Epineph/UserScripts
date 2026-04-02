#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

#===============================================================================
# maintenance-reboot
#
# Execute a fixed maintenance/update sequence immediately, or schedule it to
# start later. If the maintenance succeeds, a reboot is scheduled 90 seconds
# later unless --no-reboot is supplied.
#
# Design:
#   - A delayed start is handled by a transient systemd timer/service pair.
#   - A delayed reboot is handled by a second transient timer/service pair.
#   - Notifications are handled by separate transient services so they survive
#     after the caller exits and can be cancelled cleanly.
#   - The script itself should be started as a normal user. Root execution is
#     reserved for internal transient-service entrypoints.
#===============================================================================

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

readonly UNIT_BASE="maintenance-reboot"
readonly RUN_UNIT_BASE="${UNIT_BASE}-run"
readonly REBOOT_UNIT_BASE="${UNIT_BASE}-reboot"
readonly START_NOTIFY_UNIT_BASE="${UNIT_BASE}-start-notify"
readonly REBOOT_NOTIFY_UNIT_BASE="${UNIT_BASE}-reboot-notify"

readonly RUN_SERVICE_UNIT="${RUN_UNIT_BASE}.service"
readonly RUN_TIMER_UNIT="${RUN_UNIT_BASE}.timer"
readonly REBOOT_SERVICE_UNIT="${REBOOT_UNIT_BASE}.service"
readonly REBOOT_TIMER_UNIT="${REBOOT_UNIT_BASE}.timer"
readonly START_NOTIFY_SERVICE_UNIT="${START_NOTIFY_UNIT_BASE}.service"
readonly REBOOT_NOTIFY_SERVICE_UNIT="${REBOOT_NOTIFY_UNIT_BASE}.service"

readonly REBOOT_COUNTDOWN_SECONDS=90
readonly HYPR_NOTIFY_MS=15000

RUN_AS_USER=""
RUN_AS_UID=""
RUN_AS_GID=""
RUN_AS_HOME=""
SESSION_XDG_RUNTIME_DIR=""
SESSION_WAYLAND_DISPLAY=""
SESSION_HYPRLAND_INSTANCE_SIGNATURE=""
SESSION_DBUS_SESSION_BUS_ADDRESS=""
SESSION_DISPLAY=""

OPT_CLEAN=0
OPT_QUIET=0
OPT_SILENCE_START=0
OPT_NO_REBOOT=0
OPT_VERBOSE=0
OPT_START_MODE="now"
OPT_START_SPEC=""

#-------------------------------------------------------------------------------
# help
#-------------------------------------------------------------------------------
function show_help() {
  cat <<'EOF'
maintenance-reboot

Execute a fixed maintenance sequence immediately, or schedule it to start
later. If the maintenance succeeds, a reboot is scheduled 90 seconds later
unless --no-reboot is supplied.

USAGE
  maintenance-reboot run [options]
  maintenance-reboot cancel
  maintenance-reboot stop --force
  maintenance-reboot now
  maintenance-reboot status
  maintenance-reboot --help
  maintenance-reboot -h

RUN OPTIONS
  --clean
      Remove orphan packages and trim package caches after the update.

  --in DURATION
      Start after a relative delay.
      Accepted forms include combinations of h, m and s:
        90s
        15m
        1h30m
        2h 5m 10s

  --at TIME
      Start at an absolute time.
      Accepted forms:
        HH:MM
        HH:MM:SS
        YYYY-MM-DD HH:MM
        YYYY-MM-DD HH:MM:SS
        YYYY-MM-DDTHH:MM
        YYYY-MM-DDTHH:MM:SS
        now

      For time-only input such as 23:15, today is used if the time is still in
      the future. Otherwise, tomorrow is used.

  --quiet
      Suppress all notifications.

  --silence-start
      Suppress all notifications before the maintenance actually begins.
      This does not suppress "maintenance started" or reboot-phase messages.

  --no-reboot
      Do not schedule the post-maintenance reboot.

  -v, --verbose
      Print more scheduling detail.

BEHAVIOUR
  The maintenance sequence is:

    sudo generate-mirrorlist
    yay -Syyu --noconfirm
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo mkinitcpio -P
    sudo grub-mkconfig -o /boot/grub/grub.cfg

  If --clean is supplied, the script additionally:

    - trims old package cache entries
    - removes cached packages no longer installed
    - removes orphan packages

  If maintenance succeeds and --no-reboot was not supplied, reboot is scheduled
  for 90 seconds later. That reboot can be cancelled with:

    maintenance-reboot cancel

SUBCOMMANDS
  cancel
      Cancel a pending scheduled start and/or a pending reboot.
      It does not stop maintenance already in progress.

  stop --force
      Force-stop maintenance already in progress.
      This is dangerous and may leave the system in an inconsistent state.

  now
      Execute a pending reboot immediately.

IMPORTANT
  Do not run this script itself with sudo.
  yay must run as your normal user.

EXAMPLES
  maintenance-reboot run
  maintenance-reboot run --clean
  maintenance-reboot run --in 45m
  maintenance-reboot run --in '1h 20m 15s'
  maintenance-reboot run --at 23:15
  maintenance-reboot run --at '2026-04-02 23:15:00'
  maintenance-reboot run --at now --no-reboot
  maintenance-reboot cancel
  maintenance-reboot stop --force
  maintenance-reboot now
  maintenance-reboot status
EOF
}

#-------------------------------------------------------------------------------
# utility
#-------------------------------------------------------------------------------
function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function info() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function ensure_not_root() {
  if ((EUID == 0)); then
    die "run this script as your normal user, not as root"
  fi
}

function systemctl_cmd() {
  if ((EUID == 0)); then
    systemctl "$@"
  else
    sudo systemctl "$@"
  fi
}

function systemd_run_cmd() {
  if ((EUID == 0)); then
    systemd-run "$@"
  else
    sudo systemd-run "$@"
  fi
}

function run_cmd() {
  printf '>>> %s\n' "$*"
  "$@"
}

function run_root_cmd() {
  if ((EUID == 0)); then
    run_cmd "$@"
  else
    run_cmd sudo "$@"
  fi
}

function run_as_invoking_user_cmd() {
  if ((EUID == 0)); then
    [[ -n "${RUN_AS_USER}" ]] || die "RUN_AS_USER is not set"
    [[ -n "${RUN_AS_HOME}" ]] || die "RUN_AS_HOME is not set"

    printf '>>> as %s: %s\n' "${RUN_AS_USER}" "$*"
    sudo -u "${RUN_AS_USER}" \
      env \
      HOME="${RUN_AS_HOME}" \
      USER="${RUN_AS_USER}" \
      LOGNAME="${RUN_AS_USER}" \
      PATH="${PATH}" \
      "$@"
  else
    run_cmd "$@"
  fi
}

function capture_user_context() {
  RUN_AS_USER="$(id -un)"
  RUN_AS_UID="$(id -u)"
  RUN_AS_GID="$(id -g)"
  RUN_AS_HOME="${HOME}"

  SESSION_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${RUN_AS_UID}}"
  SESSION_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
  SESSION_HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  SESSION_DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
  SESSION_DISPLAY="${DISPLAY:-}"
}

function ensure_root_context_is_complete() {
  [[ -n "${RUN_AS_USER}" ]] || die "RUN_AS_USER is not set"
  [[ -n "${RUN_AS_UID}" ]] || die "RUN_AS_UID is not set"
  [[ -n "${RUN_AS_GID}" ]] || die "RUN_AS_GID is not set"
  [[ -n "${RUN_AS_HOME}" ]] || die "RUN_AS_HOME is not set"
}

function append_context_env_args() {
  local -n out_ref="$1"
  local vars=(
    RUN_AS_USER
    RUN_AS_UID
    RUN_AS_GID
    RUN_AS_HOME
    SESSION_XDG_RUNTIME_DIR
    SESSION_WAYLAND_DISPLAY
    SESSION_HYPRLAND_INSTANCE_SIGNATURE
    SESSION_DBUS_SESSION_BUS_ADDRESS
    SESSION_DISPLAY
    PATH
  )
  local var

  for var in "${vars[@]}"; do
    out_ref+=("--setenv=${var}=${!var-}")
  done
}

function unit_is_active() {
  systemctl_cmd is-active --quiet "$1"
}

function unit_is_failed() {
  systemctl_cmd is-failed --quiet "$1"
}

function unit_state() {
  local unit="$1"
  local load_state=""

  if unit_is_active "${unit}"; then
    printf 'active\n'
    return 0
  fi

  if unit_is_failed "${unit}"; then
    printf 'failed\n'
    return 0
  fi

  load_state="$(systemctl_cmd show --property=LoadState --value "${unit}" \
    2>/dev/null || true)"

  if [[ "${load_state}" == "not-found" || -z "${load_state}" ]]; then
    printf 'not-found\n'
  else
    printf 'inactive\n'
  fi
}

function reset_failed_units() {
  local unit

  for unit in "$@"; do
    systemctl_cmd stop "${unit}" >/dev/null 2>&1 || true
    systemctl_cmd reset-failed "${unit}" >/dev/null 2>&1 || true
  done
}

function any_phase_active_or_pending() {
  unit_is_active "${RUN_TIMER_UNIT}" || \
    unit_is_active "${RUN_SERVICE_UNIT}" || \
    unit_is_active "${REBOOT_TIMER_UNIT}" || \
    unit_is_active "${REBOOT_SERVICE_UNIT}"
}

function require_commands() {
  local missing=()
  local cmd

  for cmd in sudo systemd-run systemctl yay generate-mirrorlist \
    pacman-key mkinitcpio grub-mkconfig date; do
    if ! command_exists "${cmd}"; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

function require_clean_commands() {
  local missing=()
  local cmd

  for cmd in paccache pacman; do
    if ! command_exists "${cmd}"; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required command(s) for --clean: %s\n' \
      "${missing[*]}" >&2
    exit 1
  fi
}

function format_seconds_brief() {
  local total="$1"
  local hours=0
  local minutes=0
  local seconds=0
  local parts=()

  ((total < 0)) && total=0

  hours=$((total / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))

  if ((hours > 0)); then
    parts+=("${hours}h")
  fi

  if ((minutes > 0)); then
    parts+=("${minutes}m")
  fi

  if ((seconds > 0 || ${#parts[@]} == 0)); then
    parts+=("${seconds}s")
  fi

  printf '%s' "${parts[*]}"
}

function format_epoch_human() {
  date -d "@${1}" '+%Y-%m-%d %H:%M:%S'
}

function parse_duration_to_seconds() {
  local input_raw="$1"
  local input=""
  local total=0
  local value=0
  local unit=""

  input="$(printf '%s' "${input_raw}" | tr '[:upper:]' '[:lower:]')"
  input="${input//[[:space:]]/}"

  [[ -n "${input}" ]] || die "empty duration supplied to --in"

  while [[ -n "${input}" ]]; do
    if [[ "${input}" =~ ^([0-9]+)(hours|hour|hrs|hr|h)(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      unit="h"
      input="${BASH_REMATCH[3]}"
    elif [[ "${input}" =~ ^([0-9]+)(minutes|minute|mins|min|m)(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      unit="m"
      input="${BASH_REMATCH[3]}"
    elif [[ "${input}" =~ ^([0-9]+)(seconds|second|secs|sec|s)(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      unit="s"
      input="${BASH_REMATCH[3]}"
    else
      die "could not parse duration '${input_raw}'"
    fi

    case "${unit}" in
    h)
      total=$((total + value * 3600))
      ;;
    m)
      total=$((total + value * 60))
      ;;
    s)
      total=$((total + value))
      ;;
    esac
  done

  ((total > 0)) || die "duration must be greater than zero"
  printf '%s\n' "${total}"
}

function parse_at_to_epoch() {
  local spec="$1"
  local now_epoch=0
  local target_epoch=0
  local parsed=""

  now_epoch="$(date +%s)"

  case "${spec}" in
  now)
    printf '%s\n' "${now_epoch}"
    return 0
    ;;
  esac

  if [[ "${spec}" =~ ^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
    parsed="$(date -d "today ${spec}" +%s 2>/dev/null || true)"
    [[ -n "${parsed}" ]] || die "invalid time for --at: ${spec}"

    if ((parsed <= now_epoch)); then
      parsed="$(date -d "tomorrow ${spec}" +%s 2>/dev/null || true)"
      [[ -n "${parsed}" ]] || die "invalid time for --at: ${spec}"
    fi

    printf '%s\n' "${parsed}"
    return 0
  fi

  target_epoch="$(date -d "${spec}" +%s 2>/dev/null || true)"
  [[ -n "${target_epoch}" ]] || die "invalid datetime for --at: ${spec}"

  if ((target_epoch <= now_epoch)); then
    die "--at time is in the past: ${spec}"
  fi

  printf '%s\n' "${target_epoch}"
}

#-------------------------------------------------------------------------------
# option parsing
#-------------------------------------------------------------------------------
function reset_run_options() {
  OPT_CLEAN=0
  OPT_QUIET=0
  OPT_SILENCE_START=0
  OPT_NO_REBOOT=0
  OPT_VERBOSE=0
  OPT_START_MODE="now"
  OPT_START_SPEC=""
}

function parse_run_options() {
  reset_run_options

  while (($# > 0)); do
    case "$1" in
    --clean)
      OPT_CLEAN=1
      ;;
    --quiet)
      OPT_QUIET=1
      ;;
    --silence-start)
      OPT_SILENCE_START=1
      ;;
    --no-reboot)
      OPT_NO_REBOOT=1
      ;;
    -v | --verbose)
      OPT_VERBOSE=1
      ;;
    --in)
      [[ $# -ge 2 ]] || die "--in requires a duration"
      OPT_START_MODE="in"
      OPT_START_SPEC="$2"
      shift
      ;;
    --at)
      [[ $# -ge 2 ]] || die "--at requires a time value"
      OPT_START_MODE="at"
      OPT_START_SPEC="$2"
      shift
      ;;
    --start)
      [[ $# -ge 2 ]] || die "--start requires a value"
      OPT_START_MODE="at"
      OPT_START_SPEC="$2"
      shift
      ;;
    --start=now)
      OPT_START_MODE="now"
      OPT_START_SPEC="now"
      ;;
    *)
      die "unknown option for run: $1"
      ;;
    esac
    shift
  done
}

function build_execute_args() {
  local -n out_ref="$1"

  out_ref=()

  ((OPT_CLEAN == 1)) && out_ref+=("--clean")
  ((OPT_QUIET == 1)) && out_ref+=("--quiet")
  ((OPT_SILENCE_START == 1)) && out_ref+=("--silence-start")
  ((OPT_NO_REBOOT == 1)) && out_ref+=("--no-reboot")
  ((OPT_VERBOSE == 1)) && out_ref+=("--verbose")
}

#-------------------------------------------------------------------------------
# notifications
#-------------------------------------------------------------------------------
function notify_user_raw() {
  local title="$1"
  local body="$2"
  local hypr_msg="${title}: ${body}"

  if command_exists hyprctl && \
    [[ -n "${SESSION_HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    if ((EUID == 0)); then
      sudo -u "${RUN_AS_USER}" \
        env \
        XDG_RUNTIME_DIR="${SESSION_XDG_RUNTIME_DIR:-}" \
        WAYLAND_DISPLAY="${SESSION_WAYLAND_DISPLAY:-}" \
        HYPRLAND_INSTANCE_SIGNATURE="${SESSION_HYPRLAND_INSTANCE_SIGNATURE:-}" \
        DBUS_SESSION_BUS_ADDRESS="${SESSION_DBUS_SESSION_BUS_ADDRESS:-}" \
        DISPLAY="${SESSION_DISPLAY:-}" \
        hyprctl notify -1 "${HYPR_NOTIFY_MS}" "rgb(ff8800)" \
        "${hypr_msg}" >/dev/null 2>&1 && return 0
    else
      hyprctl notify -1 "${HYPR_NOTIFY_MS}" "rgb(ff8800)" \
        "${hypr_msg}" >/dev/null 2>&1 && return 0
    fi
  fi

  if command_exists notify-send; then
    if ((EUID == 0)); then
      sudo -u "${RUN_AS_USER}" \
        env \
        XDG_RUNTIME_DIR="${SESSION_XDG_RUNTIME_DIR:-}" \
        WAYLAND_DISPLAY="${SESSION_WAYLAND_DISPLAY:-}" \
        HYPRLAND_INSTANCE_SIGNATURE="${SESSION_HYPRLAND_INSTANCE_SIGNATURE:-}" \
        DBUS_SESSION_BUS_ADDRESS="${SESSION_DBUS_SESSION_BUS_ADDRESS:-}" \
        DISPLAY="${SESSION_DISPLAY:-}" \
        notify-send \
        --app-name="${SCRIPT_NAME}" \
        --urgency=critical \
        --expire-time="${HYPR_NOTIFY_MS}" \
        "${title}" \
        "${body}" >/dev/null 2>&1 && return 0
    else
      notify-send \
        --app-name="${SCRIPT_NAME}" \
        --urgency=critical \
        --expire-time="${HYPR_NOTIFY_MS}" \
        "${title}" \
        "${body}" >/dev/null 2>&1 && return 0
    fi
  fi

  printf '%s: %s\n' "${title}" "${body}"
}

function send_start_schedule_notification() {
  local total_seconds="$1"
  local target_label="$2"
  local remaining=""

  remaining="$(format_seconds_brief "${total_seconds}")"

  if ((total_seconds <= 300)); then
    notify_user_raw \
      "Maintenance imminent" \
      "Starts at ${target_label} (in ${remaining}). This is the last reminder before the run begins."
  elif ((total_seconds <= 1800)); then
    notify_user_raw \
      "Maintenance scheduled" \
      "Starts at ${target_label} (in ${remaining}). Less than 30 minutes remain."
  elif ((total_seconds <= 3600)); then
    notify_user_raw \
      "Maintenance scheduled" \
      "Starts at ${target_label} (in ${remaining}). Less than 1 hour remains."
  else
    notify_user_raw \
      "Maintenance scheduled" \
      "Starts at ${target_label} (in ${remaining})."
  fi
}

function notifier_loop() {
  local mode="$1"
  local total_seconds="$2"
  local target_label="${3:-}"
  local remaining=0

  remaining="${total_seconds}"

  case "${mode}" in
  start)
    send_start_schedule_notification "${total_seconds}" "${target_label}"

    if ((remaining > 3600)); then
      sleep $((remaining - 3600))
      remaining=3600
      notify_user_raw \
        "Maintenance scheduled" \
        "The run starts in 1 hour at ${target_label}."
    fi

    if ((remaining > 1800)); then
      sleep $((remaining - 1800))
      remaining=1800
      notify_user_raw \
        "Maintenance scheduled" \
        "The run starts in 30 minutes at ${target_label}."
    fi

    if ((remaining > 300)); then
      sleep $((remaining - 300))
      remaining=300
      notify_user_raw \
        "Maintenance imminent" \
        "The run starts in 5 minutes at ${target_label}. This is the last reminder before the run begins."
    fi
    ;;
  reboot)
    notify_user_raw \
      "Reboot scheduled" \
      "System will reboot in ${REBOOT_COUNTDOWN_SECONDS} seconds. Run '${SCRIPT_NAME} cancel' to stop it."

    if ((remaining > 30)); then
      sleep $((remaining - 30))
      remaining=30
      notify_user_raw \
        "Reboot scheduled" \
        "System will reboot in 30 seconds. Run '${SCRIPT_NAME} cancel' now."
    fi

    if ((remaining > 5)); then
      sleep $((remaining - 5))
      remaining=5
      notify_user_raw \
        "Reboot imminent" \
        "System will reboot in 5 seconds."
    fi
    ;;
  *)
    die "unknown notifier mode: ${mode}"
    ;;
  esac
}

function start_notifier_service() {
  local mode="$1"
  local seconds="$2"
  local target_label="${3:-}"
  local unit_base=""
  local -a cmd=( )
  local -a env_args=( )

  case "${mode}" in
  start)
    unit_base="${START_NOTIFY_UNIT_BASE}"
    ;;
  reboot)
    unit_base="${REBOOT_NOTIFY_UNIT_BASE}"
    ;;
  *)
    die "unknown notifier service mode: ${mode}"
    ;;
  esac

  append_context_env_args env_args
  reset_failed_units "${unit_base}.service"

  cmd=(
    systemd_run_cmd
    --unit="${unit_base}"
    --description="${SCRIPT_NAME} ${mode} notifier"
    "${env_args[@]}"
    "${SCRIPT_PATH}"
    __notify-loop
    "${mode}"
    "${seconds}"
    "${target_label}"
  )

  "${cmd[@]}" >/dev/null
}

#-------------------------------------------------------------------------------
# scheduling
#-------------------------------------------------------------------------------
function schedule_reboot() {
  local -a cmd=( )

  reset_failed_units \
    "${REBOOT_TIMER_UNIT}" \
    "${REBOOT_SERVICE_UNIT}" \
    "${REBOOT_NOTIFY_SERVICE_UNIT}"

  cmd=(
    systemd_run_cmd
    --unit="${REBOOT_UNIT_BASE}"
    --description="Delayed reboot scheduled by ${SCRIPT_NAME}"
    --on-active="${REBOOT_COUNTDOWN_SECONDS}s"
    /usr/bin/systemctl
    reboot
  )

  "${cmd[@]}" >/dev/null
}

function schedule_delayed_maintenance_run() {
  local delay_seconds="$1"
  shift

  local -a execute_args=("$@")
  local -a env_args=( )
  local -a cmd=( )

  append_context_env_args env_args
  reset_failed_units \
    "${RUN_TIMER_UNIT}" \
    "${RUN_SERVICE_UNIT}" \
    "${START_NOTIFY_SERVICE_UNIT}"

  cmd=(
    systemd_run_cmd
    --unit="${RUN_UNIT_BASE}"
    --description="Scheduled maintenance run by ${SCRIPT_NAME}"
    --on-active="${delay_seconds}s"
    "${env_args[@]}"
    "${SCRIPT_PATH}"
    __execute-run
    "${execute_args[@]}"
  )

  "${cmd[@]}" >/dev/null
}

function cancel_reboot() {
  reset_failed_units \
    "${REBOOT_TIMER_UNIT}" \
    "${REBOOT_SERVICE_UNIT}" \
    "${REBOOT_NOTIFY_SERVICE_UNIT}"
}

function cancel_scheduled_start() {
  reset_failed_units \
    "${RUN_TIMER_UNIT}" \
    "${RUN_SERVICE_UNIT}" \
    "${START_NOTIFY_SERVICE_UNIT}"
}

function cancel_pending_work() {
  local had_pending_start=0
  local had_pending_reboot=0
  local run_service_state=""

  if unit_is_active "${RUN_TIMER_UNIT}"; then
    had_pending_start=1
  fi

  if unit_is_active "${REBOOT_TIMER_UNIT}" || unit_is_active "${REBOOT_SERVICE_UNIT}"; then
    had_pending_reboot=1
  fi

  run_service_state="$(unit_state "${RUN_SERVICE_UNIT}")"

  if [[ "${run_service_state}" == "active" ]]; then
    warn "maintenance is already running"
    warn "cancel stops pending timers only; use '${SCRIPT_NAME} stop --force'"
  fi

  cancel_scheduled_start
  cancel_reboot

  if ((had_pending_start == 1 || had_pending_reboot == 1)); then
    notify_user_raw \
      "Operation cancelled" \
      "Pending maintenance start and/or reboot have been cancelled."
    info "Pending scheduled work cancelled."
  else
    info "No pending scheduled start or reboot was found."
  fi
}

function reboot_now() {
  local reboot_pending=0

  if unit_is_active "${REBOOT_TIMER_UNIT}" || unit_is_active "${REBOOT_SERVICE_UNIT}"; then
    reboot_pending=1
  fi

  ((reboot_pending == 1)) || \
    die "no pending reboot was found; use '${SCRIPT_NAME} run' first"

  cancel_reboot

  notify_user_raw \
    "Rebooting now" \
    "The pending reboot countdown has been bypassed. Rebooting immediately."

  info "Executing pending reboot immediately..."
  run_root_cmd systemctl reboot
}

function force_stop_running_maintenance() {
  local force=0

  while (($# > 0)); do
    case "$1" in
    --force)
      force=1
      ;;
    *)
      die "unknown option for stop: $1"
      ;;
    esac
    shift
  done

  if ! unit_is_active "${RUN_SERVICE_UNIT}"; then
    info "No running maintenance service was found."
    return 0
  fi

  if ((force == 0)); then
    die "refusing to stop active maintenance without --force"
  fi

  warn "force-stopping active maintenance is dangerous"
  warn "package database or boot artefacts may be left mid-update"

  systemctl_cmd stop "${RUN_SERVICE_UNIT}"
  systemctl_cmd reset-failed "${RUN_SERVICE_UNIT}" >/dev/null 2>&1 || true

  notify_user_raw \
    "Maintenance stopped" \
    "The running maintenance service was force-stopped. Inspect the system before rebooting."

  info "Running maintenance service force-stopped."
}

function show_status() {
  cat <<EOF
Status
  Scheduled start timer   : $(unit_state "${RUN_TIMER_UNIT}")
  Maintenance service     : $(unit_state "${RUN_SERVICE_UNIT}")
  Start notifier service  : $(unit_state "${START_NOTIFY_SERVICE_UNIT}")
  Reboot timer            : $(unit_state "${REBOOT_TIMER_UNIT}")
  Reboot service          : $(unit_state "${REBOOT_SERVICE_UNIT}")
  Reboot notifier service : $(unit_state "${REBOOT_NOTIFY_SERVICE_UNIT}")
EOF
}

#-------------------------------------------------------------------------------
# cleanup
#-------------------------------------------------------------------------------
function run_cleanup() {
  local -a orphans=( )

  info "Running cleanup tasks..."

  info "Trimming package cache (keeping recent installed versions)..."
  run_root_cmd paccache -r

  info "Removing cached packages that are no longer installed..."
  run_root_cmd paccache -ruk0

  mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)

  if ((${#orphans[@]} > 0)); then
    info "Removing orphan packages..."
    printf 'Orphans: %s\n' "${orphans[*]}"
    run_root_cmd pacman -Rns --noconfirm -- "${orphans[@]}"
  else
    info "No orphan packages found."
  fi
}

#-------------------------------------------------------------------------------
# maintenance execution
#-------------------------------------------------------------------------------
function on_execute_error() {
  local exit_code="$1"

  reset_failed_units "${START_NOTIFY_SERVICE_UNIT}"

  if ((OPT_QUIET == 0)); then
    notify_user_raw \
      "Maintenance failed" \
      "The maintenance sequence failed. No reboot has been scheduled."
  fi

  exit "${exit_code}"
}

function execute_maintenance_sequence() {
  local -a execute_args=( )

  parse_run_options "$@"
  build_execute_args execute_args

  require_commands
  ((OPT_CLEAN == 1)) && require_clean_commands

  if ((EUID == 0)); then
    ensure_root_context_is_complete
  else
    ensure_not_root
    capture_user_context
    info "Refreshing sudo credentials..."
    run_cmd sudo -v
  fi

  trap 'on_execute_error "$?"' ERR

  reset_failed_units "${START_NOTIFY_SERVICE_UNIT}"

  if ((OPT_QUIET == 0)); then
    notify_user_raw \
      "Maintenance starting" \
      "The maintenance operation has started. Use '${SCRIPT_NAME} stop --force' only if absolutely necessary."
  fi

  info "Starting maintenance sequence..."

  run_root_cmd generate-mirrorlist
  run_as_invoking_user_cmd yay -Syyu --noconfirm
  run_root_cmd pacman-key --init
  run_root_cmd pacman-key --populate archlinux
  run_root_cmd mkinitcpio -P
  run_root_cmd grub-mkconfig -o /boot/grub/grub.cfg

  if ((OPT_CLEAN == 1)); then
    run_cleanup
  fi

  trap - ERR

  info "Maintenance sequence completed successfully."

  if ((OPT_NO_REBOOT == 1)); then
    if ((OPT_QUIET == 0)); then
      notify_user_raw \
        "Maintenance completed" \
        "The maintenance sequence completed successfully. No reboot was scheduled."
    fi
    return 0
  fi

  schedule_reboot

  if ((OPT_QUIET == 0)); then
    start_notifier_service reboot "${REBOOT_COUNTDOWN_SECONDS}"
    notify_user_raw \
      "Maintenance completed" \
      "The maintenance sequence completed successfully. Reboot is scheduled in ${REBOOT_COUNTDOWN_SECONDS} seconds."
  fi

  info "Reboot scheduled in ${REBOOT_COUNTDOWN_SECONDS} seconds."
  info "Cancel with: ${SCRIPT_NAME} cancel"

  if ((OPT_VERBOSE == 1)); then
    info "Post-maintenance reboot delay is fixed at ${REBOOT_COUNTDOWN_SECONDS} seconds."
  fi
}

#-------------------------------------------------------------------------------
# run entrypoint
#-------------------------------------------------------------------------------
function run_maintenance_entry() {
  local delay_seconds=0
  local now_epoch=0
  local target_epoch=0
  local target_label=""
  local -a execute_args=( )

  parse_run_options "$@"
  build_execute_args execute_args

  ensure_not_root
  capture_user_context
  require_commands
  ((OPT_CLEAN == 1)) && require_clean_commands

  if any_phase_active_or_pending; then
    die "a scheduled start, active maintenance, or pending reboot already exists"
  fi

  reset_failed_units \
    "${START_NOTIFY_SERVICE_UNIT}" \
    "${REBOOT_NOTIFY_SERVICE_UNIT}"

  case "${OPT_START_MODE}" in
  now)
    execute_maintenance_sequence "${execute_args[@]}"
    return 0
    ;;
  in)
    delay_seconds="$(parse_duration_to_seconds "${OPT_START_SPEC}")"
    now_epoch="$(date +%s)"
    target_epoch=$((now_epoch + delay_seconds))
    ;;
  at)
    target_epoch="$(parse_at_to_epoch "${OPT_START_SPEC}")"
    now_epoch="$(date +%s)"
    delay_seconds=$((target_epoch - now_epoch))

    if ((delay_seconds <= 0)); then
      execute_maintenance_sequence "${execute_args[@]}"
      return 0
    fi
    ;;
  *)
    die "unsupported start mode: ${OPT_START_MODE}"
    ;;
  esac

  target_label="$(format_epoch_human "${target_epoch}")"

  info "Refreshing sudo credentials for scheduling..."
  run_cmd sudo -v

  schedule_delayed_maintenance_run "${delay_seconds}" "${execute_args[@]}"

  if ((OPT_QUIET == 0 && OPT_SILENCE_START == 0)); then
    start_notifier_service start "${delay_seconds}" "${target_label}"
  fi

  info "Maintenance scheduled for ${target_label}."
  info "Time until start: $(format_seconds_brief "${delay_seconds}")"
  info "Cancel with: ${SCRIPT_NAME} cancel"

  if ((OPT_VERBOSE == 1)); then
    info "Post-maintenance reboot delay is fixed at ${REBOOT_COUNTDOWN_SECONDS} seconds."
    ((OPT_NO_REBOOT == 1)) && info "Reboot has been disabled for this run."
    ((OPT_SILENCE_START == 1)) && info "Pre-run notifications are suppressed."
    ((OPT_QUIET == 1)) && info "All notifications are suppressed."
  fi
}

#-------------------------------------------------------------------------------
# entrypoint
#-------------------------------------------------------------------------------
function main() {
  local subcommand="${1:-run}"

  case "${subcommand}" in
  run)
    shift
    run_maintenance_entry "$@"
    ;;
  cancel)
    ensure_not_root
    capture_user_context
    cancel_pending_work
    ;;
  stop)
    ensure_not_root
    capture_user_context
    shift
    force_stop_running_maintenance "$@"
    ;;
  now)
    ensure_not_root
    capture_user_context
    reboot_now
    ;;
  status)
    ensure_not_root
    capture_user_context
    show_status
    ;;
  __execute-run)
    shift
    execute_maintenance_sequence "$@"
    ;;
  __notify-loop)
    shift
    if ((EUID == 0)); then
      ensure_root_context_is_complete
    fi
    notifier_loop "$@"
    ;;
  -h | --help | help)
    show_help
    ;;
  *)
    die "unknown subcommand: ${subcommand}"
    ;;
  esac
}

main "$@"
