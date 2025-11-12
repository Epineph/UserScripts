#!/usr/bin/env bash
#
# aur_build_max.sh — Clone, build and install an AUR package with max resources.
#
# Usage:
#   aur_build_max.sh [--jobs N] [--unit NAME] [--keep-dir] <aur-package>
#
# Options:
#   --jobs N, --jobs=N     Number of parallel build jobs (default: nproc)
#   --unit NAME, --unit=NAME
#                          systemd scope unit name (default: aur_build.scope)
#   --keep-dir             Don’t delete the clone directory after success
#   -h, --help             Show this help and exit
#
# Example:
#   aur_build_max.sh --jobs 8 --unit=amdvlk.build aur/amdvlk-git
#
# Requirements:
#   • git, makepkg (from pacman)  
#   • cgroup v2 mounted at /sys/fs/cgroup  
#   • systemd-run (from systemd)  
#
set -euo pipefail

### 1) Parse arguments #####################################################

UNIT="aur_build.scope"
JOBS=""
KEEP=false

while (( $# )); do
  case "$1" in
    --jobs)    JOBS="$2"; shift 2 ;;
    --jobs=*)  JOBS="${1#*=}"; shift   ;;
    --unit)    UNIT="$2"; shift 2      ;;
    --unit=*)  UNIT="${1#*=}"; shift   ;;
    --keep-dir) KEEP=true; shift       ;;
    -h|--help)
      sed -n '1,50p' "$0"
      exit 0
      ;;
    *)
      AUR_PKG="$1"; shift
      ;;
  esac
done

if [[ -z "${AUR_PKG:-}" ]]; then
  echo "Error: no AUR package specified." >&2
  exit 1
fi

### 2) Determine parallelism ################################################

if [[ -n "$JOBS" ]]; then
  PAR_JOBS="$JOBS"
else
  PAR_JOBS="$(nproc)"
fi

### 3) Verify cgroup v2 #####################################################

if ! mount | grep -q '^cgroup2 on /sys/fs/cgroup'; then
  echo "Error: cgroup2 not mounted at /sys/fs/cgroup." >&2
  exit 1
fi

### 4) Clone the AUR repo ###################################################

WORKDIR="${AUR_PKG##*/}-build"
if [[ -d "$WORKDIR" ]]; then
  echo "[INFO] Re-using existing directory '$WORKDIR'"
else
  echo "[INFO] Cloning AUR package '$AUR_PKG' into '$WORKDIR'"
  git clone "https://aur.archlinux.org/${AUR_PKG##aur/}.git" "$WORKDIR"
fi

cd "$WORKDIR"

### 5) Build & install under high priority ##################################

echo "[INFO] Launching makepkg under systemd scope '$UNIT'"
echo "[INFO] CPUWeight=10000  IOWeight=10000  jobs=$PAR_JOBS"

exec systemd-run --scope --unit="$UNIT" \
     -p CPUWeight=10000 -p IOWeight=10000 \
     makepkg --noconfirm --syncdeps --rmdeps \
             --cleanbuild --keeptemp \
             --jobs="$PAR_JOBS" \
             --install
# Note: --keeptemp ensures artifacts are in WORKDIR if you need debugging.

### 6) Cleanup (only if we reach this point) #################################

if ! $KEEP; then
  cd ..
  echo "[INFO] Removing build directory '$WORKDIR'"
  rm -rf "$WORKDIR"
fi

