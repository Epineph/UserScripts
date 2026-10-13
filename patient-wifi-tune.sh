#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# patient-wifi-tune.sh
#
# Diagnose a slow Wi-Fi connection and optionally test one reversible local
# change: disable Wi-Fi power saving until it is explicitly restored or the
# machine reboots. The script does not change DNS, NetworkManager profiles,
# routes, MTU, firewall rules, VPN settings, or hospital network controls.
#
# Usage:
#   patient-wifi-tune.sh diagnose [--download-test] [--interface wlo1]
#   patient-wifi-tune.sh apply [--interface wlo1]
#   patient-wifi-tune.sh status [--interface wlo1]
#   patient-wifi-tune.sh restore
#   patient-wifi-tune.sh --help | --long-help
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly STATE_ROOT="${XDG_STATE_HOME:-${HOME:?}/.local/state}"
readonly STATE_DIR="${STATE_ROOT}/patient-wifi-tune"
readonly STATE_FILE="${STATE_DIR}/runtime-state"

INTERFACE=""
DOWNLOAD_TEST=0
SAVED_BOOT_ID=""
SAVED_INTERFACE=""
SAVED_ORIGINAL=""

# -----------------------------------------------------------------------------
# Help and common checks
# -----------------------------------------------------------------------------

show_help() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} diagnose [--download-test] [--interface IFACE]
  ${SCRIPT_NAME} apply [--interface IFACE]
  ${SCRIPT_NAME} status [--interface IFACE]
  ${SCRIPT_NAME} restore
  ${SCRIPT_NAME} --help | --long-help

Commands:
  diagnose       Show Wi-Fi, DNS, and latency diagnostics without changes.
  apply          Temporarily disable Wi-Fi power saving on the active adapter.
  status         Show the current power-save state and any saved restore point.
  restore        Restore the state recorded before the temporary change.

Options:
  -i, --interface IFACE  Select an adapter; otherwise use active NetworkManager
                         Wi-Fi.
      --download-test    During diagnose, download up to 5 MB from Cloudflare
                         to estimate end-to-end HTTPS throughput.
  -h, --help             Show this help.
      --long-help        Show detailed notes and limitations.
EOF
}

show_long_help() {
  show_help
  cat <<'EOF'

Details:
  * The diagnostic checks the current NetworkManager connection, the Wi-Fi
    link, the configured IPv4 DNS server, gateway reachability, public ICMP
    reachability, and resolution of example.com.
  * ICMP can be filtered by public networks. A failed ping alone does not prove
    that web traffic is unavailable.
  * --download-test makes one HTTPS request for a 5 MB test file. It is
    optional because it uses data and the test endpoint may be blocked.
  * apply changes only the running Wi-Fi adapter through `iw`. It does not edit
    persistent NetworkManager profiles. Disabling power saving can increase
    battery use, may be reset when Wi-Fi reconnects, and may not improve speed.
  * restore uses a private state file under ~/.local/state (or XDG_STATE_HOME)
    to put the adapter back to the previous on/off state. A stale backup from a
    previous boot is discarded because rebooting reinitializes the adapter.
  * Do not run the whole script with sudo. It invokes sudo only for the
    temporary adapter change and its restoration.
  * This cannot increase the bandwidth supplied by a congested or rate-limited
    access point. It also does not bypass captive portals or network policy.

Examples:
  patient-wifi-tune.sh diagnose
  patient-wifi-tune.sh diagnose --download-test
  patient-wifi-tune.sh apply
  patient-wifi-tune.sh status
  patient-wifi-tune.sh restore
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_non_root() {
  (( EUID != 0 )) || die "Run this as your normal user, without sudo."
}

validate_interface() {
  local iface=$1

  [[ "$iface" =~ ^[[:alnum:]_][[:alnum:]_.:-]*$ ]] ||
    die "Invalid Wi-Fi interface name: $iface"
  [[ -d "/sys/class/net/${iface}/wireless" ]] ||
    die "Not a visible Wi-Fi interface: $iface"
}

detect_interface() {
  local iface

  if [[ -n "$INTERFACE" ]]; then
    validate_interface "$INTERFACE"
    printf '%s\n' "$INTERFACE"
    return 0
  fi

  require_command nmcli
  iface=$(nmcli -t -f DEVICE,TYPE,STATE device status |
    awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
  [[ -n "$iface" ]] || die "No connected NetworkManager Wi-Fi adapter found."
  validate_interface "$iface"
  printf '%s\n' "$iface"
}

read_power_state() {
  local iface=$1
  local output

  output=$(iw dev "$iface" get power_save 2>/dev/null) || return 1
  case "${output##* }" in
    on|off) printf '%s\n' "${output##* }" ;;
    *) return 1 ;;
  esac
}

current_boot_id() {
  cat /proc/sys/kernel/random/boot_id
}

# -----------------------------------------------------------------------------
# Private restore-point handling
# -----------------------------------------------------------------------------

write_state() {
  local boot_id=$1
  local iface=$2
  local original=$3
  local temporary_file

  [[ "$STATE_ROOT" == /* ]] || die "XDG_STATE_HOME must be an absolute path."
  umask 077
  mkdir -p -- "$STATE_DIR"
  chmod 700 -- "$STATE_DIR"
  temporary_file=$(mktemp "${STATE_DIR}/.state.XXXXXX")
  {
    printf 'boot_id=%s\n' "$boot_id"
    printf 'interface=%s\n' "$iface"
    printf 'original=%s\n' "$original"
  } >"$temporary_file"
  chmod 600 -- "$temporary_file"
  mv -f -- "$temporary_file" "$STATE_FILE"
}

load_state() {
  local key value

  [[ -f "$STATE_FILE" ]] || return 1
  [[ -O "$STATE_FILE" ]] || die "Restore file is not owned by this user."

  SAVED_BOOT_ID=""
  SAVED_INTERFACE=""
  SAVED_ORIGINAL=""
  while IFS='=' read -r key value; do
    case "$key" in
      boot_id) SAVED_BOOT_ID=$value ;;
      interface) SAVED_INTERFACE=$value ;;
      original) SAVED_ORIGINAL=$value ;;
    esac
  done <"$STATE_FILE"

  [[ "$SAVED_BOOT_ID" =~ ^[[:alnum:]-]+$ ]] ||
    die "Restore file is malformed; inspect or remove: $STATE_FILE"
  validate_interface "$SAVED_INTERFACE"
  [[ "$SAVED_ORIGINAL" == on || "$SAVED_ORIGINAL" == off ]] ||
    die "Restore file is malformed; inspect or remove: $STATE_FILE"
}

run_iw_power_save() {
  local iface=$1
  local state=$2

  command -v sudo >/dev/null 2>&1 || die "Required command not found: sudo"
  sudo -- iw dev "$iface" set power_save "$state"
}

# -----------------------------------------------------------------------------
# Read-only diagnostics
# -----------------------------------------------------------------------------

run_ping() {
  local label=$1
  local target=$2

  printf '\n%s (%s):\n' "$label" "$target"
  if ping -n -q -c 4 -W 1 "$target"; then
    :
  else
    note "  No ICMP reply; this network may filter ping."
  fi
}

run_download_test() {
  local report status speed seconds bytes http_code write_format
  local url='https://speed.cloudflare.com/__down?bytes=5000000'

  require_command curl
  note "\nOptional HTTPS download test: up to 5 MB from Cloudflare."
  write_format=$'%{speed_download}\t%{time_total}\t'
  write_format+=$'%{size_download}\t%{http_code}'
  if report=$(curl --silent --show-error --location --max-time 25 \
      --output /dev/null \
      --write-out "$write_format" \
      "$url" 2>/dev/null); then
    status=0
  else
    status=$?
  fi

  IFS=$'\t' read -r speed seconds bytes http_code <<<"$report"
  if [[ "$http_code" != 200 && "$http_code" != 206 ]]; then
    note "  Test endpoint unavailable or blocked (HTTP ${http_code:-unknown})."
    return 0
  fi
  if [[ ! "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
      [[ ! "$bytes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    note "  The endpoint returned no usable transfer measurement."
    return 0
  fi

  awk -v speed="$speed" -v seconds="$seconds" -v bytes="$bytes" \
    'BEGIN {
      printf "  Received %.0f bytes in %.2f s; average %.2f Mbit/s.\n",
             bytes, seconds, speed * 8 / 1000000
    }'
  if (( status != 0 )); then
    note "  The 25-second limit was reached; treat this as a partial estimate."
  fi
}

diagnose() {
  local iface gateway power_state dns

  require_command nmcli
  require_command iw
  require_command ip
  require_command ping
  require_command getent
  iface=$(detect_interface)

  printf 'Wi-Fi diagnostics for %s\n' "$iface"
  printf '\nNetworkManager connection and DNS:\n'
  nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.GATEWAY,IP4.DNS \
    device show "$iface" || true

  printf '\nWi-Fi link details:\n'
  if ! iw dev "$iface" link; then
    note "  Link details are unavailable."
  fi

  if power_state=$(read_power_state "$iface"); then
    printf '\nRuntime Wi-Fi power saving: %s\n' "$power_state"
  else
    note "\nRuntime Wi-Fi power-save state is unavailable for this driver."
  fi

  gateway=$(ip -4 route show default dev "$iface" |
    awk '$1 == "default" {
      for (i = 1; i <= NF; i++) {
        if ($i == "via") { print $(i + 1); exit }
      }
    }')
  if [[ -n "$gateway" ]]; then
    run_ping "Gateway latency" "$gateway"
  else
    note "\nNo IPv4 default gateway found on this adapter."
  fi
  run_ping "Public IP latency" "1.1.1.1"

  printf '\nDNS lookup for example.com:\n'
  if dns=$(getent ahostsv4 example.com 2>/dev/null); then
    printf '%s\n' "$dns" | awk 'NR == 1 { print "  Resolved to " $1; exit }'
  else
    note "  Resolution failed using the current system resolver."
  fi

  if (( DOWNLOAD_TEST == 1 )); then
    run_download_test
  fi

  note "\nNo network settings were changed."
}

# -----------------------------------------------------------------------------
# Temporary power-save trial and restoration
# -----------------------------------------------------------------------------

apply_power_save_test() {
  local iface boot_id current

  require_non_root
  require_command nmcli
  require_command iw
  iface=$(detect_interface)
  boot_id=$(current_boot_id)

  if [[ -f "$STATE_FILE" ]]; then
    load_state
    if [[ "$SAVED_BOOT_ID" != "$boot_id" ]]; then
      rm -f -- "$STATE_FILE"
      note "Discarded a restore point from a previous boot."
    elif [[ "$SAVED_INTERFACE" != "$iface" ]]; then
      die "Restore ${SAVED_INTERFACE} first, then change ${iface}."
    else
      current=$(read_power_state "$iface") ||
        die "Could not read Wi-Fi power-save state for $iface."
      if [[ "$current" == off ]]; then
        note "Wi-Fi power saving is already off; the original state is saved."
        return 0
      fi
      note "Reapplying the temporary setting; original restore point kept."
      run_iw_power_save "$iface" off ||
        die "Could not change the adapter; restore point was retained."
      note "Temporary setting applied. Use '${SCRIPT_NAME} restore' to undo it."
      return 0
    fi
  fi

  current=$(read_power_state "$iface") ||
    die "Could not read Wi-Fi power-save state for $iface."
  if [[ "$current" == off ]]; then
    note "Wi-Fi power saving is already off; no change was made."
    return 0
  fi

  write_state "$boot_id" "$iface" "$current"
  if ! run_iw_power_save "$iface" off; then
    die "Could not change adapter; restore point retained at $STATE_FILE."
  fi

  current=$(read_power_state "$iface") ||
    die "Change could not be verified; restore point retained."
  [[ "$current" == off ]] ||
    die "The adapter did not retain the setting. Restore point retained."

  note "Wi-Fi power saving is now off on $iface for this runtime session."
  note "Battery use may rise. Use '${SCRIPT_NAME} restore' to undo the change."
}

restore_power_save() {
  local boot_id current

  require_non_root
  require_command iw
  if ! load_state; then
    note "No saved power-save change exists for this user."
    return 0
  fi

  boot_id=$(current_boot_id)
  if [[ "$SAVED_BOOT_ID" != "$boot_id" ]]; then
    rm -f -- "$STATE_FILE"
    note "Removed a stale restore point from a previous boot; no change needed."
    return 0
  fi

  current=$(read_power_state "$SAVED_INTERFACE") ||
    die "Could not read state for $SAVED_INTERFACE; restore point was retained."
  if [[ "$current" == "$SAVED_ORIGINAL" ]]; then
    rm -f -- "$STATE_FILE"
    note "Adapter already matches its original state ($SAVED_ORIGINAL)."
    note "Removed the restore point."
    return 0
  fi

  run_iw_power_save "$SAVED_INTERFACE" "$SAVED_ORIGINAL" ||
    die "Could not restore the adapter; restore point was retained."
  current=$(read_power_state "$SAVED_INTERFACE") ||
    die "Restore was issued, but its state could not be verified."
  [[ "$current" == "$SAVED_ORIGINAL" ]] ||
    die "Adapter did not return to its original state; restore point retained."

  rm -f -- "$STATE_FILE"
  note "Restored $SAVED_INTERFACE to power saving: $SAVED_ORIGINAL."
}

show_status() {
  local iface current

  require_command iw
  iface=$(detect_interface)
  if current=$(read_power_state "$iface"); then
    printf 'Runtime Wi-Fi power saving on %s: %s\n' "$iface" "$current"
  else
    note "Runtime Wi-Fi power-save state is unavailable for $iface."
  fi

  if [[ -f "$STATE_FILE" ]]; then
    load_state
    if [[ "$SAVED_BOOT_ID" == "$(current_boot_id)" ]]; then
      printf 'Saved restore point: %s was %s before this test.\n' \
        "$SAVED_INTERFACE" "$SAVED_ORIGINAL"
    else
      note "A previous-boot restore point exists; restore will discard it."
    fi
  else
    note "No saved temporary change exists."
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing and dispatch
# -----------------------------------------------------------------------------

ACTION=${1:-help}
if [[ "$ACTION" == --help || "$ACTION" == -h || "$ACTION" == help ]]; then
  show_help
  exit 0
fi
if [[ "$ACTION" == --long-help ]]; then
  show_long_help
  exit 0
fi
shift || true

while (($#)); do
  case "$1" in
    -i|--interface)
      (($# >= 2)) || die "Missing value for $1"
      INTERFACE=$2
      shift 2
      ;;
    --download-test)
      DOWNLOAD_TEST=1
      shift
      ;;
    *)
      die "Unknown option: $1 (see '${SCRIPT_NAME} --help')"
      ;;
  esac
done

case "$ACTION" in
  diagnose|test)
    diagnose
    ;;
  apply)
    (( DOWNLOAD_TEST == 0 )) || die "--download-test is only for diagnose."
    apply_power_save_test
    ;;
  status)
    (( DOWNLOAD_TEST == 0 )) || die "--download-test is only for diagnose."
    show_status
    ;;
  restore|off)
    (( DOWNLOAD_TEST == 0 )) || die "--download-test is only for diagnose."
    [[ -z "$INTERFACE" ]] ||
      die "Omit --interface; restore uses the saved interface."
    restore_power_save
    ;;
  *)
    die "Unknown command: $ACTION (see '${SCRIPT_NAME} --help')"
    ;;
esac
