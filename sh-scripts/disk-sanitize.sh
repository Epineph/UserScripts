#!/usr/bin/env bash

set -Eeuo pipefail

#===============================================================================
# disk-sanitize
#
# Destructive disk sanitization helper:
#   1) Best-effort teardown of active users of the target device
#   2) Removal of signatures / partition tables / common metadata
#   3) Whole-device wipe via blkdiscard or zero-fill
#   4) Verification that signatures are gone, with optional full read verify
#
# This is designed for repurposing a disk cleanly, not for "repair".
# If the goal is destruction of layout and data, "repair first" is logically
# unnecessary. The correct sequence is teardown -> metadata removal -> wipe ->
# verification.
#
# REQUIREMENTS
#   Required:
#     bash, lsblk, findmnt, wipefs, sgdisk, dd, partprobe
#
#   Optional (used if available):
#     blkdiscard, cryptsetup, lvm2, mdadm, zpool, udevadm
#
# USAGE
#   disk-sanitize --device /dev/sdX --yes
#   disk-sanitize --device /dev/nvme1n1 --mode zero --verify read --yes
#   disk-sanitize --device /dev/sdc --mode discard --log ~/wipe-sdc.log --yes
#
# EXAMPLES
#   # Let the script choose discard if appropriate, else zero-fill:
#   disk-sanitize --device /dev/sdb --yes
#
#   # Force a zero-fill, then do a full read verification:
#   disk-sanitize --device /dev/sdb --mode zero --verify read --yes
#
#   # SSD/NVMe, force discard:
#   disk-sanitize --device /dev/nvme0n1 --mode discard --yes
#
#   # Write a log:
#   disk-sanitize --device /dev/sdc --log ~/logs/sanitize-sdc.log --yes
#
# NOTES
#   * Run from a live environment whenever possible.
#   * The target must be a whole disk, not a partition.
#   * The script aborts if it detects / mounted from the target disk tree.
#===============================================================================

readonly PROGNAME="$(basename "$0")"

DEVICE=""
MODE="auto"
VERIFY="signatures"
ASSUME_YES=0
LOGFILE=""

function usage() {
  cat <<'EOF'
Usage:
  disk-sanitize --device /dev/sdX [options] --yes

Required:
  --device PATH          Whole-disk block device, e.g. /dev/sdb, /dev/nvme1n1

Destructive confirmation:
  --yes                  Required. Without this, the script aborts.

Wipe mode:
  --mode auto            Prefer blkdiscard if supported, else zero-fill
  --mode discard         Force blkdiscard
  --mode zero            Force zero-fill with dd

Verification:
  --verify none          No verification
  --verify signatures    Confirm that known signatures are gone
  --verify read          Signature check + full linear read of the device

Logging:
  --log FILE             Append output to FILE via tee

Help:
  -h, --help             Show this help

Examples:
  disk-sanitize --device /dev/sdb --yes
  disk-sanitize --device /dev/nvme1n1 --mode zero --verify read --yes
  disk-sanitize --device /dev/sdc --mode discard --log ~/wipe-sdc.log --yes
EOF
}

function log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
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
  [[ $# -eq 0 ]] && usage && exit 1

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
        usage
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

function preflight() {
  require_cmd lsblk
  require_cmd findmnt
  require_cmd wipefs
  require_cmd sgdisk
  require_cmd dd
  require_cmd partprobe
  require_cmd awk
  require_cmd sort
  require_cmd grep
  require_cmd readlink

  [[ $EUID -eq 0 ]] || die "Run as root"

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

function device_tree_contains_root() {
  local node
  while read -r node; do
    if findmnt -rn -S "${node}" -o TARGET 2>/dev/null | grep -qx '/'; then
      return 0
    fi
  done < <(list_descendants)

  return 1
}

function list_descendants() {
  lsblk -nrpo NAME "${DEVICE}"
}

function list_raw_targets() {
  lsblk -nrpo NAME,TYPE "${DEVICE}" \
    | awk '$2 == "disk" || $2 == "part" { print $1 }'
}

function show_device_summary() {
  log "Target summary:"
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,UUID,MODEL "${DEVICE}"
}

function confirm_target() {
  local reply

  echo
  echo "==============================================================="
  echo "DESTRUCTIVE OPERATION"
  echo "Target: ${DEVICE}"
  echo
  echo "Everything reachable on this whole disk will be destroyed."
  echo "==============================================================="
  echo

  show_device_summary
  echo
  read -r -p "Type the exact path '${DEVICE}' to continue: " reply
  [[ "${reply}" == "${DEVICE}" ]] \
    || die "Confirmation string did not match; aborting"
}

function unmount_descendants() {
  log "Unmounting any mounted filesystems on the target device tree"

  local nodes=()
  local node
  while read -r node; do
    nodes+=("${node}")
  done < <(list_descendants)

  local i target
  for (( i=${#nodes[@]}-1; i>=0; i-- )); do
    node="${nodes[$i]}"
    while read -r target; do
      [[ -n "${target}" ]] || continue
      log "Unmounting ${target} (source ${node})"
      umount "${target}" || die "Failed to unmount ${target}"
    done < <(findmnt -rn -S "${node}" -o TARGET 2>/dev/null || true)
  done
}

function swapoff_descendants() {
  have swapon || return 0

  log "Disabling swap on the target device tree if present"

  local swaps=()
  local s
  while read -r s; do
    [[ -n "${s}" ]] && swaps+=("${s}")
  done < <(swapon --noheadings --raw --output NAME 2>/dev/null || true)

  [[ ${#swaps[@]} -gt 0 ]] || return 0

  local nodes=()
  local node
  while read -r node; do
    nodes+=("${node}")
  done < <(list_descendants)

  local active
  for active in "${swaps[@]}"; do
    for node in "${nodes[@]}"; do
      if [[ "${active}" == "${node}" ]]; then
        log "swapoff ${active}"
        swapoff "${active}" || die "Failed to swapoff ${active}"
      fi
    done
  done
}

function deactivate_lvm() {
  have lvs || return 0
  have vgchange || return 0

  log "Best-effort LVM deactivation"

  local lvs_found=()
  local line
  while read -r line; do
    [[ -n "${line}" ]] && lvs_found+=("${line}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "lvm" { print $1 }')

  [[ ${#lvs_found[@]} -gt 0 ]] || return 0

  local lv vg
  for lv in "${lvs_found[@]}"; do
    vg="$(lvs --noheadings -o vg_name "${lv}" 2>/dev/null | awk '{$1=$1;print}')"
    [[ -n "${vg}" ]] || continue
    log "vgchange -an ${vg}"
    vgchange -an "${vg}" || true
  done
}

function close_crypt() {
  have cryptsetup || return 0

  log "Best-effort closing of dm-crypt mappings"

  local crypts=()
  local c
  while read -r c; do
    [[ -n "${c}" ]] && crypts+=("${c}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "crypt" { print $1 }')

  [[ ${#crypts[@]} -gt 0 ]] || return 0

  local i mapname
  for (( i=${#crypts[@]}-1; i>=0; i-- )); do
    mapname="$(basename "${crypts[$i]}")"
    log "cryptsetup close ${mapname}"
    cryptsetup close "${mapname}" || true
  done
}

function stop_md() {
  have mdadm || return 0

  log "Best-effort stopping of mdraid mappings"

  local raids=()
  local r
  while read -r r; do
    [[ -n "${r}" ]] && raids+=("${r}")
  done < <(lsblk -nrpo NAME,TYPE "${DEVICE}" | awk '$2 == "raid" { print $1 }')

  [[ ${#raids[@]} -gt 0 ]] || return 0

  local i
  for (( i=${#raids[@]}-1; i>=0; i-- )); do
    log "mdadm --stop ${raids[$i]}"
    mdadm --stop "${raids[$i]}" || true
  done
}

function best_effort_teardown() {
  unmount_descendants
  swapoff_descendants
  deactivate_lvm
  close_crypt
  stop_md
}

function clear_metadata() {
  log "Clearing signatures from disk and child partitions"

  local target
  while read -r target; do
    [[ -n "${target}" ]] || continue

    log "wipefs -a -f ${target}"
    wipefs -a -f "${target}" || true

    if have mdadm; then
      log "mdadm --zero-superblock --force ${target}"
      mdadm --zero-superblock --force "${target}" || true
    fi

    if have pvremove; then
      log "pvremove -ff -y ${target}"
      pvremove -ff -y "${target}" || true
    fi

    if have zpool; then
      log "zpool labelclear -f ${target}"
      zpool labelclear -f "${target}" || true
    fi
  done < <(list_raw_targets)

  log "sgdisk --zap-all ${DEVICE}"
  sgdisk --zap-all "${DEVICE}" || true

  log "Forcing kernel partition-table re-read"
  partprobe "${DEVICE}" || true

  if have udevadm; then
    udevadm settle || true
  fi
}

function discard_supported() {
  have blkdiscard || return 1

  local base sysfile
  base="$(basename "${DEVICE}")"
  sysfile="/sys/class/block/${base}/queue/discard_max_bytes"

  [[ -r "${sysfile}" ]] || return 1
  [[ "$(cat "${sysfile}")" -gt 0 ]] || return 1

  return 0
}

function wipe_device() {
  case "${MODE}" in
    auto)
      if discard_supported; then
        log "Mode auto: discard supported, using blkdiscard"
        blkdiscard -f -v "${DEVICE}"
      else
        log "Mode auto: discard not supported, using zero-fill"
        dd if=/dev/zero of="${DEVICE}" bs=16M status=progress \
          oflag=direct conv=fsync,notrunc
      fi
      ;;
    discard)
      log "Using blkdiscard"
      blkdiscard -f -v "${DEVICE}"
      ;;
    zero)
      log "Using zero-fill with dd"
      dd if=/dev/zero of="${DEVICE}" bs=16M status=progress \
        oflag=direct conv=fsync,notrunc
      ;;
  esac

  sync
}

function signatures_present() {
  local target output
  while read -r target; do
    [[ -n "${target}" ]] || continue
    output="$(wipefs -n "${target}" 2>/dev/null | tail -n +2 || true)"
    if [[ -n "${output}" ]]; then
      echo "Residual signature(s) on ${target}:"
      echo "${output}"
      return 0
    fi
  done < <(list_raw_targets)

  return 1
}

function verify_signatures() {
  log "Verifying that known signatures are gone"

  if signatures_present; then
    die "Known signatures still appear to be present"
  fi

  log "No signatures reported by wipefs"
}

function verify_read() {
  log "Performing full linear read verification"
  dd if="${DEVICE}" of=/dev/null bs=16M status=progress iflag=direct
  log "Read verification completed"
}

function main() {
  parse_args "$@"
  setup_logging
  preflight
  confirm_target

  log "Starting destructive sanitization of ${DEVICE}"
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

  log "Completed successfully"
  log "The disk should now be blank and ready for repartitioning"
}

main "$@"
