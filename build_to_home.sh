#!/usr/bin/env bash
#
# build_to_home.sh — Detect, configure, build & install into $HOME/bin
#
# Usage:
#   build_to_home.sh [--jobs N] [--unit NAME] [--build-dir DIR] [--no-prio] -- [extra configure/build args]
#
# Options:
#   --jobs N         Number of parallel build jobs (default: all available cores)
#   --unit NAME      Name of the systemd scope unit (default: build_to_home.scope)
#   --build-dir DIR  For CMake: directory in which to build (default: build/)
#   --no-prio        Don’t wrap under `systemd-run` (skip priority boost)
#   -h, --help       Show this help message and exit
#
# Examples:
#   # Autotools project:
#   build_to_home.sh --jobs 8 -- make clean
#
#   # CMake project, 16 jobs:
#   build_to_home.sh --jobs 16 --build-dir out -- \
#     -DCMAKE_BUILD_TYPE=Release
#
#   # Force no priority boost (just plain configure+build):
#   build_to_home.sh --no-prio -- ...

set -euo pipefail

###——— Defaults & parse args —————————————————————————————
JOBS=""
UNIT="build_to_home.scope"
BUILD_DIR="build"
PRIO_WRAP=true
EXTRA_ARGS=()

while (( $# )); do
  case "$1" in
    --jobs)
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "Error: --jobs requires a number." >&2; exit 1; }
      JOBS="$2"; shift 2 ;;
    --unit)
      UNIT="$2"; shift 2 ;;
    --build-dir)
      BUILD_DIR="$2"; shift 2 ;;
    --no-prio)
      PRIO_WRAP=false; shift ;;
    -h|--help)
      sed -n '1,50p' "$0"; exit 0 ;;
    --)
      shift; EXTRA_ARGS=( "$@" ); break ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Determine parallel jobs
if [[ -z "$JOBS" ]]; then
  JOBS="$(nproc)"
fi

# Ensure install prefix exists
PREFIX="$HOME/bin"
mkdir -p "$PREFIX"

###——— Priority wrapper setup ———————————————————————————
if $PRIO_WRAP && command -v systemd-run &>/dev/null \
               && mount | grep -q '^cgroup2 on /sys/fs/cgroup'; then
  SD_RUN=( systemd-run --scope --unit="$UNIT" -p CPUWeight=10000 -p IOWeight=10000 )
else
  SD_RUN=()
fi

###——— Build-system detection —————————————————————————
if [[ -f CMakeLists.txt ]]; then
  BUILD_SYS="cmake"
elif [[ -x configure ]]; then
  BUILD_SYS="autotools"
else
  echo "Error: No CMakeLists.txt or ./configure found." >&2
  exit 1
fi

###——— Run the appropriate steps ————————————————————————
case "$BUILD_SYS" in

  cmake)
    echo "[INFO] Detected CMake build"
    # 1) Configure
    mkdir -p "$BUILD_DIR"
    echo "[INFO] Configuring in '$BUILD_DIR' with prefix '$PREFIX'"
    "${SD_RUN[@]}" cmake -S . -B "$BUILD_DIR" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" "${EXTRA_ARGS[@]}"

    # 2) Build
    echo "[INFO] Building ($JOBS jobs)"
    "${SD_RUN[@]}" cmake --build "$BUILD_DIR" --parallel "$JOBS"

    # 3) Install
    echo "[INFO] Installing into '$PREFIX'"
    "${SD_RUN[@]}" cmake --install "$BUILD_DIR"
    ;;

  autotools)
    echo "[INFO] Detected Autotools build"
    # 1) Configure
    echo "[INFO] Configuring with prefix '$PREFIX'"
    "${SD_RUN[@]}" bash -c "./configure --prefix='$PREFIX' ${EXTRA_ARGS[*]}"

    # 2) Build
    echo "[INFO] Building ($JOBS jobs)"
    "${SD_RUN[@]}" make -j"$JOBS"

    # 3) Install
    echo "[INFO] Installing into '$PREFIX'"
    "${SD_RUN[@]}" make install
    ;;

esac

echo "[SUCCESS] All done. Binaries are in '$PREFIX'."