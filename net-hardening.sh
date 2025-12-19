#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# net-harden
#
# Purpose:
#   Reversible, moderately conservative hardening for untrusted networks.
#   Focus: reduce inbound exposure, enable MAC randomization (NM), optionally
#   run a VPN, optionally launch a hardened Firefox profile, and manage
#   timers/reminders with systemd (without permanently rewriting system config).
#
# Notes (important constraints):
#   - "Shell hardening" cannot magically wrap *all* commands; this script can
#     (a) apply system/network measures so all commands benefit, and
#     (b) optionally apply session hygiene (history/umask) via an eval-able
#         snippet for the current shell.
#   - "All-traffic encryption" requires a VPN. Without a VPN you can still
#     reduce inbound attack surface and tracking, but you cannot hide all
#     destinations/metadata from the local network operator.
#
# Install suggestion:
#   sudo install -m 0755 net-harden /usr/local/bin/net-harden
# ---------------------------------------------------------------------------

set -euo pipefail

# ------------------------------- Defaults ----------------------------------

readonly PROG="net-harden"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROG}"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly EVENT_LOG="${STATE_DIR}/events.log"

DEFAULT_SCOPE="network"
DEFAULT_MAC_MODE="stable"               # stable|random|preserve
DEFAULT_BLOCK_HTTP="no"                 # yes|no
DEFAULT_REMIND="no"                     # yes|no
DEFAULT_PERSIST="os"                    # session|os|manual
DEFAULT_TIMER_SECONDS=$((24 * 60 * 60)) # 24h default for network if not given

# DNS-over-HTTPS default for Firefox hardened profile (moderate).
DEFAULT_TRR_URI="https://mozilla.cloudflare-dns.com/dns-query"

# ------------------------------ Utilities ----------------------------------

function die() {
	printf '%s: error: %s\n' "$PROG" "${1}" >&2
	exit 1
}

function warn() {
	printf '%s: warning: %s\n' "$PROG" "${1}" >&2
}

function have() {
	command -v "${1}" >/dev/null 2>&1
}

function now_epoch() {
	date +%s
}

function iso_now() {
	date -Iseconds
}

function epoch_to_iso() {
	date -d "@${1}" -Iseconds 2>/dev/null || printf 'unknown'
}

function ensure_state_dir() {
	mkdir -p "$STATE_DIR"
	chmod 700 "$STATE_DIR" 2>/dev/null || true
}

function help_pager() {
	local pager="${HELP_PAGER:-}"
	if [[ -n "$pager" ]]; then
		printf '%s' "$pager"
		return 0
	fi
	if have less; then
		printf '%s' "less -R"
		return 0
	fi
	printf '%s' "cat"
}

function show_help() {
	local pager
	pager="$(help_pager)"
	cat <<'EOF' | eval "${pager}"
# net-harden

## Synopsis

  net-harden enable [OPTIONS]
  net-harden disable [OPTIONS]
  net-harden status
  net-harden browser [OPTIONS]
  net-harden shell-env [--enable|--disable]
  net-harden checklist
  net-harden help

## Philosophy

- **Moderate** hardening: reduce inbound exposure and tracking, avoid brittle
  global proxy hacks, and keep changes reversible.
- **All-traffic privacy** requires a VPN. Without it, you can still improve
  safety (firewall/MAC/browser), but you cannot hide all metadata.

## Scopes

- `network` : nftables rules to block inbound TCP (new SYN), optional block HTTP.
              Optional NetworkManager MAC randomization (per-connection).
              Optional VPN (WireGuard or OpenVPN).
- `browser` : launches Firefox using a dedicated hardened profile directory.
- `shell`   : provides an eval-able snippet for session hygiene (history/umask).
- `all`     : expands to `network,browser,shell`.

## Enable options

  --scope SCOPE_LIST
      Comma-separated: network,browser,shell,all
      Default: network

  --persist MODE
      session : applies only to the current shell (shell scope via shell-env).
      os      : applies for the OS lifetime; cleared on reboot.
      manual  : remains active until `disable` is run.
      Default: os

  --for DURATION
      Duration like: 30m, 2h, 1d, or combined: 1h30m
      If omitted for `network`, defaults to 24h (safety default).

  --until ISO_TIME
      GNU date -d compatible, e.g.:
        "2025-12-20 08:00"
        "tomorrow 17:00"
        "2025-12-20T08:00:00+01:00"

  --remind yes|no
      Create reminder timers (systemd --user) to notify occasionally.

  --mac stable|random|preserve
      NetworkManager per-connection MAC cloning mode (wifi/ethernet).
      Default: stable

  --conn NAME
      NetworkManager connection profile name to modify.
      Default: active connection (best-effort pick).

  --block-http yes|no
      If yes, adds nft rule to drop outbound TCP port 80 (plain HTTP).
      Default: no

  --vpn-wg PATH
      Bring up WireGuard via `wg-quick up PATH` (requires sudo).

  --vpn-ovpn PATH
      Run OpenVPN via systemd transient unit (requires sudo and openvpn).

  --trr-uri URI
      Firefox DoH URI for browser scope.
      Default:
        https://mozilla.cloudflare-dns.com/dns-query

  --force
      If an active config exists, overwrite it (disables first).

  --log-event yes|no
      Append start/stop entries to ~/.local/state/net-harden/events.log

## Disable options

  --kill-browser yes|no
      If yes, attempts to terminate the Firefox PID recorded in state.
      Default: no

  --reconnect yes|no
      If yes, cycles the NM connection down/up to apply restored MAC settings.
      Default: no

  --log-event yes|no
      Log stop event if enabled.

## Browser (standalone)

  net-harden browser [--trr-uri URI]
      Launch Firefox with a hardened ephemeral profile (stored under state dir).
      This does not modify your default Firefox profile.

## Shell environment snippet

  eval "$(net-harden shell-env --enable)"
  eval "$(net-harden shell-env --disable)"

## Checklist

  net-harden checklist
      Reports whether hardening artifacts currently exist and whether they match
      the state file (nft table, NM MAC setting, VPN unit/interface, timers).

EOF
}

# ------------------------------- State -------------------------------------

function state_exists() {
	[[ -f "$STATE_FILE" ]]
}

function state_load() {
	if ! state_exists; then
		return 1
	fi
	# shellcheck disable=SC1090
	set -a
	source "$STATE_FILE"
	set +a
	return 0
}

function state_write_kv() {
	# Args: key value
	printf '%s=%q\n' "${1}" "${2}" >>"$STATE_FILE"
}

function state_save() {
	ensure_state_dir
	: >"$STATE_FILE"
	chmod 600 "$STATE_FILE" 2>/dev/null || true

	state_write_kv "ACTIVE" "$ACTIVE"
	state_write_kv "ID" "$ID"
	state_write_kv "START_EPOCH" "$START_EPOCH"
	state_write_kv "END_EPOCH" "$END_EPOCH"
	state_write_kv "SCOPE_LIST" "$SCOPE_LIST"
	state_write_kv "PERSIST_MODE" "$PERSIST_MODE"
	state_write_kv "REMIND" "$REMIND"
	state_write_kv "REMIND_UNIT" "$REMIND_UNIT"
	state_write_kv "EXPIRE_UNIT" "$EXPIRE_UNIT"
	state_write_kv "THRESH_UNITS" "$THRESH_UNITS"

	state_write_kv "NFT_TABLE" "$NFT_TABLE"
	state_write_kv "NFT_BLOCK_HTTP" "$NFT_BLOCK_HTTP"

	state_write_kv "NM_CONN" "$NM_CONN"
	state_write_kv "NM_KEY" "$NM_KEY"
	state_write_kv "NM_PREV_MAC" "$NM_PREV_MAC"
	state_write_kv "NM_SET_MAC" "$NM_SET_MAC"

	state_write_kv "VPN_KIND" "$VPN_KIND"
	state_write_kv "VPN_PATH" "$VPN_PATH"
	state_write_kv "VPN_UNIT" "$VPN_UNIT"
	state_write_kv "VPN_WG_IF" "$VPN_WG_IF"

	state_write_kv "BROWSER_PROFILE" "$BROWSER_PROFILE"
	state_write_kv "BROWSER_PID" "$BROWSER_PID"
	state_write_kv "TRR_URI" "$TRR_URI"

	state_write_kv "LOG_EVENT" "$LOG_EVENT"
}

function state_clear() {
	rm -f "$STATE_FILE"
}

function log_event() {
	local msg="${1}"
	[[ "$LOG_EVENT" == "yes" ]] || return 0
	ensure_state_dir
	printf '[%s] %s\n' "$(iso_now)" "$msg" >>"$EVENT_LOG"
}

# -------------------------- Notifications ----------------------------------

function can_notify() {
	[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
	have notify-send || return 1
	return 0
}

function notify() {
	local title="${1}"
	local body="${2}"
	if can_notify; then
		notify-send "$title" "$body" >/dev/null 2>&1 || true
	else
		printf '%s: %s\n' "$title" "$body" >&2
	fi
}

# ------------------------- Duration parsing --------------------------------

function parse_duration_to_seconds() {
	# Accept: 10s, 5m, 2h, 1d, or combinations like 1h30m.
	local s="${1}"
	local total=0
	local re='^([0-9]+)([smhd])(.*)$'

	while [[ -n "$s" ]]; do
		if [[ "$s" =~ ${re} ]]; then
			local n="${BASH_REMATCH[1]}"
			local u="${BASH_REMATCH[2]}"
			local rest="${BASH_REMATCH[3]}"
			case "$u" in
			s) total=$((total + n)) ;;
			m) total=$((total + n * 60)) ;;
			h) total=$((total + n * 3600)) ;;
			d) total=$((total + n * 86400)) ;;
			*) die "internal duration unit parse failure" ;;
			esac
			s="$rest"
		else
			return 1
		fi
	done

	printf '%s' "$total"
}

function parse_until_to_epoch() {
	local t="${1}"
	local e
	e="$(date -d "$t" +%s 2>/dev/null)" || return 1
	printf '%s' "$e"
}

# ------------------------ NetworkManager helpers ---------------------------

function nm_pick_active_connection() {
	# Prefer an active wifi connection, else first active.
	have nmcli || return 1
	local line
	line="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
		awk -F: '
        $2=="wifi" { print; exit }
        { if (!first) { first=$0 } }
        END { if (!found && first) print first }
      ')" || true
	[[ -n "$line" ]] || return 1
	printf '%s' "$line"
}

function nm_key_for_type() {
	local type="${1}"
	case "$type" in
	wifi) printf '%s' "802-11-wireless.cloned-mac-address" ;;
	ethernet) printf '%s' "802-3-ethernet.cloned-mac-address" ;;
	*) printf '%s' "" ;;
	esac
}

function nm_get_mac_mode() {
	local conn="${1}"
	local key="${2}"
	nmcli -g "$key" connection show "$conn" 2>/dev/null || true
}

function nm_set_mac_mode() {
	local conn="${1}"
	local key="${2}"
	local mode="${3}"
	nmcli connection modify "$conn" "$key" "$mode" >/dev/null
}

function nm_conn_is_active() {
	local conn="${1}"
	nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "$conn"
}

function nm_reconnect_conn() {
	local conn="${1}"
	nmcli connection down "$conn" >/dev/null 2>&1 || true
	nmcli connection up "$conn" >/dev/null 2>&1 || true
}

# ------------------------------ nftables -----------------------------------

function nft_table_exists() {
	local tbl="${1}"
	sudo nft list table inet "$tbl" >/dev/null 2>&1
}

function nft_apply_network_rules() {
	# Moderate: block inbound *new* TCP connections (SYN), allow others.
	# Optional: block outbound HTTP (dst port 80).
	local tbl="${1}"
	local block_http="${2}" # yes|no

	sudo nft add table inet "$tbl"
	sudo nft "add chain inet ${tbl} input { type filter hook input priority -110; }"
	sudo nft "add chain inet ${tbl} output { type filter hook output priority -110; }"

	sudo nft "add rule inet ${tbl} input iifname lo accept"
	sudo nft "add rule inet ${tbl} input ct state established,related accept"
	sudo nft "add rule inet ${tbl} input meta l4proto tcp tcp flags syn \
    ct state new drop"

	if [[ "$block_http" == "yes" ]]; then
		sudo nft "add rule inet ${tbl} output meta l4proto tcp tcp dport 80 drop"
	fi
}

function nft_remove_network_rules() {
	local tbl="${1}"
	if nft_table_exists "$tbl"; then
		sudo nft delete table inet "$tbl" >/dev/null
	fi
}

# ------------------------------- VPN ---------------------------------------

function vpn_wg_up() {
	local path="${1}"
	have wg-quick || die "wg-quick not found (install wireguard-tools)"
	sudo wg-quick up "$path" >/dev/null
}

function vpn_wg_down() {
	local ifname="${1}"
	have wg-quick || return 0
	sudo wg-quick down "$ifname" >/dev/null 2>&1 || true
}

function vpn_wg_ifname_from_path() {
	local path="${1}"
	local base
	base="$(basename "$path")"
	base="${base%.conf}"
	printf '%s' "$base"
}

function vpn_ovpn_up() {
	local path="${1}"
	have openvpn || die "openvpn not found"
	have systemd-run || die "systemd-run not found"
	local unit="${2}"
	sudo systemd-run --collect --unit="$unit" \
		--property=Restart=on-failure \
		openvpn --config "$path" >/dev/null
}

function vpn_ovpn_down() {
	local unit="${1}"
	if [[ -n "$unit" ]]; then
		sudo systemctl stop "$unit" >/dev/null 2>&1 || true
	fi
}

# ------------------------------ Firefox ------------------------------------

function firefox_write_userjs() {
	local profile="${1}"
	local trr_uri="${2}"

	mkdir -p "$profile"
	chmod 700 "$profile" 2>/dev/null || true

	cat >"${profile}/user.js" <<EOF
// net-harden: hardened ephemeral profile
user_pref("dom.security.https_only_mode", true);

// DNS-over-HTTPS (TRR = Trusted Recursive Resolver)
user_pref("network.trr.mode", 3);
user_pref("network.trr.uri", "${trr_uri}");
user_pref("network.trr.bootstrapAddress", "");

// Tracking protection (moderate)
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);

// Reduce background noise
user_pref("toolkit.telemetry.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);

// Safer defaults
user_pref("signon.rememberSignons", false);
user_pref("browser.formfill.enable", false);
EOF
}

function firefox_launch_profile() {
	local profile="${1}"
	have firefox || die "firefox not found"
	firefox --no-remote --profile "$profile" >/dev/null 2>&1 &
	printf '%s' "$!"
}

# ------------------------------ systemd ------------------------------------

function unit_name_safe() {
	printf '%s' "${1}" | tr -c 'a-zA-Z0-9_.@-' '_'
}

function schedule_expire() {
	local seconds="${1}"
	local unit="${2}"
	local script="${3}"

	have systemd-run || return 1
	sudo systemd-run --collect --unit="$unit" \
		--on-active="$seconds" \
		"$script" disable --_from_timer yes >/dev/null
}

function schedule_user_reminder_timer() {
	local seconds="${1}"
	local unit="${2}"
	local script="${3}"

	have systemd-run || return 1
	systemd-run --user --collect --unit="$unit" \
		--on-unit-active="$seconds" \
		"$script" remind --_from_timer yes >/dev/null
}

function schedule_user_one_shot_reminder() {
	local seconds="${1}"
	local unit="${2}"
	local script="${3}"
	local tag="${4}"

	have systemd-run || return 1
	systemd-run --user --collect --unit="$unit" \
		--on-active="$seconds" \
		"$script" remind --tag "$tag" --_from_timer yes >/dev/null
}

function stop_user_unit() {
	local unit="${1}"
	[[ -n "$unit" ]] || return 0
	systemctl --user stop "$unit" >/dev/null 2>&1 || true
	systemctl --user stop "${unit}.timer" >/dev/null 2>&1 || true
}

function stop_system_unit() {
	local unit="${1}"
	[[ -n "$unit" ]] || return 0
	sudo systemctl stop "$unit" >/dev/null 2>&1 || true
	sudo systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
}

# ------------------------------ Checklist ----------------------------------

function cmd_checklist() {
	if ! state_load; then
		printf '%s\n' "No active state file: ${STATE_FILE}"
		printf '%s\n' "Nothing to verify."
		return 0
	fi

	printf '%s\n' "State file: ${STATE_FILE}"
	printf '%s\n' "  ID: ${ID}"
	printf '%s\n' "  Scopes: ${SCOPE_LIST}"
	printf '%s\n' "  Start: $(epoch_to_iso "$START_EPOCH")"
	if [[ "$END_EPOCH" -gt 0 ]]; then
		printf '%s\n' "  End:   $(epoch_to_iso "$END_EPOCH")"
	else
		printf '%s\n' "  End:   (none)"
	fi

	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		if [[ -n "$NFT_TABLE" ]] && nft_table_exists "$NFT_TABLE"; then
			printf '%s\n' "  nft:   table inet ${NFT_TABLE} exists"
		else
			printf '%s\n' "  nft:   expected table missing"
		fi

		if have nmcli && [[ -n "$NM_CONN" && -n "$NM_KEY" ]]; then
			local cur
			cur="$(nm_get_mac_mode "$NM_CONN" "$NM_KEY")"
			printf '%s\n' "  nm:    ${NM_CONN} ${NM_KEY}=${cur:-unknown}"
		fi

		if [[ "$VPN_KIND" == "wg" ]]; then
			printf '%s\n' "  vpn:   wireguard if=${VPN_WG_IF} path=${VPN_PATH}"
		elif [[ "$VPN_KIND" == "ovpn" ]]; then
			printf '%s\n' "  vpn:   openvpn unit=${VPN_UNIT} path=${VPN_PATH}"
		else
			printf '%s\n' "  vpn:   none"
		fi
	fi

	if [[ "$SCOPE_LIST" == *"browser"* ]]; then
		printf '%s\n' "  browser: profile=${BROWSER_PROFILE}"
		if [[ "$BROWSER_PID" -gt 0 ]] && kill -0 "$BROWSER_PID" 2>/dev/null; then
			printf '%s\n' "  browser: pid=${BROWSER_PID} (running)"
		else
			printf '%s\n' "  browser: pid=${BROWSER_PID} (not running)"
		fi
	fi

	if [[ "$REMIND" == "yes" ]]; then
		printf '%s\n' "  remind: unit=${REMIND_UNIT}"
		printf '%s\n' "  remind: thresholds=${THRESH_UNITS}"
	else
		printf '%s\n' "  remind: disabled"
	fi

	if [[ -n "$EXPIRE_UNIT" ]]; then
		printf '%s\n' "  expire: unit=${EXPIRE_UNIT}"
	fi
}

# ------------------------------ Status -------------------------------------

function cmd_status() {
	if ! state_load; then
		printf '%s\n' "inactive"
		return 0
	fi

	local now left
	now="$(now_epoch)"
	if [[ "$END_EPOCH" -gt 0 ]]; then
		left=$((END_EPOCH - now))
	else
		left=-1
	fi

	printf '%s\n' "active"
	printf '%s\n' "id=${ID}"
	printf '%s\n' "scopes=${SCOPE_LIST}"
	printf '%s\n' "persist=${PERSIST_MODE}"
	printf '%s\n' "start=$(epoch_to_iso "$START_EPOCH")"
	if [[ "$END_EPOCH" -gt 0 ]]; then
		printf '%s\n' "end=$(epoch_to_iso "$END_EPOCH")"
		if [[ "$left" -ge 0 ]]; then
			printf '%s\n' "time_left_seconds=${left}"
		else
			printf '%s\n' "time_left_seconds=expired"
		fi
	else
		printf '%s\n' "end=none"
	fi

	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		printf '%s\n' "nft_table=${NFT_TABLE:-none}"
		printf '%s\n' "block_http=${NFT_BLOCK_HTTP}"
		if [[ -n "$NM_CONN" ]]; then
			printf '%s\n' "nm_conn=${NM_CONN}"
			printf '%s\n' "nm_mac_mode_set=${NM_SET_MAC}"
			printf '%s\n' "nm_mac_mode_prev=${NM_PREV_MAC}"
		fi
		if [[ "$VPN_KIND" != "none" ]]; then
			printf '%s\n' "vpn=${VPN_KIND}"
			printf '%s\n' "vpn_path=${VPN_PATH}"
			if [[ "$VPN_KIND" == "wg" ]]; then
				printf '%s\n' "vpn_if=${VPN_WG_IF}"
			else
				printf '%s\n' "vpn_unit=${VPN_UNIT}"
			fi
		else
			printf '%s\n' "vpn=none"
		fi
	fi

	if [[ "$SCOPE_LIST" == *"browser"* ]]; then
		printf '%s\n' "browser_profile=${BROWSER_PROFILE}"
		printf '%s\n' "browser_pid=${BROWSER_PID}"
		printf '%s\n' "browser_trr_uri=${TRR_URI}"
	fi

	printf '%s\n' "remind=${REMIND}"
}

# ------------------------------ Remind -------------------------------------

function cmd_remind() {
	local tag="periodic"
	local from_timer="no"

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--tag)
			tag="${2}"
			shift 2
			;;
		--_from_timer)
			from_timer="${2}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if ! state_load; then
		return 0
	fi
	[[ "$ACTIVE" == "1" ]] || return 0
	[[ "$REMIND" == "yes" ]] || return 0

	local now msg
	now="$(now_epoch)"

	if [[ "$END_EPOCH" -gt 0 ]]; then
		local left=$((END_EPOCH - now))
		if [[ "$left" -le 0 ]]; then
			notify "net-harden" "Hardening appears expired; run: ${PROG} disable"
			return 0
		fi
		msg="Hardening active (tag=${tag}). Ends: $(epoch_to_iso "$END_EPOCH")."
	else
		msg="Hardening active (tag=${tag}). No end time set (manual)."
	fi

	notify "net-harden" "$msg"
}

# ----------------------------- Shell env -----------------------------------

function cmd_shell_env() {
	local mode="enable"
	if [[ $# -gt 0 ]]; then
		case "${1}" in
		--enable) mode="enable" ;;
		--disable) mode="disable" ;;
		*) die "shell-env: expected --enable or --disable" ;;
		esac
	fi

	if [[ "$mode" == "enable" ]]; then
		cat <<'EOF'
# net-harden shell-env (enable)
umask 077
export NET_HARDEN_SHELL=1
export HISTFILE=/dev/null
export HISTSIZE=0
export SAVEHIST=0
EOF
		if [[ -n "${BASH_VERSION:-}" ]]; then
			cat <<'EOF'
set +o history
EOF
		fi
	else
		cat <<'EOF'
# net-harden shell-env (disable)
unset NET_HARDEN_SHELL
unset HISTFILE
unset HISTSIZE
unset SAVEHIST
EOF
		if [[ -n "${BASH_VERSION:-}" ]]; then
			cat <<'EOF'
set -o history
EOF
		fi
	fi
}

# ------------------------------ Browser ------------------------------------

function cmd_browser() {
	local trr_uri="$DEFAULT_TRR_URI"

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--trr-uri)
			trr_uri="${2}"
			shift 2
			;;
		-h | --help)
			show_help
			return 0
			;;
		*) die "browser: unknown option: ${1}" ;;
		esac
	done

	ensure_state_dir
	local id profile pid
	id="$(date +%Y%m%d%H%M%S)-$RANDOM"
	profile="${STATE_DIR}/firefox-profile-${id}"

	firefox_write_userjs "$profile" "$trr_uri"
	pid="$(firefox_launch_profile "$profile")"

	notify "net-harden" "Firefox launched with hardened profile: ${profile}"

	printf '%s\n' "profile=${profile}"
	printf '%s\n' "pid=${pid}"
}

# --------------------------- Enable / Disable -------------------------------

function require_sudo_if_needed() {
	local needs_root="${1}"
	[[ "$needs_root" == "yes" ]] || return 0
	if [[ "$(id -u)" -ne 0 ]]; then
		have sudo || die "sudo required but not found"
		sudo -v
	fi
}

function compute_reminder_interval() {
	# Arg: seconds_left or -1 for manual.
	local left="${1}"
	if [[ "$left" -lt 0 ]]; then
		printf '%s' $((6 * 3600))
		return 0
	fi
	if [[ "$left" -ge $((48 * 3600)) ]]; then
		printf '%s' $((12 * 3600))
	elif [[ "$left" -ge $((12 * 3600)) ]]; then
		printf '%s' $((6 * 3600))
	elif [[ "$left" -ge $((3 * 3600)) ]]; then
		printf '%s' $((1 * 3600))
	elif [[ "$left" -ge $((1 * 3600)) ]]; then
		printf '%s' $((15 * 60))
	else
		printf '%s' $((5 * 60))
	fi
}

function cmd_enable() {
	local scope="$DEFAULT_SCOPE"
	local persist="$DEFAULT_PERSIST"
	local remind="$DEFAULT_REMIND"
	local mac_mode="$DEFAULT_MAC_MODE"
	local conn_name=""
	local block_http="$DEFAULT_BLOCK_HTTP"
	local vpn_wg=""
	local vpn_ovpn=""
	local trr_uri="$DEFAULT_TRR_URI"
	local force="no"
	local log_event_opt="no"
	local duration_s=0
	local until_s=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--scope)
			scope="${2}"
			shift 2
			;;
		--persist)
			persist="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--remind)
			remind="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--mac)
			mac_mode="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--conn)
			conn_name="${2}"
			shift 2
			;;
		--block-http)
			block_http="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--vpn-wg)
			vpn_wg="${2}"
			shift 2
			;;
		--vpn-ovpn)
			vpn_ovpn="${2}"
			shift 2
			;;
		--trr-uri)
			trr_uri="${2}"
			shift 2
			;;
		--for)
			duration_s="$(parse_duration_to_seconds "${2}" 2>/dev/null || true)"
			[[ "$duration_s" -gt 0 ]] || die "invalid --for duration: ${2}"
			shift 2
			;;
		--until)
			until_s="$(parse_until_to_epoch "${2}" 2>/dev/null || true)"
			[[ "$until_s" -gt 0 ]] || die "invalid --until time: ${2}"
			shift 2
			;;
		--force)
			force="yes"
			shift
			;;
		--log-event)
			log_event_opt="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		-h | --help)
			show_help
			return 0
			;;
		*) die "enable: unknown option: ${1}" ;;
		esac
	done

	scope="$(printf '%s' "$scope" | tr 'A-Z' 'a-z')"
	scope="${scope// /}"
	if [[ "$scope" == "all" ]]; then
		scope="network,browser,shell"
	fi

	case "$persist" in
	session | os | manual) ;;
	*) die "invalid --persist: ${persist}" ;;
	esac
	case "$remind" in
	yes | no) ;;
	*) die "invalid --remind: ${remind}" ;;
	esac
	case "$mac_mode" in
	stable | random | preserve) ;;
	*) die "invalid --mac: ${mac_mode}" ;;
	esac
	case "$block_http" in
	yes | no) ;;
	*) die "invalid --block-http: ${block_http}" ;;
	esac
	case "$log_event_opt" in
	yes | no) ;;
	*) die "invalid --log-event: ${log_event_opt}" ;;
	esac

	ensure_state_dir

	if state_exists; then
		if [[ "$force" == "yes" ]]; then
			"${0}" disable --log-event "$log_event_opt" >/dev/null 2>&1 || true
		else
			die "an active configuration exists; use --force or disable first"
		fi
	fi

	ACTIVE="1"
	ID="$(date +%Y%m%d%H%M%S)-$RANDOM"
	START_EPOCH="$(now_epoch)"
	END_EPOCH=0
	SCOPE_LIST="$scope"
	PERSIST_MODE="$persist"
	REMIND="$remind"
	REMIND_UNIT=""
	EXPIRE_UNIT=""
	THRESH_UNITS=""

	NFT_TABLE=""
	NFT_BLOCK_HTTP="$block_http"

	NM_CONN=""
	NM_KEY=""
	NM_PREV_MAC=""
	NM_SET_MAC=""

	VPN_KIND="none"
	VPN_PATH=""
	VPN_UNIT=""
	VPN_WG_IF=""

	BROWSER_PROFILE=""
	BROWSER_PID=0
	TRR_URI="$trr_uri"

	LOG_EVENT="$log_event_opt"

	# Compute end time.
	if [[ "$until_s" -gt 0 && "$duration_s" -gt 0 ]]; then
		die "use only one of --until or --for"
	fi
	if [[ "$until_s" -gt 0 ]]; then
		END_EPOCH="$until_s"
	elif [[ "$duration_s" -gt 0 ]]; then
		END_EPOCH=$((START_EPOCH + duration_s))
	else
		# Safety default: if network scope is included and user did not specify a
		# duration, assume 24h to reduce "forgotten hardening" risk.
		if [[ "$SCOPE_LIST" == *"network"* ]]; then
			END_EPOCH=$((START_EPOCH + DEFAULT_TIMER_SECONDS))
			warn "no --for/--until supplied; defaulting network hardening to 24h"
		fi
	fi

	# Determine if we need root.
	local needs_root="no"
	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		needs_root="yes"
	fi
	if [[ -n "$vpn_wg" || -n "$vpn_ovpn" ]]; then
		needs_root="yes"
	fi
	require_sudo_if_needed "$needs_root"

	# Apply scopes.
	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		if have nft; then
			NFT_TABLE="net_harden_${ID}"
			nft_apply_network_rules "$NFT_TABLE" "$NFT_BLOCK_HTTP"
		else
			warn "nft not found; skipping firewall hardening"
		fi

		if have nmcli && [[ "$mac_mode" != "preserve" ]]; then
			local line conn type key cur
			if [[ -n "$conn_name" ]]; then
				conn="$conn_name"
				type="$(nmcli -g connection.type connection show "$conn" 2>/dev/null ||
					true)"
				line="${conn}:${type}:"
			else
				line="$(nm_pick_active_connection || true)"
				conn="$(printf '%s' "$line" | awk -F: '{print $1}')"
				type="$(printf '%s' "$line" | awk -F: '{print $2}')"
			fi

			key="$(nm_key_for_type "$type")"
			if [[ -n "$conn" && -n "$key" ]]; then
				cur="$(nm_get_mac_mode "$conn" "$key")"
				NM_CONN="$conn"
				NM_KEY="$key"
				NM_PREV_MAC="${cur:-}"
				NM_SET_MAC="$mac_mode"
				nm_set_mac_mode "$conn" "$key" "$mac_mode"
			else
				warn "could not determine NM connection/type for MAC randomization"
			fi
		fi

		if [[ -n "$vpn_wg" && -n "$vpn_ovpn" ]]; then
			die "choose only one VPN option: --vpn-wg or --vpn-ovpn"
		fi
		if [[ -n "$vpn_wg" ]]; then
			VPN_KIND="wg"
			VPN_PATH="$(readlink -f "$vpn_wg" 2>/dev/null || printf '%s' "$vpn_wg")"
			VPN_WG_IF="$(vpn_wg_ifname_from_path "$VPN_PATH")"
			vpn_wg_up "$VPN_PATH"
		elif [[ -n "$vpn_ovpn" ]]; then
			VPN_KIND="ovpn"
			VPN_PATH="$(readlink -f "$vpn_ovpn" 2>/dev/null || printf '%s' "$vpn_ovpn")"
			VPN_UNIT="$(unit_name_safe "net-harden-ovpn-${ID}")"
			vpn_ovpn_up "$VPN_PATH" "$VPN_UNIT"
		fi
	fi

	if [[ "$SCOPE_LIST" == *"browser"* ]]; then
		BROWSER_PROFILE="${STATE_DIR}/firefox-profile-${ID}"
		firefox_write_userjs "$BROWSER_PROFILE" "$TRR_URI"
		BROWSER_PID="$(firefox_launch_profile "$BROWSER_PROFILE")"
	fi

	# Timers: expire (system scope if network involved), reminders (user scope).
	local script_path
	script_path="$(readlink -f "${0}" 2>/dev/null || printf '%s' "${0}")"

	if [[ "$END_EPOCH" -gt 0 ]]; then
		local now left
		now="$(now_epoch)"
		left=$((END_EPOCH - now))
		if [[ "$left" -gt 0 ]]; then
			EXPIRE_UNIT="$(unit_name_safe "net-harden-expire-${ID}")"
			schedule_expire "$left" "$EXPIRE_UNIT" "$script_path" ||
				warn "could not schedule expire timer"
		fi
	fi

	if [[ "$REMIND" == "yes" ]]; then
		local interval left
		if [[ "$END_EPOCH" -gt 0 ]]; then
			left=$((END_EPOCH - START_EPOCH))
		else
			left=-1
		fi
		interval="$(compute_reminder_interval "$left")"
		REMIND_UNIT="$(unit_name_safe "net-harden-remind-${ID}")"
		schedule_user_reminder_timer "$interval" "$REMIND_UNIT" "$script_path" ||
			warn "could not schedule reminder timer"

		if [[ "$END_EPOCH" -gt 0 ]]; then
			local total=$((END_EPOCH - START_EPOCH))
			local t1=$((total - 3600))
			local t2=$((total - 600))
			local t3=$((total - 60))

			if [[ "$t1" -gt 0 ]]; then
				local u1
				u1="$(unit_name_safe "net-harden-thresh1-${ID}")"
				schedule_user_one_shot_reminder "$t1" "$u1" "$script_path" "1h" ||
					true
				THRESH_UNITS="${THRESH_UNITS}${u1} "
			fi
			if [[ "$t2" -gt 0 ]]; then
				local u2
				u2="$(unit_name_safe "net-harden-thresh2-${ID}")"
				schedule_user_one_shot_reminder "$t2" "$u2" "$script_path" "10m" ||
					true
				THRESH_UNITS="${THRESH_UNITS}${u2} "
			fi
			if [[ "$t3" -gt 0 ]]; then
				local u3
				u3="$(unit_name_safe "net-harden-thresh3-${ID}")"
				schedule_user_one_shot_reminder "$t3" "$u3" "$script_path" "1m" ||
					true
				THRESH_UNITS="${THRESH_UNITS}${u3} "
			fi
			THRESH_UNITS="${THRESH_UNITS%" "}"
		fi
	fi

	state_save
	log_event "enable id=${ID} scopes=${SCOPE_LIST} persist=${PERSIST_MODE}"

	if [[ "$SCOPE_LIST" == *"browser"* ]]; then
		notify "net-harden" "Enabled (ID=${ID}). Firefox PID=${BROWSER_PID}."
	else
		notify "net-harden" "Enabled (ID=${ID}). Scopes=${SCOPE_LIST}."
	fi

	"${0}" status
}

function cmd_disable() {
	local kill_browser="no"
	local reconnect="no"
	local from_timer="no"
	local log_event_opt="no"

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--kill-browser)
			kill_browser="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--reconnect)
			reconnect="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		--_from_timer)
			from_timer="${2}"
			shift 2
			;;
		--log-event)
			log_event_opt="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
			shift 2
			;;
		-h | --help)
			show_help
			return 0
			;;
		*) die "disable: unknown option: ${1}" ;;
		esac
	done

	if ! state_load; then
		printf '%s\n' "inactive"
		return 0
	fi

	if [[ "$log_event_opt" == "yes" ]]; then
		LOG_EVENT="yes"
	elif [[ "$log_event_opt" == "no" ]]; then
		LOG_EVENT="${LOG_EVENT:-no}"
	fi

	local needs_root="no"
	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		needs_root="yes"
	fi
	require_sudo_if_needed "$needs_root"

	# Stop timers first to avoid race-y notifications.
	stop_user_unit "$REMIND_UNIT"
	if [[ -n "$THRESH_UNITS" ]]; then
		local u
		for u in "$THRESH_UNITS"; do
			stop_user_unit "$u"
		done
	fi
	stop_system_unit "$EXPIRE_UNIT"

	if [[ "$SCOPE_LIST" == *"network"* ]]; then
		if [[ -n "$NFT_TABLE" ]]; then
			nft_remove_network_rules "$NFT_TABLE"
		fi

		if [[ "$VPN_KIND" == "wg" ]]; then
			if [[ -n "$VPN_WG_IF" ]]; then
				vpn_wg_down "$VPN_WG_IF"
			fi
		elif [[ "$VPN_KIND" == "ovpn" ]]; then
			vpn_ovpn_down "$VPN_UNIT"
		fi

		if have nmcli && [[ -n "$NM_CONN" && -n "$NM_KEY" ]]; then
			if [[ -n "$NM_PREV_MAC" ]]; then
				nm_set_mac_mode "$NM_CONN" "$NM_KEY" "$NM_PREV_MAC"
			else
				nm_set_mac_mode "$NM_CONN" "$NM_KEY" ""
			fi
			if [[ "$reconnect" == "yes" ]] && nm_conn_is_active "$NM_CONN"; then
				nm_reconnect_conn "$NM_CONN"
			fi
		fi
	fi

	if [[ "$SCOPE_LIST" == *"browser"* ]]; then
		if [[ "$kill_browser" == "yes" && "$BROWSER_PID" -gt 0 ]]; then
			kill "$BROWSER_PID" >/dev/null 2>&1 || true
		fi
		if [[ -n "$BROWSER_PROFILE" ]]; then
			if [[ "$BROWSER_PID" -gt 0 ]] && kill -0 "$BROWSER_PID" 2>/dev/null; then
				warn "Firefox still running; leaving profile directory in place"
			else
				rm -rf "$BROWSER_PROFILE" 2>/dev/null || true
			fi
		fi
	fi

	log_event "disable id=${ID} scopes=${SCOPE_LIST} from_timer=${from_timer}"
	state_clear
	notify "net-harden" "Disabled."
	printf '%s\n' "inactive"
}

# -------------------------------- Main -------------------------------------

function main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	help | -h | --help) show_help ;;
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	status) cmd_status ;;
	checklist) cmd_checklist ;;
	remind) cmd_remind "$@" ;;
	browser) cmd_browser "$@" ;;
	shell-env) cmd_shell_env "$@" ;;
	*) die "unknown command: ${cmd} (try: ${PROG} help)" ;;
	esac
}

main "$@"
