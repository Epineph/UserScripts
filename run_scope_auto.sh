#!/usr/bin/env bash
#
# run_scope_auto.sh — Launch any command under cgroup v2 with max CPU/IO weight,
#                    auto-checking dependencies & prompting install if missing.
#
# Usage:
#   run_scope_auto.sh [--jobs N] [--unit NAME] -- <command> [args...]
#
# Options:
#   --jobs N       Number of parallel jobs (default: all cores)
#   --unit NAME    systemd scope unit name (default: run_scope_auto.scope)
#   -h, --help     Show this help message and exit
#
# Author: (you)
# License: MIT
set -euo pipefail

########################
### 0. Helper fns    ###
########################

# Ask a yes/no question
ask_yes_no() {
  local prompt="$1"; shift
  local reply
  while true; do
    read -rp "$prompt [Y/n] " reply
    case "${reply,,}" in
      y|yes|'') return 0 ;;
      n|no)     return 1 ;;
      *)        echo "Please answer yes or no." ;;
    esac
  done
}

# Detect package manager and install command
detect_pkgmgr() {
  if   command -v pacman   &>/dev/null; then echo "pacman -S"; 
  elif command -v apt-get  &>/dev/null; then echo "apt-get install -y"; 
  elif command -v dnf      &>/dev/null; then echo "dnf install -y"; 
  else                            echo ""; 
  fi
}

########################
### 1. Check deps   ###
########################

declare -A pkgname=(
  [systemd-run]=systemd
  [nproc]=util-linux
)

PKGMGR=$(detect_pkgmgr)

for cmd in "${!pkgname[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "⚠️  Dependency '$cmd' not found."
    if [[ -n "$PKGMGR" ]]; then
      if ask_yes_no "  Install package '${pkgname[$cmd]}' now?"; then
        sudo $PKGMGR "${pkgname[$cmd]}"
      else
        echo "Please install '${pkgname[$cmd]}' and re-run this script."
        exit 1
      fi
    else
      echo "Please install '${pkgname[$cmd]}' via your distro’s package manager and re-run."
      exit 1
    fi
  fi
done

########################
### 2. Check cgroup2 ###
########################

if ! mount | grep -q '^cgroup2 on /sys/fs/cgroup'; then
  cat <<EOF >&2
ERROR: cgroup v2 is not mounted at /sys/fs/cgroup.
Please:
  1) Add 'systemd.unified_cgroup_hierarchy=1' to your kernel cmdline (e.g. in GRUB),
     regenerate grub.cfg, and reboot.
  2) If needed, add to /etc/fstab:
       cgroup2  /sys/fs/cgroup  cgroup2  defaults  0 0
     then run 'sudo mount /sys/fs/cgroup'.
EOF
  exit 1
fi

########################
### 3. Parse args   ###
########################

UNIT_NAME="run_scope_auto.scope"
JOBS=""
CMD=()

while (( $# )); do
  case "$1" in
    --jobs)
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "Error: --jobs requires a number." >&2; exit 1; }
      JOBS="$2"; shift 2 ;;
    --unit)
      UNIT_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,75p' "$0"; exit 0 ;;
    --)
      shift; CMD=( "$@" ); break ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if (( ${#CMD[@]} == 0 )); then
  echo "Error: no command specified. Use -- <command> [args...]" >&2
  exit 1
fi

########################
### 4. Determine -j  ###
########################

if [[ -n "$JOBS" ]]; then
  PAR_JOBS="$JOBS"
else
  PAR_JOBS="$(nproc)"
fi

########################
### 5. Build & run  ###
########################

SD_RUN=( systemd-run --scope
         --unit="$UNIT_NAME"
         -p CPUWeight=10000
         -p IOWeight=10000 )

MAIN_CMD=( "${CMD[@]}" )
case "${CMD[0]}" in
  make)   MAIN_CMD+=( -j"$PAR_JOBS" ) ;;
  cmake)  MAIN_CMD+=( --parallel "$PAR_JOBS" ) ;;
  ninja)  MAIN_CMD+=( -j"$PAR_JOBS" ) ;;
  vcpkg)  MAIN_CMD+=( install --jobs="$PAR_JOBS" ) ;;
esac

echo "[INFO] Launching under systemd scope '$UNIT_NAME'"
echo "[INFO] CPUWeight=10000  IOWeight=10000  jobs=$PAR_JOBS"
echo "[INFO] Command: ${MAIN_CMD[*]}"

exec "${SD_RUN[@]}" "${MAIN_CMD[@]}"