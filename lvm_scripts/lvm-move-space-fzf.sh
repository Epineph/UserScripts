#!/usr/bin/env bash
# lvm-move-space-fzf.sh — interactively shrink one ext4 LV and extend another.
#
# This will:
#   1) Let you pick a source LV (to shrink) via fzf.
#   2) Let you pick a destination LV (to extend) via fzf.
#   3) Move DELTA_GIB GiB from SRC to DST within the *same* VG.
#
# WARNING:
#   - EXTREMELY DESTRUCTIVE if misused.
#   - Only ext4 filesystems supported.
#   - Both SRC and DST must be UNMOUNTED.
#   - Run preferably from a live USB / rescue env.
#
# Example:
#   sudo ./lvm-move-space-fzf.sh

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

# ────────────────────────── Helpers / usage ──────────────────────────

function usage() {
  cat <<EOF
$SCRIPT_NAME — interactively move space between ext4 LVs in the same VG.

Usage:
  sudo $SCRIPT_NAME

Requirements:
  - Run as root.
  - lvm2 tools: lvs, lvextend, lvreduce, vgchange, etc.
  - ext4 filesystems only.
  - fzf must be installed.
  - Source LV (shrink) must be UNMOUNTED.
  - Destination LV (extend) must be UNMOUNTED.

The script will:
  1) Show all logical volumes via fzf.
  2) Ask you to select the LV to SHRINK.
  3) Ask for how many GiB to move.
  4) Ask you to select the LV to EXTEND (must be same VG).
  5) Perform:

       e2fsck + resize2fs + lvreduce on SRC
       lvextend + e2fsck + resize2fs on DST

Backup before use.
EOF
}

function require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo)." >&2
    exit 1
  fi
}

function require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: required command '$cmd' not found in PATH." >&2
      exit 1
    fi
  done
}

# Select LV using fzf. Outputs: "VG LV SIZE_G LV_ATTR"
function select_lv() {
  local prompt="$1"
  local line

  line="$(
    lvs --noheadings --units g --separator ' ' \
      -o vg_name,lv_name,lv_size,lv_attr |
      sed 's/^[[:space:]]*//' |
      fzf --prompt="$prompt " --height=20 --border
  )"

  if [[ -z "$line" ]]; then
    echo "No LV selected. Aborting." >&2
    exit 1
  fi

  echo "$line"
}

# ─────────────────────────── Main logic ──────────────────────────────

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_root
require_cmd lvs blkid findmnt e2fsck resize2fs lvextend lvreduce fzf

echo "Activating volume groups (vgchange -ay)..."
vgchange -ay >/dev/null

echo
echo "=== Select source LV (to SHRINK) ==="
SRC_LINE="$(select_lv "Shrink LV >")"
SRC_VG="$(awk '{print $1}' <<<"$SRC_LINE")"
SRC_LV_NAME="$(awk '{print $2}' <<<"$SRC_LINE")"
SRC_LV="/dev/${SRC_VG}/${SRC_LV_NAME}"

SRC_SIZE_GIB="$(
  lvs --noheadings --units g --nosuffix -o LV_SIZE "$SRC_LV" |
    awk '{print int($1)}'
)"

SRC_FS_TYPE="$(blkid -o value -s TYPE "$SRC_LV" || true)"

echo
echo "Selected SRC LV: $SRC_LV"
echo "  Size: ${SRC_SIZE_GIB}G"
echo "  FS:   ${SRC_FS_TYPE:-unknown}"

if [[ "$SRC_FS_TYPE" != "ext4" ]]; then
  echo "Error: source LV filesystem is not ext4 (found: $SRC_FS_TYPE)." >&2
  exit 1
fi

if findmnt "$SRC_LV" >/dev/null 2>&1; then
  echo "Error: source LV '$SRC_LV' is mounted. Unmount it first." >&2
  exit 1
fi

echo
read -r -p "How many GiB do you want to move *from* this LV? " DELTA_GIB

if ! [[ "$DELTA_GIB" =~ ^[0-9]+$ ]]; then
  echo "Error: DELTA_GIB must be a positive integer." >&2
  exit 1
fi

if ((DELTA_GIB <= 0)); then
  echo "Error: DELTA_GIB must be > 0." >&2
  exit 1
fi

NEW_SRC_GIB=$((SRC_SIZE_GIB - DELTA_GIB))

if ((NEW_SRC_GIB <= 0)); then
  echo "Error: resulting source LV size would be <= 0 GiB. Aborting." >&2
  exit 1
fi

echo
echo "=== Select destination LV (to EXTEND) ==="
DST_LINE="$(select_lv "Extend LV >")"
DST_VG="$(awk '{print $1}' <<<"$DST_LINE")"
DST_LV_NAME="$(awk '{print $2}' <<<"$DST_LINE")"
DST_LV="/dev/${DST_VG}/${DST_LV_NAME}"

DST_FS_TYPE="$(blkid -o value -s TYPE "$DST_LV" || true)"

echo
echo "Selected DST LV: $DST_LV"
echo "  FS: ${DST_FS_TYPE:-unknown}"

if [[ "$DST_FS_TYPE" != "ext4" ]]; then
  echo "Error: destination LV filesystem is not ext4 (found: $DST_FS_TYPE)." >&2
  exit 1
fi

if findmnt "$DST_LV" >/dev/null 2>&1; then
  echo "Error: destination LV '$DST_LV' is mounted. Unmount it first." >&2
  exit 1
fi

if [[ "$SRC_VG" != "$DST_VG" ]]; then
  echo "Error: SRC and DST must be in the same VG." >&2
  echo "  SRC VG: $SRC_VG"
  echo "  DST VG: $DST_VG"
  exit 1
fi

echo
echo "Planned operation:"
echo "  - Shrink $SRC_LV: ${SRC_SIZE_GIB}G → ${NEW_SRC_GIB}G"
echo "  - Extend $DST_LV by ${DELTA_GIB}G"
echo
echo "IMPORTANT:"
echo "  Ensure that USED space on $SRC_LV is < ${NEW_SRC_GIB}G."
echo "  This script does NOT verify usage; that's your responsibility."
echo
read -r -p "Type 'YES' to proceed: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborting."
  exit 1
fi

# ───────────────── Shrink source LV + filesystem ─────────────────────

echo
echo "Running e2fsck on SRC_LV ($SRC_LV)..."
e2fsck -f "$SRC_LV"

echo "Shrinking SRC filesystem to ${NEW_SRC_GIB}G..."
resize2fs "$SRC_LV" "${NEW_SRC_GIB}G"

echo "Reducing LV size to ${NEW_SRC_GIB}G..."
lvreduce -L "${NEW_SRC_GIB}G" "$SRC_LV" -y

# ───────────────── Extend destination LV + filesystem ─────────────────

echo
echo "Extending DST_LV ($DST_LV) by ${DELTA_GIB}G..."
lvextend -L +"${DELTA_GIB}G" "$DST_LV" -y

echo "Running e2fsck on DST_LV ($DST_LV)..."
e2fsck -f "$DST_LV"

echo "Growing DST filesystem to fill LV..."
resize2fs "$DST_LV"

echo
echo "Done. New LV sizes:"
lvs -o vg_name,lv_name,lv_size "$SRC_LV" "$DST_LV"
