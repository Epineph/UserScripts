#!/usr/bin/env bash

set -euo pipefail

function show_help() {
  cat <<'EOF'
archiso-write.sh

Interactively choose a built ISO and a target USB disk, then write the ISO.

Features:
  - fzf picker for ISO files
  - fzf picker for target disks
  - excludes the current root/system disk by default
  - unmounts mounted partitions on the target device
  - disables swap on target partitions if needed
  - writes with:
      - pv   (default if available)
      - ddrescue (fallback or explicit choice)

Usage:
  sudo ./archiso-write.sh [options]

Options:
  --iso FILE              ISO file to write.
  --device DEV            Target whole-disk device, e.g. /dev/sdb.
  --search-dir DIR        Directory to search for *.iso files.
                          Default: current directory.
  --method METHOD         Write method: auto, pv, ddrescue.
                          Default: auto.
  --include-system-disk   Allow the current root/system disk to appear
                          in the device picker. Dangerous.
  --eject                 Attempt to eject the device after writing.
  -h, --help              Show this help text.

Examples:
  sudo ./archiso-write.sh
  sudo ./archiso-write.sh --search-dir ./out
  sudo ./archiso-write.sh --iso ./out/heini-archiso.iso
  sudo ./archiso-write.sh --iso ./out/heini-archiso.iso \
    --device /dev/sdb --method pv
  sudo ./archiso-write.sh --method ddrescue

Notes:
  - Always write to the WHOLE DISK, not a partition.
  - This destroys existing data on the selected target disk.
  - If fzf is unavailable, pass both --iso and --device explicitly.
EOF
}

function log() {
  printf '[+] %s\n' "$*"
}

function warn() {
  printf '[!] %s\n' "$*" >&2
}

function die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

function need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: ${cmd}"
}

function has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function human_size() {
  local bytes="$1"

  if has_cmd numfmt; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    printf '%s B' "$bytes"
  fi
}

function ensure_root() {
  [[ ${EUID} -eq 0 ]] || die 'Run this script as root.'
}

function kv_get() {
  local line="$1"
  local key="$2"

  sed -nE "s/.*${key}=\"([^\"]*)\".*/\1/p" <<< "$line"
}

function get_root_disk() {
  local root_source=''
  local parent=''

  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$root_source" ]] || return 0

  parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  [[ -n "$parent" ]] || return 0

  printf '/dev/%s\n' "$parent"
}

function stable_device_path() {
  local dev="$1"
  local link=''
  local target=''

  shopt -s nullglob

  for link in /dev/disk/by-id/*; do
    [[ "$link" == *-part* ]] && continue
    target="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ "$target" == "$dev" ]]; then
      printf '%s\n' "$link"
      shopt -u nullglob
      return 0
    fi
  done

  shopt -u nullglob
  printf '%s\n' "$dev"
}

function list_iso_candidates() {
  local search_dir="$1"
  local file=''
  local mtime=''
  local size=''
  local stamp=''

  [[ -d "$search_dir" ]] || die "Search directory not found: ${search_dir}"

  while IFS= read -r -d '' file; do
    mtime="$(stat -c '%Y' "$file")"
    stamp="$(stat -c '%y' "$file" | cut -d'.' -f1)"
    size="$(human_size "$(stat -c '%s' "$file")")"
    printf '%s\t%s\t%s\t%s\n' "$mtime" "$stamp" "$size" "$file"
  done < <(find "$search_dir" -type f -name '*.iso' -print0)

  return 0
}

function choose_iso() {
  local search_dir="$1"
  local selected=''

  has_cmd fzf || die 'fzf is required for interactive ISO selection.'

  selected="$(
    list_iso_candidates "$search_dir" \
      | sort -r -n -k1,1 \
      | cut -f2- \
      | fzf \
          --delimiter=$'\t' \
          --with-nth=1,2,3 \
          --prompt='ISO > ' \
          --header='Choose ISO file' \
          --preview '
            iso=$(printf "%s\n" {} | cut -f3-)
            printf "Path: %s\n\n" "$iso"
            ls -lh "$iso"
            printf "\n"
            file "$iso" 2>/dev/null || true
          '
  )"

  [[ -n "$selected" ]] || die 'No ISO selected.'

  printf '%s\n' "$(printf '%s\n' "$selected" | cut -f3-)"
}

function list_device_candidates() {
  local include_system_disk="$1"
  local root_disk=''
  local line=''
  local name=''
  local size=''
  local tran=''
  local rm=''
  local vendor=''
  local model=''
  local type=''

  root_disk="$(get_root_disk)"

  while IFS= read -r line; do
    name="$(kv_get "$line" NAME)"
    size="$(kv_get "$line" SIZE)"
    tran="$(kv_get "$line" TRAN)"
    rm="$(kv_get "$line" RM)"
    vendor="$(kv_get "$line" VENDOR)"
    model="$(kv_get "$line" MODEL)"
    type="$(kv_get "$line" TYPE)"

    [[ "$type" == 'disk' ]] || continue

    if [[ "$include_system_disk" == '0' ]] && [[ -n "$root_disk" ]]; then
      [[ "$name" == "$root_disk" ]] && continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" \
      "${size:-?}" \
      "${tran:-?}" \
      "${rm:-?}" \
      "${vendor:-?}" \
      "${model:-?}"
  done < <(lsblk -dpPno NAME,SIZE,TRAN,RM,VENDOR,MODEL,TYPE)
}

function choose_device() {
  local include_system_disk="$1"
  local selected=''

  has_cmd fzf || die 'fzf is required for interactive device selection.'

  selected="$(
    list_device_candidates "$include_system_disk" \
      | fzf \
          --delimiter=$'\t' \
          --with-nth=1,2,3,4,5,6 \
          --prompt='DISK > ' \
          --header='Choose target whole disk (ALL DATA WILL BE DESTROYED)' \
          --preview '
            dev=$(printf "%s\n" {} | cut -f1)
            printf "Resolved device: %s\n\n" "$dev"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,\
VENDOR,TRAN,RM "$dev"
          '
  )"

  [[ -n "$selected" ]] || die 'No device selected.'

  printf '%s\n' "$(printf '%s\n' "$selected" | cut -f1)"
}

function ensure_whole_disk() {
  local dev="$1"
  local type=''

  [[ -b "$dev" ]] || die "Not a block device: ${dev}"

  type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
  [[ "$type" == 'disk' ]] || die "Target must be a whole disk, not: ${dev}"
}

function ensure_iso_fits() {
  local iso="$1"
  local dev="$2"
  local iso_size=''
  local dev_size=''

  iso_size="$(stat -c '%s' "$iso")"
  dev_size="$(blockdev --getsize64 "$dev")"

  if (( iso_size > dev_size )); then
    die "ISO ($(human_size "$iso_size")) is larger than device \
($(human_size "$dev_size"))."
  fi
}

function unmount_device_tree() {
  local dev="$1"
  local node=''

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if findmnt -rn "$node" >/dev/null 2>&1; then
      log "Unmounting ${node}"
      umount "$node"
    fi
  done < <(lsblk -lnpo NAME "$dev" | tail -n +2)
}

function disable_swap_on_device() {
  local dev="$1"
  local swapdev=''

  while IFS= read -r swapdev; do
    [[ -n "$swapdev" ]] || continue
    if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$swapdev"; then
      log "Disabling swap on ${swapdev}"
      swapoff "$swapdev"
    fi
  done < <(lsblk -lnpo NAME "$dev" | tail -n +2)
}

function confirm_destruction() {
  local iso="$1"
  local dev="$2"
  local stable=''
  local answer=''

  stable="$(stable_device_path "$dev")"

  printf '\n'
  warn "About to destroy all data on: ${stable}"
  printf 'ISO   : %s\n' "$iso"
  printf 'Target: %s\n' "$stable"
  printf '\n'
  printf 'Type the exact device path to continue: '
  read -r answer

  [[ "$answer" == "$stable" || "$answer" == "$dev" ]] || \
    die 'Confirmation failed.'
}

function write_with_pv() {
  local iso="$1"
  local dev="$2"
  local size=''

  need_cmd pv
  size="$(stat -c '%s' "$iso")"

  log "Writing with pv to ${dev}"
  pv -pterab -s "$size" -Y "$iso" > "$dev"
  sync
  blockdev --flushbufs "$dev" 2>/dev/null || true
}

function write_with_ddrescue() {
  local iso="$1"
  local dev="$2"
  local mapfile=''

  need_cmd ddrescue
  mapfile="$(mktemp /tmp/archiso-ddrescue.XXXXXX.map)"

  log "Writing with ddrescue to ${dev}"
  ddrescue --force "$iso" "$dev" "$mapfile"
  sync
  blockdev --flushbufs "$dev" 2>/dev/null || true
  rm -f "$mapfile"
}

function maybe_eject() {
  local dev="$1"

  if has_cmd eject; then
    eject "$dev" || true
  else
    warn 'eject not found; skipping eject.'
  fi
}

ISO_FILE=''
DEVICE=''
SEARCH_DIR="$PWD"
METHOD='auto'
INCLUDE_SYSTEM_DISK=0
EJECT_AFTER=0

while (($# > 0)); do
  case "$1" in
    --iso)
      ISO_FILE="$2"
      shift 2
      ;;
    --device)
      DEVICE="$2"
      shift 2
      ;;
    --search-dir)
      SEARCH_DIR="$2"
      shift 2
      ;;
    --method)
      METHOD="${2,,}"
      shift 2
      ;;
    --include-system-disk)
      INCLUDE_SYSTEM_DISK=1
      shift
      ;;
    --eject)
      EJECT_AFTER=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

ensure_root
need_cmd lsblk
need_cmd findmnt
need_cmd stat
need_cmd blockdev
need_cmd umount

case "$METHOD" in
  auto|pv|ddrescue)
    ;;
  *)
    die "Invalid method: ${METHOD}"
    ;;
esac

if [[ -z "$ISO_FILE" ]]; then
  ISO_FILE="$(choose_iso "$SEARCH_DIR")"
fi

[[ -f "$ISO_FILE" ]] || die "ISO file not found: ${ISO_FILE}"

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(choose_device "$INCLUDE_SYSTEM_DISK")"
fi

ensure_whole_disk "$DEVICE"
ensure_iso_fits "$ISO_FILE" "$DEVICE"
confirm_destruction "$ISO_FILE" "$DEVICE"
disable_swap_on_device "$DEVICE"
unmount_device_tree "$DEVICE"

case "$METHOD" in
  auto)
    if has_cmd pv; then
      METHOD='pv'
    elif has_cmd ddrescue; then
      METHOD='ddrescue'
    else
      die 'Need either pv or ddrescue installed.'
    fi
    ;;
esac

case "$METHOD" in
  pv)
    write_with_pv "$ISO_FILE" "$DEVICE"
    ;;
  ddrescue)
    write_with_ddrescue "$ISO_FILE" "$DEVICE"
    ;;
esac

log 'Write finished successfully.'

if [[ "$EJECT_AFTER" == '1' ]]; then
  maybe_eject "$DEVICE"
fi
