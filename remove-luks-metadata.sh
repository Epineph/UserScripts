#!/usr/bin/env bash
set -euo pipefail

# ---- show help -----------------------------------------------------

function show_help() {
	cat <<'EOF'
Usage:
  remove-luks-metadata.sh <block-device>

Description:
  Safely destroys LUKS primary and secondary metadata by overwriting
  the first and last 16 MiB of a block device.

Arguments:
  <block-device>   Raw device or partition (e.g. /dev/sdX or /dev/sdX1)

Options:
  -h, --help       Show this help and exit

WARNING:
  This operation is destructive and irreversible.
EOF
}

# ---- argument handling ---------------------------------------------

case "${1:-}" in
"" | -h | --help)
	show_help
	exit 0
	;;
esac

target_device="$1"

if [[ ! -b "$target_device" ]]; then
	echo "Error: '$target_device' is not a block device" >&2
	show_help
	exit 1
fi

# --- require root ----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." >&2
	exit 1
fi

# --- arguments -------------------------------------------------------
target_device="${1:-}"

if [[ -z "$target_device" ]]; then
	echo "Usage: $0 /dev/sdX or /dev/sdXn" >&2
	exit 1
fi

if [[ ! -b "$target_device" ]]; then
	echo "Error: $target_device is not a block device" >&2
	exit 1
fi

# --- detect LUKS before wipe ----------------------------------------
HAS_LUKS=0
if cryptsetup luksDump "$target_device" &>/dev/null; then
	HAS_LUKS=1
	echo "Detected existing LUKS metadata"
else
	echo "No LUKS metadata detected (defensive wipe)"
fi

# --- size calculations ----------------------------------------------
WIPE_MB=16
SECTORS_PER_MB=$((1024 * 1024 / 512)) # 2048
WIPE_SECTORS=$((WIPE_MB * SECTORS_PER_MB))

END=$(blockdev --getsz "$target_device")

if ((END <= WIPE_SECTORS * 2)); then
	echo "Error: device too small to safely wipe metadata" >&2
	exit 1
fi

SEEK=$((END - WIPE_SECTORS))

# --- wipe primary header --------------------------------------------
dd if=/dev/zero of="$target_device" \
	bs=1M count="$WIPE_MB" \
	conv=fdatasync status=progress

# --- wipe secondary header ------------------------------------------
dd if=/dev/zero of="$target_device" \
	bs=512 seek="$SEEK" count="$WIPE_SECTORS" \
	conv=fdatasync status=progress

# --- verify ----------------------------------------------------------
if ((HAS_LUKS)); then
	if cryptsetup luksDump "$target_device" &>/dev/null; then
		echo "ERROR: LUKS metadata still present after wipe" >&2
	else
		echo "LUKS metadata successfully destroyed"
	fi
else
	echo "Verification skipped (no LUKS detected initially)"
fi
