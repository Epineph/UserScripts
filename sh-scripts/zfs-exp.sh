#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# zfs-exp.sh
#
# Purpose:
#   Minimal, modern ZFS *experiment* script for a single small partition
#   (data-pool, not root-on-ZFS). Safe defaults:
#     - Dry-run by default (prints commands).
#     - Destructive actions require: --wipe --apply
#
# Notes:
#   - No LUKS. No mdraid. No bootloader. No root filesystem changes.
#   - You can optionally install ZFS via AUR DKMS (zfs-dkms + zfs-utils).
#   - Designed for quick create/destroy cycles on a spare partition.
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
APPLY=0
DO_WIPE=0
DO_DISCARD=0

CMD="plan"

DEV=""
POOL="tank"
TOP_DATASET="exp"
MNT_BASE="/tank"

# Space-separated names for child datasets under ${POOL}/${TOP_DATASET}
CHILD_DATASETS="Work Scratch"

# Pool properties
ASHIFT="12"
AUTOTRIM="on"            # on|off
COMPRESSION="zstd"        # zstd|lz4|off
RELATIME="on"             # on|off
ATIME="off"               # on|off

# Import/boot integration (for data pools):
#   cache  -> cachefile=/etc/zfs/zpool.cache + enable zfs-import-cache.service
#   scan   -> cachefile=none + enable zfs-import-scan.service
#   none   -> do not touch import services or cachefile
IMPORT_MODE="cache"       # cache|scan|none
ENABLE_SERVICES=1

# Optional ZVOL swap (disabled by default)
SWAP_SIZE=""              # e.g. "2G" to enable

# Optional package install
INSTALL_MODE="none"       # none|dkms
AUR_HELPER="yay"          # only used for INSTALL_MODE=dkms

# Help paging (off by default)
HELP_PAGER_MODE="off"     # off|auto|bat|cat|less

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------
function die() {
  printf 'ERROR: %s\n' "${1}" >&2
  exit 1
}

function have() {
  command -v "${1}" >/dev/null 2>&1
}

function run() {
  # Print + optionally execute the command.
  # Usage: run sudo zpool status
  printf '+'
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
  printf '\n'

  if [[ "${APPLY}" -eq 1 ]]; then
    "$@"
  fi
}

function unit_exists() {
  local unit="${1}"
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' \
  | grep -Fxq "${unit}"
}

function show_help() {
  local help_text
  help_text="$(
    cat <<'EOF'
zfs-exp.sh — single-partition ZFS experiment (dry-run by default)

USAGE
  zfs-exp.sh [command] [options]

COMMANDS
  plan        Show what would be done (default)
  install     Install ZFS (optional): dkms via AUR (zfs-dkms + zfs-utils)
  create      Create pool + datasets on the target partition
  destroy     Destroy pool (if present) + optionally wipe the partition
  status      Show ZFS/pool status and key settings

REQUIRED (for create/destroy)
  --dev <path>          Target partition (example: /dev/nvme0n1p5)

SAFETY FLAGS
  --apply               Actually run commands (otherwise dry-run)
  --wipe                Allow destructive wipefs/labelclear on --dev
  --discard             Also attempt blkdiscard (SSD/NVMe) when wiping

POOL/DATASET OPTIONS
  --pool <name>         Pool name (default: tank)
  --top <name>          Top dataset under pool (default: exp)
  --mnt <path>          Mount base for ${pool}/${top} (default: /tank)
  --datasets "<list>"   Child datasets under ${pool}/${top}
                        Default: "Work Scratch"

POOL PROPERTY OPTIONS
  --ashift <N>          Pool ashift (default: 12)
  --autotrim <on|off>   Pool autotrim (default: on)
  --compression <zstd|lz4|off>
                        Default: zstd
  --relatime <on|off>   Default: on
  --atime <on|off>      Default: off

IMPORT/SERVICES
  --import <cache|scan|none>
                        Default: cache
  --no-services         Do not enable any systemd units

OPTIONAL SWAP ZVOL
  --swap <size>         Create swap zvol (example: 2G). Disabled by default.

OPTIONAL INSTALL (Arch)
  --install <none|dkms> Default: none
  --aur-helper <cmd>    Default: yay (used for --install dkms)

HELP PAGER (OFF by default)
  --pager               Page help via bat if available, else cat
  --pager=bat|cat|less  Force a pager choice

EXAMPLES (5+)
  1) Dry-run plan (recommended first):
     ./zfs-exp.sh plan --dev /dev/nvme0n1p5 --pool tank --mnt /tank

  2) Create pool + datasets (DESTRUCTIVE: requires --wipe --apply):
     ./zfs-exp.sh create --dev /dev/nvme0n1p5 --pool tank \
       --top exp --mnt /tank --datasets "Work Scratch" --wipe --apply

  3) Create with zvol swap (example 2G):
     ./zfs-exp.sh create --dev /dev/nvme0n1p5 --pool tank \
       --mnt /tank --swap 2G --wipe --apply

  4) Use import-scan (no cachefile; relies on scan service if available):
     ./zfs-exp.sh create --dev /dev/nvme0n1p5 --pool tank \
       --import scan --wipe --apply

  5) Inspect status:
     ./zfs-exp.sh status --dev /dev/nvme0n1p5 --pool tank

  6) Destroy pool and wipe the partition (DESTRUCTIVE):
     ./zfs-exp.sh destroy --dev /dev/nvme0n1p5 --pool tank --wipe --apply

EOF
  )"

  case "${HELP_PAGER_MODE}" in
    off)
      printf '%s\n' "${help_text}"
      ;;
    less)
      printf '%s\n' "${help_text}" | less -R
      ;;
    cat)
      printf '%s\n' "${help_text}" | cat
      ;;
    bat|auto)
      if have bat; then
        # Paging requested: use bat as pager.
        printf '%s\n' "${help_text}" \
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
        printf '%s\n' "${help_text}" | cat
      fi
      ;;
    *)
      printf '%s\n' "${help_text}"
      ;;
  esac
}

function parse_args() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi

  while [[ "$#" -gt 0 ]]; do
    case "${1}" in
      -h|--help)
        show_help
        exit 0
        ;;
      plan|install|create|destroy|status)
        CMD="${1}"
        shift
        ;;
      --dev)
        DEV="${2:-}"; shift 2
        ;;
      --pool)
        POOL="${2:-}"; shift 2
        ;;
      --top)
        TOP_DATASET="${2:-}"; shift 2
        ;;
      --mnt)
        MNT_BASE="${2:-}"; shift 2
        ;;
      --datasets)
        CHILD_DATASETS="${2:-}"; shift 2
        ;;
      --ashift)
        ASHIFT="${2:-}"; shift 2
        ;;
      --autotrim)
        AUTOTRIM="${2:-}"; shift 2
        ;;
      --compression)
        COMPRESSION="${2:-}"; shift 2
        ;;
      --relatime)
        RELATIME="${2:-}"; shift 2
        ;;
      --atime)
        ATIME="${2:-}"; shift 2
        ;;
      --import)
        IMPORT_MODE="${2:-}"; shift 2
        ;;
      --no-services)
        ENABLE_SERVICES=0; shift
        ;;
      --swap)
        SWAP_SIZE="${2:-}"; shift 2
        ;;
      --install)
        INSTALL_MODE="${2:-}"; shift 2
        ;;
      --aur-helper)
        AUR_HELPER="${2:-}"; shift 2
        ;;
      --apply)
        APPLY=1; shift
        ;;
      --wipe)
        DO_WIPE=1; shift
        ;;
      --discard)
        DO_DISCARD=1; shift
        ;;
      --pager)
        HELP_PAGER_MODE="auto"; shift
        ;;
      --pager=bat)
        HELP_PAGER_MODE="bat"; shift
        ;;
      --pager=cat)
        HELP_PAGER_MODE="cat"; shift
        ;;
      --pager=less)
        HELP_PAGER_MODE="less"; shift
        ;;
      *)
        die "Unknown argument: ${1}"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
function require_dev() {
  [[ -n "${DEV}" ]] || die "--dev is required (target partition)."
  [[ -b "${DEV}" ]] || die "Not a block device: ${DEV}"

  local mp
  mp="$(lsblk -no MOUNTPOINT "${DEV}" | head -n1 || true)"
  [[ -z "${mp}" ]] || die "Device is mounted at: ${mp} (refusing)."

  if swapon --show=NAME 2>/dev/null | awk '{print $1}' | grep -Fxq "${DEV}"; then
    die "Device appears to be active swap: ${DEV} (refusing)."
  fi
}

function require_tools_for_pool() {
  have zpool || die "Missing 'zpool' (install ZFS userspace first)."
  have zfs  || die "Missing 'zfs' (install ZFS userspace first)."
}

function validate_modes() {
  case "${IMPORT_MODE}" in
    cache|scan|none) : ;;
    *) die "--import must be: cache|scan|none" ;;
  esac

  case "${AUTOTRIM}" in
    on|off) : ;;
    *) die "--autotrim must be: on|off" ;;
  esac

  case "${COMPRESSION}" in
    zstd|lz4|off) : ;;
    *) die "--compression must be: zstd|lz4|off" ;;
  esac
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
function action_install() {
  case "${INSTALL_MODE}" in
    none)
      printf 'Install mode: none (skipping)\n'
      ;;
    dkms)
      have sudo || die "sudo not found."
      have "${AUR_HELPER}" || die "AUR helper not found: ${AUR_HELPER}"

      run sudo pacman -S --needed dkms base-devel linux-headers
      run "${AUR_HELPER}" -S --needed zfs-dkms zfs-utils

      run sudo modprobe zfs
      run sudo tee /etc/modules-load.d/zfs.conf >/dev/null <<<"zfs"
      ;;
    *)
      die "--install must be: none|dkms"
      ;;
  esac
}

function action_plan() {
  require_dev
  validate_modes

  printf 'Plan summary:\n'
  printf '  DEV          = %s\n' "${DEV}"
  printf '  POOL         = %s\n' "${POOL}"
  printf '  TOP_DATASET  = %s\n' "${TOP_DATASET}"
  printf '  MNT_BASE     = %s\n' "${MNT_BASE}"
  printf '  DATASETS     = %s\n' "${CHILD_DATASETS}"
  printf '  IMPORT_MODE  = %s\n' "${IMPORT_MODE}"
  printf '  SWAP_SIZE    = %s\n' "${SWAP_SIZE:-"(disabled)"}"
  printf '  APPLY        = %s\n' "${APPLY}"
  printf '  WIPE         = %s\n' "${DO_WIPE}"
  printf '  DISCARD      = %s\n' "${DO_DISCARD}"
  printf '\nDevice info:\n'
  run lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,PARTUUID "${DEV}"
  printf '\nExisting pools (if any):\n'
  if have zpool; then
    run sudo zpool status || true
  else
    printf '  (zpool not installed)\n'
  fi
}

function action_create() {
  require_dev
  require_tools_for_pool
  validate_modes

  [[ "${DO_WIPE}" -eq 1 ]] || die "create requires --wipe (safety)."
  [[ "${APPLY}" -eq 1 ]] || die "create is dry-run unless you add --apply."

  have sudo || die "sudo not found."

  # Basic sanity: refuse if pool already exists.
  if sudo zpool list -H -o name 2>/dev/null | grep -Fxq "${POOL}"; then
    die "Pool already exists: ${POOL}"
  fi

  run sudo modprobe zfs
  run sudo tee /etc/modules-load.d/zfs.conf >/dev/null <<<"zfs"

  # Hostid helps stable imports on systemd systems.
  if [[ ! -f /etc/hostid ]] && have zgenhostid; then
    run sudo zgenhostid -f -o /etc/hostid
  fi

  # Mark GPT type (bf01 = Solaris/ZFS). Best-effort.
  if have sgdisk; then
    local disk partno
    disk="/dev/$(lsblk -no pkname "${DEV}")"
    partno="$(cat "/sys/class/block/$(basename "${DEV}")/partition" 2>/dev/null \
      || true)"
    if [[ -n "${partno}" ]]; then
      run sudo sgdisk -t "${partno}:bf01" "${disk}" || true
    fi
  fi

  # Clear old signatures/labels.
  run sudo zpool labelclear -f "${DEV}" || true
  run sudo wipefs -a "${DEV}"

  if [[ "${DO_DISCARD}" -eq 1 ]] && have blkdiscard; then
    run sudo blkdiscard -f "${DEV}" || true
  fi

  # Create pool (single device) with sane defaults for NVMe/SSD.
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
    "${POOL}" "${DEV}"

  # Import behavior
  case "${IMPORT_MODE}" in
    cache)
      run sudo zpool set cachefile=/etc/zfs/zpool.cache "${POOL}"
      ;;
    scan)
      run sudo zpool set cachefile=none "${POOL}"
      ;;
    none)
      :
      ;;
  esac

  # Create datasets
  run sudo zfs create -o mountpoint=none "${POOL}/${TOP_DATASET}"
  run sudo mkdir -p "${MNT_BASE}"
  run sudo zfs create -o mountpoint="${MNT_BASE}" "${POOL}/${TOP_DATASET}/root"

  local ds
  for ds in ${CHILD_DATASETS}; do
    run sudo zfs create -o mountpoint="${MNT_BASE}/${ds}" \
      "${POOL}/${TOP_DATASET}/${ds}"
  done

  # Ownership: allow user writes under mount base
  run sudo chown -R "${USER}:${USER}" "${MNT_BASE}"

  # Optional swap zvol
  if [[ -n "${SWAP_SIZE}" ]]; then
    local pagesz
    pagesz="$(getconf PAGESIZE)"

    run sudo zfs create -V "${SWAP_SIZE}" -b "${pagesz}" \
      -o compression=off \
      -o logbias=throughput \
      -o sync=always \
      -o primarycache=metadata \
      -o secondarycache=none \
      -o com.sun:auto-snapshot=false \
      "${POOL}/swap"

    run sudo mkswap "/dev/zvol/${POOL}/swap"
    run sudo swapon "/dev/zvol/${POOL}/swap"

    # Add fstab line (idempotent-ish)
    if ! grep -Fq "/dev/zvol/${POOL}/swap" /etc/fstab 2>/dev/null; then
      run sudo tee -a /etc/fstab >/dev/null <<EOF
/dev/zvol/${POOL}/swap none swap defaults 0 0
EOF
    fi
  fi

  # Enable services (best-effort, only what exists)
  if [[ "${ENABLE_SERVICES}" -eq 1 ]]; then
    local units
    units=(
      "zfs.target"
      "zfs-import.target"
      "zfs-mount.service"
      "zfs-zed.service"
    )

    case "${IMPORT_MODE}" in
      cache) units+=("zfs-import-cache.service") ;;
      scan)  units+=("zfs-import-scan.service") ;;
      none)  : ;;
    esac

    local u
    for u in "${units[@]}"; do
      if unit_exists "${u}"; then
        run sudo systemctl enable --now "${u}"
      fi
    done
  fi

  printf '\nCreate complete. Verification commands:\n'
  printf '  zpool status %q\n' "${POOL}"
  printf '  zfs list -o name,used,avail,mountpoint -r %q\n' "${POOL}"
  printf '  mount | grep -F %q\n' "${MNT_BASE}"
}

function action_destroy() {
  require_dev
  validate_modes

  [[ "${DO_WIPE}" -eq 1 ]] || die "destroy requires --wipe (safety)."
  [[ "${APPLY}" -eq 1 ]] || die "destroy is dry-run unless you add --apply."

  have sudo || die "sudo not found."

  # Swap off if present
  if [[ -e "/dev/zvol/${POOL}/swap" ]]; then
    run sudo swapoff "/dev/zvol/${POOL}/swap" || true
  fi

  # Remove fstab entry (best-effort)
  if [[ -f /etc/fstab ]]; then
    run sudo sed -i "\|/dev/zvol/${POOL}/swap|d" /etc/fstab || true
  fi

  # Destroy pool if it exists
  if have zpool && sudo zpool list -H -o name 2>/dev/null | grep -Fxq "${POOL}"; then
    run sudo zpool export "${POOL}" || true
    run sudo zpool destroy -f "${POOL}" || true
  fi

  # Clear labels/signatures
  if have zpool; then
    run sudo zpool labelclear -f "${DEV}" || true
  fi
  run sudo wipefs -a "${DEV}"

  if [[ "${DO_DISCARD}" -eq 1 ]] && have blkdiscard; then
    run sudo blkdiscard -f "${DEV}" || true
  fi

  printf '\nDestroy complete.\n'
}

function action_status() {
  require_tools_for_pool
  have sudo || die "sudo not found."

  run sudo zpool status
  run sudo zpool get -H ashift,autotrim,cachefile "${POOL}" || true
  run sudo zfs list -o name,used,avail,refer,mountpoint -r "${POOL}" || true

  if unit_exists "zfs-mount.service"; then
    run systemctl is-enabled zfs-mount.service || true
  fi
  if unit_exists "zfs-import-cache.service"; then
    run systemctl is-enabled zfs-import-cache.service || true
  fi
  if unit_exists "zfs-import-scan.service"; then
    run systemctl is-enabled zfs-import-scan.service || true
  fi
  if unit_exists "zfs-zed.service"; then
    run systemctl is-enabled zfs-zed.service || true
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
parse_args "$@"

case "${CMD}" in
  plan)    action_plan ;;
  install) action_install ;;
  create)  action_create ;;
  destroy) action_destroy ;;
  status)  action_status ;;
  *)       die "Unknown command: ${CMD}" ;;
esac

