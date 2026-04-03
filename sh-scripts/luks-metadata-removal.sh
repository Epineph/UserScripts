#!/usr/bin/env bash
#===============================================================================
# luks-metadata-removal
#
# WARNING: DESTRUCTIVE.
#   This script *destroys* LUKS headers/metadata on the specified partition.
#   Do not run it unless you fully understand what it does.
#
# Behaviour (summary):
#   - Can scan for crypto_LUKS partitions.
#   - Wipes LUKS metadata at both ends of a partition using:
#       * "dd"   : fixed 16 MiB head + 16 MiB tail
#       * "auto" : header size from cryptsetup luksDump (LUKS2-style),
#                 same size wiped at tail.
#
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# Utility: die
#-------------------------------------------------------------------------------
function die() {
  echo "[-] $*" >&2
  exit 1
}

#-------------------------------------------------------------------------------
# Utility: help pager + usage
#-------------------------------------------------------------------------------
function show_help() {
  local -a pager_cmd

  if [[ -n "${HELP_PAGER:-}" ]]; then
    # Split HELP_PAGER into an array (e.g. "less -R").
    # shellcheck disable=SC2206
    pager_cmd=("$HELP_PAGER")
  else
    pager_cmd=(less -R)
  fi

  if ! command -v "${pager_cmd[0]}" >/dev/null 2>&1; then
    pager_cmd=(cat)
  fi

  cat <<'EOF' | "${pager_cmd[@]}"
luks-metadata-removal - LUKS header/metadata erasure helper (DESTRUCTIVE)

Usage:

  Scan for LUKS partitions:
    luks-metadata-removal -s|--scan [DISK]

    Examples:
      luks-metadata-removal -s
        → list all crypto_LUKS partitions on all disks.

      luks-metadata-removal -s /dev/sda
        → list only crypto_LUKS partitions on /dev/sda.

  Erase LUKS metadata at both ends of a partition:
    luks-metadata-removal [-m MODE] [-t TARGET]
    luks-metadata-removal TARGET

    TARGET:
      Must be a partition path, e.g.
        /dev/sda1, /dev/sda2, /dev/nvme0n1p3, etc.

    MODE (case-insensitive):
      auto  - Compute header size from `cryptsetup luksDump` (LUKS2-style)
              and wipe that size at the front and at the end (for the
              backup LUKS2 metadata).
      dd    - Use fixed 16 MiB at head and 16 MiB at tail.

    DEFAULT (no -m):
      - Try AUTO mode.
      - If AUTO and DD propose identical head sizes (MiB), use AUTO quietly.
      - If they differ, you are prompted to choose:
          * dd   → use DD method (16 MiB head+tail)
          * auto → use AUTO method (offset-derived head+tail)
          * no   → abort
      - If AUTO is impossible (no usable offset from luksDump),
        the script offers fallback to DD mode.

What the script actually does (wipe mode):

  1. Show a full lsblk view of the *parent disk* of TARGET.
  2. Ask for a first confirmation ("yes").
  3. Compute device size and geometry in MiB.
  4. Determine the effective mode (DD / AUTO) as described above.
  5. Show the chosen wipe geometry (head/tail MiB).
  6. Ask for a final confirmation ("YES" in all caps).
  7. Execute:
       cryptsetup erase TARGET
       wipefs -a TARGET
       dd over the front region (header + metadata)
       dd over the tail region (backup metadata for LUKS2)

Notes / theory:

  - cryptsetup erase destroys all keyslots; the encrypted payload becomes
    cryptographically useless (no keys).
  - This does *not* remove the LUKS header structure itself; tools can still
    see it as LUKS unless you overwrite metadata regions.
  - The dd steps in this script are to remove the header + backup metadata
    at both ends, so luksDump and blkid/lsblk stop recognising it as LUKS.

AGAIN: This is irreversible. Do not use this on any device you are not
absolutely prepared to lose permanently.
EOF
}

#-------------------------------------------------------------------------------
# Utility: scan for crypto_LUKS
#-------------------------------------------------------------------------------
function scan_luks() {
  local scan_disk="$1"
  local cmd="lsblk -ln -o PATH,FSTYPE"

  command -v lsblk >/dev/null 2>&1 ||
    die "lsblk not found in PATH."

  if [[ -n "$scan_disk" ]]; then
    [[ -b "$scan_disk" ]] ||
      die "${scan_disk} is not a block device."
    cmd="${cmd} ${scan_disk}"
  fi

  local luks_parts
  luks_parts=$(eval "$cmd" | awk '$2=="crypto_LUKS"{print $1}')

  if [[ -z "$luks_parts" ]]; then
    if [[ -n "$scan_disk" ]]; then
      echo "[*] No crypto_LUKS partitions found on ${scan_disk}."
    else
      echo "[*] No crypto_LUKS partitions found on any disk."
    fi
  else
    if [[ -n "$scan_disk" ]]; then
      echo "[*] crypto_LUKS partitions on ${scan_disk}:"
    else
      echo "[*] crypto_LUKS partitions on all disks:"
    fi
    printf '  %s\n' "$luks_parts"
  fi
}

#-------------------------------------------------------------------------------
# Utility: resolve parent disk for a partition
#-------------------------------------------------------------------------------
function get_parent_disk() {
  local target="$1"
  local pkname disk_path

  pkname=$(lsblk -no PKNAME "$target" 2>/dev/null | head -n1 || true)

  if [[ -n "$pkname" ]]; then
    disk_path="/dev/${pkname}"
  else
    disk_path="$target" # target is already a whole disk
  fi

  printf '%s\n' "$disk_path"
}

#-------------------------------------------------------------------------------
# Core wipe function
#-------------------------------------------------------------------------------
function do_wipe() {
  local target="$1"
  local mode="$2"

  [[ -b "$target" ]] || die "${target} is not a block device."

  ((EUID == 0)) || die "This script must be run as root."

  command -v cryptsetup >/dev/null 2>&1 ||
    die "cryptsetup not found in PATH."
  command -v lsblk >/dev/null 2>&1 ||
    die "lsblk not found in PATH."
  command -v blockdev >/dev/null 2>&1 ||
    die "blockdev not found in PATH."

  local disk_path
  disk_path=$(get_parent_disk "$target")

  echo "====================================================================="
  echo "[*] SAFETY CHECK - FULL DISK VIEW"
  echo "    Target partition : ${target}"
  echo "    Parent disk      : ${disk_path}"
  echo "---------------------------------------------------------------------"
  lsblk -o NAME,TYPE,SIZE,MOUNTPOINTS,PARTTYPENAME,FSTYPE,PATH \
    "$disk_path"
  echo "====================================================================="
  echo "DESTRUCTIVE ACTION: LUKS HEADER / METADATA WILL BE WIPED ON:"
  echo "  ${target}"
  echo "Parent disk layout shown above. Double-check before continuing."
  echo
  read -r -p "Type 'yes' to continue: " reply
  if [[ "$reply" != "yes" ]]; then
    echo "[*] Aborted by user."
    exit 1
  fi

  local bs
  bs=$((1024 * 1024)) # 1 MiB

  local size_bytes total_mib
  size_bytes=$(blockdev --getsize64 "$target") ||
    die "Failed to get size of ${target}."

  total_mib=$((size_bytes / bs))
  if ((total_mib <= 32)); then
    die "Device too small (${total_mib} MiB) for head+tail wipe."
  fi

  # Geometry for DD method (fixed 16 MiB)
  local dd_head_mib dd_tail_seek
  dd_head_mib=16
  dd_tail_seek=$((total_mib - dd_head_mib))
  ((dd_tail_seek > 0)) ||
    die "Computed tail seek for dd method is invalid."

  # AUTO-mode feasibility
  local auto_possible=0
  local offset_bytes=""
  local auto_head_mib=0
  local auto_tail_seek=0

  if [[ -z "$mode" || "$mode" == "auto" ]]; then
    offset_bytes=$(
      cryptsetup luksDump "$target" 2>/dev/null |
        awk '/offset:[[:space:]]+[0-9]+[[:space:]]+\[bytes\]/{print $2; exit}'
    ) || true

    if [[ -n "$offset_bytes" ]]; then
      auto_head_mib=$(((offset_bytes + bs - 1) / bs))
      if ((auto_head_mib > 0 && auto_head_mib < total_mib / 2)); then
        auto_possible=1
        auto_tail_seek=$((total_mib - auto_head_mib))
      fi
    fi
  fi

  local effective_mode=""
  local quiet_auto=0
  local choice

  # Decide effective mode
  if [[ -n "$mode" ]]; then
    case "$mode" in
    dd)
      effective_mode="dd"
      ;;
    auto)
      if ((auto_possible == 0)); then
        die "AUTO mode requested but no usable offset from luksDump."
      fi
      effective_mode="auto"
      ;;
    *)
      die "Invalid mode: ${mode} (internal error)."
      ;;
    esac
  else
    # No mode specified; default logic.
    if ((auto_possible == 1)); then
      if ((auto_head_mib == dd_head_mib)); then
        effective_mode="auto"
        quiet_auto=1
      else
        echo "[!] AUTO and DD methods propose different header sizes:"
        echo "      AUTO head: ${auto_head_mib} MiB"
        echo "      DD   head: ${dd_head_mib} MiB"
        echo
        echo "Choose method:"
        echo "  d / D / dd   → use DD method (16 MiB head+tail)"
        echo "  a / A / auto → use AUTO method (offset-derived head+tail)"
        echo "  n / N / no   → abort"
        read -r -p "[d/a/n]: " choice
        case "$choice" in
        d | D | dd)
          effective_mode="dd"
          ;;
        a | A | auto)
          effective_mode="auto"
          ;;
        n | N | no | "")
          echo "[*] Aborted by user."
          exit 1
          ;;
        *)
          die "Invalid choice."
          ;;
        esac
      fi
    else
      echo "[!] AUTO mode not available (no parsable offset from luksDump)."
      read -r -p "Fallback to DD method (16 MiB head+tail)? [yes/NO]: " choice
      if [[ "$choice" != "yes" ]]; then
        echo "[*] Aborted by user."
        exit 1
      fi
      effective_mode="dd"
    fi
  fi

  echo
  case "$effective_mode" in
  dd)
    echo "[*] Selected method: DD (fixed 16 MiB head + 16 MiB tail)."
    echo "    Head wipe : 16 MiB"
    echo "    Tail wipe : 16 MiB (starting at MiB ${dd_tail_seek})"
    ;;
  auto)
    echo "[*] Selected method: AUTO (LUKS-derived offset)."
    echo "    Parsed offset (bytes): ${offset_bytes}"
    echo "    Head wipe            : ${auto_head_mib} MiB"
    echo "    Tail wipe            : ${auto_head_mib} MiB" \
      "(starting at MiB ${auto_tail_seek})"
    ;;
  *)
    die "No effective mode selected (internal error)."
    ;;
  esac

  read -r -p "FINAL CONFIRMATION: type 'YES' (all caps) to proceed: " choice
  if [[ "$choice" != "YES" ]]; then
    echo "[*] Aborted by user."
    exit 1
  fi

  echo "[*] Running: cryptsetup erase ${target}"
  cryptsetup erase "$target" ||
    die "cryptsetup erase failed on ${target}."

  echo "[*] Running: wipefs -a ${target}"
  if ! wipefs -a "$target"; then
    echo "[!] wipefs failed on ${target} (continuing anyway)." >&2
  fi

  case "$effective_mode" in
  dd)
    echo "[*] DD method: wiping first 16 MiB on ${target}..."
    dd if=/dev/zero of="$target" bs="$bs" count="$dd_head_mib" \
      status=progress conv=fsync

    echo "[*] DD method: wiping last 16 MiB on ${target}..."
    dd if=/dev/zero of="$target" bs="$bs" count="$dd_head_mib" \
      seek="$dd_tail_seek" status=progress conv=fsync
    ;;
  auto)
    echo "[*] AUTO method: wiping first ${auto_head_mib} MiB on ${target}..."
    dd if=/dev/zero of="$target" bs="$bs" \
      count="$auto_head_mib" status=progress conv=fsync

    echo "[*] AUTO method: wiping last ${auto_head_mib} MiB on ${target}..."
    dd if=/dev/zero of="$target" bs="$bs" \
      count="$auto_head_mib" seek="$auto_tail_seek" \
      status=progress conv=fsync
    ;;
  esac

  echo "[*] Done. LUKS header/metadata on ${target} should now be gone."
  echo "    cryptsetup luksDump ${target} ought to fail, and lsblk/blkid"
  echo "    should no longer show it as crypto_LUKS."
}

#-------------------------------------------------------------------------------
# main
#-------------------------------------------------------------------------------
function main() {
  local target=""
  local mode=""
  local scan=0
  local scan_disk=""
  local arg

  # Pre-scan for -h/--help to give help immediately.
  for arg in "$@"; do
    case "$arg" in
    -h | --help)
      show_help
      exit 0
      ;;
    esac
  done

  # Argument parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -t | --target)
      [[ -n "${2:-}" ]] || die "Missing argument for $1"
      target="$2"
      shift 2
      ;;
    -m | --mode)
      [[ -n "${2:-}" ]] || die "Missing argument for $1"
      mode="$2"
      shift 2
      ;;
    -s | --scan)
      scan=1
      if [[ -n "${2:-}" && "$2" != -* ]]; then
        scan_disk="$2"
        shift 2
      else
        shift 1
      fi
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$target" ]]; then
        target="$1"
        shift
      else
        die "Unexpected extra argument: $1"
      fi
      ;;
    esac
  done

  # Scan mode
  if ((scan == 1)); then
    scan_luks "$scan_disk"
    exit 0
  fi

  # Wipe mode
  [[ -n "$target" ]] ||
    die "No TARGET specified. Use -t /dev/sdXN or a positional target."

  if [[ -n "$mode" ]]; then
    mode=$(printf '%s\n' "$mode" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
    dd | auto) : ;;
    *)
      die "Invalid mode: ${mode}. Use 'dd' or 'auto'."
      ;;
    esac
  fi

  do_wipe "$target" "${mode:-}"
}

main "$@"
