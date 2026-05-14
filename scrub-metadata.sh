#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scrub-block-metadata
#
# Remove recognisable block-device metadata from a target partition/device:
#   - filesystem signatures
#   - swap signatures
#   - LUKS signatures
#   - mdadm RAID superblocks
#   - LVM physical-volume labels
#   - partition-table signatures, if present on the target
#   - metadata located near the start and end of the device
#
# This does NOT securely erase all user data. It only destroys metadata/signatures
# sufficiently that the block device is normally seen as "blank".
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

PROG="${0##*/}"

TARGET=""
EXECUTE=0
YES=0
HEAD_MIB=64
TAIL_MIB=64
BACKUP_DIR=""

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function usage() {
  cat <<EOF
Usage:
  ${PROG} --target DEVICE [options]

Required:
  --target DEVICE
      Block device or partition to scrub, e.g. /dev/nvme0n1p7.

Options:
  --execute
      Actually modify the target. Without this, the script runs in dry-run mode.

  --yes
      Do not ask for interactive confirmation.

  --head-mib N
      Zero the first N MiB of the target. Default: ${HEAD_MIB}.

  --tail-mib N
      Zero the last N MiB of the target. Default: ${TAIL_MIB}.

  --backup-dir DIR
      Directory for wipefs signature backups. If omitted, wipefs backups are
      not requested.

  -h, --help
      Show this help text.

Examples:
  Dry-run inspection:
    sudo ${PROG} --target /dev/nvme0n1p7

  Scrub metadata interactively:
    sudo ${PROG} --target /dev/nvme0n1p7 --execute

  Scrub metadata without prompt:
    sudo ${PROG} --target /dev/nvme0n1p7 --execute --yes

  More aggressive edge wipe:
    sudo ${PROG} --target /dev/nvme0n1p7 --execute --head-mib 256 --tail-mib 256

  Keep wipefs signature backups:
    sudo ${PROG} --target /dev/nvme0n1p7 --execute \\
      --backup-dir /root/wipefs-backups

Important:
  This script is destructive. It is intended for a partition/device that is no
  longer needed in its current form.

  It refuses to operate on mounted devices.

  It does not perform a full secure erase. For SSD/NVMe secure disposal, use
  blkdiscard, nvme format, hdparm secure erase, or full-device overwrite,
  depending on hardware and threat model.
EOF
}

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function info() {
  printf '==> %s\n' "$*" >&2
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run as root, e.g. sudo ${PROG} --target /dev/..."
  fi
}

function shell_quote() {
  printf '%q ' "$@"
}

function run_cmd() {
  if [[ "${EXECUTE}" -eq 1 ]]; then
    printf '+ ' >&2
    shell_quote "$@" >&2
    printf '\n' >&2
    "$@"
  else
    printf '[dry-run] ' >&2
    shell_quote "$@" >&2
    printf '\n' >&2
  fi
}

function parse_uint() {
  local value="$1"
  local name="$2"

  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target)
      [[ "$#" -ge 2 ]] || die "--target requires an argument"
      TARGET="$2"
      shift 2
      ;;

    --execute)
      EXECUTE=1
      shift
      ;;

    --yes)
      YES=1
      shift
      ;;

    --head-mib)
      [[ "$#" -ge 2 ]] || die "--head-mib requires an argument"
      parse_uint "$2" "--head-mib"
      HEAD_MIB="$2"
      shift 2
      ;;

    --tail-mib)
      [[ "$#" -ge 2 ]] || die "--tail-mib requires an argument"
      parse_uint "$2" "--tail-mib"
      TAIL_MIB="$2"
      shift 2
      ;;

    --backup-dir)
      [[ "$#" -ge 2 ]] || die "--backup-dir requires an argument"
      BACKUP_DIR="$2"
      shift 2
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      die "unknown argument: $1"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

require_root

[[ -n "${TARGET}" ]] || die "missing --target DEVICE"
[[ -b "${TARGET}" ]] || die "not a block device: ${TARGET}"

if [[ -n "${BACKUP_DIR}" ]]; then
  if [[ "${EXECUTE}" -eq 1 ]]; then
    mkdir -p -- "${BACKUP_DIR}"
    chmod 0700 -- "${BACKUP_DIR}"
  fi
fi

if findmnt --source "${TARGET}" >/dev/null 2>&1; then
  die "${TARGET} is mounted; unmount it first"
fi

if have lsblk; then
  if lsblk -nrpo MOUNTPOINT "${TARGET}" | grep -q '[^[:space:]]'; then
    die "${TARGET} or a child device appears mounted"
  fi
fi

# Refuse obvious system roots unless explicitly targeting something else.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ -n "${ROOT_SRC}" && "${TARGET}" == "${ROOT_SRC}" ]]; then
  die "refusing to scrub the current root device: ${TARGET}"
fi

# -----------------------------------------------------------------------------
# Pre-flight report
# -----------------------------------------------------------------------------

info "target: ${TARGET}"
info "mode: $([[ "${EXECUTE}" -eq 1 ]] && echo execute || echo dry-run)"
info "head wipe: ${HEAD_MIB} MiB"
info "tail wipe: ${TAIL_MIB} MiB"

printf '\n-- lsblk -------------------------------------------------------------\n'
lsblk -o NAME,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS "${TARGET}" || true

printf '\n-- blkid probe -------------------------------------------------------\n'
blkid -p "${TARGET}" || true

printf '\n-- wipefs signatures -------------------------------------------------\n'
wipefs -n "${TARGET}" || true

if have cryptsetup; then
  printf '\n-- cryptsetup --------------------------------------------------------\n'
  if cryptsetup isLuks "${TARGET}" 2>/dev/null; then
    printf '%s appears to contain a LUKS header.\n' "${TARGET}"
  else
    printf 'No active LUKS header detected by cryptsetup.\n'
  fi
fi

if have mdadm; then
  printf '\n-- mdadm examine -----------------------------------------------------\n'
  mdadm --examine "${TARGET}" || true
fi

printf '\n'

if [[ "${EXECUTE}" -ne 1 ]]; then
  info "dry-run only; add --execute to modify ${TARGET}"
  exit 0
fi

if [[ "${YES}" -ne 1 ]]; then
  printf 'Type exactly SCRUB %s to continue: ' "${TARGET}" >&2
  read -r answer

  if [[ "${answer}" != "SCRUB ${TARGET}" ]]; then
    die "confirmation failed; no changes made"
  fi
fi

# -----------------------------------------------------------------------------
# Scrub known metadata tools first
# -----------------------------------------------------------------------------

sync

if have mdadm; then
  info "zeroing mdadm superblocks, if present"
  run_cmd mdadm --zero-superblock --force "${TARGET}" || true
else
  warn "mdadm not found; skipping mdadm --zero-superblock"
fi

if have pvremove; then
  info "removing LVM PV label, if present"
  run_cmd pvremove --force --force --yes "${TARGET}" || true
else
  warn "pvremove not found; skipping LVM PV label removal"
fi

if have cryptsetup; then
  if cryptsetup isLuks "${TARGET}" 2>/dev/null; then
    info "erasing LUKS keyslots, if possible"
    run_cmd cryptsetup luksErase --batch-mode "${TARGET}" || true
  fi
else
  warn "cryptsetup not found; skipping LUKS keyslot erase"
fi

# -----------------------------------------------------------------------------
# wipefs removes signatures known to libblkid
# -----------------------------------------------------------------------------

info "removing libblkid-visible signatures with wipefs"

WIPEFS_ARGS=(--all --force)

if [[ -n "${BACKUP_DIR}" ]]; then
  WIPEFS_ARGS+=(--backup --backup-file "${BACKUP_DIR}/wipefs-${TARGET//\//_}")
fi

run_cmd wipefs "${WIPEFS_ARGS[@]}" "${TARGET}"

# -----------------------------------------------------------------------------
# Wipe start and end regions
# -----------------------------------------------------------------------------

SIZE_BYTES="$(blockdev --getsize64 "${TARGET}")"
MIB=$((1024 * 1024))
SIZE_MIB=$((SIZE_BYTES / MIB))

if [[ "${SIZE_MIB}" -le 0 ]]; then
  die "could not determine usable size of ${TARGET}"
fi

if [[ "${HEAD_MIB}" -gt 0 ]]; then
  HEAD_COUNT="${HEAD_MIB}"

  if [[ "${HEAD_COUNT}" -gt "${SIZE_MIB}" ]]; then
    HEAD_COUNT="${SIZE_MIB}"
  fi

  info "zeroing first ${HEAD_COUNT} MiB"
  run_cmd dd if=/dev/zero of="${TARGET}" bs=1M count="${HEAD_COUNT}" \
    conv=fsync status=progress
fi

if [[ "${TAIL_MIB}" -gt 0 ]]; then
  TAIL_COUNT="${TAIL_MIB}"

  if [[ "${TAIL_COUNT}" -gt "${SIZE_MIB}" ]]; then
    TAIL_COUNT="${SIZE_MIB}"
  fi

  TAIL_SEEK=$((SIZE_MIB - TAIL_COUNT))

  info "zeroing last ${TAIL_COUNT} MiB"
  run_cmd dd if=/dev/zero of="${TARGET}" bs=1M seek="${TAIL_SEEK}" \
    count="${TAIL_COUNT}" conv=fsync status=progress
fi

sync

# -----------------------------------------------------------------------------
# Kernel/device refresh
# -----------------------------------------------------------------------------

info "refreshing kernel block-device view"

if have udevadm; then
  run_cmd udevadm settle || true
fi

run_cmd blockdev --rereadpt "${TARGET}" || true

# -----------------------------------------------------------------------------
# Post-flight report
# -----------------------------------------------------------------------------

printf '\n-- post-scrub wipefs signatures -------------------------------------\n'
wipefs -n "${TARGET}" || true

printf '\n-- post-scrub blkid probe -------------------------------------------\n'
blkid -p "${TARGET}" || true

info "done"
