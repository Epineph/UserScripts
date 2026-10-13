#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wipe-external.sh
#
# Overwrite a whole disk with zeros, then create one GPT/exFAT volume.
# Default target: /dev/sda
# -----------------------------------------------------------------------------

set -Eeuo pipefail

function usage() {
  cat <<'EOF'
Usage: sudo bash wipe-external.sh [DEVICE]

DEVICE defaults to /dev/sda. This erases the entire device and recreates it
as one GPT partition with an exFAT filesystem.
EOF
}

function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Required command not found: $1"
}

function main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  (( $# <= 1 )) || die "Give at most one device path; see --help."

  for cmd in readlink lsblk blockdev dd findmnt swapon grep \
    parted partprobe udevadm mkfs.exfat; do
    require_command "$cmd"
  done

  (( EUID == 0 )) || die "Run this script with sudo."

  local requested_device="${1:-/dev/sda}"
  [[ -b "$requested_device" ]] ||
    die "Not a block device: $requested_device"

  local disk
  disk="$(readlink -f -- "$requested_device")"

  [[ "$(lsblk --nodeps --noheadings --output TYPE "$disk")" == "disk" ]] ||
    die "Target must be a whole disk, not a partition: $disk"

  # Refuse to erase a disk used by any mounted filesystem.
  local source
  while IFS= read -r source; do
    source="${source%%\[*}"
    [[ -b "$source" ]] || continue
    source="$(readlink -f -- "$source")"

    if lsblk --inverse --noheadings --raw --output PATH "$source" |
      grep --fixed-strings --line-regexp --quiet "$disk"; then
      die "A mounted filesystem uses $disk. Unmount it first."
    fi
  done < <(findmnt --raw --noheadings --output SOURCE)

  # Also refuse if a partition on this disk is active swap.
  local swap_device
  while IFS= read -r swap_device; do
    [[ -b "$swap_device" ]] || continue
    swap_device="$(readlink -f -- "$swap_device")"

    if lsblk --inverse --noheadings --raw --output PATH "$swap_device" |
      grep --fixed-strings --line-regexp --quiet "$disk"; then
      die "Active swap uses $disk. Disable that swap first."
    fi
  done < <(swapon --noheadings --show=NAME)

  printf '\nTarget device and current contents:\n'
  lsblk --output NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS \
    "$disk"

  local size_bytes
  size_bytes="$(blockdev --getsize64 "$disk")"

  printf '\nThis will overwrite all %s bytes on %s and erase its contents.\n' \
    "$size_bytes" "$disk"

  local confirmation
  read -r -p "Type exactly 'WIPE $disk' to continue: " confirmation
  [[ "$confirmation" == "WIPE $disk" ]] || die "Confirmation did not match."

  # GNU dd's count_bytes writes exactly the device's reported byte capacity.
  dd if=/dev/zero of="$disk" bs=16M count="$size_bytes" \
    iflag=count_bytes status=progress conv=fsync

  # Create a fresh GPT and one exFAT partition.
  parted --script "$disk" \
    mklabel gpt \
    mkpart DATA 1MiB 100%
  partprobe "$disk"
  udevadm settle

  local partition=""
  local row
  local -a device_rows
  mapfile -t device_rows < <(
    lsblk --list --noheadings --paths --raw --output PATH,TYPE "$disk"
  )

  for row in "${device_rows[@]}"; do
    local node type
    read -r node type <<< "$row"
    if [[ "$type" == "part" ]]; then
      partition="$node"
      break
    fi
  done

  [[ -b "$partition" ]] || die "The new partition device did not appear."

  mkfs.exfat -L DATA "$partition"
  sync

  printf '\nFinished. New Windows-compatible volume:\n'
  lsblk --fs "$disk"
}

main "$@"
