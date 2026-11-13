#!/usr/bin/env bash
# block-ads — DBus notification filter for ad/push spam (Wayland/Hyprland).
# Dismisses notifications whose payload matches given keywords (case-insensitive).
#
# Dependencies: dbus-monitor (dbus), and either swaync-client or makoctl.
# Optional: logger (util-linux) for syslog logging.
#
# Exit codes:
#   0  normal exit
#   1  usage error / missing dependency

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.5.0"

print_help() {
	cat <<'EOF'
		Usage:
		block-ads [--keywords "<csv>"] [--quiet] [--log <file>] [--dnd] [--version] [-h|--help]

		Description:
		Watches org.freedesktop.Notifications on DBus and auto-dismisses any
		notifications whose raw payload contains one of the keywords
		(case-insensitive match). Works with swaync or mako.

		Options:
		--keywords "<csv>"   Comma-separated keywords to block.
		Default: iplocation,taboola
		--quiet              Suppress stdout diagnostics.
		--log <file>         Append minimal events to <file>. If "-", log to syslog (logger).
		--dnd                Enable Do-Not-Disturb at startup (swaync or mako), then keep filtering.
		--version            Print version and exit.
		-h, --help           Show this help and exit.

		Examples:
		block-ads
		block-ads --keywords "iplocation,taboola,ad.doubleclick"
		block-ads --log ~/.local/state/block-ads.log
		block-ads --dnd --quiet

		Notes:
		• Add to Hyprland:   exec-once = block-ads
		• Or as user systemd service (recommended for reliability).
		EOF
}

log() {
	[[ "${QUIET}" == "1" ]] && return 0
		if [[ -n "${LOG_FILE:-}" ]]; then
			if [[ "${LOG_FILE}" == "-" ]]; then
				command -v logger >/dev/null 2>&1 && logger -t block-ads -- "$*" || true
			else
				printf '[%(%F %T)T] %s\n' -1 "$*" >> "${LOG_FILE}"
					fi
		else
			printf '[block-ads] %s\n' "$*"
				fi
}

# ─────────────────────────────── Args ───────────────────────────────
KEYWORDS_CSV="iplocation,taboola"
QUIET="0"
LOG_FILE=""
ENABLE_DND="0"

while (($#)); do
case "$1" in
--keywords) KEYWORDS_CSV="${2:-}"; shift 2 ;;
--quiet)    QUIET="1"; shift ;;
--log)      LOG_FILE="${2:-}"; shift 2 ;;
--dnd)      ENABLE_DND="1"; shift ;;
--version)  echo "${VERSION}"; exit 0 ;;
-h|--help)  print_help; exit 0 ;;
*) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
esac
done

# ─────────────────────────── Dependencies ───────────────────────────
need() { command -v "$1" >/dev/null 2>&1; }

if ! need dbus-monitor; then
echo "Error: dbus-monitor not found (install 'dbus')." >&2
exit 1
fi

DISMISS_TOOL=""
if need swaync-client; then
DISMISS_TOOL="swaync"
elif need makoctl; then
DISMISS_TOOL="mako"
else
echo "Error: neither 'swaync-client' nor 'makoctl' found." >&2
exit 1
fi

# ─────────────────────────── Preparation ────────────────────────────
IFS=',' read -r -a KEYWORDS <<<"${KEYWORDS_CSV}"
for i in "${!KEYWORDS[@]}"; do
# normalize/trim + lower
k="${KEYWORDS[$i]}"
k="${k#"${k%%[![:space:]]*}"}"
k="${k%"${k##*[![:space:]]}"}"
KEYWORDS[$i]="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
done

dismiss_all() {
	case "${DISMISS_TOOL}" in
		swaync) swaync-client -d all >/dev/null 2>&1 || true ;;
		mako)   makoctl dismiss -a  >/dev/null 2>&1 || true ;;
		esac
}

set_dnd() {
	case "${DISMISS_TOOL}" in
		swaync) swaync-client -dn enable >/dev/null 2>&1 || true ;;
		mako)   makoctl set-mode do-not-disturb >/dev/null 2>&1 || true ;;
		esac
}

trap 'log "Exiting"; exit 0' INT TERM

[[ "${ENABLE_DND}" == "1" ]] && { log "Enabling DND"; set_dnd; }

log "Watching DBus notifications via ${DISMISS_TOOL}; keywords: ${KEYWORDS_CSV}"

# ───────────────────────────── Main loop ────────────────────────────
# We scan the raw stream for matches to reduce latency; the daemon is
# freedesktop-compliant so payload includes app_name, summary, and body.
dbus-monitor "interface='org.freedesktop.Notifications'" |
while IFS= read -r line; do
lower_line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
for kw in "${KEYWORDS[@]}"; do
if [[ "$lower_line" == *"$kw"* ]]; then
log "Match: '$kw' → dismissing"
dismiss_all
break
fi
done
done

