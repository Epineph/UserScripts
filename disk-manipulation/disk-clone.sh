#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# disk-clone : raw disk-to-disk cloning helper
#-------------------------------------------------------------------------------
# WARNING:
#   * This will overwrite the TARGET disk byte-for-byte with the SOURCE disk.
#   * All data on the TARGET disk will be IRREVERSIBLY destroyed.
#-------------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

SRC_DEV=""
DST_DEV=""
BLOCK_SIZE="64M"
TEST_ONLY=0
FORCE=0

SRC_NAME=""
DST_NAME=""

#-------------------------------------------------------------------------------
# Function: print_help
#-------------------------------------------------------------------------------
function print_help() {
	local pager

	pager="${HELP_PAGER:-less -R}"
	if ! command -v "${pager%% *}" >/dev/null 2>&1; then
		pager="cat"
	fi

	cat <<'EOF' | ${pager}
disk-clone - clone a whole disk onto another disk (raw byte copy)

Usage:
  disk-clone --source /dev/sdX --target /dev/sdY [options]
  disk-clone -s /dev/nvme0n1 -t /dev/nvme1n1

Options:
  -s, --source DEV   Source disk (TYPE=disk), e.g. /dev/sda.
  -t, --target DEV   Target disk (TYPE=disk), e.g. /dev/sdb.
                     This disk will be COMPLETELY OVERWRITTEN.
  --bs SIZE          Block size for dd (default: 64M).
                     Examples: 1M, 16M, 64M, 128M.
  --test-only        Show the planned dd command and device info, but do
                     NOT actually clone.
  --force            Skip interactive confirmations (dangerous).
  -h, --help         Show this help text.

What this script does:
  * Verifies both source and target are block devices.
  * Verifies both are *whole disks* (lsblk TYPE=disk), not partitions.
  * Refuses to run if source == target.
  * Refuses to run if any part of the TARGET disk is mounted.
  * Checks that TARGET size >= SOURCE size.
  * Shows lsblk details for both disks so you can visually confirm.
  * Runs a raw clone using:
      dd if=<SOURCE> of=<TARGET> bs=<BS> status=progress conv=fdatasync

What this script does NOT do:
  * No filesystem-level copying; this is block-level imaging.
  * No resizing of partitions or filesystems.
  * No integrity verification beyond dd returning success.
    (You can manually run: cmp(1) or checksums on partitions afterwards.)

Typical use cases:
  * Cloning a failing disk to a same-size or larger replacement disk.
  * Making an exact copy of a setup disk for reuse (same partition table,
    bootloader, filesystems, etc.).
EOF
}

#-------------------------------------------------------------------------------
# Function: ensure_root
#-------------------------------------------------------------------------------
function ensure_root() {
	local uid_val
	uid_val="${EUID:-$(id -u)}"

	if [ "$uid_val" -ne 0 ]; then
		echo "ERROR: This script must run as root." >&2
		echo "       Try: sudo $0 --source /dev/sdX --target /dev/sdY" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: parse_args
#-------------------------------------------------------------------------------
function parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-s | --source)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --source requires a device path (e.g. /dev/sda)." >&2
				exit 1
			fi
			SRC_DEV="$2"
			shift 2
			;;
		-t | --target)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --target requires a device path (e.g. /dev/sdb)." >&2
				exit 1
			fi
			DST_DEV="$2"
			shift 2
			;;
		--bs)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --bs requires a block size (e.g. 64M)." >&2
				exit 1
			fi
			BLOCK_SIZE="$2"
			shift 2
			;;
		--test-only)
			TEST_ONLY=1
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		-h | --help)
			print_help
			exit 0
			;;
		*)
			echo "ERROR: Unknown argument: $1" >&2
			echo >&2
			print_help
			exit 1
			;;
		esac
	done

	if [ "$SRC_DEV" = "" ] || [ "$DST_DEV" = "" ]; then
		echo "ERROR: --source and --target are both mandatory." >&2
		echo >&2
		print_help
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: validate_devices
#-------------------------------------------------------------------------------
function validate_devices() {
	if ! [ -b "$SRC_DEV" ]; then
		echo "ERROR: Source '${SRC_DEV}' is not a block device." >&2
		exit 1
	fi

	if ! [ -b "$DST_DEV" ]; then
		echo "ERROR: Target '${DST_DEV}' is not a block device." >&2
		exit 1
	fi

	if [ "$SRC_DEV" = "$DST_DEV" ]; then
		echo "ERROR: Source and target must not be the same device." >&2
		exit 1
	fi

	local src_type dst_type
	src_type="$(lsblk -dn -o TYPE "$SRC_DEV" 2>/dev/null || true)"
	dst_type="$(lsblk -dn -o TYPE "$DST_DEV" 2>/dev/null || true)"

	if [ "$src_type" != "disk" ]; then
		echo "ERROR: Source '${SRC_DEV}' is TYPE='${src_type}'. Expected TYPE=disk."
		echo "       This script only clones whole disks, not partitions." >&2
		exit 1
	fi

	if [ "$dst_type" != "disk" ]; then
		echo "ERROR: Target '${DST_DEV}' is TYPE='${dst_type}'. Expected TYPE=disk."
		echo "       This script only clones whole disks, not partitions." >&2
		exit 1
	fi

	SRC_NAME="$(basename "$SRC_DEV")"
	DST_NAME="$(basename "$DST_DEV")"
}

#-------------------------------------------------------------------------------
# Function: ensure_target_not_mounted
#-------------------------------------------------------------------------------
function ensure_target_not_mounted() {
	local mp
	if ! command -v lsblk >/dev/null 2>&1; then
		echo "WARNING: lsblk not available, cannot verify target mount state." >&2
		echo "         You MUST ensure nothing from ${DST_DEV} is mounted." >&2
		return
	fi

	mp="$(lsblk -pn -o MOUNTPOINT "$DST_DEV" 2>/dev/null |
		grep -v '^$' || true)"

	if [ "$mp" != "" ]; then
		echo "ERROR: Some part of ${DST_DEV} is mounted:" >&2
		echo "$mp" >&2
		echo "       Unmount all filesystems on the target disk first." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: get_size_bytes
#-------------------------------------------------------------------------------
function get_size_bytes() {
	local dev size

	dev="$1"

	if command -v blockdev >/dev/null 2>&1; then
		size="$(blockdev --getsize64 "$dev" 2>/dev/null || true)"
		if [ "$size" != "" ]; then
			printf '%s\n' "$size"
			return
		fi
	fi

	if command -v lsblk >/dev/null 2>&1; then
		size="$(lsblk -bn -o SIZE "$dev" 2>/dev/null | head -n 1 || true)"
		if [ "$size" != "" ]; then
			printf '%s\n' "$size"
			return
		fi
	fi

	echo "ERROR: Could not determine size of ${dev}." >&2
	exit 1
}

#-------------------------------------------------------------------------------
# Function: check_size_relationship
#-------------------------------------------------------------------------------
function check_size_relationship() {
	local src_size dst_size

	src_size="$(get_size_bytes "$SRC_DEV")"
	dst_size="$(get_size_bytes "$DST_DEV")"

	if [ "$src_size" = "" ] || [ "$dst_size" = "" ]; then
		echo "ERROR: Failed to retrieve source/target sizes." >&2
		exit 1
	fi

	if [ "$dst_size" -lt "$src_size" ]; then
		echo "ERROR: Target disk (${DST_DEV}) is smaller than source." >&2
		echo "       Source size : ${src_size} bytes" >&2
		echo "       Target size : ${dst_size} bytes" >&2
		echo "       Cloning would truncate data and corrupt the clone." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: show_overview
#-------------------------------------------------------------------------------
function show_overview() {
	echo "==================================================================="
	echo "disk-clone : overview"
	echo "==================================================================="
	echo
	echo "Source disk: ${SRC_DEV}"
	echo "Target disk: ${DST_DEV}"
	echo

	if command -v lsblk >/dev/null 2>&1; then
		echo "lsblk -d (source):"
		lsblk -d -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL "$SRC_DEV"
		echo
		echo "lsblk -d (target):"
		lsblk -d -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL "$DST_DEV"
		echo
		echo "lsblk (source tree):"
		lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$SRC_DEV"
		echo
		echo "lsblk (target tree):"
		lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$DST_DEV"
	else
		echo "lsblk not found; skipping detailed structure overview."
	fi
}

#-------------------------------------------------------------------------------
# Function: planned_command
#-------------------------------------------------------------------------------
function planned_command() {
	# Single dd with progress; fdatasync to flush at the end.
	printf 'dd if=%s of=%s bs=%s status=progress conv=fdatasync\n' \
		"$SRC_DEV" "$DST_DEV" "$BLOCK_SIZE"
}

#-------------------------------------------------------------------------------
# Function: confirm_or_abort
#-------------------------------------------------------------------------------
function confirm_or_abort() {
	local cmd answer confirm

	if [ "$FORCE" -eq 1 ]; then
		return
	fi

	cmd="$(planned_command)"

	echo
	echo "PLANNED CLONE COMMAND --------------------------------------------"
	echo "$cmd"
	echo
	echo "WARNING:"
	echo "  * This will CLONE ${SRC_DEV} onto ${DST_DEV}."
	echo "  * ALL existing data on ${DST_DEV} will be LOST."
	echo

	read -r -p "Type the full TARGET device path (${DST_DEV}) to confirm: " answer
	if [ "$answer" != "$DST_DEV" ]; then
		echo "Aborted: device path did not match ${DST_DEV}." >&2
		exit 1
	fi

	read -r -p "Final confirmation: type YES in uppercase: " confirm
	if [ "$confirm" != "YES" ]; then
		echo "Aborted: you did not type YES." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: run_clone
#-------------------------------------------------------------------------------
function run_clone() {
	local cmd

	cmd="$(planned_command)"

	echo
	echo "Executing disk clone:"
	echo "  ${cmd}"
	echo

	if [ "$TEST_ONLY" -eq 1 ]; then
		echo "(test-only): not actually running dd."
		return
	fi

	# shellcheck disable=SC2086
	dd if="$SRC_DEV" of="$DST_DEV" bs="$BLOCK_SIZE" status=progress \
		conv=fdatasync

	echo
	echo "Clone completed. Running sync..."
	sync || true
}

#-------------------------------------------------------------------------------
# Function: main
#-------------------------------------------------------------------------------
function main() {
	parse_args "$@"
	ensure_root
	validate_devices
	ensure_target_not_mounted
	check_size_relationship
	show_overview
	confirm_or_abort
	run_clone

	echo
	echo "Done. ${DST_DEV} is now a raw clone of ${SRC_DEV}."
	echo "If partition layout changed, you may need to run partprobe(8) or"
	echo "re-plug the disk so the kernel sees the updated partition table."
}

main "$@"
