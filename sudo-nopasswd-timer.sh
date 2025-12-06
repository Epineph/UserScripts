#!/usr/bin/env bash
#------------------------------#
#  sudo-temp-nopasswd          #
#------------------------------#
# Temporary NOPASSWD sudoers.d entry for a given user.
# WARNING: Misconfiguration of sudoers can lock you out. Keep a root shell
# open when testing or modifying this script.

set -euo pipefail

SCRIPT_NAME="sudo-temp-nopasswd"
SCRIPT_VERSION="0.2.0"

DEFAULT_MODE="" # "relative" or "absolute"
MODE=""         # chosen mode
TARGET_USER=""
NOPASSWD_MODE=1      # 1 = NOPASSWD, 0 = normal password
USE_SUDO_LOOP_FLAG=0 # -s / --sudo-loop; mostly semantic
REL_HOURS=0
REL_MINUTES=0
REL_SECONDS=0
END_TIME="" # HH:MM[:SS]
DURATION_SECONDS=0
EXPIRY_EPOCH=0

HYPR_NOTIFY_AVAILABLE=0

#------------------------------#
#  Utility functions           #
#------------------------------#

function die() {
	printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

function is_non_negative_int() {
	local v="${1:-}"
	[[ "$v" =~ ^[0-9]+$ ]]
}

function require_root() {
	if [ "$EUID" -ne 0 ]; then
		die "must be run as root (use sudo)."
	fi
}

function detect_target_user() {
	if [ "$TARGET_USER" != "" ]; then
		return
	fi

	if [ "${SUDO_USER:-}" != "" ] && [ "$SUDO_USER" != "root" ]; then
		TARGET_USER="$SUDO_USER"
	elif [ "${USER:-}" != "" ] && [ "$USER" != "root" ]; then
		TARGET_USER="$USER"
	else
		die "unable to infer non-root user; use -u|--user."
	fi
}

function show_help() {
	local pager
	pager="${HELP_PAGER:-less -R}"

	if ! command -v less >/dev/null 2>&1 &&
		[ "$pager" = "less -R" ]; then
		pager="cat"
	fi

	"$pager" <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
--------------------------------

Temporarily grant passwordless sudo (NOPASSWD) to a user by dropping a
sudoers.d file and scheduling its removal after a specified duration.

The script:

  * Writes /etc/sudoers.d/temporary-nopasswd-<user>.
  * Validates syntax with 'visudo -cf'.
  * Schedules automatic deletion of that file after the chosen interval:
      - Preferentially via 'systemd-run --on-active=...'.
      - Falls back to a background 'sleep && rm' if systemd-run is absent.
  * Prints the scheduled expiry timestamp.
  * If a Hyprland session can be detected, sends Hyprland notifications:
      - Immediately after activation with expiry info.
      - At several relative and fixed thresholds before deactivation.

WARNING:
  Misusing sudoers can lock you out of administrative access. Test carefully,
  keep a root shell open, and do not blindly trust this script on production.

Usage (relative duration):
  sudo ${SCRIPT_NAME} -t --hours 1 --minutes 30
  sudo ${SCRIPT_NAME} -s -t -H 1 -M 30 -S 0 -u heini

Usage (terminate at clock time today):
  sudo ${SCRIPT_NAME} -e 18:00:00
  sudo ${SCRIPT_NAME} --terminate-at 23:30

Options:
  -h, --help
      Show this help text.

  -u, --user <name>
      Apply NOPASSWD to this user. Defaults:
        - \$SUDO_USER if set and not root
        - else \$USER if not root
        - otherwise required explicitly.

  -p, --password-bypass
      Explicitly request NOPASSWD mode (default; this flag is redundant).

  -r, --require-password
      Create a normal sudoers rule (no NOPASSWD). Mostly for testing or if
      you decide later you prefer timestamp_timeout-based behaviour.

  -s, --sudo-loop
      Semantic flag only; implies you are using this as a temporary sudo
      convenience. Currently does not change behaviour, but is recorded
      in logs/messages.

  -t, --timer-loop
      Use a relative duration (hours/minutes/seconds), specified with:
        -H, --hours <int>    (default 0)
        -M, --minutes <int>  (default 0)
        -S, --seconds <int>  (default 0)

      Example:
        -t -H 1 -M 30 -S 15
        --timer-loop --hours 0 --minutes 45

  -e, --end-time, --terminate-at <HH:MM[:SS]>
      Use an absolute terminate-at clock time for *today* in the system
      timezone. The script computes:

        duration = target_time_today - now

      and rejects values that are <= 0 (i.e. in the past or immediate).

      Example:
        -e 18:00:00
        --terminate-at 23:15

Notes:
  * Exactly one of --timer-loop (-t) or --end-time (-e) must be specified.
  * The generated sudoers file is:
        /etc/sudoers.d/temporary-nopasswd-<user>
    with mode 0440.
  * If the system reboots before the deletion job runs, the NOPASSWD stanza
    may persist. Re-run ${SCRIPT_NAME} or remove the file manually.
  * Hyprland notifications are best-effort. If no Hyprland instance can be
    detected, the core behaviour is unchanged.

Safer alternative (no sudoers editing):
  A more conservative approach to "sudo without repeated passwords" is a
  simple keepalive loop:
    while true; do sudo -v; sleep 60; done
  This keeps sudo's existing timestamp alive instead of granting NOPASSWD.
EOF
}

#------------------------------#
#  Hyprland notifications      #
#------------------------------#

function detect_hypr_env() {
	HYPR_NOTIFY_AVAILABLE=0

	if ! command -v hyprctl >/dev/null 2>&1; then
		return
	fi

	local user_uid xdg_base
	user_uid="$(id -u "$TARGET_USER" 2>/dev/null || echo "")"

	if [ "${XDG_RUNTIME_DIR:-}" != "" ]; then
		xdg_base="$XDG_RUNTIME_DIR"
	elif [ "$user_uid" != "" ]; then
		xdg_base="/run/user/${user_uid}"
	else
		return
	fi

	if [ ! -d "$xdg_base" ]; then
		return
	fi

	if [ "${HYPRLAND_INSTANCE_SIGNATURE:-}" = "" ]; then
		if [ -d "${xdg_base}/hypr" ]; then
			local cand
			cand="$(ls -1 "${xdg_base}/hypr" 2>/dev/null | head -n1 || true)"
			if [ "$cand" != "" ]; then
				HYPRLAND_INSTANCE_SIGNATURE="$cand"
			fi
		fi
	fi

	if [ "${HYPRLAND_INSTANCE_SIGNATURE:-}" = "" ]; then
		return
	fi

	if [ ! -d "${xdg_base}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}" ]; then
		return
	fi

	export HYPRLAND_INSTANCE_SIGNATURE
	export XDG_RUNTIME_DIR="$xdg_base"
	HYPR_NOTIFY_AVAILABLE=1
}

function hypr_notify() {
	local timeout_ms="${1:-5000}"
	local color="${2:-rgb(ffc857)}"
	local text="${3:-}"

	if [ "$HYPR_NOTIFY_AVAILABLE" -ne 1 ]; then
		return 0
	fi

	# hyprctl notify <id> <timeout_ms> <color> <text>
	# Use -1 to create a new notification ID.
	hyprctl notify -1 "$timeout_ms" "$color" "$text" >/dev/null 2>&1 || true
}

function schedule_notifications() {
	if [ "$HYPR_NOTIFY_AVAILABLE" -ne 1 ]; then
		return 0
	fi

	local d="$DURATION_SECONDS"
	local -a offsets=()

	# Relative thresholds.
	if [ "$d" -ge 60 ]; then
		offsets+=("$((d / 2))") # 50 %
	fi
	if [ "$d" -ge 600 ]; then
		offsets+=("$((d * 3 / 4))") # 75 %
	fi
	if [ "$d" -ge 1200 ]; then
		offsets+=("$((d * 9 / 10))") # 90 %
	fi

	# Fixed "time remaining" thresholds (only if they make sense).
	if [ "$d" -gt 600 ]; then
		offsets+=("$((d - 600))") # 10 minutes left
	fi
	if [ "$d" -gt 300 ]; then
		offsets+=("$((d - 300))") # 5 minutes left
	fi
	if [ "$d" -gt 60 ]; then
		offsets+=("$((d - 60))") # 1 minute left
	fi
	if [ "$d" -gt 10 ]; then
		offsets+=("$((d - 10))") # 10 seconds left
	fi
	if [ "$d" -gt 5 ]; then
		offsets+=("$((d - 5))") # 5 seconds left
	fi

	if [ "${#offsets[@]}" -eq 0 ]; then
		return 0
	fi

	local -a sorted=()
	mapfile -t sorted < <(
		printf '%s\n' "${offsets[@]}" |
			awk '$1 > 0' |
			sort -n |
			uniq
	)

	(
		local prev=0
		local remaining msg

		for offset in "${sorted[@]}"; do
			if [ "$offset" -le "$prev" ]; then
				continue
			fi

			sleep "$((offset - prev))" || exit 0
			remaining=$((d - offset))
			if [ "$remaining" -lt 0 ]; then
				remaining=0
			fi

			if [ "$remaining" -ge 3600 ]; then
				msg=$(printf 'sudo NOPASSWD for %s: ~%d hour(s) remaining.' \
					"$TARGET_USER" $(((remaining + 1800) / 3600)))
			elif [ "$remaining" -ge 60 ]; then
				msg=$(printf 'sudo NOPASSWD for %s: ~%d minute(s) remaining.' \
					"$TARGET_USER" $(((remaining + 30) / 60)))
			elif [ "$remaining" -gt 0 ]; then
				msg=$(printf 'sudo NOPASSWD for %s: ~%d second(s) remaining.' \
					"$TARGET_USER" "$remaining")
			else
				msg=$(printf 'sudo NOPASSWD for %s is about to be revoked.' \
					"$TARGET_USER")
			fi

			hypr_notify 8000 "rgb(ffc857)" "$msg"
			prev="$offset"
		done
	) &
}

#------------------------------#
#  Duration computation        #
#------------------------------#

function compute_duration_relative() {
	if ! is_non_negative_int "$REL_HOURS" ||
		! is_non_negative_int "$REL_MINUTES" ||
		! is_non_negative_int "$REL_SECONDS"; then
		die "hours/minutes/seconds must be non-negative integers."
	fi

	DURATION_SECONDS=$((REL_HOURS * 3600 + REL_MINUTES * 60 + REL_SECONDS))

	if [ "$DURATION_SECONDS" -le 0 ]; then
		die "relative duration must be > 0 seconds."
	fi

	EXPIRY_EPOCH=$(("$(date +%s)" + DURATION_SECONDS))
}

function compute_duration_absolute() {
	local now_epoch target_epoch today

	[ "$END_TIME" != "" ] ||
		die "--end-time/--terminate-at requires HH:MM[:SS]."

	today="$(date +%Y-%m-%d)"
	if ! target_epoch="$(date -d "${today} ${END_TIME}" +%s 2>/dev/null)"; then
		die "unable to parse end time '${END_TIME}'."
	fi

	now_epoch="$(date +%s)"

	if [ "$target_epoch" -le "$now_epoch" ]; then
		die "end time '${END_TIME}' is not in the future today."
	fi

	DURATION_SECONDS=$((target_epoch - now_epoch))
	EXPIRY_EPOCH="$target_epoch"
}

#------------------------------#
#  sudoers.d management        #
#------------------------------#

function build_sudoers_line() {
	local line
	if [ "$NOPASSWD_MODE" -eq 1 ]; then
		line="${TARGET_USER} ALL=(ALL:ALL) NOPASSWD: ALL"
	else
		line="${TARGET_USER} ALL=(ALL:ALL) ALL"
	fi
	printf '%s\n' "$line"
}

function write_sudoers_file() {
	local dir file tmp now_str expiry_str

	dir="/etc/sudoers.d"
	file="${dir}/temporary-nopasswd-${TARGET_USER}"
	tmp="${file}.tmp.$$"

	mkdir -p "$dir"

	now_str="$(date '+%Y-%m-%dT%H:%M:%S %Z')"
	if [ "${EXPIRY_EPOCH:-0}" -gt 0 ] 2>/dev/null; then
		expiry_str="$(date -d "@${EXPIRY_EPOCH}" \
			'+%Y-%m-%dT%H:%M:%S %Z')" || expiry_str="(unknown)"
	else
		expiry_str="(unknown)"
	fi

	{
		printf '# Temporary sudoers NOPASSWD entry created by %s\n' \
			"$SCRIPT_NAME"
		printf '# User      : %s\n' "$TARGET_USER"
		printf '# Created   : %s\n' "$now_str"
		printf '# Expires   : %s (scheduled removal)\n' "$expiry_str"
		printf '# Duration  : %s seconds\n' "$DURATION_SECONDS"
		if [ "$USE_SUDO_LOOP_FLAG" -eq 1 ]; then
			printf '# Mode      : sudo-loop requested\n'
		fi
		printf '%s\n' "$(build_sudoers_line)"
	} >"$tmp"

	chmod 0440 "$tmp"

	if ! visudo -cf "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		die "visudo validation failed; sudoers file not installed."
	fi

	mv "$tmp" "$file"
}

#------------------------------#
#  Deletion scheduling         #
#------------------------------#

function schedule_deletion() {
	local file unit_name rm_path

	file="/etc/sudoers.d/temporary-nopasswd-${TARGET_USER}"
	rm_path="$(command -v rm || echo /usr/bin/rm)"
	unit_name="sudo-nopasswd-clean-${TARGET_USER}-$(date +%s)"

	if command -v systemd-run >/dev/null 2>&1; then
		systemd-run \
			--unit "$unit_name" \
			--description "Remove temporary sudoers for ${TARGET_USER}" \
			--on-active="${DURATION_SECONDS}s" \
			"$rm_path" -f "$file" >/dev/null 2>&1 || {
			printf '%s: warning: systemd-run failed, falling back to sleep.\n' \
				"$SCRIPT_NAME" >&2
			(
				sleep "$DURATION_SECONDS"
				"$rm_path" -f "$file"
			) &
		}
	else
		(
			sleep "$DURATION_SECONDS"
			"$rm_path" -f "$file"
		) &
	fi
}

#------------------------------#
#  Argument parsing            #
#------------------------------#

function parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-h | --help)
			show_help
			exit 0
			;;
		-u | --user)
			[ "$#" -ge 2 ] || die "-u|--user requires an argument."
			TARGET_USER="$2"
			shift 2
			;;
		-p | --password-bypass)
			NOPASSWD_MODE=1
			shift
			;;
		-r | --require-password)
			NOPASSWD_MODE=0
			shift
			;;
		-s | --sudo-loop)
			USE_SUDO_LOOP_FLAG=1
			shift
			;;
		-t | --timer-loop)
			if [ "$MODE" != "" ] && [ "$MODE" != "relative" ]; then
				die "cannot combine --timer-loop with --end-time."
			fi
			MODE="relative"
			shift
			;;
		-H | --hours)
			[ "$#" -ge 2 ] || die "-H|--hours requires an integer."
			REL_HOURS="$2"
			shift 2
			;;
		-M | --minutes)
			[ "$#" -ge 2 ] || die "-M|--minutes requires an integer."
			REL_MINUTES="$2"
			shift 2
			;;
		-S | --seconds)
			[ "$#" -ge 2 ] || die "-S|--seconds requires an integer."
			REL_SECONDS="$2"
			shift 2
			;;
		-e | --end-time | --terminate-at)
			[ "$#" -ge 2 ] || die "-e|--end-time requires HH:MM[:SS]."
			if [ "$MODE" != "" ] && [ "$MODE" != "absolute" ]; then
				die "cannot combine --end-time with --timer-loop."
			fi
			MODE="absolute"
			END_TIME="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		*)
			die "unknown argument: ${1}"
			;;
		esac
	done

	if [ "$MODE" = "" ]; then
		die "must specify one of --timer-loop (-t) or --end-time (-e)."
	fi
}

#------------------------------#
#  Main                        #
#------------------------------#

function main() {
	parse_args "$@"
	require_root
	detect_target_user
	detect_hypr_env

	case "$MODE" in
	relative)
		compute_duration_relative
		;;
	absolute)
		compute_duration_absolute
		;;
	*)
		die "internal error: unknown MODE='${MODE}'."
		;;
	esac

	write_sudoers_file
	schedule_deletion
	schedule_notifications

	local hours_str expires_at
	hours_str="$(awk -v s="$DURATION_SECONDS" \
		'BEGIN { printf "%.2f", s / 3600 }')"

	if [ "${EXPIRY_EPOCH:-0}" -gt 0 ] 2>/dev/null; then
		expires_at="$(date -d "@${EXPIRY_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')" ||
			expires_at="unknown"
	else
		expires_at="unknown"
	fi

	printf '%s: NOPASSWD entry installed for user %s.\n' \
		"$SCRIPT_NAME" "$TARGET_USER"
	printf '%s: duration %s seconds (~%s hours).\n' \
		"$SCRIPT_NAME" "$DURATION_SECONDS" "$hours_str"
	printf '%s: sudoers snippet: /etc/sudoers.d/temporary-nopasswd-%s\n' \
		"$SCRIPT_NAME" "$TARGET_USER"
	printf '%s: removal scheduled (check with systemctl list-units | grep sudo-nopasswd-clean || ps aux | grep sleep).\n' \
		"$SCRIPT_NAME"
	printf 'Manual removal if needed: rm -f /etc/sudoers.d/temporary-nopasswd-%s\n' \
		"$TARGET_USER"
	printf '\n'

	if [ "$HYPR_NOTIFY_AVAILABLE" -eq 1 ]; then
		local init_msg
		if [ "$expires_at" != "unknown" ]; then
			init_msg=$(printf 'sudo NOPASSWD for %s enabled (~%s h, until %s).' \
				"$TARGET_USER" "$hours_str" "$expires_at")
		else
			init_msg=$(printf 'sudo NOPASSWD for %s enabled for %s seconds.' \
				"$TARGET_USER" "$DURATION_SECONDS")
		fi
		hypr_notify 8000 "rgb(89b4fa)" "$init_msg"
	fi
}

main "$@"
