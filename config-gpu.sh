#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -------------------------------------------------------------------------------------------------
# detect_gpu_env
# Purpose:
#   Detect GPU + CPU environment and write a Hyprland-friendly env block into a config file.
#
# Defaults:
#   Config file : ~/.config/hypr/UserConfigs/ENVariables.conf
#   Backup dir  : ~/.local/state/detect_gpu_env/backups/
#
# Notes:
#   - Only the block between markers is managed. Everything else remains untouched.
#   - PRIME offload variables are opt-in (--enable-prime-offload) because global offload is risky.
#   - LIBVA_DRIVER_NAME is only set by default on single-GPU systems (or with --force-libva).
# -------------------------------------------------------------------------------------------------

SCRIPT_NAME="detect_gpu_env"

MARK_START="# GPU-SPECIFIC CONFIG START"
MARK_END="# GPU-SPECIFIC CONFIG END"

VERBOSE=1
DO_APPLY=1
DO_DRY_RUN=0

ENABLE_PRIME_OFFLOAD=0
ENABLE_NVIDIA_CURSOR_WORKAROUND=0
FORCE_LIBVA=0

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

CONFIG_FILE_DEFAULT="${TARGET_HOME}/.config/hypr/UserConfigs/ENVariables.conf"
STATE_DIR_DEFAULT="${TARGET_HOME}/.local/state/${SCRIPT_NAME}"
BACKUP_DIR_DEFAULT="${STATE_DIR_DEFAULT}/backups"

CONFIG_FILE="$CONFIG_FILE_DEFAULT"
BACKUP_DIR="$BACKUP_DIR_DEFAULT"

# -------------------------------------------------------------------------------------------------
# Logging helpers
# -------------------------------------------------------------------------------------------------
function die() {
	printf '[ERROR] %s\n' "$*" >&2
	exit 1
}

function info() {
	if [[ "$VERBOSE" -ge 1 ]]; then
		printf '[INFO] %s\n' "$*"
	fi
}

function debug() {
	if [[ "$VERBOSE" -ge 2 ]]; then
		printf '[DEBUG] %s\n' "$*"
	fi
}

function have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# -------------------------------------------------------------------------------------------------
# Help (portable pager via HELP_PAGER)
# -------------------------------------------------------------------------------------------------
function show_help() {
	local pager="${HELP_PAGER:-less -R}"
	if ! have_cmd less; then
		pager="cat"
	fi

	cat <<'EOF' | eval "${pager}"
# detect_gpu_env

Detects GPU/CPU and writes a Hyprland `env = KEY,VALUE` block into a config file.

## Usage
  detect_gpu_env [options]

## Options
  -c, --config FILE            Target config file
  -b, --backup-dir DIR         Backup directory (timestamped backups)
  -n, --dry-run                Do not modify files; print what would be written
  -q, --quiet                  Less output
  -v, --verbose                More output (use twice for debug)
      --no-apply               Do not write; only print detected info + generated block
      --enable-prime-offload   Add NVIDIA PRIME offload env vars (only meaningful on hybrids)
      --nvidia-cursor-fix      Add WLR_NO_HARDWARE_CURSORS=1 for NVIDIA (opt-in workaround)
      --force-libva            Force LIBVA_DRIVER_NAME even on multi-GPU systems
  -h, --help                   Show this help

## Files
  Default config:
    ~/.config/hypr/UserConfigs/ENVariables.conf

  Default backups:
    ~/.local/state/detect_gpu_env/backups/
EOF
}

# -------------------------------------------------------------------------------------------------
# Argument parsing
# -------------------------------------------------------------------------------------------------
function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-c | --config)
			CONFIG_FILE="$2"
			shift 2
			;;
		-b | --backup-dir)
			BACKUP_DIR="$2"
			shift 2
			;;
		-n | --dry-run)
			DO_DRY_RUN=1
			shift
			;;
		--no-apply)
			DO_APPLY=0
			shift
			;;
		--enable-prime-offload)
			ENABLE_PRIME_OFFLOAD=1
			shift
			;;
		--nvidia-cursor-fix)
			ENABLE_NVIDIA_CURSOR_WORKAROUND=1
			shift
			;;
		--force-libva)
			FORCE_LIBVA=1
			shift
			;;
		-q | --quiet)
			VERBOSE=0
			shift
			;;
		-v | --verbose)
			VERBOSE=$((VERBOSE + 1))
			shift
			;;
		-h | --help)
			show_help
			exit 0
			;;
		*)
			die "Unknown argument: $1 (try --help)"
			;;
		esac
	done
}

# -------------------------------------------------------------------------------------------------
# CPU detection (microcode hint only)
# -------------------------------------------------------------------------------------------------
function detect_cpu_vendor() {
	local vendor="unknown"

	if have_cmd lscpu; then
		vendor="$(lscpu | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
	else
		vendor="$(awk -F: '/vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo ||
			true)"
	fi

	case "$vendor" in
	GenuineIntel) echo "intel" ;;
	AuthenticAMD) echo "amd" ;;
	*) echo "unknown" ;;
	esac
}

# -------------------------------------------------------------------------------------------------
# GPU detection
#   We parse lspci -Dnnk blocks for VGA/3D/Display controllers.
# -------------------------------------------------------------------------------------------------
function get_gpu_blocks() {
	lspci -Dnnk |
		awk '
      BEGIN { RS=""; FS="\n" }
      /VGA compatible controller|3D controller|Display controller/ { print $0 "\n" }
    '
}

function classify_gpu_block() {
	local block="$1"
	local first_line driver vendor

	first_line="$(printf '%s\n' "$block" | sed -n '1p')"
	driver="$(printf '%s\n' "$block" | awk -F': ' '/Kernel driver in use:/ {print $2; exit}')"

	vendor="unknown"
	if printf '%s' "$first_line" | grep -qi 'nvidia'; then
		vendor="nvidia"
	elif printf '%s' "$first_line" | grep -Eqi 'advanced micro devices|amd/ati|(\<ati\>)'; then
		vendor="amd"
	elif printf '%s' "$first_line" | grep -qi 'intel'; then
		vendor="intel"
	fi

	printf '%s|%s|%s\n' "$first_line" "$vendor" "${driver:-unknown}"
}

function file_exists_any() {
	local p
	for p in "$@"; do
		if [[ -e "$p" ]]; then
			return 0
		fi
	done
	return 1
}

# -------------------------------------------------------------------------------------------------
# Config block generation
# -------------------------------------------------------------------------------------------------
function build_hypr_env_block() {
	local gpu_summary="$1"
	local cpu_vendor="$2"
	local is_multi_gpu="$3"

	local lines=()
	local now
	now="$(date -Is)"

	# GPU-related env is conservative by default.
	# We only set LIBVA_DRIVER_NAME by default on single-GPU systems (or with --force-libva).
	local allow_libva=0
	if [[ "$FORCE_LIBVA" -eq 1 || "$is_multi_gpu" -eq 0 ]]; then
		allow_libva=1
	fi

	# Detect presence flags (from summary string)
	local has_nvidia=0 has_amd=0 has_intel=0
	local has_nvidia_proprietary=0

	if printf '%s' "$gpu_summary" | grep -q 'vendor=nvidia'; then
		has_nvidia=1
	fi
	if printf '%s' "$gpu_summary" | grep -q 'vendor=amd'; then
		has_amd=1
	fi
	if printf '%s' "$gpu_summary" | grep -q 'vendor=intel'; then
		has_intel=1
	fi
	if printf '%s' "$gpu_summary" | grep -q 'vendor=nvidia.*driver=nvidia'; then
		has_nvidia_proprietary=1
	fi

	# NVIDIA (proprietary)
	if [[ "$has_nvidia_proprietary" -eq 1 ]]; then
		lines+=("env = __GLX_VENDOR_LIBRARY_NAME,nvidia")

		# Common Hyprland/wlroots workaround for NVIDIA cursor glitches (opt-in).
		if [[ "$ENABLE_NVIDIA_CURSOR_WORKAROUND" -eq 1 ]]; then
			lines+=("env = WLR_NO_HARDWARE_CURSORS,1")
		fi

		# GBM backend for NVIDIA (only set if a matching backend is likely present).
		if file_exists_any \
			/usr/lib/gbm/nvidia-drm_gbm.so \
			/usr/lib64/gbm/nvidia-drm_gbm.so \
			/usr/lib/gbm/libgbm_nvidia.so \
			/usr/lib64/gbm/libgbm_nvidia.so; then
			lines+=("env = GBM_BACKEND,nvidia-drm")
		else
			debug "No obvious NVIDIA GBM backend file found; skipping GBM_BACKEND."
		fi

		# VA-API on NVIDIA typically requires an extra driver; only set if it exists and allowed.
		if [[ "$allow_libva" -eq 1 ]] && file_exists_any \
			/usr/lib/dri/nvidia_drv_video.so \
			/usr/lib64/dri/nvidia_drv_video.so; then
			lines+=("env = LIBVA_DRIVER_NAME,nvidia")
		fi

		# PRIME offload: opt-in only, and only meaningful if there is also a non-NVIDIA GPU.
		if [[ "$ENABLE_PRIME_OFFLOAD" -eq 1 ]] &&
			([[ "$has_intel" -eq 1 ]] || [[ "$has_amd" -eq 1 ]]); then
			lines+=("env = __NV_PRIME_RENDER_OFFLOAD,1")
			lines+=("env = __VK_LAYER_NV_optimus,NVIDIA_only")
		fi
	fi

	# AMD (amdgpu/radeon)
	if [[ "$has_amd" -eq 1 ]]; then
		if [[ "$allow_libva" -eq 1 ]] && file_exists_any \
			/usr/lib/dri/radeonsi_drv_video.so \
			/usr/lib64/dri/radeonsi_drv_video.so; then
			lines+=("env = LIBVA_DRIVER_NAME,radeonsi")
		elif [[ "$allow_libva" -eq 1 ]] && file_exists_any \
			/usr/lib/dri/r600_drv_video.so \
			/usr/lib64/dri/r600_drv_video.so; then
			lines+=("env = LIBVA_DRIVER_NAME,r600")
		fi
	fi

	# Intel (i915)
	if [[ "$has_intel" -eq 1 ]]; then
		if [[ "$allow_libva" -eq 1 ]] && file_exists_any \
			/usr/lib/dri/iHD_drv_video.so \
			/usr/lib64/dri/iHD_drv_video.so; then
			lines+=("env = LIBVA_DRIVER_NAME,iHD")
		elif [[ "$allow_libva" -eq 1 ]] && file_exists_any \
			/usr/lib/dri/i965_drv_video.so \
			/usr/lib64/dri/i965_drv_video.so; then
			lines+=("env = LIBVA_DRIVER_NAME,i965")
		fi
	fi

	# Compose final block
	{
		printf '\n%s\n' "$MARK_START"
		printf '# Generated by %s on %s\n' "$SCRIPT_NAME" "$now"
		printf '# Target user: %s\n' "$TARGET_USER"
		printf '# CPU vendor : %s (microcode: %s)\n' \
			"$cpu_vendor" \
			"$(case "$cpu_vendor" in intel) echo "intel-ucode" ;; amd) echo "amd-ucode" ;; *) echo "unknown" ;; esac)"
		printf '# GPU(s)     : %s\n' "$gpu_summary"
		printf '# Notes      : PRIME offload=%s | cursor-fix=%s | libva=%s\n' \
			"$ENABLE_PRIME_OFFLOAD" \
			"$ENABLE_NVIDIA_CURSOR_WORKAROUND" \
			"$(if [[ "$allow_libva" -eq 1 ]]; then echo "on"; else echo "auto-off (multi-GPU)"; fi)"

		if [[ "${#lines[@]}" -eq 0 ]]; then
			printf '# No GPU-specific env lines were set (by design or no matching drivers).\n'
		else
			printf '%s\n' "${lines[@]}"
		fi

		printf '%s\n' "$MARK_END"
	}
}

# -------------------------------------------------------------------------------------------------
# File update: remove old managed block, then append new one (atomic write + external backups)
# -------------------------------------------------------------------------------------------------
function ensure_parent_dirs() {
	mkdir -p "$(dirname "$CONFIG_FILE")"
	mkdir -p "$BACKUP_DIR"
}

function backup_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		local ts backup_path
		ts="$(date +%Y%m%d_%H%M%S)"
		backup_path="${BACKUP_DIR}/$(basename "$CONFIG_FILE").${ts}.bak"
		cp -a -- "$CONFIG_FILE" "$backup_path"
		info "Backup created: ${backup_path}"
	else
		info "Config file does not exist yet; no backup needed."
	fi
}

function strip_managed_block() {
	local in_file="$1"
	local out_file="$2"

	if [[ ! -f "$in_file" ]]; then
		: >"$out_file"
		return 0
	fi

	awk -v start="$MARK_START" -v end="$MARK_END" '
    $0 == start { skip=1; next }
    $0 == end   { skip=0; next }
    skip != 1   { print }
  ' "$in_file" >"$out_file"
}

function apply_block_to_config() {
	local block="$1"
	local tmp stripped mode

	tmp="$(mktemp)"
	stripped="$(mktemp)"
	trap 'rm -f "${tmp}" "${stripped}"' EXIT

	mode="644"
	if [[ -f "$CONFIG_FILE" ]]; then
		mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 644)"
	fi

	strip_managed_block "$CONFIG_FILE" "$stripped"

	{
		cat "$stripped"
		printf '%s\n' "$block"
	} >"$tmp"

	chmod "$mode" "$tmp"

	if [[ "$DO_DRY_RUN" -eq 1 || "$DO_APPLY" -eq 0 ]]; then
		info "Not writing to disk (--dry-run/--no-apply)."
	else
		mv -f -- "$tmp" "$CONFIG_FILE"
		info "Updated: ${CONFIG_FILE}"
	fi

	trap - EXIT
	rm -f "$stripped" || true
}

# -------------------------------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------------------------------
function main() {
	parse_args "$@"

	have_cmd lspci || die "Missing lspci (install: pciutils)."

	info "Running as: $(id -un) | Target user: ${TARGET_USER}"
	info "Config file: ${CONFIG_FILE}"
	info "Backup dir : ${BACKUP_DIR}"

	local cpu_vendor
	cpu_vendor="$(detect_cpu_vendor)"
	info "CPU vendor detected: ${cpu_vendor}"
	case "$cpu_vendor" in
	intel) info "Arch microcode package should be: intel-ucode" ;;
	amd) info "Arch microcode package should be: amd-ucode" ;;
	*) info "Microcode package could not be inferred (unknown vendor)." ;;
	esac

	local blocks
	blocks="$(get_gpu_blocks || true)"
	[[ -n "$blocks" ]] || die "No VGA/3D/Display controller found in lspci output."

	info "Detected GPU block(s) from lspci -Dnnk:"
	if [[ "$VERBOSE" -ge 2 ]]; then
		printf '%s\n' "$blocks"
	fi

	local gpu_lines=()
	local vendors=()
	local count=0

	while IFS= read -r block; do
		[[ -n "$block" ]] || continue
		local classified first_line vendor driver

		classified="$(classify_gpu_block "$block")"
		first_line="${classified%%|*}"
		vendor="$(printf '%s' "$classified" | cut -d'|' -f2)"
		driver="$(printf '%s' "$classified" | cut -d'|' -f3)"

		gpu_lines+=("${first_line} | vendor=${vendor} | driver=${driver}")
		vendors+=("$vendor")
		count=$((count + 1))
	done < <(printf '%s\n' "$blocks" | awk 'BEGIN{RS=""; ORS="\n\n"} {print}')

	local gpu_summary
	gpu_summary="$(printf '%s ; ' "${gpu_lines[@]}" | sed 's/ ; $//')"

	local unique_vendors
	unique_vendors="$(printf '%s\n' "${vendors[@]}" | sort -u | wc -l | awk '{print $1}')"

	local is_multi_gpu=0
	if [[ "$count" -gt 1 || "$unique_vendors" -gt 1 ]]; then
		is_multi_gpu=1
	fi

	info "GPU summary:"
	printf '%s\n' "${gpu_lines[@]}"

	info "Multi-GPU: $(if [[ "$is_multi_gpu" -eq 1 ]]; then echo "yes"; else echo "no"; fi)"

	local block
	block="$(build_hypr_env_block "$gpu_summary" "$cpu_vendor" "$is_multi_gpu")"

	info "Generated Hyprland block:"
	printf '%s\n' "$block"

	ensure_parent_dirs
	if [[ "$DO_DRY_RUN" -eq 0 && "$DO_APPLY" -eq 1 ]]; then
		backup_config
	fi

	apply_block_to_config "$block"

	info "Done."
}

main "$@"
