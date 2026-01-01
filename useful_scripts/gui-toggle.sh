#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# gui-toggle
#
# Toggle “GUI vs TTY-only” boot behavior on systemd-based Linux (e.g. Arch).
#
# Primary use-case:
#   - Boot into a safe TTY-only environment to troubleshoot Hyprland/Wayland/DM
#     problems, without accidentally dropping into the GUI.
#
# What this manipulates:
#   - systemd default target: graphical.target <-> multi-user.target
#   - the active Display Manager (DM) service (sddm/gdm/greetd/lightdm/ly/...)
#
# Safety notes:
#   - By default, this does NOT tear down your current GUI session. It changes
#     what happens on NEXT boot (and enables/disables the DM accordingly).
#   - If you use --now, it will stop/start the DM immediately (best run from a
#     TTY to avoid surprising yourself).
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ------------------------------ Constants ------------------------------------

STATE_DIR="/var/lib/gui-toggle"
STATE_FILE="${STATE_DIR}/state"
ONCE_UNIT="/etc/systemd/system/gui-toggle-restore.service"

# DM unit candidates (common on Arch + friends)
DM_CANDIDATES=(
	"display-manager.service"
	"sddm.service"
	"gdm.service"
	"greetd.service"
	"lightdm.service"
	"ly.service"
	"lxdm.service"
	"lemurs.service"
)

# ------------------------------ Utilities ------------------------------------

function _err() { printf 'ERROR: %s\n' "$*" >&2; }
function _msg() { printf '%s\n' "$*"; }

function _need_root() {
	if [[ ${EUID:-0} -ne 0 ]]; then
		_err "This must be run as root."
		_err "Try: sudo $0 ${*:-}"
		exit 1
	fi
}

function _have() { command -v "$1" >/dev/null 2>&1; }

function _pager() {
	# Help pager: override with HELP_PAGER; else prefer less -R; else cat
	if [[ -n "${HELP_PAGER:-}" ]]; then
		printf '%s' "$HELP_PAGER"
		return 0
	fi
	if _have less; then
		printf '%s' "less -R"
		return 0
	fi
	printf '%s' "cat"
}

function _show_help() {
	local pager
	pager="$(_pager)"
	cat <<'EOF' | eval "${pager}"
gui-toggle - toggle “GUI vs TTY-only” boot mode (systemd)

USAGE
  sudo gui-toggle --status
  sudo gui-toggle --tty [--once] [--now] [--dm <unit>]
  sudo gui-toggle --gui        [--now] [--dm <unit>]
  sudo gui-toggle --cleanup-once

MODES
  --status
    Show current default target and any detected/recorded DM.

  --tty
    Persistent TTY-only boot:
      - set default target to multi-user.target
      - disable the detected (or specified) DM unit

  --tty --once
    Next-boot TTY-only (single session):
      - set default target to multi-user.target
      - disable the DM unit
      - install a oneshot unit that reverts default target back to
        graphical.target AFTER that boot (so subsequent boots go GUI again)
      - The oneshot unit does NOT start the DM immediately; it only re-enables it
        for the next reboot.

  --gui
    Restore GUI boot:
      - set default target to graphical.target
      - enable the recorded/detected DM unit

OPTIONS
  --now
    Apply immediately as well:
      - with --tty : stop the DM right now
      - with --gui : start the DM right now
    Recommended to run from a TTY.

  --dm <unit>
    Explicit DM unit name (e.g. sddm.service, gdm.service, greetd.service).
    Useful if auto-detection fails.

  --cleanup-once
    Internal: removes the one-shot restore unit and clears “once” markers.

EXAMPLES
  # See current mode
  sudo gui-toggle --status

  # Next boot is TTY-only, and stays that way until you restore GUI
  sudo gui-toggle --tty

  # Next boot is TTY-only, but subsequent boots return to GUI
  sudo gui-toggle --tty --once

  # Restore GUI for next boot
  sudo gui-toggle --gui

  # Stop DM immediately and drop to TTY-only on this boot + next boots
  sudo gui-toggle --tty --now

NOTES (Hyprland-specific)
  If you have custom auto-start in ~/.zprofile or similar that launches Hyprland
  on TTY login, this tool cannot reliably prevent that; it only controls systemd
  targets and the login manager. Guard your auto-start with a condition or keep
  it disabled when troubleshooting.
EOF
}

function _mkdir_state() {
	install -d -m 0700 "$STATE_DIR"
}

function _write_state_kv() {
	local key="$1"
	local val="$2"

	_mkdir_state
	if [[ -f "$STATE_FILE" ]]; then
		# Replace existing key if present
		if grep -qE "^${key}=" "$STATE_FILE"; then
			# portable in-place edit using temp
			local tmp
			tmp="$(mktemp)"
			awk -v k="$key" -v v="$val" '
        BEGIN { found=0 }
        $0 ~ "^" k "=" { print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
      ' "$STATE_FILE" >"$tmp"
			mv -f "$tmp" "$STATE_FILE"
			chmod 0600 "$STATE_FILE"
			return 0
		fi
	fi

	printf '%s=%s\n' "$key" "$val" >>"$STATE_FILE"
	chmod 0600 "$STATE_FILE"
}

function _read_state_kv() {
	local key="$1"
	if [[ -f "$STATE_FILE" ]]; then
		awk -F= -v k="$key" '$1==k { sub($1 "=", "", $0); print $0; exit }' \
			"$STATE_FILE"
	fi
}

function _systemctl() {
	systemctl "$@"
}

function _unit_exists() {
	local unit="$1"
	_systemctl list-unit-files --no-legend --no-pager 2>/dev/null |
		awk '{print $1}' | grep -qx "$unit"
}

function _is_enabled() {
	local unit="$1"
	local st
	st="$(_systemctl is-enabled "$unit" 2>/dev/null || true)"
	[[ "$st" == "enabled" || "$st" == "indirect" ]]
}

function _detect_dm() {
	local unit
	for unit in "${DM_CANDIDATES[@]}"; do
		if _unit_exists "$unit" && _is_enabled "$unit"; then
			printf '%s' "$unit"
			return 0
		fi
	done

	# If nothing is enabled, try “active” as a fallback signal
	for unit in "${DM_CANDIDATES[@]}"; do
		if _unit_exists "$unit" &&
			_systemctl is-active --quiet "$unit" 2>/dev/null; then
			printf '%s' "$unit"
			return 0
		fi
	done

	printf '%s' ""
}

function _get_default_target() {
	_systemctl get-default 2>/dev/null || true
}

function _record_current_state() {
	local dm default_target
	dm="$1"
	default_target="$(_get_default_target)"

	if [[ -n "$dm" ]]; then
		_write_state_kv "dm_service" "$dm"
	fi
	if [[ -n "$default_target" ]]; then
		_write_state_kv "default_target" "$default_target"
	fi
	_write_state_kv "recorded_at" "$(date -Is 2>/dev/null || date)"
}

function _set_default_target() {
	local target="$1"
	_systemctl set-default "$target" >/dev/null
}

function _disable_dm() {
	local dm="$1"
	_systemctl disable "$dm" >/dev/null || true
}

function _enable_dm() {
	local dm="$1"
	_systemctl enable "$dm" >/dev/null
}

function _stop_dm_now() {
	local dm="$1"
	_systemctl stop "$dm" >/dev/null || true
}

function _start_dm_now() {
	local dm="$1"
	_systemctl start "$dm" >/dev/null
}

function _install_once_unit() {
	local self dm
	self="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
	dm="$1"

	cat >"$ONCE_UNIT" <<EOF
[Unit]
Description=gui-toggle: restore GUI boot defaults after one TTY boot
After=multi-user.target
ConditionPathExists=${STATE_FILE}

[Service]
Type=oneshot
ExecStart=${self} --gui --dm ${dm} --cleanup-once
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

	chmod 0644 "$ONCE_UNIT"
	_systemctl daemon-reload
	_systemctl enable "gui-toggle-restore.service" >/dev/null
	_write_state_kv "once_mode" "1"
}

function _cleanup_once() {
	if [[ -f "$ONCE_UNIT" ]]; then
		_systemctl disable "gui-toggle-restore.service" >/dev/null || true
		rm -f "$ONCE_UNIT"
		_systemctl daemon-reload
	fi
	if [[ -f "$STATE_FILE" ]]; then
		# Remove only the once marker; keep state for later restores
		local tmp
		tmp="$(mktemp)"
		awk '$1 !~ /^once_mode=/' "$STATE_FILE" >"$tmp"
		mv -f "$tmp" "$STATE_FILE"
		chmod 0600 "$STATE_FILE"
	fi
}

# ------------------------------ Actions --------------------------------------

function action_status() {
	local default_target detected_dm recorded_dm
	default_target="$(_get_default_target)"
	detected_dm="$(_detect_dm)"
	recorded_dm="$(_read_state_kv "dm_service")"

	_msg "Default target : ${default_target:-<unknown>}\n"
	_msg "Detected DM     : ${detected_dm:-<none>}\n"
	_msg "Recorded DM     : ${recorded_dm:-<none>}\n"

	if [[ -n "$recorded_dm" && -n "$default_target" ]]; then
		local once
		once="$(_read_state_kv "once_mode")"
		if [[ "${once:-0}" == "1" ]]; then
			_msg "Once-mode       : enabled (next TTY boot will auto-revert)\n"
		else
			_msg "Once-mode       : disabled\n"
		fi
	fi
}

function action_tty() {
	local dm once now
	dm="$1"
	once="$2"
	now="$3"

	if [[ -z "$dm" ]]; then
		_err "No DM detected and none specified via --dm."
		_err "Run: sudo $0 --status"
		exit 1
	fi

	_record_current_state "$dm"

	_set_default_target "multi-user.target"
	_disable_dm "$dm"

	if [[ "$now" == "1" ]]; then
		_stop_dm_now "$dm"
	fi

	if [[ "$once" == "1" ]]; then
		_install_once_unit "$dm"
	fi

	_msg "Configured TTY-only boot.\n"
	_msg "  default target: multi-user.target\n"
	_msg "  dm service    : ${dm} (disabled)\n"
	if [[ "$once" == "1" ]]; then
		_msg "  once-mode     : enabled (auto-revert after next TTY boot)\n"
	fi
	if [[ "$now" == "1" ]]; then
		_msg "  applied now   : DM stopped\n"
	else
		_msg "  applied now   : no (takes effect on next boot)\n"
	fi
}

function action_gui() {
	local dm now
	dm="$1"
	now="$2"

	if [[ -z "$dm" ]]; then
		dm="$(_read_state_kv "dm_service")"
	fi
	if [[ -z "$dm" ]]; then
		dm="$(_detect_dm)"
	fi
	if [[ -z "$dm" ]]; then
		_err "No DM detected and none recorded; specify one with --dm."
		exit 1
	fi

	_record_current_state "$dm"

	_set_default_target "graphical.target"
	_enable_dm "$dm"

	if [[ "$now" == "1" ]]; then
		_start_dm_now "$dm"
	fi

	_msg "Configured GUI boot.\n"
	_msg "  default target: graphical.target\n"
	_msg "  dm service    : ${dm} (enabled)\n"
	if [[ "$now" == "1" ]]; then
		_msg "  applied now   : DM started\n"
	else
		_msg "  applied now   : no (takes effect on next boot)\n"
	fi
}

# ------------------------------ Arg Parsing ----------------------------------

MODE=""
DM_OVERRIDE=""
FLAG_ONCE="0"
FLAG_NOW="0"

if [[ $# -eq 0 ]]; then
	_show_help
	exit 0
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		_show_help
		exit 0
		;;
	--status)
		MODE="status"
		shift
		;;
	--tty)
		MODE="tty"
		shift
		;;
	--gui)
		MODE="gui"
		shift
		;;
	--once)
		FLAG_ONCE="1"
		shift
		;;
	--now)
		FLAG_NOW="1"
		shift
		;;
	--dm)
		shift
		if [[ $# -lt 1 ]]; then
			_err "--dm requires a unit name (e.g. sddm.service)."
			exit 1
		fi
		DM_OVERRIDE="$1"
		shift
		;;
	--cleanup-once)
		MODE="cleanup_once"
		shift
		;;
	*)
		_err "Unknown argument: $1"
		_err "Run: $0 --help"
		exit 1
		;;
	esac
done

# ------------------------------ Main -----------------------------------------

case "$MODE" in
status)
	action_status
	;;
tty)
	_need_root
	if [[ -n "$DM_OVERRIDE" ]]; then
		action_tty "$DM_OVERRIDE" "$FLAG_ONCE" "$FLAG_NOW"
	else
		action_tty "$(_detect_dm)" "$FLAG_ONCE" "$FLAG_NOW"
	fi
	;;
gui)
	_need_root
	action_gui "$DM_OVERRIDE" "$FLAG_NOW"
	;;
cleanup_once)
	_need_root
	_cleanup_once
	_msg "Cleaned up once-mode restore unit.\n"
	;;
*)
	_err "No mode selected."
	_err "Run: $0 --help"
	exit 1
	;;
esac
