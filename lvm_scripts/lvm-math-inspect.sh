#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# lvm-math-inspect.sh
# Inspect-only LVM/ext4 sizing math (extents, rounding, ext4 minimum size).
# Optional plan evaluation: "move DELTA_GIB from SRC to DST" (no changes).
#
# Runs well from Arch ISO after: cryptsetup open ... ; vgchange -ay

SCRIPT_NAME="$(basename "$0")"

# ----------------------------- Help / pager -----------------------------

function help_pager() {
	if [[ -n "${HELP_PAGER:-}" ]]; then
		printf '%s\n' "$HELP_PAGER"
		return
	fi
	if command -v less >/dev/null 2>&1; then
		printf '%s\n' "less -R"
	else
		printf '%s\n' "cat"
	fi
}

function usage() {
	cat <<'EOF'
# lvm-math-inspect.sh

Inspect-only tool to understand LVM sizing math and ext4 minimum-size constraints.

## Usage
  sudo lvm-math-inspect.sh --vg VGNAME
  sudo lvm-math-inspect.sh --src /dev/VG/LV --dst /dev/VG/LV --delta-gib 20
  sudo lvm-math-inspect.sh --interactive
  sudo lvm-math-inspect.sh --all

## What it prints
  - VG extent size (MiB)
  - LV size in MiB and in extents
  - Mounted state
  - Filesystem type
  - ext4 minimum filesystem size (from resize2fs -P) converted to MiB/GiB
  - If --src/--dst/--delta-gib is given:
      extent rounding math and whether a shrink would be safe (ext4 minimum + margin)

## Notes
  - ext4 shrinking is offline-only: SRC should be unmounted.
  - LVM always rounds size changes to extents. This tool makes that visible.
  - No disk modifications are performed, ever.

## Options
  --vg VGNAME            Restrict report to a specific VG.
  --src DEV              Source LV device (e.g., /dev/vg0/lv_home).
  --dst DEV              Destination LV device (same VG as SRC).
  --delta-gib N           Integer GiB to move from SRC to DST (hypothetical plan).
  --margin-mib N          Extra safety margin (default: 2*extent_size).
  --interactive           Use fzf (if installed) to pick SRC/DST.
  --all                   Report all LVs in all VGs (default if no --vg given).
  -h, --help              Show this help.

Environment
  HELP_PAGER              Pager command for --help output.

EOF
}

# ------------------------------- Utilities ------------------------------

function die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

function require_root() {
	[[ "$EUID" -eq 0 ]] || die "Run as root (sudo)."
}

function require_cmds() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
	done
}

function is_mounted() {
	local dev="$1"
	findmnt -nr -S "$dev" >/dev/null 2>&1
}

function fs_type() {
	local dev="$1"
	blkid -o value -s TYPE "$dev" 2>/dev/null || true
}

function vg_name_from_dev() {
	local dev="$1"
	# /dev/VG/LV or /dev/mapper/VG-LV (best effort)
	if [[ "$dev" =~ ^/dev/([^/]+)/([^/]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi
	if [[ "$dev" =~ ^/dev/mapper/([^/-]+)- ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi
	printf '\n'
}

function lv_name_from_dev() {
	local dev="$1"
	if [[ "$dev" =~ ^/dev/([^/]+)/([^/]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return
	fi
	if [[ "$dev" =~ ^/dev/mapper/[^-]+-(.+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi
	printf '\n'
}

function vg_extent_mib() {
	local vg="$1"
	vgs --noheadings --units m --nosuffix -o vg_extent_size "$vg" |
		awk '{printf "%d\n", ($1 + 0.5)}'
}

function lv_size_mib() {
	local dev="$1"
	lvs --noheadings --units m --nosuffix -o lv_size "$dev" |
		awk '{printf "%d\n", ($1 + 0.5)}'
}

function lv_extent_count() {
	local dev="$1"
	lvs --noheadings -o lv_extent_count "$dev" | awk '{print $1}'
}

function ext4_min_blocks() {
	local dev="$1"
	resize2fs -P "$dev" 2>/dev/null |
		awk -F: '/minimum/ {gsub(/^[[:space:]]+/, "", $2); print $2}'
}

function ext4_block_size() {
	local dev="$1"
	tune2fs -l "$dev" 2>/dev/null |
		awk -F: '/Block size/ {gsub(/^[[:space:]]+/, "", $2); print $2}'
}

function ceil_div() {
	# ceil_div A B  => ceil(A/B)
	local a="$1"
	local b="$2"
	echo $(((a + b - 1) / b))
}

function fmt_gib_2dp_from_mib() {
	# prints MiB as GiB with 2 decimals (awk float)
	local mib="$1"
	awk -v m="$mib" 'BEGIN { printf "%.2f", (m / 1024.0) }'
}

# --------------------------- Reporting functions -------------------------

function print_lv_report_header() {
	printf '%-18s %-22s %-10s %-10s %-8s %-8s %-10s\n' \
		"VG" "LV" "MiB" "GiB" "#Ext" "FS" "Mounted"
	printf '%s\n' \
		"--------------------------------------------------------------------------------"
}

function print_lv_row() {
	local vg="$1"
	local lv="$2"
	local dev="/dev/${vg}/${lv}"

	local mib gib ext fs mnt
	mib="$(lv_size_mib "$dev" 2>/dev/null || echo "-")"
	gib="-"
	if [[ "$mib" =~ ^[0-9]+$ ]]; then
		gib="$(fmt_gib_2dp_from_mib "$mib")"
	fi
	ext="$(lv_extent_count "$dev" 2>/dev/null || echo "-")"
	fs="$(fs_type "$dev" || echo "-")"
	mnt="no"
	if is_mounted "$dev"; then
		mnt="YES"
	fi

	printf '%-18s %-22s %-10s %-10s %-8s %-8s %-10s\n' \
		"$vg" "$lv" "$mib" "$gib" "$ext" "${fs:-"-"}" "$mnt"
}

function report_vg() {
	local vg="$1"
	local ext_mib
	ext_mib="$(vg_extent_mib "$vg")"
	[[ "$ext_mib" =~ ^[0-9]+$ ]] || die "Could not read extent size for VG '$vg'."

	printf '\nVG: %s\n' "$vg"
	printf '  Extent size: %s MiB\n' "$ext_mib"
	printf '  Extents are the atomic allocation unit in LVM.\n'

	print_lv_report_header

	# List LVs in VG, one per row
	lvs --noheadings -o lv_name "$vg" 2>/dev/null |
		sed 's/^[[:space:]]*//' |
		while read -r lv; do
			[[ -n "$lv" ]] || continue
			print_lv_row "$vg" "$lv"
		done
}

function report_all() {
	local vg
	while read -r vg; do
		[[ -n "$vg" ]] || continue
		report_vg "$vg"
	done < <(vgs --noheadings -o vg_name | sed 's/^[[:space:]]*//')
}

# -------------------------- Plan evaluation math -------------------------

function evaluate_plan() {
	local src="$1"
	local dst="$2"
	local delta_gib="$3"
	local margin_mib="$4"

	local vg
	vg="$(vg_name_from_dev "$src")"
	[[ -n "$vg" ]] || die "Could not parse VG from SRC '$src'. Use /dev/VG/LV."

	[[ "$(vg_name_from_dev "$dst")" == "$vg" ]] ||
		die "SRC and DST must be in the same VG."

	[[ "$delta_gib" =~ ^[0-9]+$ ]] || die "--delta-gib must be an integer."
	((delta_gib > 0)) || die "--delta-gib must be > 0."

	local ext_mib
	ext_mib="$(vg_extent_mib "$vg")"
	[[ "$ext_mib" =~ ^[0-9]+$ ]] || die "Could not read extent size for VG '$vg'."

	if [[ -z "$margin_mib" ]]; then
		margin_mib=$((2 * ext_mib))
	fi

	local src_fs dst_fs
	src_fs="$(fs_type "$src")"
	dst_fs="$(fs_type "$dst")"

	printf '\nPlan evaluation (NO CHANGES):\n'
	printf '  SRC: %s (fs=%s, mounted=%s)\n' \
		"$src" "${src_fs:-unknown}" "$(is_mounted "$src" && echo YES || echo no)"
	printf '  DST: %s (fs=%s, mounted=%s)\n' \
		"$dst" "${dst_fs:-unknown}" "$(is_mounted "$dst" && echo YES || echo no)"
	printf '  VG:  %s (extent=%s MiB)\n' "$vg" "$ext_mib"

	local delta_mib delta_ext actual_mib actual_gib
	delta_mib=$((delta_gib * 1024))
	delta_ext="$(ceil_div "$delta_mib" "$ext_mib")"
	actual_mib=$((delta_ext * ext_mib))
	actual_gib="$(fmt_gib_2dp_from_mib "$actual_mib")"

	printf '\nExtent rounding:\n'
	printf '  Requested:  %s GiB = %s MiB\n' "$delta_gib" "$delta_mib"
	printf '  Extents:    ceil(%s / %s) = %s extents\n' \
		"$delta_mib" "$ext_mib" "$delta_ext"
	printf '  Actual:     %s extents * %s MiB = %s MiB (~%s GiB)\n' \
		"$delta_ext" "$ext_mib" "$actual_mib" "$actual_gib"

	local src_mib src_ext new_src_ext new_src_mib
	src_mib="$(lv_size_mib "$src")"
	src_ext="$(lv_extent_count "$src")"

	printf '\nSource LV sizing:\n'
	printf '  SRC size:   %s MiB (%s extents)\n' "$src_mib" "$src_ext"

	new_src_ext=$((src_ext - delta_ext))
	if ((new_src_ext <= 0)); then
		printf '  New SRC:    %s extents (INVALID)\n' "$new_src_ext"
		die "Move too large: SRC would become <= 0 extents."
	fi

	new_src_mib=$((new_src_ext * ext_mib))
	printf '  New SRC:    %s MiB (%s extents)\n' "$new_src_mib" "$new_src_ext"

	if [[ "$src_fs" == "ext4" ]]; then
		local bmin bsize min_bytes min_mib min_gib
		bmin="$(ext4_min_blocks "$src")"
		bsize="$(ext4_block_size "$src")"
		[[ "$bmin" =~ ^[0-9]+$ ]] || die "Could not read ext4 min blocks (resize2fs -P)."
		[[ "$bsize" =~ ^[0-9]+$ ]] || die "Could not read ext4 block size (tune2fs)."

		min_bytes=$((bmin * bsize))
		min_mib="$(ceil_div "$min_bytes" $((1024 * 1024)))"
		min_gib="$(fmt_gib_2dp_from_mib "$min_mib")"

		printf '\next4 minimum constraint:\n'
		printf '  resize2fs -P blocks: %s blocks\n' "$bmin"
		printf '  ext4 block size:     %s bytes\n' "$bsize"
		printf '  min_bytes = blocks * block_size\n'
		printf '           = %s * %s\n' "$bmin" "$bsize"
		printf '           = %s bytes\n' "$min_bytes"
		printf '  min_mib  = ceil(min_bytes / 2^20) = %s MiB (~%s GiB)\n' \
			"$min_mib" "$min_gib"
		printf '  margin:  %s MiB (default: 2*extent)\n' "$margin_mib"

		if ((new_src_mib < (min_mib + margin_mib))); then
			printf '\nResult: NOT SAFE to shrink SRC to this size.\n'
			printf '  Need: new_src_mib >= min_mib + margin\n'
			printf '      : %s >= %s + %s  (false)\n' \
				"$new_src_mib" "$min_mib" "$margin_mib"
			return 2
		fi

		printf '\nResult: SAFE (mathematically) with ext4 minimum + margin.\n'
		printf '  %s >= %s + %s  (true)\n' \
			"$new_src_mib" "$min_mib" "$margin_mib"
	else
		printf '\nNote: SRC is not ext4; ext4 minimum-size math not evaluated.\n'
	fi

	printf '\nDST growth note:\n'
	printf '  ext4 growth is generally online-capable; shrinking is not.\n'

	return 0
}

# ------------------------------ Interactive -----------------------------

function pick_lv_fzf() {
	local prompt="$1"
	local line

	command -v fzf >/dev/null 2>&1 || die "fzf not installed; use non-interactive."

	line="$(
		lvs --noheadings --separator $'\t' -o vg_name,lv_name,lv_size --units g |
			sed 's/^[[:space:]]*//' |
			fzf --prompt="${prompt} " --height=20 --border \
				--header=$'VG\tLV\tSIZE'
	)"
	[[ -n "$line" ]] || die "No selection made."

	printf '/dev/%s/%s\n' \
		"$(awk -F $'\t' '{print $1}' <<<"$line")" \
		"$(awk -F $'\t' '{print $2}' <<<"$line")"
}

# --------------------------------- Main --------------------------------

VG=""
SRC=""
DST=""
DELTA_GIB=""
MARGIN_MIB=""
INTERACTIVE=0
REPORT_ALL=0

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage | "$(help_pager)"
	exit 0
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
	--vg)
		VG="${2:-}"
		shift
		;;
	--src)
		SRC="${2:-}"
		shift
		;;
	--dst)
		DST="${2:-}"
		shift
		;;
	--delta-gib)
		DELTA_GIB="${2:-}"
		shift
		;;
	--margin-mib)
		MARGIN_MIB="${2:-}"
		shift
		;;
	--interactive)
		INTERACTIVE=1
		;;
	--all)
		REPORT_ALL=1
		;;
	-h | --help)
		usage | "$(help_pager)"
		exit 0
		;;
	*)
		die "Unknown option: $1"
		;;
	esac
	shift
done

require_root
require_cmds lvs vgs blkid findmnt resize2fs tune2fs

if [[ "$INTERACTIVE" -eq 1 ]]; then
	SRC="$(pick_lv_fzf "Pick SRC (shrink) >")"
	DST="$(pick_lv_fzf "Pick DST (extend) >")"
	printf 'Enter delta GiB to move SRC→DST: '
	read -r DELTA_GIB
fi

if [[ -n "$VG" ]]; then
	report_vg "$VG"
else
	if [[ "$REPORT_ALL" -eq 1 || (-z "$SRC" && -z "$DST") ]]; then
		report_all
	fi
fi

if [[ -n "$SRC" || -n "$DST" || -n "$DELTA_GIB" ]]; then
	[[ -n "$SRC" && -n "$DST" && -n "$DELTA_GIB" ]] ||
		die "For plan evaluation, provide --src, --dst, and --delta-gib."
	evaluate_plan "$SRC" "$DST" "$DELTA_GIB" "$MARGIN_MIB" || true
fi
