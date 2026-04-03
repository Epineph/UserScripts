#!/usr/bin/env bash

set -Eeuo pipefail

#===============================================================================
# disk-sanitize
#
# Destructive whole-disk sanitization helper.
#
# Stages:
#   1) Best-effort teardown of active users of the target device
#   2) Signature-aware metadata cleanup
#   3) Whole-device wipe:
#        - blkdiscard if supported and selected
#        - otherwise zero-fill with pv progress
#   4) Verification
#
# Notes:
#   * This is for destruction / repurposing, not repair.
#   * Run this from a live ISO or another OS whenever possible.
#   * Target must be a whole disk, not a partition.
#   * If pv is missing, the script will offer to install it. If you decline,
#     the script exits with status 1.
#===============================================================================

readonly PROGNAME="$(basename "$0")"
readonly ZERO_BS="64M"

DEVICE=""
MODE="auto"
VERIFY="signatures"
ASSUME_YES=0
LOGFILE=""

function page_output() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    eval "${HELP_PAGER}"
  elif command -v less >/dev/null 2>&1; then
    less -R
  else
    cat
  fi
}

function show_help() {
  cat <<'EOF' | page_output
Usage:
  disk-sanitize --device /dev/sdX [options] --yes

Required:
  --device PATH
      Whole-disk block device, for example:
        /dev/sdb
        /dev/sdc
        /dev/nvme1n1

Destructive confirmation:
  --yes
      Required. Without this, the script aborts.

Wipe mode:
  --mode auto
      Prefer blkdiscard if supported, else zero-fill with pv.

  --mode discard
      Force blkdiscard.

  --mode zero
      Force whole-device zero-fill with pv progress.

Verification:
  --verify none
      Do not verify after wiping.

  --verify signatures
      Confirm that known signatures are gone.

  --verify read
      Signature check plus a full linear read pass with pv progress.

Logging:
  --log FILE
      Append all output to FILE via tee.

Help:
  -h, --help
      Show this help text.

Examples:
  disk-sanitize --device /dev/sdb --yes

  disk-sanitize --device /dev/sdb --mode zero --yes

  disk-sanitize --device /dev/nvme1n1 --mode discard --yes

  disk-sanitize --device /dev/sdc --verify read --yes

  disk-sanitize --device /dev/sdc \
    --mode auto \
    --verify signatures \
    --log "$HOME/logs/sanitize-sdc.log" \
    --yes

  disk-sanitize --device /dev/sdd --mode zero --verify none --yes

Important:
  * This destroys data.
  * The script refuses to target a partition.
  * The script refuses if / appears to live on the target device tree.
  * If pv is not installed, the script will prompt to install it.
EOF
}

function log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

function stage() {
  printf '\n'
  printf '%s\n' "=============================================================================="
  log "$*"
  printf '%s\n' "=============================================================================="
}

function die() {
  log "ERROR: $*" >&2
  exit 1
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function require_cmd() {
  have "$1" || die "Required command not found: $1"
}

function setup_logging() {
  [[ -z "${LOGFILE}" ]] && return 0

  mkdir -p "$(dirname "${LOGFILE}")"
  exec > >(tee -a "${LOGFILE}") 2>&1
}

function parse_args() {
  [[ $# -eq 0 ]] && show_help && exit 1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || die "--device requires a value"
        DEVICE="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value"
        MODE="${2,,}"
        shift 2
        ;;
      --verify)
        [[ $# -ge 2 ]] || die "--verify requires a value"
        VERIFY="${2,,}"
        shift 2
        ;;
      --log)
        [[ $# -ge 2 ]] || die "--log requires a value"
        LOGFILE="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${DEVICE}" ]] || die "--device is required"
  [[ "${ASSUME_YES}" -eq 1 ]] || die "You must pass --yes"
  [[ "${MODE}" =~ ^(auto|discard|zero)$ ]] \
    || die "--mode must be one of: auto, discard, zero"
  [[ "${VERIFY}" =~ ^(none|signatures|read)$ ]] \
    || die "--verify must be one of: none, signatures, read"
}

function install_pv() {
  if have pacman; then
    pacman -Sy --needed pv
  elif have apt-get; then
    apt-get update
    apt-get install -y pv
  elif have dnf; then
    dnf install -y pv
  elif have zypper; then
    zypper --non-interactive install pv
  elif have apk; then
    apk add pv
  else
    die "Could not detect a supported package manager to install pv"
  fi
}

function ensure_pv() {
  local reply

  if have pv; then
    return 0
  fi

  printf '\n'
  printf '%s\n' "'pv' is required for progress reporting during zero-fill and"
  printf '%s\n' "read verification."
  read -r -p "Install 'pv' now? [y/N]: " reply

  case "${reply,,}" in
    y|yes)
      install_pv || die "Failed to install pv"
      ;;
    *)
      exit 1
      ;;
  esac

  have pv || die "pv is still unavailable after attempted installation"
}

function preflight() {
  require_cmd lsblk
  require_cmd findmnt
  require_cmd wipefs
  require_cmd sgdisk
  require_cmd dd
  require_cmd partprobe
  require_cmd awk
  require_cmd grep
  require_cmd readlink
  require_cmd head
  require_cmd tee

  [[ $EUID -eq 0 ]] || die "Run as root"

  ensure_pv

  DEVICE="$(readlink -f "${DEVICE}")"
  [[ -b "${DEVICE}" ]] || die "Not a block device: ${DEVICE}"

  local dtype
  dtype="$(lsblk -dnro TYPE "${DEVICE}")"
  [[ "${dtype}" == "disk" ]] \
    || die "Target must be a whole disk, not type '${dtype}'"

  if device_tree_contains_root; then
    die "Refusing: / appears to live on the target device tree"
  fi

  if [[ "${MODE}" == "discard" ]] && ! have blkdiscard; then
    die "blkdiscard not found, but --mode discard was requested"
  fi
}

function list_descendants() {
  lsblk -nrpo NAME "${DEVICE}"
}

function list_raw_targets() {
  lsblk -nrpo NAME,TYPE "${DEVICE}" \
    | awk '$2 == "disk" || $2 == "part" { print $1 }'
}

function device_tree_contains_root() {
  local node

  while read -r node; do
    if findmnt -rn -S "${node}" -o TARGET 2>/dev/null | grep -qx '/'; then
      return 0
    fi
  done < <(list_descendants)

  return 1
}

function show_device_summary() {
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,UUID,MODEL "${DEVICE}"
}

function confirm_target() {
  local reply

  printf '\n'
  printf '%s\n' "DESTRUCTIVE OPERATION"
  printf '%s\n' "Target: ${DEVICE}"
  printf '\n'
  printf '%s\n' \
    "Everything reachable on this whole disk will be destroyed."
  printf '%s\n' \
    "==============================================================="
  printf '\n'

  log "Target summary:"
  show_device_summary
  printf '\n'

  read -r -p "Type the exact path '${DEVICE}' to continue: " reply
  [[ "${reply}" == "${DEVICE}" ]] \
    || die "Confirmation string did not match; aborting"
}

function unmount_descendants() {
  local nodes=()
  local node
  local i
  local target

  stage "Unmounting mounted filesystems on the target device tree"

  while read -r node; do
    nodes+=("${node}")
  done < <(list_descendants)

  for (( i=${#nodes[@]} - 1; i>=0; i-- )); do
    node="${nodes[$i]}"
    while read -r target; do
      [[ -n "${target}" ]] || continue
      log "Unmounting ${target} (source ${node})"
      umount "${target}" || die "Failed to unmount ${target}"
    done < <(findmnt -rn -S "${node}" -o TARGET 2>/dev/null || true)
  done
}

function swapoff_descendants() {
  local swaps=()
  local active
  local node

  have swapon || return 0

  stage "Disabling swap on the target device tree if present"

  while read -r active; do
    [[ -n "${active}" ]] && swaps+=("${active}")
  done < <(swapon --noheadings --raw --output NAME 2>/dev/null || true)

  [[ ${#swaps[@]} -gt 0 ]] || return 0

  for active in "${swaps[@]}"; do
    while read -r node; do
      if [[ "${active}" == "${node}" ]]; then
        log "swapoff ${active}"
        swapoff "${active}" || die "Failed to swapoff ${active}"
      fi
    done < <(list_descendants)
  done
}

function deactivate_lvm() {
  local lvs_found=()
  local lv
  local vg

  have lvs || return 0
  have vgchange || return 0

  stage "Best-effort LVM deactivation"

  while read -r lv; do
    [[ -n "${lv}" ]] && lvs_found+=("${lv}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "lvm" { print $1 }')

  [[ ${#lvs_found[@]} -gt 0 ]] || return 0

  for lv in "${lvs_found[@]}"; do
    vg="$(lvs --noheadings -o vg_name "${lv}" 2>/dev/null \
      | awk '{$1=$1; print}')"
    [[ -n "${vg}" ]] || continue
    log "vgchange -an ${vg}"
    vgchange -an "${vg}" || true
  done
}

function close_crypt() {
  local crypts=()
  local map
  local i

  have cryptsetup || return 0

  stage "Best-effort closing of dm-crypt mappings"

  while read -r map; do
    [[ -n "${map}" ]] && crypts+=("${map}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "crypt" { print $1 }')

  [[ ${#crypts[@]} -gt 0 ]] || return 0

  for (( i=${#crypts[@]} - 1; i>=0; i-- )); do
    map="$(basename "${crypts[$i]}")"
    log "cryptsetup close ${map}"
    cryptsetup close "${map}" || true
  done
}

function stop_md() {
  local raids=()
  local raid
  local i

  have mdadm || return 0

  stage "Best-effort stopping of mdraid mappings"

  while read -r raid; do
    [[ -n "${raid}" ]] && raids+=("${raid}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "raid" { print $1 }')

  [[ ${#raids[@]} -gt 0 ]] || return 0

  for (( i=${#raids[@]} - 1; i>=0; i-- )); do
    raid="${raids[$i]}"
    log "mdadm --stop ${raid}"
    mdadm --stop "${raid}" || true
  done
}

function best_effort_teardown() {
  unmount_descendants
  swapoff_descendants
  deactivate_lvm
  close_crypt
  stop_md
}

function get_wipefs_signatures() {
  local target="$1"

  wipefs -n "${target}" 2>/dev/null | awk 'NR > 1' || true
}

function has_signature() {
  local target="$1"
  local needle="$2"
  local signatures

  signatures="$(get_wipefs_signatures "${target}")"
  grep -Fqi -- "${needle}" <<<"${signatures}"
}

function clear_target_metadata() {
  local target="$1"
  local signatures

  signatures="$(get_wipefs_signatures "${target}")"

  if [[ -z "${signatures}" ]]; then
    log "No signatures detected on ${target}"
    return 0
  fi

  log "Detected signatures on ${target}:"
  printf '%s\n' "${signatures}"

  if has_signature "${target}" "LVM2_member" && have pvremove; then
    log "Clearing LVM metadata on ${target}"
    LVM_SUPPRESS_FD_WARNINGS=1 pvremove -ff -y "${target}" >/dev/null 2>&1 \
      || true
  fi

  if has_signature "${target}" "linux_raid_member" && have mdadm; then
    log "Clearing mdraid superblock on ${target}"
    mdadm --zero-superblock --force "${target}" >/dev/null 2>&1 || true
  fi

  if has_signature "${target}" "zfs_member" && have zpool; then
    log "Clearing ZFS label on ${target}"
    zpool labelclear -f "${target}" >/dev/null 2>&1 || true
  fi

  log "wipefs -a -f ${target}"
  wipefs -a -f "${target}" || true
}

function clear_metadata() {
  local target

  stage "Clearing signatures and on-disk metadata"

  while read -r target; do
    [[ -n "${target}" ]] || continue
    clear_target_metadata "${target}"
  done < <(list_raw_targets)

  log "sgdisk --zap-all ${DEVICE}"
  sgdisk --zap-all "${DEVICE}" || true

  log "Forcing kernel partition-table re-read"
  partprobe "${DEVICE}" || true

  if have udevadm; then
    udevadm settle || true
  fi
}

function get_device_size_bytes() {
  local target="$1"

  if have blockdev; then
    blockdev --getsize64 "${target}"
  else
    lsblk -bdno SIZE "${target}"
  fi
}

function discard_supported() {
  local base
  local sysfile

  have blkdiscard || return 1

  base="$(basename "${DEVICE}")"
  sysfile="/sys/class/block/${base}/queue/discard_max_bytes"

  [[ -r "${sysfile}" ]] || return 1
  [[ "$(cat "${sysfile}")" -gt 0 ]] || return 1

  return 0
}

function zero_fill_device() {
  local target="$1"
  local total_bytes

  total_bytes="$(get_device_size_bytes "${target}")"

  stage "Zero-filling ${target} with pv progress"

  log "This is limited mainly by the device's sustained write speed"
  log "Using block size ${ZERO_BS}"

  head -c "${total_bytes}" /dev/zero \
    | pv \
        --size "${total_bytes}" \
        --progress \
        --timer \
        --eta \
        --rate \
        --bytes \
    | dd \
        of="${target}" \
        bs="${ZERO_BS}" \
        iflag=fullblock \
        oflag=direct \
        conv=fdatasync \
        status=none

  sync
}

function wipe_device() {
  case "${MODE}" in
    auto)
      if discard_supported; then
        stage "Mode auto: discard supported; using blkdiscard"
        blkdiscard -f -v "${DEVICE}"
      else
        stage "Mode auto: discard not supported; using zero-fill"
        zero_fill_device "${DEVICE}"
      fi
      ;;
    discard)
      stage "Using blkdiscard"
      blkdiscard -f -v "${DEVICE}"
      ;;
    zero)
      zero_fill_device "${DEVICE}"
      ;;
  esac

  sync
}

function signatures_present() {
  local target
  local output

  while read -r target; do
    [[ -n "${target}" ]] || continue
    output="$(get_wipefs_signatures "${target}")"
    if [[ -n "${output}" ]]; then
      printf '%s\n' "Residual signatures on ${target}:"
      printf '%s\n' "${output}"
      return 0
    fi
  done < <(list_raw_targets)

  return 1
}

function verify_signatures() {
  stage "Verifying that known signatures are gone"

  if signatures_present; then
    die "Known signatures still appear to be present"
  fi

  log "No signatures reported by wipefs"
}

function verify_read() {
  local total_bytes

  total_bytes="$(get_device_size_bytes "${DEVICE}")"

  stage "Full linear read verification with pv progress"

  dd if="${DEVICE}" bs="${ZERO_BS}" iflag=direct status=none \
    | pv \
        --size "${total_bytes}" \
        --progress \
        --timer \
        --eta \
        --rate \
        --bytes \
    > /dev/null

  log "Read verification completed"
}

function main() {
  parse_args "$@"
  setup_logging
  preflight
  confirm_target

  stage "Starting destructive sanitization of ${DEVICE}"

  best_effort_teardown
  clear_metadata
  wipe_device

  case "${VERIFY}" in
    none)
      ;;
    signatures)
      verify_signatures
      ;;
    read)
      verify_signatures
      verify_read
      ;;
  esac

  stage "Completed successfully"
  log "The disk should now be blank and ready for repartitioning"
}

main "$@"
