#!/usr/bin/env bash
# Build LLVM and its in-tree projects with Ninja.
#
# The script clones into $HOME/repos/llvm-project, checks prerequisites,
# offers to install missing packages, and runs a Release build. It never uses
# sudo for cloning or compiling.

set -uo pipefail
umask 022

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

readonly LLVM_GIT_URL="https://github.com/llvm/llvm-project.git"
readonly DEFAULT_REPO_DIR="${HOME}/repos/llvm-project"
readonly DEFAULT_BUILD_TYPE="Release"

REPO_DIR="$DEFAULT_REPO_DIR"
BUILD_DIR=""
JOBS_OVERRIDE=""
LINK_JOBS_OVERRIDE=""
BUILD_NICE="0"
IONICE_LEVEL="0"
USE_IONICE=1
UPDATE_REPO=1
SKIP_DEPS=0
ASSUME_YES=0
NATIVE_TARGET_ONLY=0

# Include all main upstream projects and Flang (which LLVM's literal `all`
# project selection currently leaves out). Include every runtime currently
# listed as supported by LLVM's top-level CMake configuration.
readonly LLVM_PROJECTS="bolt;clang;clang-tools-extra;cross-project-tests;flang;lld;lldb;mlir;polly"
readonly LLVM_RUNTIMES="libc;libunwind;libcxxabi;libcxx;compiler-rt;openmp;llvm-libgcc;offload;flang-rt;libclc;libsycl;orc-rt"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'HELP'
Usage:
  build-llvm-all.sh [options]

Clone LLVM into $HOME/repos/llvm-project, configure a Release build with Ninja,
and build all listed projects, runtimes, and supported code-generation targets.
Missing prerequisites trigger an installation prompt when a supported package
manager is available.

Options:
  --repo-dir DIR       Source checkout (default: $HOME/repos/llvm-project)
  --build-dir DIR      Build directory (default: <repo-dir>/build)
  --jobs N             Compile jobs (default: calculated from RAM and CPUs)
  --link-jobs N        Concurrent link jobs (default: calculated from RAM)
  --nice N             CPU niceness, 0-19 (default: 0)
  --ionice N           Best-effort I/O priority, 0-7 (default: 0)
  --no-ionice          Do not apply ionice, even if installed
  --native-target      Build only the host backend instead of every backend
  --no-update          Do not fetch updates in an existing clean checkout
  --skip-deps          Do not offer or attempt package installation
  --yes                Approve dependency installation and disk-space prompts
  --help               Show this help
  --long-help          Show detailed build and resource notes

Examples:
  ./build-llvm-all.sh
  ./build-llvm-all.sh --jobs 8 --link-jobs 1
  ./build-llvm-all.sh --repo-dir "$HOME/repos/llvm-project" --native-target
HELP
}

function show_long_help() {
  show_help
  cat <<'HELP'

Build details:
  * The build uses Release mode and Ninja. It includes Clang, Clang tools,
    LLD, LLDB, MLIR, Polly, BOLT, cross-project test support, and Flang.
    It also enables every runtime currently listed as supported by LLVM's
    top-level CMake configuration. Some newer runtimes may need vendor or
    toolchain components beyond the distro packages listed by this script.
  * Every supported code-generation backend is enabled by default. Use
    `--native-target` to reduce backend compilation to the host architecture.
  * Tests, examples, benchmarks, and documentation are disabled to keep this
    build focused on compiler tools and libraries. The script does not run
    `install`; binaries are available in <build-dir>/bin.
  * Compile concurrency is capped by available CPU quota and an estimated
    1.25 GiB per compiler job, leaving 3 GiB for the OS and other processes.
    Link concurrency follows LLVM's guidance of roughly one link job per
    15 GiB of RAM. Use --jobs to override the compile estimate.
  * `ionice` only adjusts I/O scheduling priority. It does not make the
    compiler faster on its own. The default best-effort priority is 0.
  * A large all-project and all-target build can use tens of gigabytes. The
    script warns below 80 GiB free and stops below 35 GiB unless --yes is
    supplied.
  * Package installation is supported on Arch Linux, Debian/Ubuntu, and
    Fedora. Other distributions receive a list of required tool checks.
  * An existing LLVM checkout is never reset or cleaned. A dirty checkout is
    built as it is; automatic updates are skipped when local changes exist.

Build output and configure/build logs are kept in the build directory.
HELP
}

# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function ask_yes_no() {
  local prompt="$1"
  local answer=""

  if (( ASSUME_YES )); then
    return 0
  fi

  [[ -r /dev/tty ]] || return 1
  printf '%s [y/N] ' "$prompt" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function run_as_root_if_needed() {
  if (( EUID == 0 )); then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    return 127
  fi
}

function parse_args() {
  while (($#)); do
    case "$1" in
      --repo-dir)
        (($# >= 2)) || die "--repo-dir requires a directory"
        REPO_DIR="$2"
        shift 2
        ;;
      --build-dir)
        (($# >= 2)) || die "--build-dir requires a directory"
        BUILD_DIR="$2"
        shift 2
        ;;
      --jobs)
        (($# >= 2)) || die "--jobs requires a positive integer"
        JOBS_OVERRIDE="$2"
        shift 2
        ;;
      --link-jobs)
        (($# >= 2)) || die "--link-jobs requires a positive integer"
        LINK_JOBS_OVERRIDE="$2"
        shift 2
        ;;
      --nice)
        (($# >= 2)) || die "--nice requires an integer from 0 to 19"
        BUILD_NICE="$2"
        shift 2
        ;;
      --ionice)
        (($# >= 2)) || die "--ionice requires an integer from 0 to 7"
        IONICE_LEVEL="$2"
        USE_IONICE=1
        shift 2
        ;;
      --no-ionice)
        USE_IONICE=0
        shift
        ;;
      --native-target)
        NATIVE_TARGET_ONLY=1
        shift
        ;;
      --no-update)
        UPDATE_REPO=0
        shift
        ;;
      --skip-deps)
        SKIP_DEPS=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      --long-help)
        show_long_help
        exit 0
        ;;
      *)
        die "Unknown option: $1 (try --help)"
        ;;
    esac
  done

  if [[ -n "$JOBS_OVERRIDE" ]] &&
    [[ ! "$JOBS_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    die "--jobs must be a positive integer"
  fi
  if [[ -n "$LINK_JOBS_OVERRIDE" ]] &&
    [[ ! "$LINK_JOBS_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    die "--link-jobs must be a positive integer"
  fi
  [[ "$BUILD_NICE" =~ ^([0-9]|1[0-9])$ ]] ||
    die "--nice must be an integer from 0 to 19"
  [[ "$IONICE_LEVEL" =~ ^[0-7]$ ]] ||
    die "--ionice must be an integer from 0 to 7"

  [[ -n "$BUILD_DIR" ]] || BUILD_DIR="${REPO_DIR}/build"
  REPO_DIR="$(realpath -m -- "$REPO_DIR")"
  BUILD_DIR="$(realpath -m -- "$BUILD_DIR")"
}

# -----------------------------------------------------------------------------
# Resource detection
# -----------------------------------------------------------------------------

function detected_memory_bytes() {
  local host_kib=""
  local limit=""

  host_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  [[ "$host_kib" =~ ^[0-9]+$ ]] || return 1
  local host_bytes=$((host_kib * 1024))

  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    limit="$(< /sys/fs/cgroup/memory.max)"
    if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit < host_bytes )); then
      host_bytes="$limit"
    fi
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    limit="$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit < host_bytes )); then
      host_bytes="$limit"
    fi
  fi

  printf '%s\n' "$host_bytes"
}

function detected_cpu_count() {
  local cpus=1
  local cpu_max=""

  command_exists nproc && cpus="$(nproc)"
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1

  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    cpu_max="$(< /sys/fs/cgroup/cpu.max)"
    local quota period quota_cpus
    read -r quota period <<< "$cpu_max"
    if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] &&
      (( period > 0 )); then
      quota_cpus=$((quota / period))
      (( quota_cpus < 1 )) && quota_cpus=1
      (( quota_cpus < cpus )) && cpus="$quota_cpus"
    fi
  fi

  printf '%s\n' "$cpus"
}

function calculate_parallelism() {
  local memory_bytes memory_gib memory_jobs cpu_count
  memory_bytes="$(detected_memory_bytes)" || die "Cannot read system memory"
  memory_gib=$((memory_bytes / 1073741824))
  cpu_count="$(detected_cpu_count)"

  # Reserve 3 GiB for the desktop and other processes; budget 1.25 GiB per
  # active C++ compile. This is a conservative starting point for LLVM.
  memory_jobs=$(((memory_gib - 3) * 4 / 5))
  (( memory_jobs < 1 )) && memory_jobs=1

  AUTO_JOBS="$cpu_count"
  (( memory_jobs < AUTO_JOBS )) && AUTO_JOBS="$memory_jobs"
  JOBS="$AUTO_JOBS"
  [[ -z "$JOBS_OVERRIDE" ]] || JOBS="$JOBS_OVERRIDE"

  AUTO_LINK_JOBS=$((memory_gib / 15))
  (( AUTO_LINK_JOBS < 1 )) && AUTO_LINK_JOBS=1
  (( AUTO_LINK_JOBS > JOBS )) && AUTO_LINK_JOBS="$JOBS"
  LINK_JOBS="$AUTO_LINK_JOBS"
  [[ -z "$LINK_JOBS_OVERRIDE" ]] || LINK_JOBS="$LINK_JOBS_OVERRIDE"

  MEMORY_GIB="$memory_gib"
  CPU_COUNT="$cpu_count"
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

function distro_id() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf '%s\n' "${ID:-unknown}"
  else
    printf 'unknown\n'
  fi
}

function install_packages() {
  local id="$1"
  shift
  local -a packages=()

  case "$id" in
    arch|manjaro|endeavouros)
      packages=(
        base-devel cmake ninja git python python-yaml zlib zstd libffi
        libedit ncurses libxml2 xz swig libpfm z3 isl lld pkgconf curl
        spirv-headers spirv-tools
      )
      if ask_yes_no "Install LLVM build prerequisites with pacman?"; then
        run_as_root_if_needed pacman -S --needed "${packages[@]}"
      else
        return 1
      fi
      ;;
    debian|ubuntu|linuxmint|pop)
      packages=(
        build-essential cmake ninja-build git python3 python3-dev
        python3-yaml zlib1g-dev libzstd-dev libffi-dev libedit-dev
        libncurses-dev libxml2-dev liblzma-dev libcurl4-openssl-dev
        libpfm4-dev libz3-dev libisl-dev swig lld pkg-config
        spirv-headers spirv-tools
      )
      if ask_yes_no "Install LLVM build prerequisites with apt?"; then
        run_as_root_if_needed apt-get update &&
          run_as_root_if_needed apt-get install -y --no-install-recommends \
            "${packages[@]}"
      else
        return 1
      fi
      ;;
    fedora|rhel|rocky|almalinux)
      packages=(
        gcc gcc-c++ make cmake ninja-build git python3 python3-devel
        python3-pyyaml zlib-devel libzstd-devel libffi-devel libedit-devel
        ncurses-devel libxml2-devel xz-devel libcurl-devel libpfm-devel
        z3-devel isl-devel swig lld pkgconf-pkg-config spirv-headers
        spirv-tools gawk
      )
      if ask_yes_no "Install LLVM build prerequisites with dnf?"; then
        run_as_root_if_needed dnf install -y "${packages[@]}"
      else
        return 1
      fi
      ;;
    *)
      printf 'No supported package mapping for distro ID: %s\n' "$id" >&2
      return 1
      ;;
  esac
}

function check_prerequisites() {
  local -a missing=()
  local -a commands=(git cmake ninja python3 pkg-config swig realpath awk df tee)
  local command_name module

  for command_name in "${commands[@]}"; do
    command_exists "$command_name" || missing+=("command:$command_name")
  done

  if ! command_exists c++ && ! command_exists clang++; then
    missing+=("C++ compiler (g++ or clang++)")
  fi
  if ! command_exists cc && ! command_exists clang; then
    missing+=("C compiler (gcc or clang)")
  fi

  if command_exists cmake; then
    local version="0.0.0" major=0 minor=0 extra=""
    version="$(cmake --version | awk 'NR == 1 { print $3 }')"
    IFS=. read -r major minor extra <<< "$version"
    if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] ||
      (( major < 3 || (major == 3 && minor < 20) )); then
      missing+=("CMake >= 3.20 (found ${version:-unknown})")
    fi
  fi

  if command_exists pkg-config; then
    for module in \
      zlib libzstd libxml-2.0 libedit ncurses liblzma z3 isl; do
      pkg-config --exists "$module" || missing+=("pkg-config:$module")
    done
  fi

  if command_exists python3; then
    python3 - <<'PY' >/dev/null 2>&1 || missing+=("Python >= 3.8, PyYAML, and Python.h")
import pathlib
import sys
import sysconfig
import yaml

header = pathlib.Path(sysconfig.get_path("include")) / "Python.h"
sys.exit(0 if sys.version_info >= (3, 8) and header.is_file() else 1)
PY
  fi

  if ((${#missing[@]} == 0)); then
    printf 'Prerequisite checks passed.\n'
    return 0
  fi

  printf 'Missing or incomplete prerequisites:\n' >&2
  printf '  - %s\n' "${missing[@]}" >&2

  if (( SKIP_DEPS )); then
    die "Install the listed dependencies, then rerun without --skip-deps."
  fi

  if ! install_packages "$(distro_id)"; then
    die "Prerequisites were not installed. Install them and rerun the script."
  fi

  printf '\nRechecking prerequisites...\n'
  SKIP_DEPS=1
  check_prerequisites
}

# -----------------------------------------------------------------------------
# Checkout and storage checks
# -----------------------------------------------------------------------------

function repository_is_llvm() {
  local origin=""
  origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  case "$origin" in
    https://github.com/llvm/llvm-project.git|\
    https://github.com/llvm/llvm-project|\
    git@github.com:llvm/llvm-project.git|\
    ssh://git@github.com/llvm/llvm-project.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function prepare_checkout() {
  local repo_parent="$(dirname -- "$REPO_DIR")"

  mkdir -p -- "$repo_parent" || die "Cannot create $repo_parent"
  [[ -w "$repo_parent" ]] || die "No write permission for $repo_parent"

  if [[ ! -e "$REPO_DIR" ]]; then
    printf 'Cloning LLVM into %s (shallow clone)...\n' "$REPO_DIR"
    git clone --depth 1 --single-branch --branch main \
      "$LLVM_GIT_URL" "$REPO_DIR" || die "LLVM clone failed"
    return 0
  fi

  [[ -d "$REPO_DIR/.git" ]] ||
    die "$REPO_DIR exists but is not an LLVM Git checkout"
  repository_is_llvm || die "The Git remote in $REPO_DIR is not llvm-project"

  if (( ! UPDATE_REPO )); then
    printf 'Using existing checkout; updates disabled.\n'
    return 0
  fi

  if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    printf 'Local changes found; preserving them and skipping Git updates.\n'
    return 0
  fi

  if [[ "$(git -C "$REPO_DIR" branch --show-current)" != "main" ]]; then
    printf 'Checkout is not on main; preserving its current revision.\n'
    return 0
  fi

  printf 'Updating the clean LLVM checkout...\n'
  git -C "$REPO_DIR" fetch --depth 1 origin main ||
    die "Could not fetch LLVM updates"
  git -C "$REPO_DIR" merge --ff-only FETCH_HEAD ||
    die "Could not fast-forward the LLVM checkout"
}

function available_bytes() {
  local directory="$1"
  while [[ ! -d "$directory" ]]; do
    directory="$(dirname -- "$directory")"
  done
  df -Pk -- "$directory" | awk 'NR == 2 { print $4 * 1024; exit }'
}

function check_disk_space() {
  local free_bytes free_gib min_bytes warn_bytes
  free_bytes="$(available_bytes "$BUILD_DIR")"
  [[ "$free_bytes" =~ ^[0-9]+$ ]] || die "Could not determine free disk space"
  free_gib=$((free_bytes / 1073741824))
  min_bytes=$((35 * 1073741824))
  warn_bytes=$((80 * 1073741824))

  printf 'Free space for build: %s GiB\n' "$free_gib"
  if (( free_bytes < min_bytes )); then
    (( ASSUME_YES )) || die "Less than 35 GiB is free; refusing a likely-to-fail build."
    printf 'Warning: proceeding below the 35 GiB safety threshold (--yes).\n' >&2
  elif (( free_bytes < warn_bytes )); then
    if ! ask_yes_no "Less than 80 GiB is free. Continue with the full build?"; then
      die "Build cancelled at the disk-space check."
    fi
  fi
}

# -----------------------------------------------------------------------------
# Build setup and execution
# -----------------------------------------------------------------------------

function choose_compilers() {
  if [[ -n "${CC:-}" && -n "${CXX:-}" ]]; then
    BUILD_CC="$CC"
    BUILD_CXX="$CXX"
  elif command_exists clang && command_exists clang++; then
    BUILD_CC="$(command -v clang)"
    BUILD_CXX="$(command -v clang++)"
  else
    BUILD_CC="$(command -v cc || command -v gcc)"
    BUILD_CXX="$(command -v c++ || command -v g++)"
  fi
}

function setup_build() {
  local -a cmake_args=()
  local targets="all"

  (( NATIVE_TARGET_ONLY )) && targets="Native"
  choose_compilers
  mkdir -p -- "$BUILD_DIR" || die "Cannot create build directory"
  [[ -w "$BUILD_DIR" ]] || die "No write permission for $BUILD_DIR"

  cmake_args=(
    -S "${REPO_DIR}/llvm"
    -B "$BUILD_DIR"
    -G Ninja
    "-DCMAKE_BUILD_TYPE=${DEFAULT_BUILD_TYPE}"
    "-DCMAKE_INSTALL_PREFIX=${REPO_DIR}/install"
    "-DCMAKE_C_COMPILER=${BUILD_CC}"
    "-DCMAKE_CXX_COMPILER=${BUILD_CXX}"
    "-DLLVM_ENABLE_PROJECTS=${LLVM_PROJECTS}"
    "-DLLVM_ENABLE_RUNTIMES=${LLVM_RUNTIMES}"
    "-DLLVM_TARGETS_TO_BUILD=${targets}"
    "-DLLVM_PARALLEL_COMPILE_JOBS=${JOBS}"
    "-DLLVM_PARALLEL_LINK_JOBS=${LINK_JOBS}"
    "-DLLVM_PARALLEL_TABLEGEN_JOBS=${JOBS}"
    -DLLVM_BUILD_LLVM_DYLIB=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
    -DLLVM_ENABLE_LIBEDIT=ON
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DCLANG_INCLUDE_TESTS=OFF
    -DLLD_INCLUDE_TESTS=OFF
    -DLLDB_INCLUDE_TESTS=OFF
    -DMLIR_INCLUDE_TESTS=OFF
    -DFLANG_INCLUDE_TESTS=OFF
    -DLLVM_ENABLE_ZLIB=FORCE_ON
    -DLLVM_ENABLE_ZSTD=FORCE_ON
    -DLLVM_ENABLE_LZMA=ON
  )

  if command_exists ld.lld; then
    cmake_args+=(-DLLVM_USE_LINKER=lld)
    printf 'Using host LLD as the build linker.\n'
  fi

  CONFIG_LOG="${BUILD_DIR}/configure.log"
  BUILD_LOG="${BUILD_DIR}/build.log"
  : > "$CONFIG_LOG" || die "Cannot write $CONFIG_LOG"
  : > "$BUILD_LOG" || die "Cannot write $BUILD_LOG"

  printf 'Source:          %s\n' "$REPO_DIR"
  printf 'Build directory: %s\n' "$BUILD_DIR"
  printf 'Projects:        %s\n' "$LLVM_PROJECTS"
  printf 'Runtimes:        %s\n' "$LLVM_RUNTIMES"
  printf 'LLVM targets:    %s\n' "$targets"
  printf 'Compiler:        %s / %s\n' "$BUILD_CC" "$BUILD_CXX"
  printf 'Parallel jobs:   %s compile, %s link\n' "$JOBS" "$LINK_JOBS"
  printf 'Memory / CPUs:   %s GiB / %s available\n' "$MEMORY_GIB" "$CPU_COUNT"
  printf 'Configure log:   %s\n' "$CONFIG_LOG"
  printf 'Build log:       %s\n\n' "$BUILD_LOG"

  if ! run_logged "$CONFIG_LOG" cmake "${cmake_args[@]}"; then
    die "CMake configuration failed; inspect $CONFIG_LOG"
  fi
}

function run_logged() {
  local log_file="$1"
  shift
  local -a command=("$@")
  local -a wrapped=()
  local command_status

  if (( USE_IONICE )) && command_exists ionice; then
    wrapped+=(ionice -c 2 -n "$IONICE_LEVEL")
  fi
  if command_exists nice; then
    wrapped+=(nice -n "$BUILD_NICE")
  fi
  wrapped+=("${command[@]}")

  printf '+ '
  printf '%q ' "${wrapped[@]}"
  printf '\n'
  "${wrapped[@]}" 2>&1 | tee -a "$log_file"
  local -a statuses=("${PIPESTATUS[@]}")
  command_status="${statuses[0]}"
  return "$command_status"
}

function main() {
  parse_args "$@"

  [[ "$(uname -s)" == "Linux" ]] ||
    die "This launcher currently supports Linux hosts."
  (( EUID != 0 )) ||
    die "Run this script as your regular user, not with sudo."

  check_prerequisites
  calculate_parallelism

  if [[ -n "$JOBS_OVERRIDE" ]]; then
    local safe_jobs="$AUTO_JOBS"
    if (( JOBS > safe_jobs )); then
      printf 'Requested -j%s exceeds the estimated safe default of %s.\n' \
        "$JOBS" "$safe_jobs" >&2
      ask_yes_no "Continue with the higher compile parallelism?" ||
        die "Build cancelled. Rerun with --jobs $safe_jobs or another value."
    fi
  fi

  check_disk_space
  prepare_checkout
  check_disk_space
  setup_build

  printf '\nStarting LLVM build...\n'
  if ! run_logged "$BUILD_LOG" cmake --build "$BUILD_DIR" \
    --parallel "$JOBS"; then
    die "LLVM build failed; inspect $BUILD_LOG and resume with this script."
  fi

  printf '\nLLVM build completed. Binaries are in %s/bin\n' "$BUILD_DIR"
  printf 'This script did not install the build system-wide or run tests.\n'
}

main "$@"
