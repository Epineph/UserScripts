#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build-llvm.sh
#
# Build LLVM (llvm-project monorepo) + as many subprojects/runtimes as you want,
# using an out-of-tree CMake + Ninja build (sane defaults; configurable).
#
# Intended for: "I have source files that won't build with anything else."
# You get a fresh clang/clang++/lld (and optionally lldb, mlir, etc.).
#
# Notes:
#   - This script does NOT install distro dependencies for you.
#   - On Arch Linux, you typically want:
#       sudo pacman -S --needed base-devel cmake ninja git python
#       sudo pacman -S --needed zlib libxml2 libedit ncurses
#       sudo pacman -S --needed swig python-setuptools   # for LLDB (often)
#
# Usage:
#   ./build-llvm.sh --help
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

function _log() { printf '%s\n' "[$(date +'%F %T')] $*" >&2; }
function _die() {
	printf '%s\n' "ERROR: $*" >&2
	exit 1
}

function _have() { command -v "$1" >/dev/null 2>&1; }

function _help() {
	local -a pager_cmd
	if [[ -n "${HELP_PAGER:-}" ]]; then
		# Split on spaces/tabs/newlines. (HELP_PAGER is expected to be a simple
		# command like "less -R" or "cat", not a shell snippet.)
		local IFS=$' \t\n'
		read -r -a pager_cmd <<<"$HELP_PAGER"
		if ((${#pager_cmd[@]} == 0)); then
			pager_cmd=(cat)
		fi
	elif _have less; then
		pager_cmd=(less -R)
	else
		pager_cmd=(cat)
	fi

	cat <<'EOF' | "${pager_cmd[@]}"
build-llvm.sh — build LLVM/Clang toolchain from source (llvm-project)

SYNOPSIS
  build-llvm.sh [options]

COMMON ONE-LINERS
  # "Safe" default: clang + tools + lld + lldb + mlir, and key runtimes.
  ./build-llvm.sh

  # Max-ish preset (more projects; may require extra deps)
  ./build-llvm.sh --preset max

  # Install to ~/opt/llvm-main and keep source/build alongside
  ./build-llvm.sh --root "$HOME/opt/llvm-main"

  # Use a specific released tag
  ./build-llvm.sh --ref llvmorg-19.1.5

  # Provide extra CMake definitions
  ./build-llvm.sh --cmake-extra "-DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_ENABLE_ZSTD=ON"

WHAT THIS DOES
  - clones (or updates) llvm-project into:   <root>/src/llvm-project
  - configures build in:                    <root>/build
  - installs into:                          <root>/install
  - writes env helper:                      <root>/install/enable-llvm-env.sh

DEFAULTS (PRESET=safe)
  Projects:
    clang;clang-tools-extra;lld;lldb;mlir
  Runtimes:
    compiler-rt;libcxx;libcxxabi;libunwind
  Targets to build:
    X86;AArch64;ARM;RISCV;WebAssembly
  Build type:
    Release
  Generator:
    Ninja

OPTIONS
  --root PATH
      Root directory for src/build/install (default: ./llvm-local)

  --ref REF
      Git ref to checkout (default: main). Examples:
        main
        llvmorg-19.1.5
        <commit-sha>

  --no-update
      Do not git fetch/pull if repo already exists.

  --clean
      Remove <root>/build before configuring.

  --build-type TYPE
      Release | RelWithDebInfo | Debug (default: Release)

  --preset NAME
      safe | max
      safe: usually builds on a stock dev machine.
      max:  enables more projects; higher chance of missing deps.

  --projects LIST
      Semicolon or comma separated list for LLVM_ENABLE_PROJECTS.
      Example:
        --projects "clang;clang-tools-extra;lld;lldb;mlir;polly;bolt"

  --runtimes LIST
      Semicolon or comma separated list for LLVM_ENABLE_RUNTIMES.
      Example:
        --runtimes "compiler-rt;libcxx;libcxxabi;libunwind"

  --targets LIST
      Semicolon or comma separated list for LLVM_TARGETS_TO_BUILD.
      Example:
        --targets "X86;AArch64"

  --use-lld [auto|on|off]
      auto: use lld if available after build config (default)
      on:   force -DLLVM_USE_LINKER=lld
      off:  do not request lld as linker

  --cc PATH
  --cxx PATH
      Host compilers to bootstrap LLVM build (defaults: cc/c++ in PATH).

  --jobs N
      Parallel build jobs (default: nproc).

  --cmake-extra "..."
      Extra arguments appended verbatim to the CMake configure command.

  -h, --help
      Show this help.

AFTER INSTALL
  Source:
    source "<root>/install/enable-llvm-env.sh"
  Then:
    clang --version
    clang++ --version
    lld --version

EXAMPLE: COMPILE A STUBBORN FILE
  source ./llvm-local/install/enable-llvm-env.sh
  clang++ -std=c++23 -O2 -pipe -fuse-ld=lld your_file.cpp -o a.out

EOF
}

# ----------------------------- defaults --------------------------------------

ROOT="${PWD}/llvm-local"
REF="main"
NO_UPDATE="0"
CLEAN="0"
BUILD_TYPE="Release"
PRESET="safe"

PROJECTS_SAFE="clang;clang-tools-extra;lld;lldb;mlir"
RUNTIMES_SAFE="compiler-rt;libcxx;libcxxabi;libunwind"

# "Max-ish": you may need extra deps (polly/bolt/flang/etc.) depending on host.
PROJECTS_MAX="clang;clang-tools-extra;lld;lldb;mlir;polly;bolt;openmp"
RUNTIMES_MAX="compiler-rt;libc;libcxx;libcxxabi;libunwind"

PROJECTS="$PROJECTS_SAFE"
RUNTIMES="$RUNTIMES_SAFE"

TARGETS="X86;AArch64;ARM;RISCV;WebAssembly"

USE_LLD_MODE="auto" # auto|on|off
CC_BIN=""
CXX_BIN=""
JOBS=""
CMAKE_EXTRA=""

# ----------------------------- arg parsing -----------------------------------

function _norm_list() {
	# Convert commas -> semicolons, strip spaces.
	# Keep case as-is (CMake expects specific target names sometimes).
	local s="${1}"
	s="${s//,/;}"
	s="${s// /}"
	printf '%s' "$s"
}

function _parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			_help
			exit 0
			;;
		--root)
			[[ $# -ge 2 ]] || _die "--root requires a PATH"
			ROOT="$2"
			[[ -n "$ROOT" ]] || _die "--root cannot be empty"
			[[ "$ROOT" != "/" ]] || _die "--root cannot be / (refusing for safety)"
			shift 2
			;;
		--ref)
			[[ $# -ge 2 ]] || _die "--ref requires a REF"
			REF="$2"
			shift 2
			;;
		--no-update)
			NO_UPDATE="1"
			shift 1
			;;
		--clean)
			CLEAN="1"
			shift 1
			;;
		--build-type)
			[[ $# -ge 2 ]] || _die "--build-type requires a TYPE"
			BUILD_TYPE="$2"
			shift 2
			;;
		--preset)
			[[ $# -ge 2 ]] || _die "--preset requires a NAME"
			PRESET="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--projects)
			[[ $# -ge 2 ]] || _die "--projects requires a LIST"
			PROJECTS="$(_norm_list "$2")"
			shift 2
			;;
		--runtimes)
			[[ $# -ge 2 ]] || _die "--runtimes requires a LIST"
			RUNTIMES="$(_norm_list "$2")"
			shift 2
			;;
		--targets)
			[[ $# -ge 2 ]] || _die "--targets requires a LIST"
			TARGETS="$(_norm_list "$2")"
			shift 2
			;;
		--use-lld)
			if [[ $# -ge 2 ]] && [[ ! "$2" =~ ^- ]]; then
				USE_LLD_MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
				shift 2
			else
				USE_LLD_MODE="on"
				shift 1
			fi
			;;
		--cc)
			[[ $# -ge 2 ]] || _die "--cc requires a PATH"
			CC_BIN="$2"
			shift 2
			;;
		--cxx)
			[[ $# -ge 2 ]] || _die "--cxx requires a PATH"
			CXX_BIN="$2"
			shift 2
			;;
		--jobs)
			[[ $# -ge 2 ]] || _die "--jobs requires N"
			JOBS="$2"
			shift 2
			;;
		--cmake-extra)
			[[ $# -ge 2 ]] || _die "--cmake-extra requires a STRING"
			CMAKE_EXTRA="$2"
			shift 2
			;;
		*)
			_die "Unknown argument: $1 (try --help)"
			;;
		esac
	done
}

# ----------------------------- build logic -----------------------------------

function _apply_preset() {
	case "$PRESET" in
	safe)
		PROJECTS="$PROJECTS_SAFE"
		RUNTIMES="$RUNTIMES_SAFE"
		;;
	max)
		PROJECTS="$PROJECTS_MAX"
		RUNTIMES="$RUNTIMES_MAX"
		;;
	*)
		_die "Unknown preset: ${PRESET} (expected: safe|max)"
		;;
	esac
}

function _require_tools() {
	local missing="0"
	for t in git cmake; do
		if ! _have "$t"; then
			_log "Missing required tool: ${t}"
			missing="1"
		fi
	done

	if ! (_have ninja || _have ninja-build); then
		_log "Missing required tool: ninja (or ninja-build)"
		missing="1"
	fi

	if [[ "$missing" == "1" ]]; then
		_die "Install missing tools and re-run."
	fi
}

function _ensure_jobs() {
	if [[ -n "$JOBS" ]]; then
		return 0
	fi
	if _have nproc; then
		JOBS="$(nproc)"
	else
		JOBS="4"
	fi
}

function _paths() {
	SRC_DIR="${ROOT}/src/llvm-project"
	BUILD_DIR="${ROOT}/build"
	INSTALL_DIR="${ROOT}/install"
}

function _clone_or_update() {
	mkdir -p "${ROOT}/src"

	if [[ -d "${SRC_DIR}/.git" ]]; then
		_log "Source repo exists: ${SRC_DIR}"
		if [[ "$NO_UPDATE" == "1" ]]; then
			_log "Skipping update (--no-update)."
		else
			_log "Updating repo (fetch + checkout ${REF})."
			git -C "$SRC_DIR" fetch --all --tags --prune
		fi
	else
		_log "Cloning llvm-project into: ${SRC_DIR}"
		git clone --filter=blob:none --no-checkout \
			https://github.com/llvm/llvm-project.git "$SRC_DIR"
		git -C "$SRC_DIR" fetch --all --tags --prune
	fi

	_log "Checking out: ${REF}"
	git -C "$SRC_DIR" checkout -f "$REF"

	if [[ "$NO_UPDATE" != "1" ]]; then
		# Pull if we're on a branch.
		if git -C "$SRC_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
			git -C "$SRC_DIR" pull --ff-only || true
		fi
	fi
}

function _clean_build_dir() {
	if [[ "$CLEAN" == "1" ]]; then
		_log "Removing build dir: ${BUILD_DIR}"
		rm -rf -- "$BUILD_DIR"
	fi
	mkdir -p "$BUILD_DIR"
	mkdir -p "$INSTALL_DIR"
}

function _resolve_ninja() {
	if _have ninja; then
		NINJA_BIN="ninja"
		return 0
	fi
	if _have ninja-build; then
		NINJA_BIN="ninja-build"
		return 0
	fi
	_die "ninja not found (expected ninja or ninja-build)."
}

function _configure() {
	local cc cxx
	_resolve_ninja

	cc="${CC_BIN:-}"
	cxx="${CXX_BIN:-}"

	if [[ -z "$cc" ]]; then
		if _have cc; then cc="cc"; else _die "No C compiler found (cc)."; fi
	fi
	if [[ -z "$cxx" ]]; then
		if _have c++; then cxx="c++"; else _die "No C++ compiler found (c++)."; fi
	fi

	_log "Configuring LLVM with:"
	_log "  ROOT:      ${ROOT}"
	_log "  REF:       ${REF}"
	_log "  BUILD:     ${BUILD_TYPE}"
	_log "  PROJECTS:  ${PROJECTS}"
	_log "  RUNTIMES:  ${RUNTIMES}"
	_log "  TARGETS:   ${TARGETS}"
	_log "  JOBS:      ${JOBS}"

	local -a cmake_args
	cmake_args=(
		"-S" "${SRC_DIR}/llvm"
		"-B" "$BUILD_DIR"
		"-G" "Ninja"
		"-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
		"-DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}"
		"-DCMAKE_C_COMPILER=${cc}"
		"-DCMAKE_CXX_COMPILER=${cxx}"
		"-DLLVM_ENABLE_PROJECTS=${PROJECTS}"
		"-DLLVM_ENABLE_RUNTIMES=${RUNTIMES}"
		"-DLLVM_TARGETS_TO_BUILD=${TARGETS}"
		"-DLLVM_ENABLE_TERMINFO=ON"
		"-DLLVM_ENABLE_ZLIB=ON"
	)

	case "$USE_LLD_MODE" in
	auto)
		# Do nothing; CMake may still pick up lld later if you set it explicitly.
		;;
	on)
		cmake_args+=("-DLLVM_USE_LINKER=lld")
		;;
	off) ;;
	*)
		_die "--use-lld must be auto|on|off (got: ${USE_LLD_MODE})"
		;;
	esac

	if [[ -n "$CMAKE_EXTRA" ]]; then
		# Split CMAKE_EXTRA into separate arguments so multiple -D flags are passed
		# correctly to CMake. Uses `read -r -a` to split on IFS safely.
		local -a extra_args
		local IFS=$' \t\n'
		read -r -a extra_args <<<"$CMAKE_EXTRA"
		cmake_args+=("${extra_args[@]}")
	fi

	# If we resolved a ninja binary, explicitly tell CMake to use it. This ensures
	# CMake picks the same ninja implementation detected earlier (ninja vs ninja-build).
	if [[ -n "${NINJA_BIN:-}" ]]; then
		cmake_args+=("-DCMAKE_MAKE_PROGRAM=${NINJA_BIN}")
	fi

	_log "Running CMake configure..."
	cmake "${cmake_args[@]}"
}

function _build() {
	_log "Building..."
	cmake --build "$BUILD_DIR" -- -j "$JOBS"
}

function _install() {
	_log "Installing to: ${INSTALL_DIR}"
	cmake --install "$BUILD_DIR"
}

function _write_env_helper() {
	local libdir
	if [[ -d "${INSTALL_DIR}/lib" ]]; then
		libdir="${INSTALL_DIR}/lib"
	elif [[ -d "${INSTALL_DIR}/lib64" ]]; then
		libdir="${INSTALL_DIR}/lib64"
	else
		libdir=""
	fi

	_log "Writing env helper: ${INSTALL_DIR}/enable-llvm-env.sh"
	cat >"${INSTALL_DIR}/enable-llvm-env.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated by build-llvm.sh
set -euo pipefail

export LLVM_HOME="${INSTALL_DIR}"
export PATH="\${LLVM_HOME}/bin:\${PATH}"
EOF

	if [[ -n "$libdir" ]]; then
		cat >>"${INSTALL_DIR}/enable-llvm-env.sh" <<EOF
export LD_LIBRARY_PATH="${libdir}:\${LD_LIBRARY_PATH:-}"
EOF
	fi

	chmod 0755 "${INSTALL_DIR}/enable-llvm-env.sh"
}

function main() {
	_parse_args "$@"

	_paths
	_require_tools
	_ensure_jobs

	# Apply preset only if the user did not explicitly override lists.
	# Heuristic: if PROJECTS/RUNTIMES still equal SAFE defaults and preset != safe.
	if [[ "$PRESET" != "safe" ]]; then
		if [[ "$PROJECTS" == "$PROJECTS_SAFE" ]] &&
			[[ "$RUNTIMES" == "$RUNTIMES_SAFE" ]]; then
			_apply_preset
		fi
	fi

	mkdir -p "$ROOT"

	_clone_or_update
	_clean_build_dir
	_configure
	_build
	_install
	_write_env_helper

	_log "Done."
	_log "Next:"
	_log "  source \"${INSTALL_DIR}/enable-llvm-env.sh\""
	_log "  clang --version"
}

main "$@"
