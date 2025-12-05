#!/usr/bin/env bash
#===============================================================================
# make-arch-usb / mk-usb.sh
#
# Create a bootable Arch Linux USB stick from an existing ISO.
#
# - Works for BIOS and UEFI because Arch ISOs are hybrid images.
# - Does NOT install GRUB/syslinux; it simply writes the ISO 1:1.
# - Uses ddrescue if available, otherwise dd.
#
# Usage examples:
#   sudo mk-usb.sh --iso /path/to/archlinux.iso
#   sudo mk-usb.sh --fetch-latest-iso --target /dev/sdX
#   sudo mk-usb.sh                           # fully interactive
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

ISO_PATH=""
TARGET_DEV=""
BLOCK_SIZE="4M"
TEST_ONLY=0

ISO_DOWNLOAD_DIR="${HOME}/Downloads"
FETCH_LATEST=0

# paging: auto | never
PAGING_MODE="auto"

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
function print_help() {
  local pager

  if [[ "$PAGING_MODE" == "never" ]]; then
    pager="cat"
  else
    pager="${HELP_PAGER:-less -R}"
    local bin="${pager%% *}"
    if ! command -v "$bin" >/dev/null 2>&1; then
      pager="cat"
    fi
  fi

  cat <<EOF | ${pager}
${SCRIPT_NAME} — write an Arch ISO to a USB stick (hybrid ISO method)

Usage:
  sudo ${SCRIPT_NAME} --iso /path/to/archlinux.iso
  sudo ${SCRIPT_NAME} --fetch-latest-iso [--target /dev/sdX]
  sudo ${SCRIPT_NAME} [options]                # interactive ISO + disk

Options:
  -i, --iso PATH
      Path to ISO file. If omitted and --fetch-latest-iso is not given,
      you will be prompted interactively (fzf if installed, else read).

  -d, --device DEV
  -t, --target DEV
      Target block device (e.g. /dev/sdX, /dev/nvme0n1). If omitted, you
      will pick from a list interactively.

  --bs SIZE
      Block size for dd/ddrescue (default: 4M).

  --test-only
      Show what would be done, but do NOT write anything.

  --fetch-latest-iso
  --fetch-newest-iso
  --latest
      Download the newest official Arch ISO from the dotsrc mirror:
        https://mirrors.dotsrc.org/archlinux/iso/latest/archlinux-x86_64.iso
      into:
        ${ISO_DOWNLOAD_DIR}/archlinux-x86_64.iso
      and use it as the ISO source.

  -p, --paging MODE
      Control help paging: MODE in {auto, never}.
      - auto  : use \$HELP_PAGER or 'less -R' if available (default)
      - never : always print help via 'cat' (no paging).

  --no-paging
      Shortcut for '--paging never'.

  -h, --help
      Show this help text.

What this script does:
  * Ensures it runs as root.
  * Lets you choose an ISO and a target USB disk (never a partition).
  * Unmounts any partitions belonging to the target disk.
  * Uses ddrescue (if installed) or dd to write the ISO 1:1 to the disk.
  * Calls sync(1) at the end.

Why this works:
  Arch's official ISOs are "hybrid" images. They already contain the
  correct partitioning and bootloaders for BIOS and UEFI. Writing the
  ISO directly to the USB device preserves this layout exactly; no need
  to install GRUB, syslinux, or create a FAT32 partition manually.

WARNING:
  - The chosen target disk will be OVERWRITTEN COMPLETELY.
  - Double-check the device (e.g. /dev/sdb vs /dev/sda) before confirming.
EOF
}

#-------------------------------------------------------------------------------
# Require-tool helper
#-------------------------------------------------------------------------------
function require_tool() {
  local cmd="$1"
  local purpose="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required for ${purpose}, but is not installed." >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Root check
#-------------------------------------------------------------------------------
function ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf 'ERROR: %s must be run as root (sudo).\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Args
#-------------------------------------------------------------------------------
function parse_args() {
  while (($#)); do
    case "$1" in
    -i | --iso)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --iso requires a path." >&2
        exit 1
      fi
      ISO_PATH="$2"
      shift 2
      ;;
    -d | --device | -t | --target)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --device/--target requires a block device." >&2
        exit 1
      fi
      TARGET_DEV="$2"
      shift 2
      ;;
    --bs)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --bs requires a size (e.g. 4M, 8M)." >&2
        exit 1
      fi
      BLOCK_SIZE="$2"
      shift 2
      ;;
    --fetch-latest-iso | --fetch-newest-iso | --latest)
      FETCH_LATEST=1
      shift
      ;;
    --test-only)
      TEST_ONLY=1
      shift
      ;;
    -p | --paging)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --paging requires a mode: auto|never." >&2
        exit 1
      fi
      case "$2" in
      auto | AUTO)
        PAGING_MODE="auto"
        ;;
      never | NEVER)
        PAGING_MODE="never"
        ;;
      *)
        echo "ERROR: Unsupported paging mode '$2' (use auto|never)." >&2
        exit 1
        ;;
      esac
      shift 2
      ;;
    --no-paging)
      PAGING_MODE="never"
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
# ISO selection
#-------------------------------------------------------------------------------
function select_iso_interactive() {
  # Prefer fzf if present, but don't depend on it.
  if command -v fzf >/dev/null 2>&1; then
    echo "Select ISO file (fzf):"
    ISO_PATH="$(
      find "$HOME" -type f -name '*.iso' 2>/dev/null |
        fzf --prompt='Choose ISO: '
    )"
  else
    echo "Enter path to ISO file (no fzf available):"
    read -r ISO_PATH
  fi

  if [[ -z "$ISO_PATH" ]]; then
    echo "ERROR: No ISO selected." >&2
    exit 1
  fi
}

function validate_iso_path() {
  if [[ -z "$ISO_PATH" ]]; then
    select_iso_interactive
  fi

  if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO not found: ${ISO_PATH}" >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Device selection
#-------------------------------------------------------------------------------
function list_candidate_disks() {
  echo "Available disks (TYPE=disk):"
  lsblk -dpno NAME,TRAN,SIZE,MODEL,TYPE |
    awk '$5 == "disk" {printf "  %-15s %-5s %-8s %s\n",$1,$2,$3,$4}'
  echo
}

function select_device_interactive() {
  list_candidate_disks

  if command -v fzf >/dev/null 2>&1; then
    TARGET_DEV="$(
      lsblk -dpno NAME,TRAN,SIZE,MODEL,TYPE |
        awk '$5=="disk"{print $1" "$3" "$2" "$4}' |
        fzf --prompt='Choose target disk: ' |
        awk '{print $1}'
    )"
  else
    read -r -p "Enter target disk device (e.g. /dev/sdX): " TARGET_DEV
  fi

  if [[ -z "$TARGET_DEV" ]]; then
    echo "ERROR: No target disk selected." >&2
    exit 1
  fi
}

function validate_target_device() {
  if [[ -z "$TARGET_DEV" ]]; then
    select_device_interactive
  fi

  if [[ ! -b "$TARGET_DEV" ]]; then
    echo "ERROR: ${TARGET_DEV} is not a block device." >&2
    exit 1
  fi

  local type
  type="$(lsblk -dn -o TYPE "$TARGET_DEV" 2>/dev/null || true)"
  if [[ "$type" != "disk" ]]; then
    echo "ERROR: ${TARGET_DEV} is TYPE='${type}'. Use a whole disk, not a" >&2
    echo "       partition. Example: /dev/sdb, not /dev/sdb1." >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Unmount all partitions on target disk
#-------------------------------------------------------------------------------
function unmount_partitions() {
  local dev="$1"
  local parts mp

  parts="$(lsblk -lnpo NAME "$dev" | tail -n +2 || true)"
  if [[ -z "$parts" ]]; then
    return 0
  fi

  echo "Unmounting any mounted partitions on ${dev}..."
  while read -r p; do
    mp="$(awk -v d="$p" '$1==d {print $2}' /proc/self/mounts | head -n1)"
    if [[ -n "$mp" ]]; then
      echo "  umount ${mp}"
      umount "$mp"
    fi
  done <<<"$parts"
}

#-------------------------------------------------------------------------------
# Confirmation
#-------------------------------------------------------------------------------
function confirm_or_abort() {
  echo
  echo "About to write ISO to USB:"
  echo "  ISO : ${ISO_PATH}"
  echo "  Disk: ${TARGET_DEV}"
  echo
  echo "WARNING: ALL data on ${TARGET_DEV} will be DESTROYED."
  echo

  local answer
  read -r -p "Type the full device path (${TARGET_DEV}) to confirm: " answer
  if [[ "$answer" != "$TARGET_DEV" ]]; then
    echo "Aborted: device did not match." >&2
    exit 1
  fi

  read -r -p "Final confirmation: type YES in uppercase: " answer
  if [[ "$answer" != "YES" ]]; then
    echo "Aborted: you did not type YES." >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Writer selection (ddrescue vs dd) – returns *only* the command
#-------------------------------------------------------------------------------
function choose_writer() {
  if command -v ddrescue >/dev/null 2>&1; then
    printf 'ddrescue -v --force "%s" "%s"' \
      "$ISO_PATH" "$TARGET_DEV"
  else
    printf 'dd if="%s" of="%s" bs=%s status=progress conv=fdatasync' \
      "$ISO_PATH" "$TARGET_DEV" "$BLOCK_SIZE"
  fi
}

#-------------------------------------------------------------------------------
# Execute write
#-------------------------------------------------------------------------------
function write_iso_to_usb() {
  local cmd writer

  if command -v ddrescue >/dev/null 2>&1; then
    writer="ddrescue"
  else
    writer="dd"
  fi

  cmd="$(choose_writer)"

  echo
  echo "Using ${writer}."
  echo "Planned write command:"
  echo "  ${cmd}"
  echo

  if [[ "$TEST_ONLY" -eq 1 ]]; then
    echo "(test-only): not executing."
    return 0
  fi

  # cmd already has correct quoting; run it as a single shell command
  eval "$cmd"

  echo
  echo "Syncing buffers..."
  sync || true
}

#-------------------------------------------------------------------------------
# Fetch latest Arch ISO from dotsrc
#-------------------------------------------------------------------------------
function fetch_latest_iso() {
  local base_url="https://mirrors.dotsrc.org/archlinux/iso/latest"
  local file_name="archlinux-x86_64.iso"
  local out_dir="$ISO_DOWNLOAD_DIR"
  local out_path="${out_dir}/${file_name}"

  mkdir -p "$out_dir"

  echo "Fetching latest Arch ISO from:"
  echo "  ${base_url}/${file_name}"
  echo

  curl -L --fail --progress-bar \
    -o "${out_path}.part" \
    "${base_url}/${file_name}"

  mv "${out_path}.part" "$out_path"

  ISO_PATH="$out_path"
  echo "Downloaded ISO to: ${ISO_PATH}"
}

#-------------------------------------------------------------------------------
# main
#-------------------------------------------------------------------------------
function main() {
  ensure_root
  parse_args "$@"

  # If requested, download the latest ISO first.
  if ((FETCH_LATEST == 1)); then
    if [[ -n "$ISO_PATH" ]]; then
      echo "ERROR: Use either --iso or --fetch-latest-iso/--fetch-newest-iso, not both." >&2
      exit 1
    fi
    require_tool curl "downloading latest Arch ISO"
    fetch_latest_iso
  fi

  validate_iso_path
  validate_target_device
  unmount_partitions "$TARGET_DEV"
  confirm_or_abort
  write_iso_to_usb

  echo
  echo "Done. ${TARGET_DEV} should now be a bootable Arch installer (BIOS+UEFI)."
}

main "$@"
