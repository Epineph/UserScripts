#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# mount-shared-ntfs: mount an NTFS partition and optionally add it to /etc/fstab
# ---------------------------------------------------------------------------

DEFAULT_MOUNTPOINT="/shared"
FSTAB_FILE="/etc/fstab"
NTFS_OPTS="rw,relatime,uid=1000,gid=1000,dmask=0022,fmask=0022,iocharset=utf8"

function usage() {
  cat <<EOF
mount-shared-ntfs - mount an NTFS partition and optionally update /etc/fstab

Usage:
  mount-shared-ntfs <partition> [mountpoint]

Arguments:
  partition    Block device (e.g. /dev/nvme0n1p5, /dev/sda5) to mount.
  mountpoint   Where to mount it (default: ${DEFAULT_MOUNTPOINT})

Behavior:
  - Detects UUID of the given partition via blkid.
  - Creates the mountpoint directory if needed.
  - Mounts using:
      -t ntfs -o "${NTFS_OPTS}"
  - Then offers to append a matching line to ${FSTAB_FILE} of the form:
      UUID=<uuid>  <mountpoint>  ntfs  ${NTFS_OPTS}  0  0
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PART="${1:-}"
MNT="${2:-$DEFAULT_MOUNTPOINT}"

[[ -n "$PART" ]] || die "No partition given. Try: mount-shared-ntfs /dev/nvme0n1p5 /shared"
[[ -b "$PART" ]] || die "Partition '$PART' is not a block device."

# Grab UUID
UUID="$(blkid -s UUID -o value "$PART" 2>/dev/null || true)"
[[ -n "$UUID" ]] || die "Could not detect UUID for $PART (blkid returned nothing)."

# Create mountpoint if needed
if [[ ! -d "$MNT" ]]; then
  echo "Creating mountpoint: $MNT"
  sudo mkdir -p "$MNT"
fi

# Mount with NTFS options
echo "Mounting UUID=${UUID} on ${MNT} (ntfs, ${NTFS_OPTS})"
sudo mount -t ntfs -o "${NTFS_OPTS}" "UUID=${UUID}" "$MNT"

# Offer to append to /etc/fstab
echo
echo "Mounted successfully."
read -r -p "Append entry to ${FSTAB_FILE}? [y/N] " ans

case "$ans" in
  [Yy]*)
    FSTAB_LINE="UUID=${UUID}  ${MNT}  ntfs  ${NTFS_OPTS}  0  0"
    echo "Appending to ${FSTAB_FILE}:"
    echo "  ${FSTAB_LINE}"
    printf '%s\n' "$FSTAB_LINE" | sudo tee -a "$FSTAB_FILE" >/dev/null
    echo "Done."
    ;;
  *)
    echo "Skipping ${FSTAB_FILE} modification."
    ;;
esac
