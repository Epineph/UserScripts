#!/usr/bin/env bash
set -euo pipefail

# zero-fill-dd-pv
# -----------------------------------------------------------------------------
# Zero-fill a block device (partition) with defensible dd block sizing and a pv
# progress bar, while reporting the exact parameters chosen.
#
# NOTE:
#   This is destructive. It will overwrite the target device.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
zero-fill-dd-pv

Usage:
  zero-fill-dd-pv [--dry-run] [--force] [--no-direct] <BLOCK_DEVICE>

Examples:
  zero-fill-dd-pv --dry-run /dev/nvme0n1p5
  zero-fill-dd-pv /dev/nvme0n1p5
  zero-fill-dd-pv --no-direct /dev/sda3

Options:
  --dry-run     Print chosen parameters and exit without writing.
  --force       Proceed even if the device appears mounted or used as swap.
  --no-direct   Do not use direct I/O (oflag=direct).
  -h, --help    Show this help.

Environment:
  TARGET_BS_MIB  Target dd block size in MiB (default: 64).
EOF
}

function die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
function warn() { printf 'WARN: %s\n' "$*" >&2; }

function gcd() {
  local a="$1" b="$2" t
  while (( b != 0 )); do
    t=$(( a % b ))
    a="$b"
    b="$t"
  done
  printf '%s\n' "$a"
}

function lcm() {
  local a="$1" b="$2" g
  g="$(gcd "$a" "$b")"
  printf '%s\n' "$(( a / g * b ))"
}

function have() { command -v "$1" >/dev/null 2>&1; }

dry_run=0
force=0
use_direct=1
dev=""

while (( $# > 0 )); do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --force) force=1; shift ;;
    --no-direct) use_direct=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *) dev="$1"; shift ;;
  esac
done

[[ -n "${dev:-}" ]] || die "Missing <BLOCK_DEVICE> (e.g., /dev/nvme0n1p5)."
[[ -b "$dev" ]] || die "Not a block device: $dev"

# -----------------------------------------------------------------------------
# Safety checks: mounted / swap / in-use
# -----------------------------------------------------------------------------
if have findmnt; then
  if findmnt -S "$dev" >/dev/null 2>&1; then
    if (( force == 0 )); then
      die "$dev appears mounted. Unmount it or use --force."
    fi
    warn "$dev appears mounted, proceeding due to --force."
  fi
fi

if [[ -r /proc/swaps ]] && grep -qE "^[^ ]*${dev}([[:space:]]|$)" /proc/swaps; then
  if (( force == 0 )); then
    die "$dev appears to be active swap. Disable swap or use --force."
  fi
  warn "$dev appears to be active swap, proceeding due to --force."
fi

# -----------------------------------------------------------------------------
# Compute device geometry and a defensible bs
# -----------------------------------------------------------------------------
parent="/dev/$(lsblk -no PKNAME -- "$dev")"
[[ -b "$parent" ]] || die "Could not determine parent disk for: $dev"

bytes="$(blockdev --getsize64 "$dev")"
[[ "$bytes" =~ ^[0-9]+$ ]] || die "Could not read size in bytes for: $dev"

q="/sys/block/$(basename -- "$parent")/queue"

p="4096"
m="4096"
o="0"
[[ -r "$q/physical_block_size" ]] && p="$(<"$q/physical_block_size")"
[[ -r "$q/minimum_io_size" ]] && m="$(<"$q/minimum_io_size")"
[[ -r "$q/optimal_io_size" ]] && o="$(<"$q/optimal_io_size")"

a="$p"
(( m > a )) && a="$m"
(( o > 0 )) && a="$(lcm "$a" "$o")"

target_mib="${TARGET_BS_MIB:-64}"
[[ "$target_mib" =~ ^[0-9]+$ ]] || die "TARGET_BS_MIB must be an integer."

T=$(( target_mib * 1024 * 1024 ))
k=$(( T / a ))
(( k < 1 )) && k=1
bs=$(( k * a ))

# dd expects bs= in bytes or suffix form; we pass bytes for alignment precision.
# For pv buffer-size, bytes are accepted as well.
oflag=""
(( use_direct == 1 )) && oflag="direct"

# -----------------------------------------------------------------------------
# Report chosen parameters
# -----------------------------------------------------------------------------
printf '%s\n' "----------------------------------------" >&2
printf 'Target device:           %s\n' "$dev" >&2
printf 'Parent disk:             %s\n' "$parent" >&2
printf 'Device size (bytes):     %s\n' "$bytes" >&2
printf 'physical_block_size:     %s\n' "$p" >&2
printf 'minimum_io_size:         %s\n' "$m" >&2
printf 'optimal_io_size:         %s\n' "$o" >&2
printf 'Alignment base (bytes):  %s\n' "$a" >&2
printf 'TARGET_BS_MIB:           %s\n' "$target_mib" >&2
printf 'Chosen bs (bytes):       %s\n' "$bs" >&2
printf 'dd oflag:                %s\n' "${oflag:-"(none)"}" >&2
printf 'dd conv:                 %s\n' "fdatasync" >&2
printf '%s\n' "----------------------------------------" >&2

if (( dry_run == 1 )); then
  exit 0
fi

# -----------------------------------------------------------------------------
# Execute: pv-driven progress (exact byte limit) + dd write
# -----------------------------------------------------------------------------
if have pv; then
  pv_stop_flag=""
  if pv --help 2>&1 | grep -q -- '--stop-at-size'; then
    pv_stop_flag="--stop-at-size"
  fi

  # Use pv for progress; ensure it stops after exactly $bytes to avoid /dev/zero
  # being infinite.
  #
  # pv flags:
  #   -p  progress bar
  #   -t  timer
  #   -e  ETA
  #   -r  rate
  #   -b  bytes
  #   -s  expected total size
  #   -B  buffer size
  #
  # dd:
  #   if=stdin (implicit)
  #   of=<device>
  #   bs=<computed>
  #   oflag=direct (optional)
  #   conv=fdatasync (flush at end)
  if [[ -n "$pv_stop_flag" ]]; then
    pv -ptebr -s "$bytes" -B "$bs" "$pv_stop_flag" /dev/zero \
      | dd of="$dev" bs="$bs" ${oflag:+oflag="$oflag"} \
          conv=fdatasync status=none
  else
    # Fallback if pv lacks --stop-at-size: limit exactly with head -c.
    head -c "$bytes" /dev/zero \
      | pv -ptebr -s "$bytes" -B "$bs" \
      | dd of="$dev" bs="$bs" ${oflag:+oflag="$oflag"} \
          conv=fdatasync status=none
  fi
else
  warn "pv not found; using dd status=progress instead."
  dd if=/dev/zero of="$dev" bs="$bs" ${oflag:+oflag="$oflag"} \
    conv=fdatasync status=progress
fi

sync
printf 'Done: %s zero-filled (%s bytes).\n' "$dev" "$bytes" >&2
