#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

# -----------------------------------------------------------------------------
# power-delay
#
# Schedule a delayed shutdown or reboot.
#
# Design:
#   - -H, -M, and -S are additive delay components.
#   - -s and -r select the final action and are mutually exclusive.
#   - Hyprland notifications are used when available.
#   - notify-send is used as a fallback.
#   - -q / --quiet silences notifications.
# -----------------------------------------------------------------------------

umask 077

readonly PROGRAM="${0##*/}"
readonly STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/${PROGRAM}.${UID}"
readonly PID_FILE="${STATE_DIR}/pid"
readonly META_FILE="${STATE_DIR}/meta"
readonly LOG_FILE="${STATE_DIR}/log"

QUIET=false
REPLACE=false
ACTION=""
HOURS=0
MINUTES=0
SECONDS=0
PARSED_UINT=0

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function print_help() {
  cat <<EOF
${PROGRAM} - schedule delayed shutdown or reboot

Usage:
  ${PROGRAM} -s [-H HOURS] [-M MINUTES] [-S SECONDS] [options]
  ${PROGRAM} -r [-H HOURS] [-M MINUTES] [-S SECONDS] [options]
  ${PROGRAM} --cancel
  ${PROGRAM} --status

Actions:
  -s, --shutdown        Power off after the delay
  -r, --reboot          Reboot after the delay

Delay components:
  -H, --hours N         Add N hours to the delay
  -M, --minutes N       Add N minutes to the delay
  -S, --seconds N       Add N seconds to the delay

Options:
  -q, --quiet           Silence Hyprland / desktop notifications
  -c, --cancel          Cancel this script's active schedule
      --status          Show this script's active schedule
      --replace         Replace an active schedule from this script
  -h, --help            Show this help text

Examples:
  ${PROGRAM} -s -M 30
  ${PROGRAM} -r -H 1
  ${PROGRAM} -s -H 1 -M 15 -S 30
  ${PROGRAM} -r -S 90
  ${PROGRAM} -s -H 2 --quiet
  ${PROGRAM} --status
  ${PROGRAM} --cancel

Notes:
  - Delay flags are additive and not mutually exclusive.
  - Exactly one of -s or -r must be selected.
  - The scheduled worker is detached from the terminal.
  - If poweroff/reboot requires extra privileges, configure polkit or run from
    a session where systemctl poweroff/reboot is permitted.
EOF
}

# -----------------------------------------------------------------------------
# Basic helpers
# -----------------------------------------------------------------------------

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function ensure_state_dir() {
  mkdir -p -- "${STATE_DIR}"
  chmod 700 -- "${STATE_DIR}" 2>/dev/null || true
}

function require_uint_arg() {
  local opt="$1"
  local value="${2-}"

  [[ -n "${value}" ]] || die "${opt} requires a non-negative integer argument"
  [[ "${value}" =~ ^[0-9]+$ ]] || {
    die "${opt} requires a non-negative integer, got: ${value}"
  }

  PARSED_UINT="${value}"
}

function format_duration() {
  local total="$1"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  local parts=()

  ((h > 0)) && parts+=("${h}h")
  ((m > 0)) && parts+=("${m}m")
  ((s > 0)) && parts+=("${s}s")

  if ((${#parts[@]} == 0)); then
    printf '0s\n'
  else
    printf '%s\n' "${parts[*]}"
  fi
}

function notify_user() {
  local title="$1"
  local body="$2"
  local icon="${3:-1}"
  local ms="${4:-5000}"
  local message="${title}: ${body}"

  [[ "${QUIET}" == true ]] && return 0

  if have hyprctl; then
    hyprctl notify "${icon}" "${ms}" 0 "${message}" >/dev/null 2>&1 \
      && return 0
  fi

  if have notify-send; then
    notify-send "${title}" "${body}" >/dev/null 2>&1 \
      && return 0
  fi

  return 0
}

function running_pid() {
  local pid=""

  [[ -r "${PID_FILE}" ]] || return 1

  pid="$(<"${PID_FILE}")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1

  kill -0 "${pid}" 2>/dev/null || return 1
  printf '%s\n' "${pid}"
}

function read_meta_value() {
  local key="$1"

  [[ -r "${META_FILE}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key { print $2; exit }' "${META_FILE}"
}

function write_meta() {
  local action="$1"
  local total="$2"
  local deadline="$3"
  local pid="$4"

  cat >"${META_FILE}" <<EOF
action=${action}
total_seconds=${total}
deadline_epoch=${deadline}
pid=${pid}
log=${LOG_FILE}
EOF
}

# -----------------------------------------------------------------------------
# Status / cancellation
# -----------------------------------------------------------------------------

function show_status() {
  local pid=""
  local action=""
  local total=""
  local deadline=""
  local now=""
  local remaining=""

  if ! pid="$(running_pid)"; then
    rm -f -- "${PID_FILE}" "${META_FILE}"
    printf 'No active %s schedule found.\n' "${PROGRAM}"
    return 0
  fi

  action="$(read_meta_value action || true)"
  total="$(read_meta_value total_seconds || true)"
  deadline="$(read_meta_value deadline_epoch || true)"
  now="$(date +%s)"

  if [[ "${deadline}" =~ ^[0-9]+$ ]] && ((deadline > now)); then
    remaining=$((deadline - now))
  else
    remaining=0
  fi

  printf 'Active %s schedule:\n' "${PROGRAM}"
  printf '  action:      %s\n' "${action:-unknown}"
  printf '  pid:         %s\n' "${pid}"
  printf '  original:    %s\n' "$(format_duration "${total:-0}")"
  printf '  remaining:   %s\n' "$(format_duration "${remaining}")"
  printf '  log:         %s\n' "${LOG_FILE}"
}

function cancel_schedule() {
  local pid=""

  if pid="$(running_pid)"; then
    kill "${pid}" 2>/dev/null || true

    for _ in {1..20}; do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.05
    done

    rm -f -- "${PID_FILE}" "${META_FILE}"
    notify_user "Scheduled power cancelled" "Cancelled PID ${pid}" 1 4000
    printf 'Cancelled active %s schedule, PID %s.\n' "${PROGRAM}" "${pid}"
    return 0
  fi

  rm -f -- "${PID_FILE}" "${META_FILE}"
  printf 'No active %s schedule found.\n' "${PROGRAM}"
}

# -----------------------------------------------------------------------------
# Worker
# -----------------------------------------------------------------------------

function worker_cleanup() {
  rm -f -- "${PID_FILE}" "${META_FILE}"
}

function worker_main() {
  local action="$1"
  local total="$2"
  local quiet="$3"
  local start=""
  local deadline=""
  local remaining=""
  local checkpoint=""
  local sleep_for=""
  local cmd=""

  QUIET="${quiet}"

  ensure_state_dir

  start="$(date +%s)"
  deadline=$((start + total))

  printf '%s\n' "$$" >"${PID_FILE}"
  write_meta "${action}" "${total}" "${deadline}" "$$"

  trap 'worker_cleanup; exit 143' TERM INT HUP

  notify_user \
    "Scheduled ${action}" \
    "${action} in $(format_duration "${total}")" \
    1 \
    5000

  remaining="${total}"

  for checkpoint in 3600 1800 900 300 60 30 10; do
    if ((remaining > checkpoint)); then
      sleep_for=$((remaining - checkpoint))
      sleep "${sleep_for}"
      remaining="${checkpoint}"

      notify_user \
        "Scheduled ${action}" \
        "${action} in $(format_duration "${remaining}")" \
        0 \
        5000
    fi
  done

  if ((remaining > 0)); then
    sleep "${remaining}"
  fi

  notify_user "Executing ${action}" "Running systemctl ${action}" 0 3000

  worker_cleanup

  case "${action}" in
    shutdown)
      cmd="poweroff"
      ;;
    reboot)
      cmd="reboot"
      ;;
    *)
      notify_user "Scheduled power failed" "Unknown action: ${action}" 3 7000
      exit 2
      ;;
  esac

  if ! systemctl "${cmd}"; then
    notify_user \
      "Scheduled power failed" \
      "systemctl ${cmd} failed; see ${LOG_FILE}" \
      3 \
      7000
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

if [[ "${1-}" == "--_worker" ]]; then
  shift
  [[ $# -eq 3 ]] || exit 2
  worker_main "$@"
  exit $?
fi

while (($# > 0)); do
  case "$1" in
    -H|--hours)
      require_uint_arg "$1" "${2-}"
      HOURS=$((HOURS + PARSED_UINT))
      shift 2
      ;;
    -M|--minutes)
      require_uint_arg "$1" "${2-}"
      MINUTES=$((MINUTES + PARSED_UINT))
      shift 2
      ;;
    -S|--seconds)
      require_uint_arg "$1" "${2-}"
      SECONDS=$((SECONDS + PARSED_UINT))
      shift 2
      ;;
    -s|--shutdown)
      [[ -z "${ACTION}" ]] || die "choose exactly one of -s or -r"
      ACTION="shutdown"
      shift
      ;;
    -r|--reboot)
      [[ -z "${ACTION}" ]] || die "choose exactly one of -s or -r"
      ACTION="reboot"
      shift
      ;;
    -q|--quiet|--silent)
      QUIET=true
      shift
      ;;
    -c|--cancel)
      ensure_state_dir
      cancel_schedule
      exit 0
      ;;
    --status)
      ensure_state_dir
      show_status
      exit 0
      ;;
    --replace)
      REPLACE=true
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Schedule
# -----------------------------------------------------------------------------

[[ -n "${ACTION}" ]] || die "choose exactly one action: -s or -r"

readonly TOTAL_SECONDS=$((HOURS * 3600 + MINUTES * 60 + SECONDS))

((TOTAL_SECONDS > 0)) || {
  die "delay must be greater than zero; use -H, -M, and/or -S"
}

ensure_state_dir

if running_pid >/dev/null; then
  if [[ "${REPLACE}" == true ]]; then
    cancel_schedule >/dev/null
  else
    show_status
    die "an active schedule already exists; use --replace or --cancel"
  fi
fi

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"

(
  trap '' HUP
  exec "${SCRIPT_PATH}" \
    --_worker \
    "${ACTION}" \
    "${TOTAL_SECONDS}" \
    "${QUIET}"
) </dev/null >>"${LOG_FILE}" 2>&1 &

child_pid="$!"
disown "${child_pid}" 2>/dev/null || true

printf '%s\n' "${child_pid}" >"${PID_FILE}"

printf 'Scheduled %s in %s.\n' \
  "${ACTION}" \
  "$(format_duration "${TOTAL_SECONDS}")"

printf 'Use "%s --status" or "%s --cancel".\n' "${PROGRAM}" "${PROGRAM}"
