#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# disk-inspect : inspect a block device (SSD/HDD/NVMe) and basic health status
#-------------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

TARGET_DEVICE=""
NO_SMART=0
SHOW_DMESG=1

DISK_DEV=""
DISK_NAME=""

#-------------------------------------------------------------------------------
# Function: print_help
#-------------------------------------------------------------------------------
function print_help() {
	local pager

	pager="${HELP_PAGER:-less -R}"
	# If pager command is not present, fall back to cat
	if ! command -v "${pager%% *}" >/dev/null 2>&1; then
		pager="cat"
	fi

	cat <<'EOF' | ${pager}
disk-inspect - inspect a block device for type and potential problems

Usage:
  disk-inspect --target /dev/sdX [--no-smart] [--no-dmesg]
  disk-inspect -t /dev/nvme0n1

Options:
  -t, --target   Block device to inspect (disk or partition).
  --no-smart     Skip SMART queries via smartctl(8).
  --no-dmesg     Skip printing recent kernel messages mentioning the device.
  -h, --help     Show this help text.

What this script does (read-only):
  * Resolves the parent disk if you pass a partition.
  * Shows disk layout and basic attributes with lsblk(8).
  * Classifies media: HDD vs SSD vs NVMe using /sys/block/*/queue/rotational.
  * Queries SMART status via smartctl(8), if available.
  * Highlights a few SMART attributes that often indicate trouble:
      - Reallocated_Sector_Ct
      - Current_Pending_Sector
      - Offline_Uncorrectable
  * Prints recent dmesg(1) lines mentioning the disk (I/O errors etc.).

Limitations:
  - No destructive tests (e.g. badblocks) are run.
  - SMART interpretation is simplified; it can miss subtle or vendor-specific
    failure modes. If SMART complains, take it seriously. If it does not,
    that does NOT guarantee the drive is healthy.
EOF
}

#-------------------------------------------------------------------------------
# Function: ensure_root
#-------------------------------------------------------------------------------
function ensure_root() {
	local uid_val

	uid_val="${EUID:-$(id -u)}"
	if [ "$uid_val" -ne 0 ]; then
		echo "ERROR: This script must run as root for full diagnostics." >&2
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
				echo "ERROR: --target requires a device path (e.g. /dev/sda)." >&2
				exit 1
			fi
			TARGET_DEVICE="$2"
			shift 2
			;;
		--no-smart)
			NO_SMART=1
			shift
			;;
		--no-dmesg)
			SHOW_DMESG=0
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
}

#-------------------------------------------------------------------------------
# Function: resolve_disk_device
#   - Accepts partition or whole-disk path.
#   - Resolves the parent disk using lsblk(8).
#-------------------------------------------------------------------------------
function resolve_disk_device() {
	local dev pk

	dev="$TARGET_DEVICE"

	if ! [ -b "$dev" ]; then
		echo "ERROR: '${dev}' is not a block device." >&2
		exit 1
	fi

	# PKNAME is the parent device name if 'dev' is a partition.
	pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n 1 || true)"

	if [ "$pk" != "" ]; then
		DISK_DEV="/dev/${pk}"
	else
		DISK_DEV="$dev"
	fi

	DISK_NAME="$(basename "$DISK_DEV")"
}

#-------------------------------------------------------------------------------
# Function: show_basic_info
#-------------------------------------------------------------------------------
function show_basic_info() {
	echo "==================================================================="
	echo "Basic information for: ${DISK_DEV}"
	echo "==================================================================="

	if command -v lsblk >/dev/null 2>&1; then
		echo
		echo "lsblk (device-only view):"
		lsblk -d -o NAME,TYPE,SIZE,ROTA,RO,DISC-MAX,DISC-GRAN,MODEL,SERIAL,TRAN \
			"$DISK_DEV" 2>/dev/null ||
			lsblk -d "$DISK_DEV"
		echo
		echo "lsblk (tree view):"
		lsblk -o NAME,TYPE,SIZE,ROTA,MODEL,SERIAL,TRAN,MOUNTPOINTS "$DISK_DEV"
	else
		echo "WARNING: lsblk not found; cannot show block device overview."
	fi
}

#-------------------------------------------------------------------------------
# Function: detect_media_type
#-------------------------------------------------------------------------------
function detect_media_type() {
	local sys_path rotational media_type model vendor

	sys_path="/sys/block/${DISK_NAME}"
	media_type="unknown"

	if [[ "$DISK_NAME" == nvme* ]]; then
		media_type="NVMe SSD (non-rotational)"
	elif [ -r "${sys_path}/queue/rotational" ]; then
		rotational="$(cat "${sys_path}/queue/rotational")"
		case "$rotational" in
		0)
			media_type="non-rotational (likely SSD, NVMe or eMMC)"
			;;
		1)
			media_type="rotational (likely HDD)"
			;;
		*)
			media_type="unknown (rotational flag=${rotational})"
			;;
		esac
	fi

	model="$(cat "${sys_path}/device/model" 2>/dev/null || true)"
	vendor="$(cat "${sys_path}/device/vendor" 2>/dev/null || true)"

	echo
	echo "Media type classification -----------------------------------------"
	echo "  Kernel name : ${DISK_NAME}"
	echo "  Vendor      : ${vendor:-<unknown>}"
	echo "  Model       : ${model:-<unknown>}"
	echo "  Media type  : ${media_type}"
	if [ -r "${sys_path}/queue/scheduler" ]; then
		echo "  Scheduler   : $(cat "${sys_path}/queue/scheduler")"
	fi
}

#-------------------------------------------------------------------------------
# Function: run_smart_checks
#-------------------------------------------------------------------------------
function run_smart_checks() {
	local smart_out reallocated pending offline

	if [ "$NO_SMART" -eq 1 ]; then
		echo
		echo "SMART checks skipped (user requested --no-smart)."
		return
	fi

	if ! command -v smartctl >/dev/null 2>&1; then
		echo
		echo "SMART checks ------------------------------------------------------"
		echo "smartctl(8) not found; SMART diagnostics are skipped."
		echo "Install the 'smartmontools' package to enable SMART checks."
		return
	fi

	echo
	echo "SMART overall health ---------------------------------------------"
	if ! smartctl -H "$DISK_DEV"; then
		echo
		echo "WARNING: smartctl -H failed. Device may not support SMART or"
		echo "         may require a specific -d TYPE argument (USB enclosures,"
		echo "         hardware RAID, very old disks, etc.)."
	fi

	echo
	echo "SMART detailed output (attributes / log) --------------------------"
	if ! smartctl -A "$DISK_DEV"; then
		echo
		echo "WARNING: smartctl -A failed. Attributes unavailable for this"
		echo "         device with the current invocation."
		return
	fi

	# Cache attributes once to avoid running smartctl repeatedly
	smart_out="$(smartctl -A "$DISK_DEV" 2>/dev/null || true)"

	# ATA-style attribute names; will be empty for NVMe, which is fine.
	reallocated="$(
		printf '%s\n' "$smart_out" |
			awk '$2=="Reallocated_Sector_Ct" {print $10}'
	)"
	pending="$(
		printf '%s\n' "$smart_out" |
			awk '$2=="Current_Pending_Sector" {print $10}'
	)"
	offline="$(
		printf '%s\n' "$smart_out" |
			awk '$2=="Offline_Uncorrectable" {print $10}'
	)"

	echo
	echo "SMART quick interpretation ----------------------------------------"

	if printf '%s\n' "$smart_out" |
		grep -E 'FAILING_NOW|In_the_past' >/dev/null 2>&1; then
		echo "CRITICAL: SMART reports attributes in a failing state."
	fi

	if [ "$reallocated" != "" ] && [ "$reallocated" -gt 0 ] 2>/dev/null; then
		echo "WARNING: Reallocated_Sector_Ct = ${reallocated}"
		echo "         Non-zero reallocated sectors often indicate physical"
		echo "         media damage or previous write failures."
	fi

	if [ "$pending" != "" ] && [ "$pending" -gt 0 ] 2>/dev/null; then
		echo "WARNING: Current_Pending_Sector = ${pending}"
		echo "         Pending sectors are unstable and may become bad sectors."
	fi

	if [ "$offline" != "" ] && [ "$offline" -gt 0 ] 2>/dev/null; then
		echo "WARNING: Offline_Uncorrectable = ${offline}"
		echo "         Uncorrectable errors during offline tests are a bad sign."
	fi

	if [ "${reallocated:-}" = "" ] && [ "${pending:-}" = "" ] &&
		[ "${offline:-}" = "" ]; then
		echo "Note: Drive is not reporting classic ATA SMART attributes like"
		echo "      Reallocated_Sector_Ct / Current_Pending_Sector. This is"
		echo "      expected for NVMe devices; inspect the SMART output above"
		echo "      for 'Media and Data Integrity Errors', 'Percentage Used',"
		echo "      and similar fields instead."
	fi
}

#-------------------------------------------------------------------------------
# Function: show_dmesg_snippet
#-------------------------------------------------------------------------------
function show_dmesg_snippet() {
	if [ "$SHOW_DMESG" -eq 0 ]; then
		return
	fi

	if ! command -v dmesg >/dev/null 2>&1; then
		echo
		echo "Kernel log scan skipped: dmesg(1) not available."
		return
	fi

	echo
	echo "Recent kernel messages mentioning ${DISK_NAME} --------------------"
	if ! dmesg | grep -i "$DISK_NAME" | tail -n 40; then
		echo "(no recent messages mentioning ${DISK_NAME})"
	fi
}

#-------------------------------------------------------------------------------
# Function: main
#-------------------------------------------------------------------------------
function main() {
	parse_args "$@"
	ensure_root
	resolve_disk_device
	show_basic_info
	detect_media_type
	run_smart_checks
	show_dmesg_snippet

	echo
	echo "Done. Remember:"
	echo "  * SMART warnings are strong evidence the disk is not healthy."
	echo "  * Lack of warnings is NOT proof of health."
	echo "  * For deeper surface checks, use tools like badblocks(8) or"
	echo "    vendor-specific diagnostics, but those can be destructive if"
	echo "    misused and are not run by this script."
}

main "$@"
