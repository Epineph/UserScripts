#!/usr/bin/env bash
# win-usb-maker.sh — Create a Windows installer USB (BIOS+UEFI) from an ISO
# Version: 0.7.0
# License: GPL-3.0-or-later
# Requires: bash>=4.3, coreutils, util-linux, grep, gawk, findutils, sed,
#           parted, dosfstools (mkfs.fat/mkfs.vfat), ntfs-3g (mkntfs),
#           grub-pc-bin (grub-install i386-pc), grub-common,
#           p7zip (7z) [optional: Win7 UEFI fix], wimlib-imagex [optional]
# Notes:
#  - Defaults to NTFS+UEFI:NTFS so UEFI boot works with >4 GiB install.wim.
#  - “Fit-to-ISO” sizes the data partition using ISO content size + headroom.
#  - Leaves remaining device space unallocated for your own partitions.
#  - Uses a tiny FAT UEFI:NTFS partition at the *front* of the disk (p1),
#    then the data partition (p2), then free space (rest).
#  - Run with --dry-run first. **This will DESTROY the target device.**
#  - Must be executed as root (or via sudo).
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Globals (defaults)
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
VERSION="0.7.0"

ISO_PATH=""
TARGET_DEV=""
TARGET_FS="ntfs"             # ntfs | fat32
VOL_LABEL="WINSTALL"         # volume label
FIT_MODE="fit"               # fit | whole
HEADROOM_PCT=7               # percentage overhead added in fit mode
HEADROOM_MIN_MIB=1024        # minimum MiB headroom in fit mode
SMALL_FAT_MIB=8              # size of UEFI:NTFS FAT partition (MiB, >= 2)
DO_UEFI_NTFS="yes"           # only relevant for ntfs targets
DO_BIOS_GRUB="yes"           # install GRUB (legacy BIOS)
SPLIT_WIM="no"               # split WIM if FAT32 and >4GiB (needs wimlib)
FORCE="no"                   # skip destructive prompt
DRYRUN="no"                  # print actions only
QUIET="no"                   # reduce chatter

# UEFI:NTFS image (Rufus’ 1 MiB prebuilt image). Can override via env/CLI.
UEFI_NTFS_IMG_URL="${UEFI_NTFS_IMG_URL:-https://raw.githubusercontent.com/\
pbatard/rufus/master/res/uefi/uefi-ntfs.img}"

# Runtime state
WORKDIR=""
MNT_ISO=""
MNT_USB=""
P1_FAT=""                    # e.g., /dev/sdX1
P2_DATA=""                   # e.g., /dev/sdX2

# ──────────────────────────────────────────────────────────────────────────────
# Styled help (Markdown here-doc; helpout/batwrap/bat fallback to cat)
# ──────────────────────────────────────────────────────────────────────────────
function _pager() {
  if command -v helpout >/dev/null 2>&1; then
    helpout
  elif command -v batwrap >/dev/null 2>&1; then
    batwrap
  elif command -v bat >/dev/null 2>&1; then
    bat --style="grid,header,snip" --italic-text="always" \
        --theme="gruvbox-dark" --squeeze-blank --squeeze-limit="2" \
        --force-colorization --terminal-width="auto" --tabs="2" \
        --paging="never" --chop-long-lines
  else
    cat
  fi
}

function print_help() {
  cat <<'EOF' | _pager
# `win-usb-maker.sh` — Create a Windows installer USB (BIOS + UEFI)

**Synopsis**
- `win-usb-maker.sh --iso <path.iso> --device </dev/sdX|/dev/nvmeXnY> [opts]`
- `win-usb-maker.sh --dry-run --iso Win11.iso --device /dev/sdX --fit`
- `win-usb-maker.sh --iso Win10.iso --device /dev/sdX --fs fat32 --split-wim`

**Description**
Creates a Windows installation USB from a local ISO, supporting:
- **UEFI boot on NTFS** via Rufus’ *UEFI:NTFS* (small FAT partition + NTFS data)
  so you can install Windows even if `install.wim > 4 GiB`.
- **Legacy BIOS** via GRUB (i386-pc) that chainloads `/bootmgr`.
- **Fit-to-ISO** partitioning: the data partition uses *only* the required space
  (ISO content + headroom), leaving the rest of the device unallocated.

**Destructive**: the target device will be repartitioned. Use `--dry-run` first.

**Requirements**
- `parted`, `mkfs.fat|mkfs.vfat`, `mkntfs` (ntfs-3g), `grub-install` (i386-pc),
  `7z` (optional, Win7 UEFI fix), `wimlib-imagex` (optional, WIM split),
  `mount`, `lsblk`, `dd`, `curl` or `wget`.

**Key Options**
- `--iso <path>`               Windows ISO path (required)
- `--device </dev/sdX>`        Target block device (required, not a partition)
- `--fs <ntfs|fat32>`          Target filesystem (default: ntfs)
- `--fit | --whole`            Partition only what’s needed (default: --fit)
- `--headroom-pct <N>`         Extra % space added in --fit (default: 7)
- `--headroom-min-mib <MiB>`   Minimum headroom in MiB (default: 1024)
- `--label <VOL>`              Volume label (default: WINSTALL)
- `--no-uefi-ntfs`             Disable UEFI:NTFS (NTFS will be BIOS-only)
- `--no-bios-grub`             Skip GRUB install (UEFI-only media)
- `--split-wim`                If FAT32 and >4GiB WIM, split via wimlib
- `--force`                    Do not prompt before destroying partitions
- `--dry-run`                  Print actions; do not modify anything
- `-q, --quiet`                Less verbose
- `-h, --help`                 Show this help
- `--version`                  Print version

**Partition Layout**
- NTFS target:  [ p1: FAT (UEFI:NTFS, ~8 MiB) ] + [ p2: NTFS data (fit/whole) ] +
                [ free space (remainder of device) ].
- FAT32 target: [ p1: FAT32 data (fit/whole) ] + [ free space ].
  (No UEFI:NTFS needed. For >4 GiB WIM use `--split-wim` or choose NTFS.)

**Safety**
- This script wipes the partition table. Triple-check `--device`.
- Prefer `--dry-run` first. Example:
  `sudo ./win-usb-maker.sh --dry-run --iso Win11.iso --device /dev/sdX`

EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────────────────────────────────────
function die() { echo "ERROR: $*" >&2; exit 1; }
function info() { [[ "$QUIET" == "yes" ]] || echo "→ $*"; }
function run()  { [[ "$DRYRUN" == "yes" ]] && { echo "[DRY] $*"; return 0; }
                  eval "$@"; }

function need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."
}

function check_cmds() {
  local missing=()
  local req=(parted lsblk dd mount umount awk sed grep cut tr du stat)
  local fs_any="mkfs.fat|mkfs.vfat"
  local have_fat_mkfs=""
  command -v mkfs.fat >/dev/null 2>&1 && have_fat_mkfs="mkfs.fat"
  command -v mkfs.vfat >/dev/null 2>&1 && have_fat_mkfs="${have_fat_mkfs:-mkfs.vfat}"
  [[ -n "$have_fat_mkfs" ]] || req+=("mkfs.fat (or mkfs.vfat)")

  command -v mkntfs >/dev/null 2>&1 || req+=("mkntfs")
  command -v grub-install >/dev/null 2>&1 || req+=("grub-install (i386-pc)")
  command -v 7z >/dev/null 2>&1 || info "Note: 7z not found (Win7 UEFI fix disabled)"
  command -v wimlib-imagex >/dev/null 2>&1 || info "Note: wimlib-imagex not found"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    req+=("curl or wget")
  fi
  if ((${#req[@]})); then
    printf 'Missing required tools:\n' >&2
    printf '  - %s\n' "${req[@]}" >&2
    exit 1
  fi
}

function mkfs_fat() {
  if command -v mkfs.fat >/dev/null 2>&1; then
    run mkfs.fat -F 32 -n "$VOL_LABEL" "$1"
  else
    run mkfs.vfat -F 32 -n "$VOL_LABEL" "$1"
  fi
}

function fetch_uefi_ntfs_img() {
  local out="$1"
  if command -v curl >/dev/null 2>&1; then
    run curl -fsSL "$UEFI_NTFS_IMG_URL" -o "$out"
  else
    run wget -qO "$out" "$UEFI_NTFS_IMG_URL"
  fi
  [[ -s "$out" ]] || die "Failed to download UEFI:NTFS image."
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
  local argv=("$@")
  while ((${#argv[@]})); do
    case "${argv[0]}" in
      --iso)               ISO_PATH="${argv[1]}"; shift 2;;
      --device)            TARGET_DEV="${argv[1]}"; shift 2;;
      --fs)                TARGET_FS="${argv[1]}"; shift 2;;
      --label)             VOL_LABEL="${argv[1]}"; shift 2;;
      --fit)               FIT_MODE="fit"; shift 1;;
      --whole)             FIT_MODE="whole"; shift 1;;
      --headroom-pct)      HEADROOM_PCT="${argv[1]}"; shift 2;;
      --headroom-min-mib)  HEADROOM_MIN_MIB="${argv[1]}"; shift 2;;
      --small-fat-mib)     SMALL_FAT_MIB="${argv[1]}"; shift 2;;
      --no-uefi-ntfs)      DO_UEFI_NTFS="no"; shift 1;;
      --no-bios-grub)      DO_BIOS_GRUB="no"; shift 1;;
      --split-wim)         SPLIT_WIM="yes"; shift 1;;
      --dry-run)           DRYRUN="yes"; shift 1;;
      --force)             FORCE="yes"; shift 1;;
      -q|--quiet)          QUIET="yes"; shift 1;;
      --version)           echo "$SCRIPT_NAME $VERSION"; exit 0;;
      -h|--help)           print_help; exit 0;;
      *) die "Unknown option: ${argv[0]} (use --help)";;
    esac
  done

  [[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || die "--iso <path.iso> is required"
  [[ -n "$TARGET_DEV" && -b "$TARGET_DEV" ]] || die "--device </dev/...> is required"
  [[ "$TARGET_DEV" =~ [0-9]$ ]] && die "--device must be a *disk*, not a partition"
  [[ "$TARGET_FS" =~ ^(ntfs|fat32)$ ]] || die "--fs must be ntfs or fat32"
  (( SMALL_FAT_MIB >= 2 )) || die "--small-fat-mib must be >= 2"
}

# ──────────────────────────────────────────────────────────────────────────────
# Mount helpers and cleanup
# ──────────────────────────────────────────────────────────────────────────────
function setup_workdirs() {
  WORKDIR="$(mktemp -d -t winusb.XXXXXX)"
  MNT_ISO="$WORKDIR/mnt_iso"
  MNT_USB="$WORKDIR/mnt_usb"
  run mkdir -p "$MNT_ISO" "$MNT_USB"
  trap cleanup EXIT
}

function cleanup() {
  set +e
  [[ -n "$MNT_USB" ]] && mountpoint -q "$MNT_USB" && umount -l "$MNT_USB"
  [[ -n "$MNT_ISO" ]] && mountpoint -q "$MNT_ISO" && umount -l "$MNT_ISO"
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
  set -e
}

# ──────────────────────────────────────────────────────────────────────────────
# Sizing logic (fit-to-ISO)
# ──────────────────────────────────────────────────────────────────────────────
function calc_fit_size_mib() {
  # Mount ISO and measure apparent file size, add headroom.
  info "Mounting ISO to compute size…"
  run mount -o ro,loop "$ISO_PATH" "$MNT_ISO"
  local iso_mib
  iso_mib="$(du -sm --apparent-size "$MNT_ISO" | awk '{print $1}')"
  [[ "$iso_mib" =~ ^[0-9]+$ ]] || die "Could not size ISO content."

  local extra_pct=$(( (iso_mib * HEADROOM_PCT + 99) / 100 ))
  local added=$(( extra_pct > HEADROOM_MIN_MIB ? extra_pct : HEADROOM_MIN_MIB ))
  local total=$(( iso_mib + added ))
  info "ISO content ≈ ${iso_mib} MiB; headroom ${added} MiB; total ${total} MiB"
  echo "$total"
}

# ──────────────────────────────────────────────────────────────────────────────
# Partitioning & formatting
# ──────────────────────────────────────────────────────────────────────────────
function unmount_device_partitions() {
  info "Ensuring target partitions are unmounted…"
  local parts
  parts="$(lsblk -ln -o NAME "$TARGET_DEV" | tail -n +2 || true)"
  while read -r p; do
    [[ -z "$p" ]] && continue
    local node="/dev/$p"
    if mountpoint -q -- "$(lsblk -no MOUNTPOINT "$node" 2>/dev/null)"; then
      run umount -l "$node" || true
    fi
  done <<< "$parts"
}

function wipe_device() {
  info "Wiping signatures and partition table on $TARGET_DEV…"
  run wipefs -a "$TARGET_DEV"
  run parted -s "$TARGET_DEV" mklabel msdos
}

function partition_whole_fat32() {
  info "Creating [ p1: FAT32 (whole device) ]…"
  run parted -s "$TARGET_DEV" mkpart primary fat32 1MiB 100%
  run parted -s "$TARGET_DEV" set 1 boot on
  P1_FAT="${TARGET_DEV}1"
  P2_DATA=""  # not used in FAT32 layout
}

function partition_fit_fat32(size_mib) {
  local end_mib="$1"
  info "Creating [ p1: FAT32 ${end_mib} MiB ] + [ free space ]…"
  run parted -s "$TARGET_DEV" mkpart primary fat32 1MiB "$(( end_mib ))MiB"
  run parted -s "$TARGET_DEV" set 1 boot on
  P1_FAT="${TARGET_DEV}1"
}

function partition_fit_ntfs(size_mib) {
  local data_mib="$1"
  local a="$SMALL_FAT_MIB"
  local p1_start=1
  local p1_end=$(( p1_start + a ))          # 1MiB..(1+SMALL_FAT_MIB)MiB
  local p2_start="$p1_end"
  local p2_end=$(( p2_start + data_mib ))   # then free space after

  info "Creating [ p1: FAT (UEFI:NTFS) ${SMALL_FAT_MIB} MiB ] + " \
       "[ p2: NTFS ${data_mib} MiB ] + [ free space ]…"
  run parted -s "$TARGET_DEV" mkpart primary fat16 "${p1_start}MiB" "${p1_end}MiB"
  run parted -s "$TARGET_DEV" set 1 esp on
  run parted -s "$TARGET_DEV" mkpart primary ntfs  "${p2_start}MiB" "${p2_end}MiB"
  run parted -s "$TARGET_DEV" set 2 boot on
  P1_FAT="${TARGET_DEV}1"
  P2_DATA="${TARGET_DEV}2"
}

function partition_whole_ntfs() {
  # Whole-device NTFS still needs a tiny FAT p1 (UEFI:NTFS) and p2 = rest.
  info "Creating [ p1: FAT (UEFI:NTFS) ${SMALL_FAT_MIB} MiB ] + [ p2: NTFS 100% ]…"
  local p1_start=1
  local p1_end=$(( p1_start + SMALL_FAT_MIB ))
  run parted -s "$TARGET_DEV" mkpart primary fat16 "${p1_start}MiB" "${p1_end}MiB"
  run parted -s "$TARGET_DEV" set 1 esp on
  run parted -s "$TARGET_DEV" mkpart primary ntfs  "${p1_end}MiB" 100%
  run parted -s "$TARGET_DEV" set 2 boot on
  P1_FAT="${TARGET_DEV}1"
  P2_DATA="${TARGET_DEV}2"
}

function format_partitions() {
  sync
  partprobe "$TARGET_DEV" || true
  sleep 1
  if [[ "$TARGET_FS" == "fat32" ]]; then
    [[ -n "$P1_FAT" ]] || die "Internal error: no FAT data partition"
    info "Formatting FAT32 data partition ($P1_FAT)…"
    mkfs_fat "$P1_FAT"
  else
    [[ -n "$P2_DATA" && -n "$P1_FAT" ]] || die "Internal error: NTFS layout invalid"
    info "Formatting NTFS data partition ($P2_DATA)…"
    run mkntfs -Q -F -L "$VOL_LABEL" "$P2_DATA"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# UEFI:NTFS (NTFS targets) + BIOS GRUB
# ──────────────────────────────────────────────────────────────────────────────
function install_uefi_ntfs() {
  [[ "$TARGET_FS" == "ntfs" ]] || return 0
  [[ "$DO_UEFI_NTFS" == "yes" ]] || { info "Skipping UEFI:NTFS by request"; return 0; }

  info "Installing UEFI:NTFS to small FAT partition ($P1_FAT)…"
  local img="$WORKDIR/uefi-ntfs.img"
  fetch_uefi_ntfs_img "$img"
  # Write image directly to the FAT partition node.
  run dd if="$img" of="$P1_FAT" bs=1M conv=fsync status=none
}

function install_grub_bios() {
  [[ "$DO_BIOS_GRUB" == "yes" ]] || { info "Skipping BIOS GRUB by request"; return 0; }

  info "Installing GRUB (i386-pc) MBR bootloader to $TARGET_DEV…"
  # Mount data partition to place /boot/grub + grub.cfg there.
  local data_part
  if [[ "$TARGET_FS" == "fat32" ]]; then
    data_part="$P1_FAT"
  else
    data_part="$P2_DATA"
  fi
  run mount "$data_part" "$MNT_USB"

  # Install GRUB to the device’s MBR, boot directory on the data partition.
  run grub-install --target=i386-pc --boot-directory="$MNT_USB/boot" \
      --modules="ntfs fat part_msdos" "$TARGET_DEV"

  # Minimal grub.cfg: chainload Windows bootmgr
  cat > "$MNT_USB/boot/grub/grub.cfg" <<'GRUBEOF'
insmod part_msdos
insmod ntfs
insmod fat
set default=0
set timeout=0
menuentry "Windows Installer" {
  if [ -f (hd0,msdos2)/bootmgr ]; then
    ntldr (hd0,msdos2)/bootmgr
  elif [ -f (hd0,msdos1)/bootmgr ]; then
    ntldr (hd0,msdos1)/bootmgr
  else
    echo "bootmgr not found on msdos1 or msdos2"
    sleep 3
  fi
}
GRUBEOF

  sync
  umount "$MNT_USB"
}

# ──────────────────────────────────────────────────────────────────────────────
# File copy + Win7 UEFI fix + optional WIM split for FAT32
# ──────────────────────────────────────────────────────────────────────────────
function mount_iso_and_target() {
  run mount -o ro,loop "$ISO_PATH" "$MNT_ISO"
  local data_part
  if [[ "$TARGET_FS" == "fat32" ]]; then data_part="$P1_FAT"; else data_part="$P2_DATA"; fi
  run mount "$data_part" "$MNT_USB"
}

function copy_iso_contents() {
  info "Copying ISO contents to USB (this may take a while)…"
  # Use rsync if available; else fallback to cp -a
  if command -v rsync >/dev/null 2>&1; then
    run rsync -aHAX --info=progress2 "$MNT_ISO"/ "$MNT_USB"/
  else
    run cp -a "$MNT_ISO"/. "$MNT_USB"/
  fi
}

function win7_uefi_fix_if_needed() {
  # If EFI/BOOT/bootx64.efi is missing, try to extract from install.wim
  if [[ ! -f "$MNT_USB/EFI/BOOT/bootx64.efi" ]] && command -v 7z >/dev/null 2>&1; then
    if [[ -f "$MNT_USB/sources/install.wim" ]]; then
      info "Applying Win7 UEFI fix: extracting bootmgfw.efi → EFI/BOOT/bootx64.efi"
      run mkdir -p "$MNT_USB/EFI/BOOT"
      run 7z e -y -so "$MNT_USB/sources/install.wim" \
          'Windows/Boot/EFI/bootmgfw.efi' > "$MNT_USB/EFI/BOOT/bootx64.efi"
      sync
    fi
  fi
}

function maybe_split_wim_for_fat32() {
  [[ "$TARGET_FS" == "fat32" ]] || return 0
  local wim="$MNT_USB/sources/install.wim"
  if [[ -f "$wim" ]]; then
    local sz
    sz="$(stat -c %s "$wim")"
    # 4GiB = 4*1024^3 = 4294967296
    if (( sz > 4294967295 )); then
      if [[ "$SPLIT_WIM" == "yes" ]] && command -v wimlib-imagex >/dev/null 2>&1; then
        info "Splitting install.wim for FAT32 via wimlib-imagex…"
        run mv "$wim" "$wim.bak"
        run wimlib-imagex split "$wim.bak" "$MNT_USB/sources/install.swm" 4000
        sync
        info "WIM split complete; removing original WIM"
        run rm -f "$wim.bak"
      else
        die "install.wim > 4 GiB on FAT32; use --split-wim (needs wimlib) or --fs ntfs"
      fi
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main() {
  need_root
  parse_args "$@"
  check_cmds
  setup_workdirs

  info "Target device: $TARGET_DEV"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$TARGET_DEV" | sed 's/^/  /'
  [[ "$FORCE" == "yes" ]] || {
    echo
    read -r -p "This will ERASE all data on $TARGET_DEV. Continue? [yes/N]: " a
    [[ "$a" == "yes" ]] || die "Aborted."
  }

  unmount_device_partitions
  wipe_device

  local fit_mib=""
  if [[ "$FIT_MODE" == "fit" ]]; then
    fit_mib="$(calc_fit_size_mib)"
    # If NTFS target, reserve the front FAT p1 space too (handled in partition fn)
  fi

  if [[ "$TARGET_FS" == "fat32" ]]; then
    if [[ "$FIT_MODE" == "fit" ]]; then
      partition_fit_fat32 "$fit_mib"
    else
      partition_whole_fat32
    fi
  else
    if [[ "$FIT_MODE" == "fit" ]]; then
      partition_fit_ntfs "$fit_mib"
    else
      partition_whole_ntfs
    fi
  fi

  format_partitions
  install_uefi_ntfs
  mount_iso_and_target
  copy_iso_contents
  win7_uefi_fix_if_needed
  maybe_split_wim_for_fat32
  umount "$MNT_USB"
  umount "$MNT_ISO"
  install_grub_bios

  info "Done. USB is ready."
  info "Layout:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DEV" | sed 's/^/  /'
}

main "$@"

