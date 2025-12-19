#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ovpn-guard
#
# A "religious-usecase" OpenVPN launcher + kill-switch:
#   - Starts OpenVPN as a managed transient systemd unit.
#   - Applies an nftables kill-switch so *only* VPN traffic can leave your host.
#   - Optionally allows local LAN ranges (default: yes) to reduce breakage.
#   - Optionally enables NetworkManager MAC randomization on the active profile.
#   - Fully reversible via: ovpn-guard down
#
# Why this exists:
#   - On open/unknown Wi-Fi, the only major privacy upgrade is a VPN.
#   - A kill-switch prevents accidental traffic leaks if the VPN drops.
#
# Security posture:
#   - Output chain is policy DROP (strict).
#   - Input is minimally hardened by dropping NEW inbound TCP SYN.
#   - This script avoids global proxy hacks and avoids persistent system config.
#
# Install:
#   sudo install -m 0755 ovpn-guard /usr/local/bin/ovpn-guard
#
# Packages (Arch hints):
#   openvpn, nftables, iproute2, systemd, sudo
#   optional: networkmanager (nmcli), libnotify (notify-send)
# ---------------------------------------------------------------------------

set -euo pipefail

readonly PROG="ovpn-guard"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROG}"
readonly STATE_FILE="${STATE_DIR}/state.env"

readonly DEFAULT_ALLOW_LAN="yes"   # yes|no
readonly DEFAULT_MAC_MODE="stable" # stable|random|preserve
readonly DEFAULT_WAIT_SECS=20

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

function ensure_state_dir() {
	mkdir -p "$STATE_DIR"
	chmod 700 "$STATE_DIR" 2>/dev/null || true
}

function now_epoch() {
	date +%s
}

function iso_now() {
	date -Iseconds
}

function boot_id() {
	if [[ -r /proc/sys/kernel/random/boot_id ]]; then
		cat /proc/sys/kernel/random/boot_id
	else
		printf '%s' "unknown"
	fi
}

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

function arch_pkg_hint_for_cmd() {
	local cmd="${1}"
	case "$cmd" in
	openvpn) printf '%s' "openvpn" ;;
	nft) printf '%s' "nftables" ;;
	ip) printf '%s' "iproute2" ;;
	systemd-run | systemctl) printf '%s' "systemd" ;;
	sudo) printf '%s' "sudo" ;;
	nmcli) printf '%s' "networkmanager" ;;
	notify-send) printf '%s' "libnotify" ;;
	getent) printf '%s' "glibc" ;;
	*) printf '%s' "" ;;
	esac
}

function require_cmd() {
	local cmd="${1}"
	if have "$cmd"; then
		return 0
	fi
	local hint
	hint="$(arch_pkg_hint_for_cmd "$cmd")"
	if [[ -n "$hint" ]]; then
		die "missing '${cmd}' (Arch package hint: ${hint})"
	fi
	die "missing '${cmd}'"
}

function require_sudo() {
	require_cmd sudo
	sudo -v
}

# ------------------------------- Help --------------------------------------

function show_help() {
	cat <<'EOF'
ovpn-guard

Usage:
  ovpn-guard up /path/to/client.ovpn [OPTIONS]
  ovpn-guard down
  ovpn-guard status
  ovpn-guard logs
  ovpn-guard deps
  ovpn-guard help

Options (kept intentionally minimal):
  --allow-lan yes|no
      Default: yes
      If yes, allows outbound traffic to RFC1918 + link-local ranges outside
      the VPN. This reduces breakage (printers/intranet), but those LAN flows
      are not tunneled.

  --mac stable|random|preserve
      Default: stable
      If nmcli is present, sets MAC mode on the active NetworkManager profile.
      'preserve' skips any MAC changes.

  --conn NAME
      NetworkManager connection profile name (default: auto-detect active).

  --wait SECONDS
      Default: 20
      Wait time for the VPN interface to appear before arming the kill-switch.

  --force
      If active state exists, run 'down' first.

What it does:
  - Starts OpenVPN as a transient systemd unit:
      sudo systemd-run --collect --unit=<unit> openvpn --config <cfg>
  - Creates an nftables table with:
      * input: drop NEW inbound TCP SYN (minimal hardening)
      * output: policy drop; allow only:
          - loopback
          - established/related
          - VPN interface (tun/tap)
          - VPN server IP:port over the physical interface
          - optional LAN ranges (if --allow-lan yes)
          - DHCP client traffic (UDP dport 67, plus DHCP reply)

How to use safely:
  - 'up' arms a kill-switch. If the VPN fails to come up, your outbound traffic
    will be restricted. Run 'down' to fully revert.

EOF
}

# ------------------------------- State -------------------------------------

function state_exists() {
	[[ -f "$STATE_FILE" ]]
}

function state_write_kv() {
	printf '%s=%q\n' "${1}" "${2}" >>"$STATE_FILE"
}

function state_save() {
	ensure_state_dir
	: >"$STATE_FILE"
	chmod 600 "$STATE_FILE" 2>/dev/null || true

	state_write_kv "ACTIVE" "$ACTIVE"
	state_write_kv "ID" "$ID"
	state_write_kv "STATE_BOOT_ID" "$STATE_BOOT_ID"
	state_write_kv "START_EPOCH" "$START_EPOCH"

	state_write_kv "UNIT" "$UNIT"
	state_write_kv "NFT_TABLE" "$NFT_TABLE"

	state_write_kv "CFG_ORIG" "$CFG_ORIG"
	state_write_kv "CFG_TMP" "$CFG_TMP"

	state_write_kv "REMOTE_HOST" "$REMOTE_HOST"
	state_write_kv "REMOTE_IP" "$REMOTE_IP"
	state_write_kv "REMOTE_PORT" "$REMOTE_PORT"
	state_write_kv "REMOTE_PROTO" "$REMOTE_PROTO"
	state_write_kv "PHY_IF" "$PHY_IF"

	state_write_kv "VPN_IF" "$VPN_IF"
	state_write_kv "ALLOW_LAN" "$ALLOW_LAN"

	state_write_kv "NM_CONN" "$NM_CONN"
	state_write_kv "NM_KEY" "$NM_KEY"
	state_write_kv "NM_PREV_MAC" "$NM_PREV_MAC"
	state_write_kv "NM_SET_MAC" "$NM_SET_MAC"
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

function state_clear() {
	rm -f "$STATE_FILE"
}

function state_is_stale_boot() {
	local cur
	cur="$(boot_id)"
	[[ "${STATE_BOOT_ID:-}" != "$cur" ]]
}

# ------------------------ NetworkManager helpers ---------------------------

function nm_pick_active_connection() {
	nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
		awk -F: '
        $2=="wifi" { print; exit }
        { if (!first) { first=$0 } }
        END { if (first) print first }
      '
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

# ---------------------------- OpenVPN parse --------------------------------

function ovpn_strip_comments() {
	# Remove trailing comments beginning with ';' or '#', preserving leading text.
	sed -E 's/[[:space:]]*[;#].*$//'
}

function ovpn_first_value() {
	# Usage: ovpn_first_value <keyword> <file>
	local key="${1}"
	local file="${2}"
	awk -v k="$key" '
    BEGIN { IGNORECASE=1 }
    {
      line=$0
      sub(/^[ \t]+/, "", line)
      if (tolower(substr(line, 1, length(k))) == tolower(k)) {
        sub(/^[^ \t]+[ \t]+/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

function ovpn_count_remote() {
	local file="${1}"
	awk '
    BEGIN { c=0; IGNORECASE=1 }
    {
      line=$0
      sub(/^[ \t]+/, "", line)
      if (tolower(substr(line, 1, 6)) == "remote") c++
    }
    END { print c }
  ' "$file"
}

function ovpn_parse_remote() {
	# Extract first "remote host port" from config, ignoring comments/blank lines.
	local file="${1}"
	local out
	out="$(
		ovpn_strip_comments <"$file" |
			awk '
          BEGIN { IGNORECASE=1 }
          {
            line=$0
            sub(/^[ \t]+/, "", line)
            if (line=="") next
            split(line, a, /[ \t]+/)
            if (tolower(a[1])=="remote") {
              host=a[2]
              port=a[3]
              if (port=="") port="1194"
              print host, port
              exit
            }
          }
        '
	)"
	[[ -n "$out" ]] || return 1
	printf '%s\n' "$out"
}

function ovpn_parse_proto() {
	local file="${1}"
	local proto
	proto="$(
		ovpn_strip_comments <"$file" |
			awk '
          BEGIN { IGNORECASE=1 }
          {
            line=$0
            sub(/^[ \t]+/, "", line)
            if (line=="") next
            split(line, a, /[ \t]+/)
            if (tolower(a[1])=="proto") {
              p=tolower(a[2])
              if (p=="tcp-client") p="tcp"
              print p
              exit
            }
          }
        '
	)"
	if [[ -z "$proto" ]]; then
		proto="udp"
	fi
	case "$proto" in
	udp | tcp) printf '%s' "$proto" ;;
	*)
		warn "unknown proto '${proto}', defaulting to udp"
		printf '%s' "udp"
		;;
	esac
}

function resolve_to_ipv4() {
	local host="${1}"
	if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		printf '%s' "$host"
		return 0
	fi
	require_cmd getent
	getent ahostsv4 "$host" 2>/dev/null |
		awk '{print $1; exit}'
}

function ovpn_make_temp_config() {
	# Replace ALL remote lines after the first with comments, and replace the first
	# remote host with an IP to avoid later DNS dependence.
	local src="${1}"
	local dst="${2}"
	local ip="${3}"
	local port="${4}"

	local seen=0
	awk -v ip="$ip" -v port="$port" '
    BEGIN { IGNORECASE=1 }
    {
      raw=$0
      line=$0
      sub(/^[ \t]+/, "", line)

      # Preserve pure comment lines.
      if (line ~ /^[;#]/) { print raw; next }

      # Identify directive token.
      split(line, a, /[ \t]+/)
      if (tolower(a[1])=="remote") {
        seen++
        if (seen==1) {
          # Emit a deterministic remote using the resolved IP.
          # We comment the original remote line for traceability.
          print "; ovpn-guard: original remote was: " raw
          print "remote " ip " " port
        } else {
          print "; ovpn-guard: disabled extra remote: " raw
        }
        next
      }

      print raw
    }
  ' "$src" >"$dst"
}

function guess_vpn_if() {
	# Try to determine the tun/tap interface OpenVPN will use.
	# 1) If config contains "dev tun0" or "dev tap1", use it.
	# 2) If config says "dev tun" or empty, we will detect after start.
	local file="${1}"
	local dev
	dev="$(
		ovpn_strip_comments <"$file" |
			awk '
          BEGIN { IGNORECASE=1 }
          {
            line=$0
            sub(/^[ \t]+/, "", line)
            if (line=="") next
            split(line, a, /[ \t]+/)
            if (tolower(a[1])=="dev") {
              print a[2]
              exit
            }
          }
        '
	)"
	if [[ -z "$dev" ]]; then
		printf '%s' ""
		return 0
	fi
	if [[ "$dev" == "tun" || "$dev" == "tap" ]]; then
		printf '%s' ""
		return 0
	fi
	printf '%s' "$dev"
}

function wait_for_vpn_if() {
	# Wait for an interface to appear. Prefer an expected name; else first tun/tap.
	local expect="${1}"
	local secs="${2}"

	local deadline t
	deadline=$(($(now_epoch) + secs))

	while :; do
		if [[ -n "$expect" ]]; then
			if ip link show dev "$expect" >/dev/null 2>&1; then
				printf '%s' "$expect"
				return 0
			fi
		else
			t="$(
				ip -brief link 2>/dev/null |
					awk '{print $1}' |
					awk '
              $1 ~ /^tun[0-9]+$/ { print; exit }
              $1 ~ /^tap[0-9]+$/ { print; exit }
            '
			)"
			if [[ -n "$t" ]]; then
				printf '%s' "$t"
				return 0
			fi
		fi

		if [[ "$(now_epoch)" -ge "$deadline" ]]; then
			return 1
		fi
		sleep 0.25
	done
}

# ------------------------------ Routing ------------------------------------

function route_get_dev() {
	local ipaddr="${1}"
	ip -4 route get "$ipaddr" 2>/dev/null |
		awk '
        {
          for (i=1;i<=NF;i++) {
            if ($i=="dev") { print $(i+1); exit }
          }
        }
      '
}

# ------------------------------ nftables -----------------------------------

function nft_table_exists() {
	local tbl="${1}"
	sudo nft list table inet "$tbl" >/dev/null 2>&1
}

function nft_remove_table() {
	local tbl="${1}"
	if nft_table_exists "$tbl"; then
		sudo nft delete table inet "$tbl" >/dev/null
	fi
}

function nft_apply_killswitch() {
	local tbl="${1}"
	local vpn_if="${2}"
	local phy_if="${3}"
	local proto="${4}" # udp|tcp
	local remote_ip="${5}"
	local remote_port="${6}"
	local allow_lan="${7}" # yes|no

	sudo nft add table inet "$tbl"

	# Input: minimal hardening, low breakage.
	sudo nft "add chain inet ${tbl} input { type filter hook input priority -110; policy accept; }"
	sudo nft "add rule inet ${tbl} input iifname lo accept"
	sudo nft "add rule inet ${tbl} input ct state established,related accept"
	sudo nft "add rule inet ${tbl} input meta l4proto tcp tcp flags syn \
    ct state new drop"
	sudo nft "add rule inet ${tbl} input udp sport 67 udp dport 68 accept"

	# Output: strict kill-switch.
	sudo nft "add chain inet ${tbl} output { type filter hook output priority -110; policy drop; }"
	sudo nft "add rule inet ${tbl} output oifname lo accept"
	sudo nft "add rule inet ${tbl} output ct state established,related accept"

	# Always allow traffic through the VPN interface.
	sudo nft "add rule inet ${tbl} output oifname \"${vpn_if}\" accept"

	# Allow the OpenVPN transport flow to the VPN server via the physical IF.
	if [[ "$proto" == "udp" ]]; then
		sudo nft "add rule inet ${tbl} output oifname \"${phy_if}\" \
      ip daddr ${remote_ip} udp dport ${remote_port} accept"
	else
		sudo nft "add rule inet ${tbl} output oifname \"${phy_if}\" \
      ip daddr ${remote_ip} tcp dport ${remote_port} accept"
	fi

	# Allow DHCP client traffic (for renewals) even while strict.
	sudo nft "add rule inet ${tbl} output udp dport 67 accept"

	# Optional: allow local LAN ranges outside VPN to reduce breakage.
	if [[ "$allow_lan" == "yes" ]]; then
		sudo nft "add rule inet ${tbl} output ip daddr { \
      10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept"
		sudo nft "add rule inet ${tbl} output ip6 daddr { \
      fc00::/7, fe80::/10 } accept"
	fi
}

# ------------------------------ systemd ------------------------------------

function unit_name_safe() {
	printf '%s' "${1}" | tr -c 'a-zA-Z0-9_.@-' '_'
}

function ovpn_start_unit() {
	local unit="${1}"
	local cfg="${2}"
	sudo systemd-run --collect --unit="$unit" \
		--property=Restart=on-failure \
		openvpn --config "$cfg" --auth-nocache >/dev/null
}

function ovpn_stop_unit() {
	local unit="${1}"
	sudo systemctl stop "$unit" >/dev/null 2>&1 || true
}

# ----------------------------- Deps command --------------------------------

function cmd_deps() {
	local cmds=(
		bash date sed awk grep
		sudo ip nft getent
		systemd-run systemctl
		openvpn
	)
	local opt=(nmcli notify-send)

	printf '%s\n' "Required commands:"
	local c
	for c in "${cmds[@]}"; do
		if have "$c"; then
			printf '  - %-12s : present\n' "$c"
		else
			local hint
			hint="$(arch_pkg_hint_for_cmd "$c")"
			if [[ -n "$hint" ]]; then
				printf '  - %-12s : missing (Arch package: %s)\n' "$c" "$hint"
			else
				printf '  - %-12s : missing\n' "$c"
			fi
		fi
	done

	printf '\n%s\n' "Optional commands:"
	for c in "${opt[@]}"; do
		if have "$c"; then
			printf '  - %-12s : present\n' "$c"
		else
			local hint
			hint="$(arch_pkg_hint_for_cmd "$c")"
			if [[ -n "$hint" ]]; then
				printf '  - %-12s : missing (Arch package: %s)\n' "$c" "$hint"
			else
				printf '  - %-12s : missing\n' "$c"
			fi
		fi
	done
}

# ------------------------------ Status -------------------------------------

function cmd_status() {
	if ! state_load; then
		printf '%s\n' "inactive"
		return 0
	fi

	if state_is_stale_boot; then
		printf '%s\n' "inactive (stale state from prior boot; consider 'down')"
		return 0
	fi

	printf '%s\n' "active"
	printf '%s\n' "id=${ID}"
	printf '%s\n' "unit=${UNIT}"
	printf '%s\n' "nft_table=${NFT_TABLE}"
	printf '%s\n' "vpn_if=${VPN_IF}"
	printf '%s\n' "phy_if=${PHY_IF}"
	printf '%s\n' "remote=${REMOTE_IP}:${REMOTE_PORT}/${REMOTE_PROTO}"
	printf '%s\n' "allow_lan=${ALLOW_LAN}"
}

function cmd_logs() {
	if ! state_load; then
		die "inactive"
	fi
	sudo journalctl -u "$UNIT" -e --no-pager
}

# ------------------------------- Up / Down ---------------------------------

function cmd_up() {
	local cfg=""
	local allow_lan="$DEFAULT_ALLOW_LAN"
	local mac_mode="$DEFAULT_MAC_MODE"
	local conn_name=""
	local wait_secs="$DEFAULT_WAIT_SECS"
	local force="no"

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		--allow-lan)
			allow_lan="$(printf '%s' "${2}" | tr 'A-Z' 'a-z')"
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
		--wait)
			wait_secs="${2}"
			shift 2
			;;
		--force)
			force="yes"
			shift
			;;
		-h | --help)
			show_help
			return 0
			;;
		*)
			if [[ -z "$cfg" ]]; then
				cfg="${1}"
				shift
			else
				die "unexpected argument: ${1}"
			fi
			;;
		esac
	done

	[[ -n "$cfg" ]] || die "missing .ovpn path (try: ${PROG} help)"
	[[ -r "$cfg" ]] || die "cannot read: ${cfg}"

	case "$allow_lan" in yes | no) ;; *) die "invalid --allow-lan: ${allow_lan}" ;; esac
	case "$mac_mode" in stable | random | preserve) ;; *) die "invalid --mac: ${mac_mode}" ;; esac
	[[ "$wait_secs" =~ ^[0-9]+$ ]] || die "invalid --wait: ${wait_secs}"

	ensure_state_dir

	if state_exists; then
		if [[ "$force" == "yes" ]]; then
			"${0}" down || true
		else
			die "already active; run '${PROG} down' or use --force"
		fi
	fi

	require_cmd ip
	require_cmd nft
	require_cmd openvpn
	require_cmd systemd-run
	require_cmd systemctl
	require_cmd sed
	require_cmd awk
	require_cmd getent
	require_sudo

	# Parse config: remote + proto.
	local remote_line
	remote_line="$(ovpn_parse_remote "$cfg")" || die "no 'remote' in config"
	REMOTE_HOST="$(printf '%s' "$remote_line" | awk '{print $1}')"
	REMOTE_PORT="$(printf '%s' "$remote_line" | awk '{print $2}')"
	REMOTE_PROTO="$(ovpn_parse_proto "$cfg")"

	REMOTE_IP="$(resolve_to_ipv4 "$REMOTE_HOST")"
	[[ -n "$REMOTE_IP" ]] || die "failed to resolve remote host: ${REMOTE_HOST}"

	# Determine physical interface to reach the VPN server (pre-VPN route).
	PHY_IF="$(route_get_dev "$REMOTE_IP")"
	[[ -n "$PHY_IF" ]] || die "could not determine egress device to ${REMOTE_IP}"

	# NetworkManager MAC randomization (optional, low-risk).
	NM_CONN=""
	NM_KEY=""
	NM_PREV_MAC=""
	NM_SET_MAC=""

	if have nmcli && [[ "$mac_mode" != "preserve" ]]; then
		local line conn type key cur
		if [[ -n "$conn_name" ]]; then
			conn="$conn_name"
			type="$(nmcli -g connection.type connection show "$conn" 2>/dev/null ||
				true)"
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
			warn "nmcli present but could not detect connection/type; skipping MAC"
		fi
	fi

	# Create a temp config that uses the resolved IP and disables extra remotes.
	ID="$(date +%Y%m%d%H%M%S)-$RANDOM"
	STATE_BOOT_ID="$(boot_id)"
	START_EPOCH="$(now_epoch)"
	CFG_ORIG="$(readlink -f "$cfg" 2>/dev/null || printf '%s' "$cfg")"
	CFG_TMP="${STATE_DIR}/client-${ID}.ovpn"

	local remote_count
	remote_count="$(ovpn_count_remote "$CFG_ORIG")"
	if [[ "$remote_count" -gt 1 ]]; then
		warn "config has ${remote_count} remote entries; using only the first"
	fi

	ovpn_make_temp_config "$CFG_ORIG" "$CFG_TMP" "$REMOTE_IP" "$REMOTE_PORT"

	# Start OpenVPN unit.
	UNIT="$(unit_name_safe "ovpn-guard-${ID}")"
	ovpn_start_unit "$UNIT" "$CFG_TMP"

	# Determine VPN interface.
	local expected_if
	expected_if="$(guess_vpn_if "$CFG_TMP")" || expected_if=""

	VPN_IF="$(wait_for_vpn_if "$expected_if" "$wait_secs")" ||
		die "VPN interface did not appear within ${wait_secs}s (see logs)"

	# Arm kill-switch + inbound hardening.
	NFT_TABLE="ovpn_guard_${ID}"
	nft_apply_killswitch "$NFT_TABLE" "$VPN_IF" "$PHY_IF" \
		"$REMOTE_PROTO" "$REMOTE_IP" "$REMOTE_PORT" "$allow_lan"

	# Persist state.
	ACTIVE="1"
	ALLOW_LAN="$allow_lan"
	state_save

	notify "ovpn-guard" "Up: unit=${UNIT}, if=${VPN_IF}, kill-switch armed."
	"${0}" status
}

function cmd_down() {
	if ! state_load; then
		printf '%s\n' "inactive"
		return 0
	fi

	require_sudo

	# Undo kill-switch first, then stop VPN.
	if [[ -n "${NFT_TABLE:-}" ]]; then
		nft_remove_table "$NFT_TABLE" || true
	fi

	if [[ -n "${UNIT:-}" ]]; then
		ovpn_stop_unit "$UNIT"
	fi

	# Restore MAC mode if we changed it.
	if have nmcli && [[ -n "${NM_CONN:-}" && -n "${NM_KEY:-}" ]]; then
		if [[ -n "${NM_PREV_MAC:-}" ]]; then
			nm_set_mac_mode "$NM_CONN" "$NM_KEY" "$NM_PREV_MAC" || true
		else
			nm_set_mac_mode "$NM_CONN" "$NM_KEY" "" || true
		fi
	fi

	# Remove temp config.
	if [[ -n "${CFG_TMP:-}" ]]; then
		rm -f "$CFG_TMP" 2>/dev/null || true
	fi

	state_clear
	notify "ovpn-guard" "Down: reverted (VPN stopped, kill-switch removed)."
	printf '%s\n' "inactive"
}

# -------------------------------- Main -------------------------------------

function main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	help | -h | --help) show_help ;;
	deps) cmd_deps ;;
	up) cmd_up "$@" ;;
	down) cmd_down ;;
	status) cmd_status ;;
	logs) cmd_logs ;;
	*) die "unknown command: ${cmd} (try: ${PROG} help)" ;;
	esac
}

main "$@"
