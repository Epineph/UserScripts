#!/usr/bin/env bash
#
# usb-wipe-signatures.sh
#
# Destructively remove partition tables, filesystem signatures, swap
# signatures, and LUKS metadata from an entire removable drive.
#
# WARNING:
#   This permanently destroys all data and partition metadata on the
#   selected device.
#
# Usage:
#   sudo usb-wipe-signatures.sh /dev/sdX
#

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"

# ---------------------------------------------------------------------------
# Help and diagnostics
# ---------------------------------------------------------------------------

function show_help() {
  cat <<EOF
Usage:
  sudo ${PROGRAM} DEVICE

Example:
  sudo ${PROGRAM} /dev/sda

The DEVICE must be an entire block device, not a partition.

This script will:
  1. Display identifying information about the selected device.
  2. Refuse to operate on the disk containing the running root filesystem.
  3. Unmount filesystems and disable swap on descendant partitions.
  4. Close descendant LUKS/device-mapper mappings where possible.
  5. Erase filesystem, RAID, swap, LUKS, MBR, and GPT signatures.
  6. Ask the kernel to re-read the partition table.
  7. Display the resulting device state.

Required commands:
  lsblk, findmnt, wipefs, umount, swapoff, blockdev, udevadm

Recommended:
  sgdisk   Strongly erases both primary and backup GPT metadata.
  partprobe
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Device validation
# ---------------------------------------------------------------------------

function validate_device() {
  local device="$1"
  local device_type
  local root_source
  local root_node
  local read_only

  [[ "$EUID" -eq 0 ]] ||
    die "Run this script as root, for example: sudo ${PROGRAM} /dev/sdX"

  [[ -b "$device" ]] ||
    die "Not a block device: $device"

  device="$(readlink -f -- "$device")"
  device_type="$(lsblk -dnro TYPE "$device")"
  read_only="$(lsblk -dnro RO "$device")"

  [[ "$device_type" == "disk" ]] ||
    die "Specify an entire disk, not a partition: $device"

  [[ "$read_only" == "0" ]] ||
    die "The selected device is read-only: $device"

  root_source="$(findmnt -nro SOURCE /)"
  root_source="$(readlink -f -- "$root_source")"

  while read -r root_node; do
    [[ -n "$root_node" ]] || continue
    root_node="$(readlink -f -- "$root_node")"

    [[ "$device" != "$root_node" ]] ||
      die "Refusing to erase a disk underlying the root filesystem: $device"
  done < <(lsblk -srno PATH "$root_source" 2>/dev/null || true)

  printf '%s\n' "$device"
}

function show_device_summary() {
  local device="$1"

  printf '\nSelected device:\n\n'
  lsblk \
    -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,RO,TYPE,FSTYPE,MOUNTPOINTS \
    "$device"

  printf '\nDetected signatures:\n\n'
  wipefs "$device" || true

  while read -r descendant; do
    [[ "$descendant" == "$device" ]] && continue
    wipefs "$descendant" 2>/dev/null || true
  done < <(lsblk -nrpo NAME "$device")
}

function confirm_erasure() {
  local device="$1"
  local answer

  cat <<EOF

DANGER
------
Every partition and all data on:

  ${device}

will be permanently destroyed.

To continue, type exactly:

  ERASE ${device}

EOF

  read -r -p '> ' answer

  [[ "$answer" == "ERASE $device" ]] ||
    die "Confirmation did not match. Nothing was changed."
}

# ---------------------------------------------------------------------------
# Cleanup operations
# ---------------------------------------------------------------------------

function deactivate_descendants() {
  local device="$1"
  local node
  local node_type
  local mapper_name

  printf '\nDisabling swap and unmounting descendant filesystems...\n'

  while read -r node node_type; do
    [[ "$node" == "$device" ]] && continue

    swapoff "$node" 2>/dev/null || true
    umount --recursive "$node" 2>/dev/null || true

    if [[ "$node_type" == "crypt" ]]; then
      mapper_name="${node##*/}"
      cryptsetup close "$mapper_name" 2>/dev/null || true
    fi
  done < <(lsblk -nrpo NAME,TYPE "$device" | tac)
}

function erase_signatures() {
  local device="$1"
  local node

  printf '\nErasing descendant signatures...\n'

  while read -r node; do
    [[ "$node" == "$device" ]] && continue
    wipefs --all --force "$node" 2>/dev/null || true
  done < <(lsblk -nrpo NAME "$device" | tac)

  if command -v sgdisk >/dev/null 2>&1; then
    printf 'Erasing primary and backup GPT metadata...\n'
    sgdisk --zap-all "$device"
  else
    printf '%s\n' \
      'Warning: sgdisk is unavailable; relying on wipefs for table removal.' \
      'Install it on Arch Linux with: pacman -S --needed gptfdisk' >&2
  fi

  printf 'Erasing whole-device signatures...\n'
  wipefs --all --force "$device"

  # Zero the first and last 4 MiB to remove stubborn bootloader/table remnants.
  printf 'Zeroing the first and last 4 MiB...\n'
  dd if=/dev/zero of="$device" bs=1M count=4 conv=fsync status=progress

  local sectors
  local sector_size
  local total_bytes
  local seek_bytes

  sectors="$(blockdev --getsz "$device")"
  sector_size="$(blockdev --getss "$device")"
  total_bytes=$((sectors * sector_size))

  if ((total_bytes > 8 * 1024 * 1024)); then
    seek_bytes=$((total_bytes / 1024 / 1024 - 4))
    dd \
      if=/dev/zero \
      of="$device" \
      bs=1M \
      seek="$seek_bytes" \
      count=4 \
      conv=fsync,notrunc \
      status=progress
  fi

  sync
}

function refresh_kernel_state() {
  local device="$1"

  printf '\nRefreshing kernel device state...\n'

  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$device" 2>/dev/null || true
  fi

  blockdev --rereadpt "$device" 2>/dev/null || true
  udevadm settle
}

function verify_result() {
  local device="$1"

  printf '\nFinal device state:\n\n'
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$device"

  printf '\nRemaining signatures:\n\n'
  if ! wipefs "$device"; then
    true
  fi

  printf '\nCompleted. The device is now unpartitioned and unsigned.\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main() {
  local device

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
  fi

  [[ "$#" -eq 1 ]] || {
    show_help >&2
    exit 2
  }

  for command_name in \
    lsblk \
    findmnt \
    wipefs \
    umount \
    swapoff \
    blockdev \
    udevadm \
    dd; do
    require_command "$command_name"
  done

  device="$(validate_device "$1")"

  show_device_summary "$device"
  confirm_erasure "$device"
  deactivate_descendants "$device"
  erase_signatures "$device"
  refresh_kernel_state "$device"
  verify_result "$device"
}

main "$@"
