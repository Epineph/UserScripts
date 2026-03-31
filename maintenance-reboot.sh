#!/usr/bin/env bash

set -euo pipefail

#===============================================================================
# maintenance-reboot
#
# Execute a maintenance/update sequence and, only if all steps succeed,
# schedule a reboot in 90 seconds. During the countdown, send desktop
# notifications in a Hyprland session when possible.
#
# The pending reboot can be cancelled with:
#   maintenance-reboot cancel
#
# Design notes:
#   - The update sequence runs as the invoking user.
#   - Root-only commands use sudo individually.
#   - The delayed reboot itself is scheduled via systemd-run, which is more
#     robust than a background "sleep ... && reboot" job.
#   - A separate notifier worker is spawned in the user session so the
#     cancellation command can kill it cleanly.
#===============================================================================

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

readonly UNIT_BASE="maintenance-reboot"
readonly TIMER_UNIT="${UNIT_BASE}.timer"
readonly SERVICE_UNIT="${UNIT_BASE}.service"

readonly STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/${UNIT_BASE}"
readonly NOTIFIER_PID_FILE="${STATE_DIR}/notifier.pid"

readonly COUNTDOWN_SECONDS=90
readonly HYPR_NOTIFY_MS=15000

#-------------------------------------------------------------------------------
# help
#-------------------------------------------------------------------------------
function show_help() {
  cat <<'EOF'
maintenance-reboot

Run a fixed maintenance sequence, then schedule a reboot in 90 seconds.
The reboot can be cancelled during that countdown window.

USAGE
  maintenance-reboot run
  maintenance-reboot cancel
  maintenance-reboot status
  maintenance-reboot --help
  maintenance-reboot -h

BEHAVIOUR
  The run subcommand executes this exact sequence:

    sudo generate-mirrorlist
    yay -Syyy
    yay -Syyu --noconfirm
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo mkinitcpio -P
    sudo grub-mkconfig -o /boot/grub/grub.cfg

  If, and only if, all commands succeed, a reboot is scheduled for 90 seconds
  later. Notifications are sent immediately, at 30 seconds remaining, and at
  5 seconds remaining when possible.

CANCEL
  Cancel the pending reboot with:

    maintenance-reboot cancel

REQUIREMENTS
  Required:
    - bash
    - sudo
    - systemd-run
    - systemctl
    - yay
    - generate-mirrorlist
    - pacman-key
    - mkinitcpio
    - grub-mkconfig

  Optional for notifications:
    - hyprctl
    - notify-send

IMPORTANT
  Do not run this script itself with sudo.
  yay should run as your normal user, not as root.

EXAMPLES
  maintenance-reboot run
  maintenance-reboot status
  maintenance-reboot cancel
  /usr/local/bin/maintenance-reboot run
  chmod +x ./maintenance-reboot && ./maintenance-reboot run
  cp ./maintenance-reboot /usr/local/bin/maintenance-reboot
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

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function ensure_not_root() {
  if (( EUID == 0 )); then
    die "run this script as your normal user, not as root"
  fi
}

function ensure_state_dir() {
  mkdir -p "${STATE_DIR}"
}

function notifier_pid_is_running() {
  [[ -f "${NOTIFIER_PID_FILE}" ]] || return 1

  local pid
  pid="$(<"${NOTIFIER_PID_FILE}")"

  [[ -n "${pid}" ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1
}

function cleanup_notifier_pid_file() {
  rm -f "${NOTIFIER_PID_FILE}"
}

function cleanup_notifier() {
  if notifier_pid_is_running; then
    local pid
    pid="$(<"${NOTIFIER_PID_FILE}")"
    kill "${pid}" >/dev/null 2>&1 || true
  fi

  cleanup_notifier_pid_file
}

function timer_is_active() {
  sudo systemctl is-active --quiet "${TIMER_UNIT}"
}

function service_is_active() {
  sudo systemctl is-active --quiet "${SERVICE_UNIT}"
}

function reboot_is_scheduled() {
  timer_is_active || service_is_active
}

function require_commands() {
  local missing=()
  local cmd

  for cmd in sudo systemd-run systemctl yay generate-mirrorlist \
    pacman-key mkinitcpio grub-mkconfig; do
    if ! command_exists "${cmd}"; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

function run_cmd() {
  printf '>>> %s\n' "$*"
  "$@"
}

#-------------------------------------------------------------------------------
# notifications
#-------------------------------------------------------------------------------
function notify_user() {
  local title="${1}"
  local body="${2}"
  local hypr_msg="${title}: ${body}"

  if command_exists hyprctl &&
    [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    hyprctl notify -1 "${HYPR_NOTIFY_MS}" "rgb(ff8800)" \
      "${hypr_msg}" >/dev/null 2>&1 && return 0
  fi

  if command_exists notify-send; then
    notify-send \
      --app-name="${SCRIPT_NAME}" \
      --urgency=critical \
      --expire-time="${HYPR_NOTIFY_MS}" \
      "${title}" \
      "${body}" >/dev/null 2>&1 && return 0
  fi

  printf '%s: %s\n' "${title}" "${body}"
}

function notifier_loop() {
  notify_user \
    "Reboot scheduled" \
    "System will reboot in 90 seconds. Run '${SCRIPT_NAME} cancel' to stop it."

  sleep 60

  notify_user \
    "Reboot scheduled" \
    "System will reboot in 30 seconds. Run '${SCRIPT_NAME} cancel' now."

  sleep 25

  notify_user \
    "Reboot imminent" \
    "System will reboot in 5 seconds."
}

function start_notifier() {
  ensure_state_dir
  cleanup_notifier

  nohup "${SCRIPT_PATH}" __notify-loop >/dev/null 2>&1 &
  printf '%s\n' "$!" > "${NOTIFIER_PID_FILE}"
}

#-------------------------------------------------------------------------------
# scheduling
#-------------------------------------------------------------------------------
function schedule_reboot() {
  run_cmd sudo systemd-run \
    --unit="${UNIT_BASE}" \
    --description="Delayed reboot scheduled by ${SCRIPT_NAME}" \
    --on-active="${COUNTDOWN_SECONDS}" \
    /usr/bin/systemctl reboot >/dev/null
}

function cancel_reboot() {
  local had_timer=0
  local had_notifier=0

  if reboot_is_scheduled; then
    had_timer=1
  fi

  if notifier_pid_is_running; then
    had_notifier=1
  fi

  run_cmd sudo systemctl stop "${TIMER_UNIT}" "${SERVICE_UNIT}" \
    >/dev/null 2>&1 || true
  run_cmd sudo systemctl reset-failed "${TIMER_UNIT}" "${SERVICE_UNIT}" \
    >/dev/null 2>&1 || true

  cleanup_notifier

  if (( had_timer == 1 || had_notifier == 1 )); then
    notify_user \
      "Reboot cancelled" \
      "The pending reboot has been cancelled."
    info "Pending reboot cancelled."
  else
    info "No pending reboot was found."
  fi
}

function show_status() {
  local timer_state="inactive"
  local service_state="inactive"
  local notifier_state="not running"

  if timer_is_active; then
    timer_state="active"
  fi

  if service_is_active; then
    service_state="active"
  fi

  if notifier_pid_is_running; then
    notifier_state="running (PID $(<"${NOTIFIER_PID_FILE}"))"
  fi

  cat <<EOF
Status
  Timer unit   : ${TIMER_UNIT} -> ${timer_state}
  Service unit : ${SERVICE_UNIT} -> ${service_state}
  Notifier     : ${notifier_state}
EOF
}

#-------------------------------------------------------------------------------
# main work sequence
#-------------------------------------------------------------------------------
function run_maintenance_sequence() {
  ensure_not_root
  require_commands
  ensure_state_dir

  if reboot_is_scheduled || notifier_pid_is_running; then
    die "a reboot countdown is already pending; use '${SCRIPT_NAME} cancel'"
  fi

  info "Refreshing sudo credentials..."
  run_cmd sudo -v

  run_cmd sudo generate-mirrorlist
  run_cmd yay -Syyy
  run_cmd yay -Syyu --noconfirm
  run_cmd sudo pacman-key --init
  run_cmd sudo pacman-key --populate archlinux
  run_cmd sudo mkinitcpio -P
  run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg

  schedule_reboot
  start_notifier

  info "Maintenance sequence completed successfully."
  info "Reboot scheduled in ${COUNTDOWN_SECONDS} seconds."
  info "Cancel with: ${SCRIPT_NAME} cancel"
}

#-------------------------------------------------------------------------------
# entrypoint
#-------------------------------------------------------------------------------
function main() {
  local subcommand="${1:-run}"

  case "${subcommand}" in
    run)
      run_maintenance_sequence
      ;;
    cancel)
      ensure_not_root
      cancel_reboot
      ;;
    status)
      ensure_not_root
      show_status
      ;;
    __notify-loop)
      notifier_loop
      ;;
    -h|--help|help)
      show_help
      ;;
    *)
      die "unknown subcommand: ${subcommand}"
      ;;
  esac
}

main "${@}"
