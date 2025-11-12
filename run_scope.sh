#!/usr/bin/env bash
#
# run_scope.sh — Launch a build (or any) command under a systemd scope
#                with maximum CPU and I/O weight on cgroup v2 systems.
#
# Usage:
#   run_scope.sh [--jobs N] [--unit NAME] -- <command> [args...]
#
# Options:
#   --jobs N       Manually set number of parallel jobs (default: all cores)
#   --unit NAME    Override the systemd unit name (default: run_scope.scope)
#   -h, --help     Show this help message and exit
#
# Requirements:
#   • systemd (with cgroup v2 enabled; Arch’s default)
#   • A build tool that accepts -j/--parallel/--jobs if you want
#     CPU parallelism (make, cmake, vcpkg, ninja, etc.)
#
set -euo pipefail

###########################
### 1. Parse arguments  ###
###########################

UNIT_NAME="run_scope.scope"
JOBS=""
CMD=()

while (( $# )); do
  case "$1" in
    --jobs)
      if [[ -n "${2-}" && "$2" =~ ^[0-9]+$ ]]; then
        JOBS="$2"
        shift 2
      else
        echo "Error: --jobs requires a numeric argument." >&2
        exit 1
      fi
      ;;
    --unit)
      if [[ -n "${2-}" ]]; then
        UNIT_NAME="$2"
        shift 2
      else
        echo "Error: --unit requires a name." >&2
        exit 1
      fi
      ;;
    -h|--help)
      sed -n '1,50p' "$0"
      exit 0
      ;;
    --)
      shift
      CMD=( "$@" )
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "Error: no command specified. Use -- <command> [args...]" >&2
  exit 1
fi

###########################
### 2. Determine cores  ###
###########################

# By default, use all online cores
if [[ -n "$JOBS" ]]; then
  PAR_JOBS="$JOBS"
else
  PAR_JOBS="$(nproc)"
fi

###########################
### 3. Build the prefix ###
###########################

# systemd-run properties:
#   CPUWeight=10000 → max CPU scheduling weight
#   IOWeight=10000  → max I/O scheduling weight
SD_RUN=( systemd-run --scope
         --unit="$UNIT_NAME"
         -p CPUWeight=10000
         -p IOWeight=10000 )

###########################
### 4. Inject parallelism ###
###########################

MAIN_CMD=( "${CMD[@]}" )
case "${CMD[0]}" in
  make)
    MAIN_CMD+=( -j"$PAR_JOBS" )
    ;;
  cmake)
    MAIN_CMD+=( --parallel "$PAR_JOBS" )
    ;;
  ninja)
    MAIN_CMD+=( -j"$PAR_JOBS" )
    ;;
  vcpkg)
    MAIN_CMD+=( install --jobs="$PAR_JOBS" )
    ;;
  *)
    # Other commands: no automatic -j injection
    ;;
esac

###########################
### 5. Execute everything ###
###########################

echo "[INFO] Launching under systemd scope '$UNIT_NAME'"
echo "[INFO] CPUWeight=10000, IOWeight=10000, parallel jobs=$PAR_JOBS"
echo "[INFO] Command: ${MAIN_CMD[*]}"

exec "${SD_RUN[@]}" "${MAIN_CMD[@]}"