#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# lvm-move-space-safe.sh
# Move space from one ext4 LV to another ext4 LV (same VG), safely.
# - SRC shrink is offline-only (SRC must be unmounted).
# - DST may be mounted or unmounted (ext4 grow works either way).
# - Validates ext4 minimum size and VG extent rounding.

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
# lvm-move-space-safe.sh

Move space from one ext4 logical volume to another ext4 logical volume within
the same volume group (VG), with safety checks.

## Usage
  sudo lvm-move-space-safe.sh
  sudo lvm-move-space-safe.sh --dry-run
  sudo lvm-move-space-safe.sh --yes

## Requirements
  - Run as root.
  - Tools: lvs vgs vgchange findmnt blkid e2fsck resize2fs lvreduce lvextend fzf
  - SRC: ext4 + UNMOUNTED  (ext4 shrink is offline-only)
  - DST: ext4

## Safety features
  - Computes VG extent size and rounds the move to extents.
  - Checks ext4 minimum size via: resize2fs -P
  - Refuses snapshot/thin/virtual LV types.

## Options
  --yes       Skip interactive confirmation.
  --dry-run   Print the plan and commands, do not execute.
  -h, --help  Show this help.

## Strong recommendation
  Run from a live/rescue environment if SRC is a critical filesystem.
EOF
}

# ----------------------------- Utilities -------------------------------

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

function run() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf '[dry-run] %q' "$1"
		shift
		for _arg in "$@"; do printf ' %q' "$_arg"; done
		printf '\n'
		return 0
	fi
	"$@"
}

function is_mounted() {
	local dev="$1"
	findmnt -nr -S "$dev" >/dev/null 2>&1
}

function lv_attr_type() {
	local lv="$1"
	lvs --noheadings -o lv_attr "$lv" | awk '{print substr($1,1,1)}'
}

function refuse_weird_lv() {
	local lv="$1"
	local t
	t="$(lv_attr_type "$lv")"
	case "$t" in
	s | S | t | T | V | v | z)
		die "Refusing LV '$lv' (lv_attr type '$t'): snapshot/thin/virtual/VDO-like."
		;;
	esac
}

function ext4_min_mib() {
	local dev="$1"
	local blocks block_size min_bytes

	blocks="$(
		resize2fs -P "$dev" 2>/dev/null |
			awk -F: '/minimum/ {gsub(/^[[:space:]]+/, "", $2); print $2}'
	)"
	[[ -n "$blocks" ]] || die "Could not read ext4 minimum blocks from resize2fs -P."

	block_size="$(
		tune2fs -l "$dev" 2>/dev/null |
			awk -F: '/Block size/ {gsub(/^[[:space:]]+/, "", $2); print $2}'
	)"
	[[ -n "$block_size" ]] || die "Could not read ext4 block size from tune2fs."

	min_bytes=$((blocks * block_size))
	# ceil(min_bytes / MiB)
	echo $(((min_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
}

function vg_extent_mib() {
	local vg="$1"
	vgs --noheadings --units m --nosuffix -o vg_extent_size "$vg" |
		awk '{printf "%d\n", ($1 + 0.5)}'
}

function lv_size_mib() {
	local lv="$1"
	lvs --noheadings --units m --nosuffix -o lv_size "$lv" |
		awk '{printf "%d\n", ($1 + 0.5)}'
}

function list_lvs_tsv() {
	# vg\tlv\tsize\tfstype\tmnt\tattr
	lvs --noheadings --separator $'\t' -o vg_name,lv_name,lv_size,lv_attr --units g |
		sed 's/^[[:space:]]*//' |
		while IFS=$'\t' read -r vg lv size_g attr; do
			local dev="/dev/${vg}/${lv}"
			local fstype mnt
			fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "-")"
			mnt="$(findmnt -nr -o TARGET -S "$dev" 2>/dev/null || echo "-")"
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$vg" "$lv" "$size_g" "$fstype" "$mnt" "$attr"
		done
}

function pick_lv() {
	local prompt="$1"
	local line

	line="$(
		list_lvs_tsv |
			fzf --prompt="${prompt} " \
				--with-nth=1,2,3,4,5 \
				--delimiter=$'\t' \
				--height=20 --border \
				--header=$'VG\tLV\tSIZE\tFS\tMOUNT\tATTR'
	)"

	[[ -n "$line" ]] || die "No LV selected."
	echo "$line"
}

function confirm_or_die() {
	[[ "$ASSUME_YES" -eq 1 ]] && return 0
	local and
	read -r -p "Type 'YES' to proceed: " and
	[[ "$and" == "YES" ]] || die "Aborted."
}

# ------------------------------ Main -----------------------------------

ASSUME_YES=0
DRY_RUN=0

case "${1:-}" in
-h | --help)
	usage | "$(help_pager)"
	exit 0
	;;
esac

while [[ $# -gt 0 ]]; do
	case "$1" in
	--yes) ASSUME_YES=1 ;;
	--dry-run) DRY_RUN=1 ;;
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
require_cmds lvs vgs vgchange findmnt blkid e2fsck resize2fs tune2fs lvreduce lvextend fzf

run vgchange -ay >/dev/null || true

printf '\n=== Select source LV (SRC) to SHRINK (must be ext4 + unmounted) ===\n'
SRC_LINE="$(pick_lv "Shrink SRC >")"
SRC_VG="$(awk -F $'\t' '{print $1}' <<<"$SRC_LINE")"
SRC_LV_NAME="$(awk -F $'\t' '{print $2}' <<<"$SRC_LINE")"
SRC_DEV="/dev/${SRC_VG}/${SRC_LV_NAME}"
SRC_FS="$(awk -F $'\t' '{print $4}' <<<"$SRC_LINE")"

printf 'SRC: %s (fs=%s)\n' "$SRC_DEV" "$SRC_FS"
[[ "$SRC_FS" == "ext4" ]] || die "SRC must be ext4."
! is_mounted "$SRC_DEV" || die "SRC is mounted. Unmount it first."
refuse_weird_lv "$SRC_DEV"

printf '\nHow many GiB do you want to move from SRC to DST? '
read -r DELTA_GIB
[[ "$DELTA_GIB" =~ ^[0-9]+$ ]] || die "GiB must be an integer."
((DELTA_GIB > 0)) || die "GiB must be > 0."

printf '\n=== Select destination LV (DST) to EXTEND (must be ext4) ===\n'
DST_LINE="$(pick_lv "Extend DST >")"
DST_VG="$(awk -F $'\t' '{print $1}' <<<"$DST_LINE")"
DST_LV_NAME="$(awk -F $'\t' '{print $2}' <<<"$DST_LINE")"
DST_DEV="/dev/${DST_VG}/${DST_LV_NAME}"
DST_FS="$(awk -F $'\t' '{print $4}' <<<"$DST_LINE")"

printf 'DST: %s (fs=%s)\n' "$DST_DEV" "$DST_FS"
[[ "$DST_FS" == "ext4" ]] || die "DST must be ext4."
refuse_weird_lv "$DST_DEV"

[[ "$SRC_VG" == "$DST_VG" ]] || die "SRC and DST must be in the same VG."

EXT_MIB="$(vg_extent_mib "$SRC_VG")"
[[ "$EXT_MIB" =~ ^[0-9]+$ ]] || die "Could not read VG extent size."
((EXT_MIB > 0)) || die "VG extent size looks invalid."

DELTA_MIB=$((DELTA_GIB * 1024))
DELTA_EXT=$(((DELTA_MIB + EXT_MIB - 1) / EXT_MIB))
ACTUAL_DELTA_MIB=$((DELTA_EXT * EXT_MIB))
ACTUAL_DELTA_GIB=$((ACTUAL_DELTA_MIB / 1024))

SRC_MIB="$(lv_size_mib "$SRC_DEV")"
SRC_EXT=$((SRC_MIB / EXT_MIB))
NEW_SRC_EXT=$((SRC_EXT - DELTA_EXT))
((NEW_SRC_EXT > 0)) || die "Move is too large; SRC would become <= 0 extents."

NEW_SRC_MIB=$((NEW_SRC_EXT * EXT_MIB))

MIN_MIB="$(ext4_min_mib "$SRC_DEV")"
SAFETY_MIB=128
((NEW_SRC_MIB >= MIN_MIB + SAFETY_MIB)) || die \
	"SRC target too small. Need >= $((MIN_MIB + SAFETY_MIB)) MiB; planned $NEW_SRC_MIB MiB."

# We shrink filesystem a bit below the target LV size to avoid any extent rounding
# mismatch, then after lvreduce we grow to fill the (smaller) LV.
FS_SHRINK_MIB=$((NEW_SRC_MIB - EXT_MIB))
((FS_SHRINK_MIB > 0)) || die "Internal error: FS shrink target <= 0."

printf '\n--- Plan ---\n'
printf 'VG extent size:      %s MiB\n' "$EXT_MIB"
printf 'Requested move:      %s GiB\n' "$DELTA_GIB"
printf 'Extent-rounded move: %s extents = %s MiB (~%s GiB)\n' \
	"$DELTA_EXT" "$ACTUAL_DELTA_MIB" "$ACTUAL_DELTA_GIB"
printf 'SRC current:         %s MiB (%s extents)\n' "$SRC_MIB" "$SRC_EXT"
printf 'SRC new LV size:     %s MiB (%s extents)\n' "$NEW_SRC_MIB" "$NEW_SRC_EXT"
printf 'SRC ext4 minimum:    %s MiB (+%s MiB safety)\n' "$MIN_MIB" "$SAFETY_MIB"
printf 'DST will extend by:  %s extents\n' "$DELTA_EXT"
printf '\n'

confirm_or_die

printf '\n--- Executing (SRC shrink) ---\n'
# e2fsck return codes are bitmasks; accept 0,1,2 as “OK enough to proceed”.
set +e
run e2fsck -f -p "$SRC_DEV"
RC=$?
set -e
(((RC & 0x04) == 0)) || die "e2fsck reports uncorrected errors (rc=$RC)."
(((RC & 0x08) == 0)) || die "e2fsck operational error (rc=$RC)."
(((RC & 0x10) == 0)) || die "e2fsck usage error (rc=$RC)."
(((RC & 0x20) == 0)) || die "e2fsck canceled (rc=$RC)."
(((RC & 0x80) == 0)) || die "e2fsck shared library error (rc=$RC)."

run resize2fs "$SRC_DEV" "${FS_SHRINK_MIB}M"
run lvreduce -l "$NEW_SRC_EXT" "$SRC_DEV" -y
run resize2fs "$SRC_DEV"

printf '\n--- Executing (DST extend) ---\n'
run lvextend -l +"$DELTA_EXT" "$DST_DEV" -y
run resize2fs "$DST_DEV"

printf '\n--- Result ---\n'
run lvs -o vg_name,lv_name,lv_size,lv_attr "$SRC_DEV" "$DST_DEV"
printf '\nDone.\n'
