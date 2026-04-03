#!/usr/bin/env bash
# grub-tune.sh — Tweak GRUB menu behaviour and readability reproducibly.
#
# Features:
#   - Set visible timeout and menu style.
#   - Enable "saved" default so GRUB boots the last used entry.
#   - Set graphics mode (resolution) and keep it for the kernel.
#   - Optionally generate a larger GRUB font and use it.
#   - Regenerate grub.cfg (Arch-style path).
#
# Exit codes:
#   0  success
#   1  usage / input error
#   2  missing dependency
#   3  runtime failure

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
GRUB_DEFAULT_CFG="/etc/default/grub"
GRUB_OUT_CFG="/boot/grub/grub.cfg"

# ────────────────────────────── Helpers ────────────────────────────────

function die() {
	printf '%s: %s\n' "$SCRIPT_NAME" "${1:-unknown error}" >&2
	exit "${2:-1}"
}

function ensure_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		die "Must be run as root (try: sudo $SCRIPT_NAME)" 1
	fi
}

function ensure_file() {
	local file="$1"
	[[ -f "$file" ]] || die "Config file not found: $file" 3
}

function backup_file() {
	local file="$1"
	ensure_file "$file"
	local ts backup
	ts="$(date +%Y%m%d_%H%M%S)"
	backup="${file}.${ts}.bak"
	cp -a -- "$file" "$backup"
	printf 'Backup written: %s\n' "$backup"
}

# Set KEY="VALUE" in /etc/default/grub:
#  - If an uncommented KEY= line exists, replace it.
#  - Otherwise, append at the end.
function set_grub_kv() {
	local key="$1"
	local value="$2"
	local file="$3"

	ensure_file "$file"

	if grep -qE "^${key}=" "$file"; then
		sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
	else
		printf '%s="%s"\n' "$key" "$value" >>"$file"
	fi
}

# Resolve pager for help text using HELP_PAGER, helpout, batwrap, bat, less,
# then cat as a last resort.
function resolve_pager() {
	local pager

	if [[ -n "${HELP_PAGER:-}" ]]; then
		# Use first word of HELP_PAGER to test existence.
		local cmd="${HELP_PAGER%% *}"
		if command -v "$cmd" >/dev/null 2>&1; then
			pager="$HELP_PAGER"
		fi
	fi

	if [[ -z "${pager:-}" ]] && command -v helpout >/dev/null 2>&1; then
		pager="helpout"
	fi

	if [[ -z "${pager:-}" ]] && command -v batwrap >/dev/null 2>&1; then
		pager="batwrap"
	fi

	if [[ -z "${pager:-}" ]] && command -v bat >/dev/null 2>&1; then
		pager="bat --style='grid,header,snip' \
      --italic-text='always' \
      --theme='gruvbox-dark' \
      --squeeze-blank \
      --squeeze-limit='2' \
      --force-colorization \
      --terminal-width='auto' \
      --tabs='2' \
      --paging='never' \
      --chop-long-lines"
	fi

	if [[ -z "${pager:-}" ]] && command -v less >/dev/null 2>&1; then
		pager="less -R"
	fi

	if [[ -z "${pager:-}" ]]; then
		pager="cat"
	fi

	printf '%s\n' "$pager"
}

function show_help() {
	local pager
	pager="$(resolve_pager)"

	cat <<'EOF' | eval "$pager"
# grub-tune.sh — Tune GRUB menu defaults and readability

Usage:
  sudo grub-tune.sh [OPTIONS]

Options:
  -t, --timeout SECONDS
      Set GRUB menu timeout (in seconds).
      Also forces a visible menu (`GRUB_TIMEOUT_STYLE=menu`).

  -r, --resolution MODE
      Set graphics mode for GRUB menu, e.g.:
        --resolution 1920x1080
        --resolution 1920x1080,auto
      This sets GRUB_GFXMODE and GRUB_GFXPAYLOAD_LINUX=keep.

  -s, --saved-default
      Use "saved" default entry:
        GRUB_DEFAULT=saved
        GRUB_SAVEDEFAULT=true
      GRUB will boot the entry you last selected.

  -F, --font-size PX
      Generate a larger GRUB font using DejaVu Sans Mono
      (requires grub-mkfont and ttf-dejavu) and set GRUB_FONT.
      Example: --font-size 32

  --no-mkconfig
      Do NOT run grub-mkconfig automatically. You will have to run:
        grub-mkconfig -o /boot/grub/grub.cfg
      yourself afterwards.

  -h, --help
      Show this help.

Notes / behaviour:
  * The script backs up /etc/default/grub before modifying it.
  * It only touches keys you explicitly configure via options.
  * By default it regenerates /boot/grub/grub.cfg (Arch-style path).

Examples:
  # 10s timeout, visible menu, remember last-selected entry
  sudo grub-tune.sh -t 10 -s

  # 10s timeout, high-res menu, keep graphics in kernel payload
  sudo grub-tune.sh -t 10 -r 1920x1080,auto -s

  # As above, but also make the font bigger (32 px)
  sudo grub-tune.sh -t 10 -r 1920x1080,auto -s -F 32

EOF
}

# ────────────────────────────── Main logic ─────────────────────────────

function main() {
	ensure_root

	local timeout=""
	local gfxmode=""
	local font_size=""
	local use_saved_default=false
	local run_mkconfig=true
	local changed=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-t | --timeout)
			[[ $# -ge 2 ]] || die "Missing argument for $1" 1
			timeout="$2"
			shift 2
			;;
		-r | --resolution)
			[[ $# -ge 2 ]] || die "Missing argument for $1" 1
			gfxmode="$2"
			shift 2
			;;
		-s | --saved-default)
			use_saved_default=true
			shift
			;;
		-F | --font-size)
			[[ $# -ge 2 ]] || die "Missing argument for $1" 1
			font_size="$2"
			shift 2
			;;
		--no-mkconfig)
			run_mkconfig=false
			shift
			;;
		-h | --help)
			show_help
			exit 0
			;;
		*)
			die "Unknown argument: $1" 1
			;;
		esac
	done

	if [[ -z "$timeout" && -z "$gfxmode" && -z "$font_size" &&
		"$use_saved_default" = false ]]; then
		die "No changes requested. Use --help for usage." 1
	fi

	backup_file "$GRUB_DEFAULT_CFG"

	if [[ -n "$timeout" ]]; then
		if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
			die "Timeout must be an integer number of seconds." 1
		fi
		set_grub_kv "GRUB_TIMEOUT_STYLE" "menu" "$GRUB_DEFAULT_CFG"
		set_grub_kv "GRUB_TIMEOUT" "$timeout" "$GRUB_DEFAULT_CFG"
		printf 'Set GRUB_TIMEOUT_STYLE=menu and GRUB_TIMEOUT=%s\n' "$timeout"
		changed=true
	fi

	if [[ -n "$gfxmode" ]]; then
		set_grub_kv "GRUB_GFXMODE" "$gfxmode" "$GRUB_DEFAULT_CFG"
		set_grub_kv "GRUB_GFXPAYLOAD_LINUX" "keep" "$GRUB_DEFAULT_CFG"
		printf 'Set GRUB_GFXMODE=%s and GRUB_GFXPAYLOAD_LINUX=keep\n' \
			"$gfxmode"
		changed=true
	fi

	if [[ "$use_saved_default" = true ]]; then
		set_grub_kv "GRUB_DEFAULT" "saved" "$GRUB_DEFAULT_CFG"
		set_grub_kv "GRUB_SAVEDEFAULT" "true" "$GRUB_DEFAULT_CFG"
		printf 'Enabled saved default (GRUB_DEFAULT=saved, GRUB_SAVEDEFAULT=true)\n'
		changed=true
	fi

	if [[ -n "$font_size" ]]; then
		command -v grub-mkfont >/dev/null 2>&1 ||
			die "grub-mkfont not found (install grub package)." 2

		local font_src="/usr/share/fonts/TTF/DejaVuSansMono.ttf"
		local font_out="/boot/grub/dejavu-mono-${font_size}.pf2"

		[[ -r "$font_src" ]] ||
			die "Font file not found: $font_src (install ttf-dejavu)." 2

		printf 'Generating GRUB font at size %s...\n' "$font_size"
		grub-mkfont -s "$font_size" -o "$font_out" "$font_src" ||
			die "grub-mkfont failed." 3

		set_grub_kv "GRUB_FONT" "$font_out" "$GRUB_DEFAULT_CFG"
		printf 'Set GRUB_FONT=%s\n' "$font_out"
		changed=true
	fi

	if [[ "$changed" = false ]]; then
		printf 'Nothing changed in %s\n' "$GRUB_DEFAULT_CFG"
		exit 0
	fi

	if [[ "$run_mkconfig" = true ]]; then
		command -v grub-mkconfig >/dev/null 2>&1 ||
			die "grub-mkconfig not found (install grub package)." 2

		printf 'Regenerating GRUB config: %s\n' "$GRUB_OUT_CFG"
		grub-mkconfig -o "$GRUB_OUT_CFG" ||
			die "grub-mkconfig failed." 3

		printf 'Done. New GRUB config written to %s\n' "$GRUB_OUT_CFG"
	else
		printf 'Config updated. Remember to run:\n'
		printf '  grub-mkconfig -o %s\n' "$GRUB_OUT_CFG"
	fi
}

main "$@"
