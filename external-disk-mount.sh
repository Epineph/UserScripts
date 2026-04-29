#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# external-disk-mount
#
# Mount numbered partitions from a block device to:
#
#   /external-disk/usb1
#   /external-disk/usb2
#   ...
#
# Examples:
#
#   external-disk-mount sda
#   external-disk-mount /dev/sdb
#   external-disk-mount /sdb
#   external-disk-mount --count 7 sdb
#   external-disk-mount --base /mnt/external --prefix part sdb
#   external-disk-mount --unmount
#   external-disk-mount --unmount --base /external-disk --prefix usb
# -----------------------------------------------------------------------------

BASE="/external-disk"
PREFIX="usb"
COUNT=""
ACTION="mount"
COMMON_OPTIONS="rw,nosuid,nodev,noatime"
OWNER_OPTIONS=1
DRY_RUN=0
DISK=""

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
external-disk-mount

Usage:
  external-disk-mount [OPTIONS] <disk>
  external-disk-mount --unmount [OPTIONS] [disk]

Examples:
  external-disk-mount sda
  external-disk-mount /dev/sdb
  external-disk-mount /sdb
  external-disk-mount --count 7 sdb
  external-disk-mount --base /mnt/external --prefix part sdb
  external-disk-mount --dry-run sdb
  external-disk-mount --unmount
  external-disk-mount --unmount --count 5

Options:
  -b, --base DIR          Base directory. Default: /external-disk
  -p, --prefix PREFIX     Mountpoint prefix. Default: usb
  -n, --count N           Check/mount partition slots 1..N.
                          If omitted, partitions are auto-detected.
  -o, --options OPTIONS   Base mount options.
                          Default: rw,nosuid,nodev,noatime
  -u, --unmount           Unmount matching mountpoints instead of mounting.
  --no-owner-options      Do not add uid/gid/umask for exfat/vfat/ntfs.
  --dry-run               Print commands without executing them.
  -h, --help              Show this help text.

Notes:
  - For /dev/sda, partitions are assumed to be /dev/sda1, /dev/sda2, ...
  - For /dev/nvme0n1, partitions are assumed to be /dev/nvme0n1p1, ...
  - If --count is larger than the existing partitions, extra directories are
    created, but missing partitions are skipped with a warning.
EOF
}

# -----------------------------------------------------------------------------
# Diagnostics
# -----------------------------------------------------------------------------

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# Command execution
# -----------------------------------------------------------------------------

function print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

function run_command() {
  print_command "$@"

  if (( DRY_RUN == 0 )); then
    "$@"
  fi
}

function sudo_command() {
  if (( EUID == 0 )); then
    run_command "$@"
  else
    run_command sudo "$@"
  fi
}

# -----------------------------------------------------------------------------
# Parsing and validation
# -----------------------------------------------------------------------------

function parse_positive_integer() {
  local value="${1:-}"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    die "expected a positive integer, got: ${value}"
  }

  printf '%s\n' "${value}"
}

function normalize_disk() {
  local disk="${1:-}"

  [[ -n "${disk}" ]] || die "missing disk argument"

  if [[ "${disk}" == /dev/* ]]; then
    printf '%s\n' "${disk}"
  elif [[ "${disk}" == /* ]]; then
    printf '/dev%s\n' "${disk}"
  else
    printf '/dev/%s\n' "${disk}"
  fi
}

function parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -b|--base)
        shift
        [[ $# -gt 0 ]] || die "--base requires an argument"
        BASE="$1"
        ;;
      -p|--prefix)
        shift
        [[ $# -gt 0 ]] || die "--prefix requires an argument"
        PREFIX="$1"
        ;;
      -n|--count)
        shift
        [[ $# -gt 0 ]] || die "--count requires an argument"
        COUNT="$(parse_positive_integer "$1")"
        ;;
      -o|--options)
        shift
        [[ $# -gt 0 ]] || die "--options requires an argument"
        COMMON_OPTIONS="$1"
        ;;
      -u|--unmount|--umount)
        ACTION="unmount"
        ;;
      --no-owner-options)
        OWNER_OPTIONS=0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "${DISK}" ]]; then
          DISK="$(normalize_disk "$1")"
        else
          die "unexpected extra argument: $1"
        fi
        ;;
    esac

    shift
  done

  while (( $# > 0 )); do
    if [[ -z "${DISK}" ]]; then
      DISK="$(normalize_disk "$1")"
    else
      die "unexpected extra argument: $1"
    fi

    shift
  done
}

# -----------------------------------------------------------------------------
# Partition handling
# -----------------------------------------------------------------------------

function partition_path() {
  local disk="$1"
  local number="$2"

  if [[ "${disk}" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "${disk}" "${number}"
  else
    printf '%s%s\n' "${disk}" "${number}"
  fi
}

function partition_number() {
  local part_base
  part_base="$(basename "$1")"

  if [[ "${part_base}" =~ p([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "${part_base}" =~ ([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    die "could not infer partition number from: $1"
  fi
}

function detected_partitions() {
  local disk="$1"

  lsblk -nrpo NAME,TYPE "${disk}" |
    awk '$2 == "part" { print $1 }'
}

function max_partition_number_from_disk() {
  local disk="$1"
  local max_number=0
  local number
  local part

  while IFS= read -r part; do
    number="$(partition_number "${part}")"

    if (( number > max_number )); then
      max_number="${number}"
    fi
  done < <(detected_partitions "${disk}")

  printf '%s\n' "${max_number}"
}

# -----------------------------------------------------------------------------
# Mount options
# -----------------------------------------------------------------------------

function filesystem_type() {
  local part="$1"

  lsblk -no FSTYPE "${part}" | awk 'NR == 1 { print tolower($1) }'
}

function effective_mount_options() {
  local part="$1"
  local fstype
  local options="${COMMON_OPTIONS}"

  fstype="$(filesystem_type "${part}")"

  if (( OWNER_OPTIONS == 1 )); then
    case "${fstype}" in
      exfat|vfat|fat|ntfs|ntfs3)
        options="${options},uid=$(id -u),gid=$(id -g),umask=022"
        ;;
    esac
  fi

  printf '%s\n' "${options}"
}

# -----------------------------------------------------------------------------
# Directory handling
# -----------------------------------------------------------------------------

function ensure_mountpoints() {
  local count="$1"
  local missing=()
  local dir
  local n

  for n in $(seq 1 "${count}"); do
    dir="${BASE}/${PREFIX}${n}"

    if [[ ! -d "${dir}" ]]; then
      missing+=("${dir}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    sudo_command install -d -m 0755 "${missing[@]}"
  fi
}

# -----------------------------------------------------------------------------
# Mounting
# -----------------------------------------------------------------------------

function mount_partitions() {
  local partitions=()
  local max_number=0
  local number
  local part
  local target
  local current_target
  local options

  [[ -n "${DISK}" ]] || die "mounting requires a disk argument"
  [[ -b "${DISK}" ]] || die "not a block device: ${DISK}"

  if [[ -n "${COUNT}" ]]; then
    max_number="${COUNT}"

    for number in $(seq 1 "${COUNT}"); do
      part="$(partition_path "${DISK}" "${number}")"

      if [[ -b "${part}" ]]; then
        partitions+=("${part}")
      else
        warn "missing partition ${part}; creating mountpoint only"
      fi
    done
  else
    mapfile -t partitions < <(detected_partitions "${DISK}")
    max_number="$(max_partition_number_from_disk "${DISK}")"
  fi

  (( max_number > 0 )) || die "no partitions found for ${DISK}"

  ensure_mountpoints "${max_number}"

  for part in "${partitions[@]}"; do
    number="$(partition_number "${part}")"
    target="${BASE}/${PREFIX}${number}"

    if findmnt -rn --target "${target}" >/dev/null; then
      warn "${target} is already a mountpoint; skipping"
      continue
    fi

    current_target="$(findmnt -rn --source "${part}" -o TARGET | head -n 1 || true)"

    if [[ -n "${current_target}" ]]; then
      warn "${part} is already mounted at ${current_target}; skipping"
      continue
    fi

    options="$(effective_mount_options "${part}")"

    sudo_command mount -o "${options}" "${part}" "${target}"
  done
}

# -----------------------------------------------------------------------------
# Unmounting
# -----------------------------------------------------------------------------

function matching_mountpoint_dirs() {
  if [[ -n "${COUNT}" ]]; then
    local n

    for n in $(seq 1 "${COUNT}"); do
      printf '%s\n' "${BASE}/${PREFIX}${n}"
    done

    return 0
  fi

  if [[ -d "${BASE}" ]]; then
    find "${BASE}" \
      -maxdepth 1 \
      -type d \
      -name "${PREFIX}[0-9]*" \
      -print |
      sort -Vr
  fi
}

function unmount_partitions() {
  local targets=()
  local target

  mapfile -t targets < <(matching_mountpoint_dirs)

  if (( ${#targets[@]} == 0 )); then
    warn "no matching mountpoint directories found"
    return 0
  fi

  for target in "${targets[@]}"; do
    if findmnt -rn --target "${target}" >/dev/null; then
      sudo_command umount "${target}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  parse_args "$@"

  case "${ACTION}" in
    mount)
      mount_partitions
      ;;
    unmount)
      unmount_partitions
      ;;
    *)
      die "invalid action: ${ACTION}"
      ;;
  esac
}

main "$@"
