#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# zfs-checklist.sh
#
# Purpose:
#   A sequential “check-list” style ZFS experiment on a *single* spare
#   partition (data pool, not root-on-ZFS).
#
# Key properties:
#   - Dry-run by default (prints commands).
#   - Destructive actions require: --apply --confirm
#   - Minimal flags; customize via the CONFIG section below.
#
# Scope:
#   - No LUKS. No mdraid. No bootloader. No root filesystem changes.
#   - Intended for short-lived experiments on a small partition.
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# CONFIG (edit these; keep CLI flags minimal)
# -----------------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-tank}"
TOP_DATASET="${TOP_DATASET:-exp}"
MNT_BASE="${MNT_BASE:-/tank}"

# Child datasets created under: ${POOL_NAME}/${TOP_DATASET}
# Mountpoints: ${MNT_BASE}/Work, ${MNT_BASE}/Scratch, ...
CHILD_DATASETS="${CHILD_DATASETS:-Work Scratch}"

# Pool defaults for SSD/NVMe experiments
ASHIFT="${ASHIFT:-12}"
AUTOTRIM="${AUTOTRIM:-on}"          # on|off
COMPRESSION="${COMPRESSION:-zstd}"  # zstd|lz4|off
RELATIME="${RELATIME:-on}"          # on|off
ATIME="${ATIME:-off}"               # on|off

# Import behavior:
#   cache  -> cachefile=/etc/zfs/zpool.cache + enable zfs-import-cache if present
#   scan   -> cachefile=none + enable zfs-import-scan if present
IMPORT_MODE="${IMPORT_MODE:-cache}" # cache|scan|none

# Optional swap ZVOL (leave empty to disable)
SWAP_SIZE="${SWAP_SIZE:-}"          # e.g. "2G"

# Optional extra wipe (SSD/NVMe). Only used with --confirm + --apply.
DO_DISCARD="${DO_DISCARD:-0}"       # 0|1

# -----------------------------------------------------------------------------
# CLI state (keep this intentionally small)
# -----------------------------------------------------------------------------
CMD="${1:-create}"
DEV=""
APPLY=0
CONFIRM=0
PAGER=0

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function die() {
  printf 'ERROR: %s\n' "${1}" >&2
  exit 1
}

function have() {
  command -v "${1}" >/dev/null 2>&1
}

function run() {
  printf '+'
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
  printf '\n'
  if [[ "${APPLY}" -eq 1 ]]; then
    "$@"
  fi
}

function header() {
  printf '\n%s\n' "============================================================================="
  printf '%s\n' "${1}"
  printf '%s\n' "============================================================================="
}

function unit_exists() {
  local unit="${1}"
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' \
  | grep -Fxq "${unit}"
}

function enable_unit_if_exists() {
  local unit="${1}"
  if unit_exists "${unit}"; then
    run sudo systemctl enable --now "${unit}"
  fi
}

function show_help() {
  local txt
  txt="$(
    cat <<'EOF'
zfs-checklist.sh — sequential ZFS experiment (single spare partition)

USAGE
  zfs-checklist.sh <create|destroy|status|plan> --dev /dev/XYZ [--apply --confirm]
  zfs-checklist.sh --help

SAFETY
  - Default is DRY-RUN (prints commands).
  - Any destructive steps require BOTH:
      --apply     (execute commands)
      --confirm   (acknowledge wipe/destroy)
  - The script refuses to touch mounted partitions.

CONFIG
  Edit the CONFIG section at the top (POOL_NAME, MNT_BASE, datasets, etc.).
  You may also override via environment variables, e.g.:
    POOL_NAME=tank MNT_BASE=/tank CHILD_DATASETS="Work Scratch" ./zfs-checklist.sh ...

OPTIONS
  --dev <path>   Target partition (required for create/destroy/plan)
  --apply        Execute (otherwise dry-run)
  --confirm      Required for destructive steps (wipe/destroy)
  --pager        Page --help using bat if available, else cat

EXAMPLES (5+)
  1) Dry-run plan (recommended):
     ./zfs-checklist.sh plan --dev /dev/nvme0n1p5

  2) Dry-run create (prints everything it would do):
     ./zfs-checklist.sh create --dev /dev/nvme0n1p5

  3) Actually create pool + datasets (DESTRUCTIVE):
     ./zfs-checklist.sh create --dev /dev/nvme0n1p5 --apply --confirm

  4) Create with swap zvol (2G) via env override:
     SWAP_SIZE=2G ./zfs-checklist.sh create --dev /dev/nvme0n1p5 --apply --confirm

  5) Inspect status:
     ./zfs-checklist.sh status

  6) Destroy pool and wipe signatures (DESTRUCTIVE):
     ./zfs-checklist.sh destroy --dev /dev/nvme0n1p5 --apply --confirm

NOTES (Arch)
  - This script assumes ZFS userland exists: zpool + zfs commands.
  - It does not force an install method; it will tell you what is missing.
EOF
  )"

  if [[ "${PAGER}" -eq 1 ]] && have bat; then
    printf '%s\n' "${txt}" \
    | bat --style="grid,header,snip" \
          --italic-text="always" \
          --theme="gruvbox-dark" \
          --squeeze-blank \
          --squeeze-limit="2" \
          --force-colorization \
          --terminal-width="auto" \
          --tabs="2" \
          --paging="always" \
          --chop-long-lines
  else
    printf '%s\n' "${txt}" | cat
  fi
}

function parse_args() {
  shift || true  # shift off CMD
  while [[ "$#" -gt 0 ]]; do
    case "${1}" in
      -h|--help)
        show_help
        exit 0
        ;;
      --dev)
        DEV="${2:-}"; shift 2
        ;;
      --apply)
        APPLY=1; shift
        ;;
      --confirm)
        CONFIRM=1; shift
        ;;
      --pager)
        PAGER=1; shift
        ;;
      *)
        die "Unknown argument: ${1}"
        ;;
    esac
  done
}

function validate_modes() {
  case "${IMPORT_MODE}" in
    cache|scan|none) : ;;
    *) die "IMPORT_MODE must be: cache|scan|none" ;;
  esac
  case "${AUTOTRIM}" in
    on|off) : ;;
    *) die "AUTOTRIM must be: on|off" ;;
  esac
  case "${COMPRESSION}" in
    zstd|lz4|off) : ;;
    *) die "COMPRESSION must be: zstd|lz4|off" ;;
  esac
  case "${RELATIME}" in
    on|off) : ;;
    *) die "RELATIME must be: on|off" ;;
  esac
  case "${ATIME}" in
    on|off) : ;;
    *) die "ATIME must be: on|off" ;;
  esac
}

function require_dev() {
  [[ -n "${DEV}" ]] || die "--dev is required."
  [[ -b "${DEV}" ]] || die "Not a block device: ${DEV}"

  local mp
  mp="$(lsblk -no MOUNTPOINT "${DEV}" | head -n1 || true)"
  [[ -z "${mp}" ]] || die "Device is mounted at: ${mp} (refusing)."

  if swapon --show=NAME 2>/dev/null | awk '{print $1}' | grep -Fxq "${DEV}"; then
    die "Device appears to be active swap: ${DEV} (refusing)."
  fi
}

function require_zfs_tools() {
  have zpool || die "Missing 'zpool'. Install ZFS userspace first."
  have zfs  || die "Missing 'zfs'. Install ZFS userspace first."
}

function require_destructive_ok() {
  [[ "${APPLY}" -eq 1 ]] || die "Refusing: add --apply to execute."
  [[ "${CONFIRM}" -eq 1 ]] || die "Refusing: add --confirm for destructive steps."
}

# -----------------------------------------------------------------------------
# Checklist steps (sequential)
# -----------------------------------------------------------------------------
function step_00_preflight() {
  header "STEP 00: Preflight"
  validate_modes

  run uname -r
  run lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "${DEV}"
  run sudo -v
}

function step_01_zfs_presence() {
  header "STEP 01: Verify ZFS tools are present"
  require_zfs_tools
  run zpool --version
  run zfs --version
}

function step_02_load_module() {
  header "STEP 02: Load ZFS module and persist across boots"
  run sudo modprobe zfs
  run sudo tee /etc/modules-load.d/zfs.conf >/dev/null <<<"zfs"
}

function step_03_hostid_best_effort() {
  header "STEP 03: Best-effort hostid (helps stable imports)"
  if [[ ! -f /etc/hostid ]] && have zgenhostid; then
    run sudo zgenhostid -f -o /etc/hostid
  else
    run ls -l /etc/hostid || true
  fi
}

function step_04_mark_gpt_type_best_effort() {
  header "STEP 04: Mark GPT type as ZFS (bf01) (best-effort)"
  if have sgdisk; then
    local disk partno
    disk="/dev/$(lsblk -no pkname "${DEV}")"
    partno="$(cat "/sys/class/block/$(basename "${DEV}")/partition" 2>/dev/null \
      || true)"
    if [[ -n "${partno}" ]]; then
      run sudo sgdisk -t "${partno}:bf01" "${disk}" || true
    fi
  else
    printf 'NOTE: sgdisk not found; skipping GPT type marking.\n'
  fi
}

function step_05_wipe_signatures() {
  header "STEP 05: Wipe signatures (DESTRUCTIVE)"
  require_destructive_ok

  run sudo zpool labelclear -f "${DEV}" || true
  run sudo wipefs -a "${DEV}"

  if [[ "${DO_DISCARD}" -eq 1 ]] && have blkdiscard; then
    run sudo blkdiscard -f "${DEV}" || true
  fi
}

function step_06_create_pool() {
  header "STEP 06: Create pool (single device)"
  require_destructive_ok

  if sudo zpool list -H -o name 2>/dev/null | grep -Fxq "${POOL_NAME}"; then
    die "Pool already exists: ${POOL_NAME}"
  fi

  run sudo mkdir -p /etc/zfs

  run sudo zpool create -f \
    -o ashift="${ASHIFT}" \
    -o autotrim="${AUTOTRIM}" \
    -O compression="${COMPRESSION}" \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime="${RELATIME}" \
    -O atime="${ATIME}" \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    "${POOL_NAME}" "${DEV}"
}

function step_07_create_datasets() {
  header "STEP 07: Create datasets and mountpoints"
  run sudo mkdir -p "${MNT_BASE}"

  run sudo zfs create -o mountpoint=none "${POOL_NAME}/${TOP_DATASET}"
  run sudo zfs create -o mountpoint="${MNT_BASE}" \
    "${POOL_NAME}/${TOP_DATASET}/root"

  local ds
  for ds in ${CHILD_DATASETS}; do
    run sudo zfs create -o mountpoint="${MNT_BASE}/${ds}" \
      "${POOL_NAME}/${TOP_DATASET}/${ds}"
  done

  run sudo chown -R "${USER}:${USER}" "${MNT_BASE}"
}

function step_08_optional_swap() {
  header "STEP 08: Optional swap ZVOL"
  if [[ -z "${SWAP_SIZE}" ]]; then
    printf 'Swap ZVOL disabled (SWAP_SIZE is empty).\n'
    return 0
  fi

  local pagesz
  pagesz="$(getconf PAGESIZE)"

  run sudo zfs create -V "${SWAP_SIZE}" -b "${pagesz}" \
    -o compression=off \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    "${POOL_NAME}/swap"

  run sudo mkswap "/dev/zvol/${POOL_NAME}/swap"
  run sudo swapon "/dev/zvol/${POOL_NAME}/swap"

  if ! grep -Fq "/dev/zvol/${POOL_NAME}/swap" /etc/fstab 2>/dev/null; then
    run sudo tee -a /etc/fstab >/dev/null <<EOF
/dev/zvol/${POOL_NAME}/swap none swap defaults 0 0
EOF
  fi
}

function step_09_import_mode_and_services() {
  header "STEP 09: Import mode and systemd units (best-effort)"
  case "${IMPORT_MODE}" in
    cache)
      run sudo zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}"
      ;;
    scan)
      run sudo zpool set cachefile=none "${POOL_NAME}"
      ;;
    none)
      printf 'IMPORT_MODE=none (not touching cachefile/services).\n'
      return 0
      ;;
  esac

  enable_unit_if_exists zfs.target
  enable_unit_if_exists zfs-import.target
  enable_unit_if_exists zfs-mount.service
  enable_unit_if_exists zfs-zed.service

  case "${IMPORT_MODE}" in
    cache) enable_unit_if_exists zfs-import-cache.service ;;
    scan)  enable_unit_if_exists zfs-import-scan.service ;;
  esac
}

function step_10_verify() {
  header "STEP 10: Verification"
  run sudo zpool status "${POOL_NAME}"
  run sudo zpool get -H ashift,autotrim,cachefile "${POOL_NAME}" || true
  run sudo zfs list -o name,used,avail,refer,mountpoint -r "${POOL_NAME}"

  run mount | grep -F "${MNT_BASE}" || true
  run sh -c "touch '${MNT_BASE}/.zfs_write_test' && ls -l '${MNT_BASE}/.zfs_write_test'"
}

# -----------------------------------------------------------------------------
# Destroy checklist
# -----------------------------------------------------------------------------
function destroy_checklist() {
  require_destructive_ok
  require_zfs_tools

  header "DESTROY: Swapoff (if present)"
  if [[ -e "/dev/zvol/${POOL_NAME}/swap" ]]; then
    run sudo swapoff "/dev/zvol/${POOL_NAME}/swap" || true
  fi
  if [[ -f /etc/fstab ]]; then
    run sudo sed -i "\|/dev/zvol/${POOL_NAME}/swap|d" /etc/fstab || true
  fi

  header "DESTROY: Unmount datasets (best-effort)"
  run sudo zfs unmount -a || true

  header "DESTROY: Destroy pool (if present)"
  if sudo zpool list -H -o name 2>/dev/null | grep -Fxq "${POOL_NAME}"; then
    run sudo zpool export "${POOL_NAME}" || true
    run sudo zpool destroy -f "${POOL_NAME}"
  else
    printf 'Pool not found: %s (skipping destroy)\n' "${POOL_NAME}"
  fi

  header "DESTROY: Wipe signatures on target device"
  run sudo zpool labelclear -f "${DEV}" || true
  run sudo wipefs -a "${DEV}"

  if [[ "${DO_DISCARD}" -eq 1 ]] && have blkdiscard; then
    run sudo blkdiscard -f "${DEV}" || true
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
case "${CMD}" in
  create|destroy|status|plan|-h|--help) : ;;
  *)
    die "Unknown command: ${CMD} (use create|destroy|status|plan)"
    ;;
esac

parse_args "$@"

if [[ "${CMD}" == "-h" || "${CMD}" == "--help" ]]; then
  show_help
  exit 0
fi

case "${CMD}" in
  plan)
    require_dev
    header "PLAN: Configuration summary"
    printf 'DEV         = %s\n' "${DEV}"
    printf 'POOL_NAME   = %s\n' "${POOL_NAME}"
    printf 'TOP_DATASET = %s\n' "${TOP_DATASET}"
    printf 'MNT_BASE    = %s\n' "${MNT_BASE}"
    printf 'DATASETS    = %s\n' "${CHILD_DATASETS}"
    printf 'IMPORT_MODE = %s\n' "${IMPORT_MODE}"
    printf 'SWAP_SIZE   = %s\n' "${SWAP_SIZE:-"(disabled)"}"
    printf 'APPLY       = %s\n' "${APPLY}"
    printf 'CONFIRM     = %s\n' "${CONFIRM}"
    run lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "${DEV}"
    ;;
  status)
    require_zfs_tools
    header "STATUS: Pools and datasets"
    run sudo zpool status
    run sudo zfs list -o name,used,avail,refer,mountpoint
    ;;
  create)
    require_dev
    step_00_preflight
    step_01_zfs_presence
    step_02_load_module
    step_03_hostid_best_effort
    step_04_mark_gpt_type_best_effort
    step_05_wipe_signatures
    step_06_create_pool
    step_07_create_datasets
    step_08_optional_swap
    step_09_import_mode_and_services
    step_10_verify
    ;;
  destroy)
    require_dev
    step_00_preflight
    destroy_checklist
    ;;
esac

