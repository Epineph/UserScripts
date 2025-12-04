#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# disk-overview : structural + high-level contents overview for a disk/partition
#-------------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

TARGET_DEVICE=""
AUTO_MOUNT_RO=0
MAX_ENTRIES=20

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
disk-overview - inspect a disk's layout and give a high-level overview
of its contents (directory tops of mounted filesystems).

Usage:
  disk-overview --target /dev/sdX [options]
  disk-overview -t /dev/nvme0n1
  disk-overview -t /dev/sda1 --max-entries 30

Options:
  -t, --target       Block device (disk or partition) to inspect.
  --auto-mount-ro    Attempt to read-only mount UNmounted partitions
                     under /mnt/disk-overview-<name>-<n> and show a top
                     directory listing. Only basic filesystems are
                     attempted (ext*, xfs, btrfs, vfat, ntfs).
  --max-entries N    Limit number of directory entries listed per
                     mountpoint (default: 20).
  -h, --help         Show this help text.

What it does (read-only by default):
  * Resolves /dev/sdX vs /dev/sdXN (partition) to the parent disk.
  * Shows lsblk(8) layout with filesystem types, labels, UUIDs.
  * Shows blkid(8) info for the disk and its partitions.
  * Shows df -h(1) usage for filesystems on this disk.
  * For each mounted filesystem on this disk, shows the top-level
    directory listing (up to --max-entries per mountpoint).

If --auto-mount-ro is given:
  * Partitions on the disk that are not currently mounted will be
    read-only mounted under /mnt/disk-overview-<NAME>-<index>.
  * These temporary mountpoints are left in place intentionally, so
    you can inspect them further if desired.

Notes:
  - Run as root to avoid permission-related blind spots.
  - This script does not modify data unless you explicitly mount
    things read-only with --auto-mount-ro, which is still non-
    destructive.
EOF
}

#-------------------------------------------------------------------------------
# Function: warn_if_not_root
#-------------------------------------------------------------------------------
function warn_if_not_root() {
	local uid_val
	uid_val="${EUID:-$(id -u)}"

	if [ "$uid_val" -ne 0 ]; then
		echo "WARNING: Not running as root. Some information may be incomplete" >&2
		echo "         (blkid details, unreadable directories, etc.)." >&2
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
				echo "ERROR: --target requires a device path (e.g. /dev/sda)." >&2
				exit 1
			fi
			TARGET_DEVICE="$2"
			shift 2
			;;
		--auto-mount-ro)
			AUTO_MOUNT_RO=1
			shift
			;;
		--max-entries)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --max-entries requires an integer." >&2
				exit 1
			fi
			MAX_ENTRIES="$2"
			shift 2
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
}

#-------------------------------------------------------------------------------
# Function: resolve_disk_device
#   If TARGET_DEVICE is a partition, resolve its parent disk.
#-------------------------------------------------------------------------------
function resolve_disk_device() {
	local dev pk

	dev="$TARGET_DEVICE"

	if ! [ -b "$dev" ]; then
		echo "ERROR: '${dev}' is not a block device." >&2
		exit 1
	fi

	pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n 1 || true)"

	if [ "$pk" != "" ]; then
		DISK_DEV="/dev/${pk}"
	else
		DISK_DEV="$dev"
	fi

	DISK_NAME="$(basename "$DISK_DEV")"
}

#-------------------------------------------------------------------------------
# Function: show_lsblk_structure
#-------------------------------------------------------------------------------
function show_lsblk_structure() {
	echo "==================================================================="
	echo "Block device structure for: ${DISK_DEV}"
	echo "==================================================================="
	echo

	if command -v lsblk >/dev/null 2>&1; then
		echo "lsblk (device tree):"
		lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$DISK_DEV"
	else
		echo "lsblk not found; cannot show block device layout."
	fi
}

#-------------------------------------------------------------------------------
# Function: show_blkid
#-------------------------------------------------------------------------------
function show_blkid() {
	if ! command -v blkid >/dev/null 2>&1; then
		echo
		echo "blkid not found; filesystem label/UUID scan skipped."
		return
	fi

	echo
	echo "blkid filesystem signatures --------------------------------------"
	local name dev
	while read -r name; do
		dev="/dev/${name}"
		blkid "$dev" 2>/dev/null || true
	done < <(lsblk -ln -o NAME "$DISK_DEV")
}

#-------------------------------------------------------------------------------
# Function: show_df_usage
#-------------------------------------------------------------------------------
function show_df_usage() {
	echo
	echo "Filesystem usage (df -h) for this disk ---------------------------"

	if ! command -v df >/dev/null 2>&1; then
		echo "df(1) not found; usage information skipped."
		return
	fi

	local names pattern

	# Build regex of /dev/<name> for all names on this disk
	names="$(lsblk -ln -o NAME "$DISK_DEV" | tr '\n' ' ' | sed 's/ $//')"
	if [ "$names" = "" ]; then
		echo "(no sub-devices found by lsblk)"
		return
	fi

	pattern=""
	local n
	for n in "$names"; do
		pattern="${pattern}^/dev/${n}$|"
	done
	pattern="${pattern%|}"

	df -h | awk -v pat="$pattern" 'NR==1 || $1 ~ pat'
}

#-------------------------------------------------------------------------------
# Function: show_top_directories_mounted
#-------------------------------------------------------------------------------
function show_top_directories_mounted() {
	echo
	echo "Top-level directory listing for mounted filesystems --------------"

	local line dev mp
	local found=0

	while read -r line; do
		dev="${line%% *}"
		mp="${line#* }"
		if [ "$mp" = "" ] || [ "$mp" = "-" ]; then
			continue
		fi

		found=1
		echo
		echo ">>> ${dev} mounted on ${mp}"
		if [ -r "$mp" ]; then
			ls -A "$mp" 2>/dev/null | head -n "$MAX_ENTRIES" ||
				echo "(ls failed for ${mp})"
		else
			echo "(no read permission for ${mp})"
		fi
	done < <(lsblk -pn -o NAME,MOUNTPOINTS "$DISK_DEV" |
		awk '$2!="" {print $1" "$2}')

	if [ "$found" -eq 0 ]; then
		echo "(no filesystems from this disk are currently mounted)"
	fi
}

#-------------------------------------------------------------------------------
# Function: auto_mount_unmounted_ro
#-------------------------------------------------------------------------------
function auto_mount_unmounted_ro() {
	if [ "$AUTO_MOUNT_RO" -eq 0 ]; then
		return
	fi

	if ! command -v mount >/dev/null 2>&1; then
		echo
		echo "mount(8) not found; cannot auto-mount partitions read-only."
		return
	fi

	echo
	echo "Read-only mounting unmounted partitions --------------------------"

	local idx=1
	local name fstype mp dev mountpoint

	while read -r name fstype mp; do
		dev="/dev/${name}"

		# Skip already mounted
		if [ "$mp" != "" ] && [ "$mp" != "-" ]; then
			continue
		fi

		# Skip partitions without a recognizable filesystem type
		case "$fstype" in
		ext2 | ext3 | ext4 | xfs | btrfs | vfat | fat | fat32 | ntfs | ntfs3) ;;
		*)
			continue
			;;
		esac

		mountpoint="/mnt/disk-overview-${DISK_NAME}-${idx}"
		idx=$((idx + 1))

		mkdir -p "$mountpoint"
		echo "Mounting ${dev} (${fstype}) read-only on ${mountpoint}"
		if mount -o ro "$dev" "$mountpoint"; then
			:
		else
			echo "  -> mount failed for ${dev}, cleaning ${mountpoint}"
			rmdir "$mountpoint" 2>/dev/null || true
		fi
	done < <(lsblk -ln -o NAME,FSTYPE,MOUNTPOINT "$DISK_DEV")
}

#-------------------------------------------------------------------------------
# Function: show_top_directories_auto_mounts
#-------------------------------------------------------------------------------
function show_top_directories_auto_mounts() {
	if [ "$AUTO_MOUNT_RO" -eq 0 ]; then
		return
	fi

	echo
	echo "Top-level directories for auto-mounted partitions ----------------"

	local dir
	for dir in /mnt/disk-overview-"$DISK_NAME"-*; do
		if [ ! -d "$dir" ]; then
			continue
		fi
		echo
		echo ">>> ${dir}"
		ls -A "$dir" 2>/dev/null | head -n "$MAX_ENTRIES" ||
			echo "(ls failed for ${dir})"
	done
}

#-------------------------------------------------------------------------------
# Function: main
#-------------------------------------------------------------------------------
function main() {
	parse_args "$@"
	warn_if_not_root
	resolve_disk_device
	show_lsblk_structure
	show_blkid
	show_df_usage
	show_top_directories_mounted
	auto_mount_unmounted_ro
	show_top_directories_auto_mounts

	echo
	echo "Summary:"
	echo "  * Above you have the on-disk partition layout (lsblk)."
	echo "  * Filesystem signatures and UUIDs (blkid)."
	echo "  * Actual space usage (df -h)."
	echo "  * High-level directory contents per mountpoint."
	[ "$AUTO_MOUNT_RO" -eq 1 ] &&
		echo "  * Some partitions have been read-only mounted under /mnt."
}

main "$@"
