#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# disk-wipe : destructive whole-disk erasure helper
#-------------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

TARGET_DEVICE=""
MODE="auto" # auto | zero | random | blkdiscard
TEST_ONLY=0 # if 1, print plan only
FORCE=0     # if 1, skip interactive confirmations

DISK_DEV=""
DISK_NAME=""

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
disk-wipe - irreversibly erase a whole disk (no partitions afterwards)

Usage:
  disk-wipe --target /dev/sdX [--mode auto|zero|random|blkdiscard]
            [--test-only] [--force]

Examples:
  # Show what WOULD be done, but do not actually erase:
  sudo disk-wipe -t /dev/sdb --mode auto --test-only

  # Actually erase with automatic choice (blkdiscard on SSD if possible,
  # dd if=/dev/zero on HDD otherwise), with interactive confirmation:
  sudo disk-wipe -t /dev/sdb --mode auto

  # Force wipe without questions (dangerous):
  sudo disk-wipe -t /dev/sdb --mode zero --force

Options:
  -t, --target       Whole-disk device to erase (e.g. /dev/sdb,
                     /dev/nvme0n1). Partitions (/dev/sdb1) are rejected.
  --mode auto        Default. Use blkdiscard on non-rotational media if
                     possible, otherwise write zeros with dd.
  --mode zero        Write zeros over the entire device via dd.
  --mode random      Write pseudorandom data over the entire device via dd.
                     Slow. Mostly overkill for modern drives.
  --mode blkdiscard  Use blkdiscard(8) to issue discard/TRIM for the whole
                     device. Supported mainly by SSDs and some virtual disks.
  --test-only        Print chosen commands but do NOT execute them.
  --force            Skip interactive prompt; proceed immediately.
  -h, --help         Show this help text.

What this does:
  * Verifies that the target is a *disk*, not a partition.
  * Shows lsblk(8) structure so you can visually verify you picked the
    correct disk.
  * Chooses a wipe method based on --mode (and rotational flag for auto).
  * Executes dd(1) or blkdiscard(8) accordingly.

What this does NOT do:
  * No partition table re-creation. After wiping, you must run parted,
    fdisk, or similar tools to create a new partition layout.
  * No real "repair" of bad sectors. If SMART and kernel logs show
    problems, the disk may simply be failing and should be replaced.

This script is for the situation: "we want to help a friend by nuking a
broken/confused disk and start fresh with a clean device."
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
		echo "       Try: sudo $0 --target /dev/sdX" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: parse_args
#-------------------------------------------------------------------------------
function parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-t | --target)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --target requires a device path (e.g. /dev/sdb)." >&2
				exit 1
			fi
			TARGET_DEVICE="$2"
			shift 2
			;;
		--mode)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --mode requires one of: auto, zero, random, blkdiscard." >&2
				exit 1
			fi
			MODE="$2"
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

	if [ "$TARGET_DEVICE" = "" ]; then
		echo "ERROR: --target /dev/XYZ is mandatory." >&2
		echo >&2
		print_help
		exit 1
	fi

	case "$MODE" in
	auto | zero | random | blkdiscard) ;;
	*)
		echo "ERROR: Invalid --mode '${MODE}'. Use auto|zero|random|blkdiscard." >&2
		exit 1
		;;
	esac
}

#-------------------------------------------------------------------------------
# Function: resolve_disk_and_validate
#   - Ensure the target is a disk, not a partition.
#-------------------------------------------------------------------------------
function resolve_disk_and_validate() {
	local dev type

	dev="$TARGET_DEVICE"

	if ! [ -b "$dev" ]; then
		echo "ERROR: '${dev}' is not a block device." >&2
		exit 1
	fi

	type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"

	if [ "$type" != "disk" ]; then
		echo "ERROR: '${dev}' is type '${type}'. This script only accepts" >&2
		echo "       whole disks (TYPE=disk), not partitions or LVs." >&2
		exit 1
	fi

	DISK_DEV="$dev"
	DISK_NAME="$(basename "$DISK_DEV")"
}

#-------------------------------------------------------------------------------
# Function: show_device_overview
#-------------------------------------------------------------------------------
function show_device_overview() {
	echo "==================================================================="
	echo "About to ERASE disk: ${DISK_DEV}"
	echo "==================================================================="
	echo

	if command -v lsblk >/dev/null 2>&1; then
		echo "lsblk (device-only):"
		lsblk -d -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL "$DISK_DEV"
		echo
		echo "lsblk (full tree, children if any):"
		lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$DISK_DEV"
	else
		echo "lsblk not found; cannot show block device structure."
	fi
}

#-------------------------------------------------------------------------------
# Function: get_rotational_flag
#-------------------------------------------------------------------------------
function get_rotational_flag() {
	local sys_path rotational
	sys_path="/sys/block/${DISK_NAME}/queue/rotational"

	if [ -r "$sys_path" ]; then
		rotational="$(cat "$sys_path")"
		echo "$rotational"
	else
		echo "unknown"
	fi
}

#-------------------------------------------------------------------------------
# Function: decide_wipe_command
#   Outputs the actual command line that will be used to stdout.
#-------------------------------------------------------------------------------
function decide_wipe_command() {
	local chosen mode rot

	mode="$MODE"

	if [ "$mode" = "auto" ]; then
		rot="$(get_rotational_flag)"
		if [ "$rot" = "0" ] && command -v blkdiscard >/dev/null 2>&1; then
			mode="blkdiscard"
		else
			mode="zero"
		fi
	fi

	case "$mode" in
	zero)
		chosen="dd if=/dev/zero of=${DISK_DEV} bs=16M status=progress \
conv=fdatasync"
		;;
	random)
		chosen="dd if=/dev/urandom of=${DISK_DEV} bs=8M status=progress \
conv=fdatasync"
		;;
	blkdiscard)
		chosen="blkdiscard -v ${DISK_DEV}"
		;;
	*)
		echo "BUG: unexpected mode '${mode}' in decide_wipe_command" >&2
		exit 1
		;;
	esac

	printf '%s\n' "$chosen"
}

#-------------------------------------------------------------------------------
# Function: confirm_or_abort
#-------------------------------------------------------------------------------
function confirm_or_abort() {
	local cmd answer confirm

	if [ "$FORCE" -eq 1 ]; then
		return
	fi

	cmd="$(decide_wipe_command)"

	echo
	echo "PLANNED ERASE COMMAND --------------------------------------------"
	echo "$cmd"
	echo
	echo "WARNING: This will IRREVERSIBLY destroy ALL data on ${DISK_DEV}."
	echo "         Double-check you selected the correct disk."
	echo

	read -r -p "Type the full device path (${DISK_DEV}) to confirm: " answer
	if [ "$answer" != "$DISK_DEV" ]; then
		echo "Aborted: device path did not match." >&2
		exit 1
	fi

	read -r -p "Final confirmation: type YES in uppercase: " confirm
	if [ "$confirm" != "YES" ]; then
		echo "Aborted: you did not type YES." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: run_wipe
#-------------------------------------------------------------------------------
function run_wipe() {
	local cmd

	cmd="$(decide_wipe_command)"

	echo
	echo "Executing wipe with mode='${MODE}' on ${DISK_DEV}"
	echo "Command:"
	echo "  ${cmd}"
	echo

	if [ "$TEST_ONLY" -eq 1 ]; then
		echo "(test-only): not actually executing command."
		return
	fi

	# shellcheck disable=SC2086
	eval "$cmd"
}

#-------------------------------------------------------------------------------
# Function: main
#-------------------------------------------------------------------------------
function main() {
	parse_args "$@"
	ensure_root
	resolve_disk_and_validate
	show_device_overview
	confirm_or_abort
	run_wipe

	echo
	echo "Done. ${DISK_DEV} has been wiped according to the selected mode."
	echo "Next steps (manual):"
	echo "  * Use parted/fdisk/gdisk/GParted to create a new partition table."
	echo "  * Create filesystems and restore data as needed."
}

main "$@"
