#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# disk-clone : raw cloning and imaging helper
#-------------------------------------------------------------------------------
# MODES:
#   1) Disk -> Disk
#      -s /dev/src  -t /dev/dst
#
#   2) Disk -> Image (optionally compressed)
#      -s /dev/src  --to-image /path/image.img[.gz/.xz/.zst]
#
#   3) Image -> Disk (optionally compressed)
#      --from-image /path/image.img[.gz/.xz/.zst]  -t /dev/dst
#
# WARNING:
#   * Any mode that writes to a disk DESTROYS existing data on that disk.
#   * Use --test-only to see the planned command without doing anything.
#-------------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

SRC_DEV=""
DST_DEV=""
TO_IMAGE=""
FROM_IMAGE=""
BLOCK_SIZE="64M"
TEST_ONLY=0
FORCE=0
COMPRESS=""   # none|gzip|xz|zstd (for disk -> image)
DECOMPRESS="" # none|gzip|xz|zstd (for image -> disk, optional)
MODE=""       # disk_to_disk | disk_to_image | image_to_disk

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
disk-clone - clone disks, create disk images, and restore from images

Usage (disk -> disk):
  disk-clone --source /dev/sdX --target /dev/sdY [--bs 64M] [--test-only]

Usage (disk -> image):
  disk-clone --source /dev/sdX --to-image /path/disk.img
  disk-clone --source /dev/sdX --to-image /path/disk.img.gz \
             --compress gzip

Usage (image -> disk):
  disk-clone --from-image /path/disk.img --target /dev/sdY
  disk-clone --from-image /path/disk.img.gz --target /dev/sdY \
             --decompress gzip

Options:
  -s, --source DEV     Source disk (TYPE=disk), e.g. /dev/sda.
  -t, --target DEV     Target disk (TYPE=disk), e.g. /dev/sdb.
                       Destructive in disk->disk and image->disk modes.
  --to-image PATH      Create an image from a source disk at PATH.
                       If PATH ends with .gz/.xz/.zst, compression is
                       auto-detected unless --compress is given.
  --from-image PATH    Restore an image file PATH to a target disk.
                       Compression is auto-detected from extension
                       unless --decompress is given.
  --compress TYPE      Compression for disk->image:
                         TYPE in: none, gzip, xz, zstd
  --decompress TYPE    Decompression for image->disk:
                         TYPE in: none, gzip, xz, zstd
  --bs SIZE            Block size for dd (default: 64M).
  --test-only          Print planned command(s), do not execute.
  --force              Skip interactive confirmations (dangerous).
  -h, --help           Show this help text.

Modes:
  1) Disk -> Disk:
       -s /dev/src -t /dev/dst
     * Byte-for-byte clone with dd.
  2) Disk -> Image:
       -s /dev/src --to-image /path.img[.gz/.xz/.zst]
     * Creates a raw or compressed disk image.
  3) Image -> Disk:
       --from-image /path.img[.gz/.xz/.zst] -t /dev/dst
     * Restores a raw or compressed disk image to a disk.

Notes:
  * Disks must be whole disks (TYPE=disk), not partitions.
  * Target disks must be unmounted.
  * For disk->disk, the target must be at least as large as the source.
  * For images:
      - Raw images (.img, no compression) are simple dd snapshots.
      - Compressed images are raw images piped through gzip/xz/zstd.
  * You can absolutely restore a compressed image later to another
    disk of equal or greater size: that is the point of this script.
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
		echo "       Try: sudo $0 ..." >&2
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
				echo "ERROR: --source requires a device path." >&2
				exit 1
			fi
			SRC_DEV="$2"
			shift 2
			;;
		-t | --target)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --target requires a device path." >&2
				exit 1
			fi
			DST_DEV="$2"
			shift 2
			;;
		--to-image)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --to-image requires a file path." >&2
				exit 1
			fi
			TO_IMAGE="$2"
			shift 2
			;;
		--from-image)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --from-image requires a file path." >&2
				exit 1
			fi
			FROM_IMAGE="$2"
			shift 2
			;;
		--compress)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --compress requires: none|gzip|xz|zstd." >&2
				exit 1
			fi
			COMPRESS="$2"
			shift 2
			;;
		--decompress)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --decompress requires: none|gzip|xz|zstd." >&2
				exit 1
			fi
			DECOMPRESS="$2"
			shift 2
			;;
		--bs)
			if [ "$#" -lt 2 ]; then
				echo "ERROR: --bs requires a block size, e.g. 64M." >&2
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
}

#-------------------------------------------------------------------------------
# Function: normalize_compression
#-------------------------------------------------------------------------------
function normalize_compression() {
	local val="$1"
	case "$val" in
	"")
		echo ""
		;;
	none | NONE)
		echo "none"
		;;
	gzip | GZIP)
		echo "gzip"
		;;
	xz | XZ)
		echo "xz"
		;;
	zstd | ZSTD)
		echo "zstd"
		;;
	*)
		echo "ERROR: Invalid compression type '${val}'." >&2
		exit 1
		;;
	esac
}

#-------------------------------------------------------------------------------
# Function: auto_detect_compression_by_extension
#-------------------------------------------------------------------------------
function auto_detect_compression_by_extension() {
	local path="$1"
	case "$path" in
	*.gz)
		echo "gzip"
		;;
	*.xz)
		echo "xz"
		;;
	*.zst | *.zstd)
		echo "zstd"
		;;
	*)
		echo "none"
		;;
	esac
}

#-------------------------------------------------------------------------------
# Function: determine_mode_and_check_combos
#-------------------------------------------------------------------------------
function determine_mode_and_check_combos() {
	# Normalize compression flags
	COMPRESS="$(normalize_compression "$COMPRESS")"
	DECOMPRESS="$(normalize_compression "$DECOMPRESS")"

	if [ "$TO_IMAGE" != "" ] && [ "$FROM_IMAGE" != "" ]; then
		echo "ERROR: Use either --to-image or --from-image, not both." >&2
		exit 1
	fi

	if [ "$TO_IMAGE" != "" ]; then
		# Disk -> Image
		if [ "$SRC_DEV" = "" ]; then
			echo "ERROR: Disk->image mode requires --source /dev/XYZ." >&2
			exit 1
		fi
		if [ "$DST_DEV" != "" ]; then
			echo "ERROR: Disk->image mode must NOT have a target disk." >&2
			exit 1
		fi
		MODE="disk_to_image"
		if [ "$COMPRESS" = "" ]; then
			COMPRESS="$(auto_detect_compression_by_extension "$TO_IMAGE")"
		fi
		return
	fi

	if [ "$FROM_IMAGE" != "" ]; then
		# Image -> Disk
		if [ "$DST_DEV" = "" ]; then
			echo "ERROR: Image->disk mode requires --target /dev/XYZ." >&2
			exit 1
		fi
		if [ "$SRC_DEV" != "" ]; then
			echo "ERROR: Image->disk mode must NOT have a source disk." >&2
			exit 1
		fi
		MODE="image_to_disk"
		if [ "$DECOMPRESS" = "" ]; then
			DECOMPRESS="$(auto_detect_compression_by_extension "$FROM_IMAGE")"
		fi
		return
	fi

	# Disk -> Disk
	if [ "$SRC_DEV" = "" ] || [ "$DST_DEV" = "" ]; then
		echo "ERROR: Disk->disk mode needs both --source and --target." >&2
		echo "       For images, use --to-image or --from-image." >&2
		exit 1
	fi
	MODE="disk_to_disk"
}

#-------------------------------------------------------------------------------
# Function: validate_disk_device
#-------------------------------------------------------------------------------
function validate_disk_device() {
	local dev="$1"
	local role="$2" # "source" or "target"
	local type

	if ! [ -b "$dev" ]; then
		echo "ERROR: ${role} '${dev}' is not a block device." >&2
		exit 1
	fi

	type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
	if [ "$type" != "disk" ]; then
		echo "ERROR: ${role} '${dev}' is TYPE='${type}'. Expected TYPE='disk'." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: ensure_target_not_mounted
#-------------------------------------------------------------------------------
function ensure_target_not_mounted() {
	local dev="$1"
	local mp

	if ! command -v lsblk >/dev/null 2>&1; then
		echo "WARNING: lsblk not available, cannot verify target mount state." >&2
		echo "         YOU must ensure nothing on ${dev} is mounted." >&2
		return
	fi

	mp="$(lsblk -pn -o MOUNTPOINT "$dev" 2>/dev/null |
		grep -v '^$' || true)"
	if [ "$mp" != "" ]; then
		echo "ERROR: Some part of ${dev} is mounted:" >&2
		echo "$mp" >&2
		echo "       Unmount everything on the target disk first." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: get_size_bytes
#-------------------------------------------------------------------------------
function get_size_bytes() {
	local dev="$1"
	local size

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
# Function: check_size_relationship_disk_to_disk
#-------------------------------------------------------------------------------
function check_size_relationship_disk_to_disk() {
	local src_size dst_size

	src_size="$(get_size_bytes "$SRC_DEV")"
	dst_size="$(get_size_bytes "$DST_DEV")"

	if [ "$dst_size" -lt "$src_size" ]; then
		echo "ERROR: Target disk is smaller than source disk." >&2
		echo "       Source: ${src_size} bytes" >&2
		echo "       Target: ${dst_size} bytes" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: check_image_exists_for_restore
#-------------------------------------------------------------------------------
function check_image_exists_for_restore() {
	if [ ! -f "$FROM_IMAGE" ]; then
		echo "ERROR: Image file '${FROM_IMAGE}' does not exist." >&2
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

	case "$MODE" in
	disk_to_disk)
		echo "Mode      : Disk -> Disk"
		echo "Source    : ${SRC_DEV}"
		echo "Target    : ${DST_DEV}"
		;;
	disk_to_image)
		echo "Mode      : Disk -> Image"
		echo "Source    : ${SRC_DEV}"
		echo "Image     : ${TO_IMAGE}"
		echo "Compress  : ${COMPRESS}"
		;;
	image_to_disk)
		echo "Mode      : Image -> Disk"
		echo "Image     : ${FROM_IMAGE}"
		echo "Target    : ${DST_DEV}"
		echo "Decompress: ${DECOMPRESS}"
		;;
	esac

	echo

	if command -v lsblk >/dev/null 2>&1; then
		if [ "$SRC_DEV" != "" ]; then
			echo "lsblk -d (source):"
			lsblk -d -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL "$SRC_DEV"
			echo
			echo "lsblk (source tree):"
			lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$SRC_DEV"
			echo
		fi
		if [ "$DST_DEV" != "" ]; then
			echo "lsblk -d (target):"
			lsblk -d -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL "$DST_DEV"
			echo
			echo "lsblk (target tree):"
			lsblk -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS "$DST_DEV"
			echo
		fi
	else
		echo "lsblk not found; skipping detailed structure overview."
	fi
}

#-------------------------------------------------------------------------------
# Function: require_tool
#-------------------------------------------------------------------------------
function require_tool() {
	local cmd="$1"
	local purpose="$2"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: '${cmd}' is required for ${purpose} but is not installed." >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Function: planned_command
#   Human-readable only; real execution is done in run_clone().
#-------------------------------------------------------------------------------
function planned_command() {
	case "$MODE" in
	disk_to_disk)
		printf 'dd if=%s of=%s bs=%s status=progress conv=fdatasync\n' \
			"$SRC_DEV" "$DST_DEV" "$BLOCK_SIZE"
		;;
	disk_to_image)
		case "$COMPRESS" in
		none)
			printf 'dd if=%s of="%s" bs=%s status=progress conv=fdatasync\n' \
				"$SRC_DEV" "$TO_IMAGE" "$BLOCK_SIZE"
			;;
		gzip)
			printf 'dd if=%s bs=%s status=progress | gzip -c > "%s"\n' \
				"$SRC_DEV" "$BLOCK_SIZE" "$TO_IMAGE"
			;;
		xz)
			printf 'dd if=%s bs=%s status=progress | xz -c > "%s"\n' \
				"$SRC_DEV" "$BLOCK_SIZE" "$TO_IMAGE"
			;;
		zstd)
			printf 'dd if=%s bs=%s status=progress | zstd -c > "%s"\n' \
				"$SRC_DEV" "$BLOCK_SIZE" "$TO_IMAGE"
			;;
		esac
		;;
	image_to_disk)
		case "$DECOMPRESS" in
		none)
			printf 'dd if="%s" of=%s bs=%s status=progress conv=fdatasync\n' \
				"$FROM_IMAGE" "$DST_DEV" "$BLOCK_SIZE"
			;;
		gzip)
			printf 'gunzip -c "%s" | dd of=%s bs=%s status=progress conv=fdatasync\n' \
				"$FROM_IMAGE" "$DST_DEV" "$BLOCK_SIZE"
			;;
		xz)
			printf 'xz -dc "%s" | dd of=%s bs=%s status=progress conv=fdatasync\n' \
				"$FROM_IMAGE" "$DST_DEV" "$BLOCK_SIZE"
			;;
		zstd)
			printf 'zstd -dc "%s" | dd of=%s bs=%s status=progress conv=fdatasync\n' \
				"$FROM_IMAGE" "$DST_DEV" "$BLOCK_SIZE"
			;;
		esac
		;;
	esac
}

#-------------------------------------------------------------------------------
# Function: confirm_or_abort
#-------------------------------------------------------------------------------
function confirm_or_abort() {
	local cmd answer confirm target_dev

	if [ "$FORCE" -eq 1 ]; then
		return
	fi

	cmd="$(planned_command)"

	echo
	echo "PLANNED COMMAND ---------------------------------------------------"
	echo "$cmd"
	echo

	case "$MODE" in
	disk_to_disk)
		target_dev="$DST_DEV"
		;;
	disk_to_image)
		target_dev="$TO_IMAGE"
		;;
	image_to_disk)
		target_dev="$DST_DEV"
		;;
	esac

	echo "WARNING: This operation is potentially destructive."
	case "$MODE" in
	disk_to_disk | image_to_disk)
		echo "  * ALL data on target disk ${DST_DEV} will be LOST."
		;;
	disk_to_image)
		echo "  * Existing file at ${TO_IMAGE} (if any) will be overwritten."
		;;
	esac
	echo

	read -r -p "Type the exact target identifier (${target_dev}) to confirm: " \
		answer
	if [ "$answer" != "$target_dev" ]; then
		echo "Aborted: input did not match '${target_dev}'." >&2
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
	if [ "$TEST_ONLY" -eq 1 ]; then
		echo
		echo "(test-only): not executing the operation."
		return
	fi

	echo
	echo "Executing operation..."
	echo

	case "$MODE" in
	disk_to_disk)
		# shellcheck disable=SC2086
		dd if="$SRC_DEV" of="$DST_DEV" bs="$BLOCK_SIZE" \
			status=progress conv=fdatasync
		;;
	disk_to_image)
		case "$COMPRESS" in
		none)
			# shellcheck disable=SC2086
			dd if="$SRC_DEV" of="$TO_IMAGE" bs="$BLOCK_SIZE" \
				status=progress conv=fdatasync
			;;
		gzip)
			require_tool gzip "gzip compression"
			# shellcheck disable=SC2086
			dd if="$SRC_DEV" bs="$BLOCK_SIZE" status=progress |
				gzip -c >"$TO_IMAGE"
			;;
		xz)
			require_tool xz "xz compression"
			# shellcheck disable=SC2086
			dd if="$SRC_DEV" bs="$BLOCK_SIZE" status=progress |
				xz -c >"$TO_IMAGE"
			;;
		zstd)
			require_tool zstd "zstd compression"
			# shellcheck disable=SC2086
			dd if="$SRC_DEV" bs="$BLOCK_SIZE" status=progress |
				zstd -c >"$TO_IMAGE"
			;;
		esac
		;;
	image_to_disk)
		case "$DECOMPRESS" in
		none)
			# shellcheck disable=SC2086
			dd if="$FROM_IMAGE" of="$DST_DEV" bs="$BLOCK_SIZE" \
				status=progress conv=fdatasync
			;;
		gzip)
			require_tool gunzip "gzip decompression"
			# shellcheck disable=SC2086
			gunzip -c "$FROM_IMAGE" |
				dd of="$DST_DEV" bs="$BLOCK_SIZE" \
					status=progress conv=fdatasync
			;;
		xz)
			require_tool xz "xz decompression"
			# shellcheck disable=SC2086
			xz -dc "$FROM_IMAGE" |
				dd of="$DST_DEV" bs="$BLOCK_SIZE" \
					status=progress conv=fdatasync
			;;
		zstd)
			require_tool zstd "zstd decompression"
			# shellcheck disable=SC2086
			zstd -dc "$FROM_IMAGE" |
				dd of="$DST_DEV" bs="$BLOCK_SIZE" \
					status=progress conv=fdatasync
			;;
		esac
		;;
	esac

	echo
	echo "Operation completed. Syncing buffers..."
	sync || true
}

#-------------------------------------------------------------------------------
# Function: main
#-------------------------------------------------------------------------------
function main() {
	parse_args "$@"
	ensure_root
	determine_mode_and_check_combos

	# Validate disks depending on mode
	case "$MODE" in
	disk_to_disk)
		validate_disk_device "$SRC_DEV" "source"
		validate_disk_device "$DST_DEV" "target"
		if [ "$SRC_DEV" = "$DST_DEV" ]; then
			echo "ERROR: Source and target disks must be different." >&2
			exit 1
		fi
		ensure_target_not_mounted "$DST_DEV"
		check_size_relationship_disk_to_disk
		;;
	disk_to_image)
		validate_disk_device "$SRC_DEV" "source"
		;;
	image_to_disk)
		validate_disk_device "$DST_DEV" "target"
		ensure_target_not_mounted "$DST_DEV"
		check_image_exists_for_restore
		;;
	esac

	SRC_NAME="$(basename "${SRC_DEV:-""}")"
	DST_NAME="$(basename "${DST_DEV:-""}")"

	show_overview
	confirm_or_abort
	run_clone

	echo
	echo "Done."
	case "$MODE" in
	disk_to_disk)
		echo "Target disk now contains an exact clone of the source."
		;;
	disk_to_image)
		echo "Image file '${TO_IMAGE}' now holds a raw snapshot of ${SRC_DEV}"
		echo "(compressed via '${COMPRESS}' if applicable)."
		;;
	image_to_disk)
		echo "Disk '${DST_DEV}' has been populated from image '${FROM_IMAGE}'."
		;;
	esac
	echo "If partition layout changed, run partprobe(8) or re-plug the disk so"
	echo "the kernel sees the updated partition table."
}

main "$@"
