#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tor-arch-privacy.sh
#
# Arch Linux Tor privacy controller:
#   - installs Tor/torsocks/nftables/macchanger support packages
#   - writes a managed Tor client configuration block
#   - provides session-only or persistent activation
#   - optionally loads a reversible nftables Tor kill-switch
#   - optionally enables NetworkManager MAC randomisation
#   - optionally installs a shell-level LC_TIME/date-display randomiser
#   - performs preflight checks, activation verification, and doctor reports
#
# This is not a replacement for Tor Browser. Browser fingerprinting is mostly
# solved at the browser profile level, not by system-wide Tor routing alone.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly SELF_NAME="${0##*/}"
readonly INSTALL_BIN="/usr/local/bin/tor-privacy"
readonly TW_BIN="/usr/local/bin/tw"

readonly TORRC="/etc/tor/torrc"
readonly TOR_BLOCK_BEGIN="# >>> tor-privacy managed block >>>"
readonly TOR_BLOCK_END="# <<< tor-privacy managed block <<<"

readonly NFT_RULES="/etc/tor/tor-privacy.nft"
readonly NFT_UNIT="/etc/systemd/system/tor-privacy-nft.service"
readonly NM_MAC_CONF="/etc/NetworkManager/conf.d/90-tor-privacy-mac.conf"
readonly FP_PROFILE="/etc/profile.d/90-tor-privacy-session-random.sh"

readonly TOR_SOCKS_PORT="9050"
readonly TOR_TRANS_PORT="9040"
readonly TOR_DNS_PORT="5353"
readonly TOR_CONTROL_PORT="9051"
readonly TOR_CHECK_URL="https://check.torproject.org/api/ip"
readonly TOR_FALLBACK_IP_URL="https://ifconfig.io/ip"

# -----------------------------------------------------------------------------
# CLI help
# -----------------------------------------------------------------------------
function usage() {
  cat <<'EOF'
tor-privacy — Arch Linux Tor privacy installer/controller

Usage
  sudo ./tor-arch-privacy.sh install [--killswitch] [--mac-random] [--fp-random]
  sudo tor-privacy on --session [--killswitch]
  sudo tor-privacy on --persist  [--killswitch]
  sudo tor-privacy off [--keep-tor]
  tor-privacy status
  tor-privacy doctor [--online] [--strict]
  tor-privacy check
  tor-privacy ip
  sudo tor-privacy mac-on
  sudo tor-privacy mac-off
  sudo tor-privacy mac-rotate --iface IFACE
  sudo tor-privacy fp-on
  sudo tor-privacy fp-off
  sudo tor-privacy uninstall [--purge]

Modes
  off / deactivated
      Removes the tor-privacy nftables table and stops/disables the managed
      Tor services unless --keep-tor is passed.

  on --session
      Starts Tor now. If --killswitch is passed, loads nftables rules now.
      Does not enable persistence, so state is lost at reboot/poweroff.

  on --persist
      Enables Tor and, when --killswitch is passed, the nftables kill-switch
      after reboot.

Options
  --killswitch
      Load or persist nftables rules that redirect normal TCP and DNS through
      Tor and block non-Tor egress. IPv6 egress is blocked in this mode.

  --mac-random
      Write a NetworkManager drop-in enabling Wi-Fi scan randomisation and
      random cloned MAC addresses for Wi-Fi/Ethernet connections.

  --fp-random
      Install a conservative interactive-shell randomiser for LC_TIME/date
      display. Keyboard layout changes are opt-in through
      TOR_PRIVACY_RANDOM_XKB=1 because changing layout blindly can lock you out
      or corrupt muscle memory.

Examples
  sudo ./tor-arch-privacy.sh install --killswitch --mac-random
  sudo tor-privacy on --session --killswitch
  sudo tor-privacy on --persist --killswitch
  sudo tor-privacy off
  tor-privacy status
  tor-privacy doctor --online
  tor-privacy check
  tor-privacy ip
  sudo tor-privacy mac-rotate --iface wlan0
EOF
}

# -----------------------------------------------------------------------------
# Printing and error handling
# -----------------------------------------------------------------------------
function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function info() {
  printf '==> %s\n' "$*"
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function is_root() {
  [[ "${EUID}" -eq 0 ]]
}

function torrc_has_managed_block() {
  [[ -r "${TORRC}" ]] \
    && grep -qxF "${TOR_BLOCK_BEGIN}" "${TORRC}" \
    && grep -qxF "${TOR_BLOCK_END}" "${TORRC}"
}

function port_listening_tcp() {
  local port="$1"
  have ss || return 1
  ss -ltnH 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p"$" || $4 ~ p"\\]$" { found = 1 }
        END { exit(found ? 0 : 1) }'
}

function port_listening_udp() {
  local port="$1"
  have ss || return 1
  ss -lunH 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p"$" || $4 ~ p"\\]$" { found = 1 }
        END { exit(found ? 0 : 1) }'
}

function tor_config_valid() {
  have tor || return 1
  [[ -r "${TORRC}" ]] || return 1
  tor --verify-config -f "${TORRC}" >/dev/null 2>&1
}

function nft_rules_valid() {
  have nft || return 1
  [[ -r "${NFT_RULES}" ]] || return 1

  if ! is_root; then
    return 2
  fi

  nft -c -f "${NFT_RULES}" >/dev/null 2>&1
}

function tor_socks_confirmed() {
  have curl || return 1
  curl --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" \
    --max-time 30 -fsS "${TOR_CHECK_URL}" 2>/dev/null \
    | grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true'
}

function transparent_tor_confirmed() {
  have curl || return 1
  curl -4 --max-time 30 -fsS "${TOR_CHECK_URL}" 2>/dev/null \
    | grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true'
}

function ipv6_egress_blocked_or_absent() {
  have curl || return 1
  ! curl -6 --max-time 10 -fsS "${TOR_FALLBACK_IP_URL}" >/dev/null 2>&1
}

function direct_tor_ip() {
  curl -4 --max-time 30 -fsS "${TOR_FALLBACK_IP_URL}" 2>/dev/null || true
}

function socks_tor_ip() {
  curl --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" \
    --max-time 30 -fsS "${TOR_FALLBACK_IP_URL}" 2>/dev/null || true
}

function require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "this command must be run as root; use sudo"
  fi
}

function require_arch() {
  if [[ ! -r /etc/arch-release ]]; then
    die "this script is intentionally Arch Linux-specific"
  fi
}

function require_core_commands() {
  local -a missing=()
  local cmd

  for cmd in systemctl pacman awk grep sed mktemp install chmod id; do
    have "${cmd}" || missing+=("${cmd}")
  done

  if (( ${#missing[@]} > 0 )); then
    die "missing required command(s): ${missing[*]}"
  fi
}

function preflight_base() {
  require_arch
  require_core_commands

  [[ -d /run/systemd/system ]] \
    || die "systemd does not appear to be running"
}

function validate_written_config() {
  if ! torrc_has_managed_block; then
    die "managed Tor block was not found in ${TORRC}"
  fi

  if ! tor_config_valid; then
    die "Tor rejected ${TORRC}; inspect: sudo tor --verify-config -f ${TORRC}"
  fi

  if [[ -f "${NFT_RULES}" ]]; then
    if nft_rules_valid; then
      :
    else
      local nft_status="$?"
      case "${nft_status}" in
        2)
          warn "nft syntax check skipped because this process is not root"
          ;;
        *)
          die "nftables rejected ${NFT_RULES}; inspect: sudo nft -c -f ${NFT_RULES}"
          ;;
      esac
    fi
  fi
}

function verify_activation() {
  local require_killswitch="${1:-no}"

  unit_active tor.service \
    || die "tor.service is not active after activation"
  port_listening_tcp "${TOR_SOCKS_PORT}" \
    || die "Tor SOCKS port ${TOR_SOCKS_PORT} is not listening"

  if [[ "${require_killswitch}" == "yes" ]]; then
    nft_tables_loaded \
      || die "kill-switch requested, but tor-privacy nftables tables are absent"
    port_listening_tcp "${TOR_TRANS_PORT}" \
      || die "Tor TransPort ${TOR_TRANS_PORT} is not listening"
    port_listening_udp "${TOR_DNS_PORT}" \
      || die "Tor DNSPort ${TOR_DNS_PORT} is not listening"
  fi
}

# -----------------------------------------------------------------------------
# Package installation
# -----------------------------------------------------------------------------
function install_packages() {
  require_root
  preflight_base

  local -a packages=(
    tor
    torsocks
    nftables
    macchanger
    curl
    iproute2
    networkmanager
  )

  info "installing required packages with pacman"
  pacman -Syu --needed "${packages[@]}"
}

# -----------------------------------------------------------------------------
# Tor configuration
# -----------------------------------------------------------------------------
function ensure_torrc_exists() {
  install -d -m 0755 /etc/tor
  touch "${TORRC}"
  chmod 0644 "${TORRC}"
}

function remove_managed_tor_block() {
  [[ -f "${TORRC}" ]] || return 0

  local tmp
  tmp="$(mktemp)"

  awk -v begin="${TOR_BLOCK_BEGIN}" -v end="${TOR_BLOCK_END}" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "${TORRC}" > "${tmp}"

  cat "${tmp}" > "${TORRC}"
  rm -f "${tmp}"
}

function write_tor_config() {
  require_root
  ensure_torrc_exists
  remove_managed_tor_block

  cat >> "${TORRC}" <<EOF

${TOR_BLOCK_BEGIN}
# Client-only Tor configuration for tor-privacy.
ClientOnly 1
DataDirectory /var/lib/tor
User tor

# SOCKS proxy for torsocks, curl --socks5-hostname, browser proxy settings, etc.
SocksPort 127.0.0.1:${TOR_SOCKS_PORT} IsolateSOCKSAuth

# Transparent proxy endpoints used by the nftables kill-switch.
TransPort 127.0.0.1:${TOR_TRANS_PORT}
DNSPort 127.0.0.1:${TOR_DNS_PORT}
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1

# Local control socket for explicit NEWNYM workflows if you later want them.
# Kept local and cookie-authenticated. The script does not open it to LAN.
ControlPort 127.0.0.1:${TOR_CONTROL_PORT}
CookieAuthentication 1
${TOR_BLOCK_END}
EOF

  info "wrote managed Tor block to ${TORRC}"
}

# -----------------------------------------------------------------------------
# nftables kill-switch
# -----------------------------------------------------------------------------
function get_tor_uid() {
  id -u tor 2>/dev/null || die "user 'tor' does not exist; install tor first"
}

function write_nft_rules() {
  require_root

  local tor_uid
  tor_uid="$(get_tor_uid)"

  install -d -m 0755 /etc/tor

  cat > "${NFT_RULES}" <<EOF
#!/usr/bin/nft -f
# -----------------------------------------------------------------------------
# tor-privacy nftables rules
# Generated by tor-privacy. Do not edit manually unless you know nftables.
# -----------------------------------------------------------------------------

table ip torprivacy_nat {
  define local_ipv4 = {
    0.0.0.0/8,
    10.0.0.0/8,
    127.0.0.0/8,
    169.254.0.0/16,
    172.16.0.0/12,
    192.168.0.0/16,
    224.0.0.0/4,
    240.0.0.0/4,
    255.255.255.255/32
  }

  chain output {
    type nat hook output priority dstnat; policy accept;

    meta skuid ${tor_uid} return
    oifname "lo" return
    ip daddr \$local_ipv4 return

    udp dport 53 redirect to :${TOR_DNS_PORT}
    tcp flags & (fin | syn | rst | ack) == syn redirect to :${TOR_TRANS_PORT}
  }
}

table inet torprivacy_filter {
  chain output {
    type filter hook output priority filter; policy drop;

    ct state established,related accept
    meta skuid ${tor_uid} accept
    oifname "lo" accept

    # DHCP is allowed so NetworkManager can obtain a lease after MAC rotation.
    udp sport 68 udp dport 67 accept

    # After NAT redirection, normal applications should only egress locally to
    # Tor's SOCKS, TransPort, DNSPort, or ControlPort.
    ip daddr 127.0.0.1 tcp dport {
      ${TOR_SOCKS_PORT}, ${TOR_TRANS_PORT}, ${TOR_CONTROL_PORT}
    } accept
    ip daddr 127.0.0.1 udp dport ${TOR_DNS_PORT} accept

    # IPv6 transparent torification is deliberately not attempted here. Drop it
    # instead of risking an IPv6 leak.
    ip6 nexthdr { tcp, udp, icmpv6 } reject with icmpx type admin-prohibited

    reject with icmpx type admin-prohibited
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain input {
    type filter hook input priority filter; policy accept;
  }
}
EOF

  chmod 0644 "${NFT_RULES}"
  info "wrote nftables rules to ${NFT_RULES}"
}

function write_nft_unit() {
  require_root

  cat > "${NFT_UNIT}" <<EOF
[Unit]
Description=tor-privacy nftables Tor kill-switch
Documentation=man:nft(8)
Wants=tor.service
After=tor.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/bash -c '/usr/bin/nft delete table ip torprivacy_nat 2>/dev/null || true; /usr/bin/nft delete table inet torprivacy_filter 2>/dev/null || true'
ExecStart=/usr/bin/nft -f ${NFT_RULES}
ExecStop=/usr/bin/bash -c '/usr/bin/nft delete table ip torprivacy_nat 2>/dev/null || true; /usr/bin/nft delete table inet torprivacy_filter 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${NFT_UNIT}"
  systemctl daemon-reload
  info "wrote systemd unit to ${NFT_UNIT}"
}

function nft_tables_loaded() {
  nft list table ip torprivacy_nat >/dev/null 2>&1 \
    && nft list table inet torprivacy_filter >/dev/null 2>&1
}

function load_killswitch() {
  require_root
  write_nft_rules
  write_nft_unit
  systemctl start tor-privacy-nft.service
  info "loaded tor-privacy nftables kill-switch"
}

function unload_killswitch() {
  require_root

  systemctl disable --now tor-privacy-nft.service >/dev/null 2>&1 || true
  nft delete table ip torprivacy_nat >/dev/null 2>&1 || true
  nft delete table inet torprivacy_filter >/dev/null 2>&1 || true

  info "removed tor-privacy nftables kill-switch"
}

# -----------------------------------------------------------------------------
# NetworkManager MAC randomisation
# -----------------------------------------------------------------------------
function enable_mac_randomisation() {
  require_root

  install -d -m 0755 /etc/NetworkManager/conf.d

  cat > "${NM_MAC_CONF}" <<'EOF'
# -----------------------------------------------------------------------------
# tor-privacy NetworkManager MAC randomisation
# -----------------------------------------------------------------------------
[device-90-tor-privacy]
wifi.scan-rand-mac-address=yes

[connection-90-tor-privacy]
connection.stable-id=${RANDOM}
ethernet.cloned-mac-address=random
wifi.cloned-mac-address=random
ipv4.dhcp-client-id=mac
ipv6.ip6-privacy=2
EOF

  chmod 0644 "${NM_MAC_CONF}"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    systemctl reload NetworkManager.service >/dev/null 2>&1 \
      || systemctl restart NetworkManager.service
  else
    warn "NetworkManager.service not found; config written but not reloaded"
  fi

  info "enabled NetworkManager MAC randomisation"
}

function disable_mac_randomisation() {
  require_root

  rm -f "${NM_MAC_CONF}"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    systemctl reload NetworkManager.service >/dev/null 2>&1 \
      || systemctl restart NetworkManager.service
  fi

  info "disabled tor-privacy NetworkManager MAC randomisation"
}

function rotate_mac_now() {
  require_root

  local iface=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --iface)
        iface="${2:-}"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage
  sudo tor-privacy mac-rotate --iface IFACE

This disconnects the interface, randomises its MAC address using macchanger,
and asks NetworkManager to reconnect it. Expect a brief network drop.
EOF
        return 0
        ;;
      *)
        die "unknown mac-rotate option: $1"
        ;;
    esac
  done

  [[ -n "${iface}" ]] || die "missing --iface IFACE"
  [[ -d "/sys/class/net/${iface}" ]] || die "no such interface: ${iface}"
  have macchanger || die "macchanger is not installed"

  nmcli device disconnect "${iface}" >/dev/null 2>&1 || true
  ip link set dev "${iface}" down
  macchanger -r "${iface}"
  ip link set dev "${iface}" up
  nmcli device connect "${iface}" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Conservative session display randomisation
# -----------------------------------------------------------------------------
function enable_fingerprint_randomiser() {
  require_root

  cat > "${FP_PROFILE}" <<'EOF'
# -----------------------------------------------------------------------------
# tor-privacy interactive-shell display randomiser
#
# This is deliberately conservative:
#   - randomises LC_TIME only, not LANG/LC_ALL
#   - adds tdate/tkbd helper functions
#   - does not change keyboard layout unless TOR_PRIVACY_RANDOM_XKB=1 is set
# -----------------------------------------------------------------------------

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ "${TOR_PRIVACY_NO_RANDOM_FP:-0}" = "1" ] && return 0 2>/dev/null

function _tor_privacy_pick() {
  local n pick
  n="$(printf '%s\n' "$@" | sed '/^$/d' | wc -l)"
  [ "${n}" -gt 0 ] || return 1
  pick="$(( ($(od -An -N2 -tu2 /dev/urandom 2>/dev/null) % n) + 1 ))"
  printf '%s\n' "$@" | sed -n "${pick}p"
}

function _tor_privacy_randomise_lc_time() {
  local candidates available loc
  candidates="C.UTF-8 en_DK.UTF-8 en_US.UTF-8 en_GB.UTF-8 de_DE.UTF-8 sv_SE.UTF-8 nb_NO.UTF-8"
  available="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]')"

  for loc in ${candidates}; do
    if printf '%s\n' "${available}" | grep -qx "$(printf '%s' "${loc}" | tr '[:upper:]' '[:lower:]')"; then
      printf '%s\n' "${loc}"
    fi
  done | _tor_privacy_pick
}

function tor_privacy_date() {
  local fmt
  fmt="$(_tor_privacy_pick \
    '+%Y-%m-%d %H:%M:%S %z' \
    '+%A, %d %B %Y, %H:%M:%S %Z' \
    '+%d/%m/%Y %H:%M:%S' \
    '+%b %d, %Y %I:%M:%S %p %Z' \
    '+%FT%T%z')"
  date "${fmt}"
}

function tor_privacy_keyboard() {
  printf 'XKB_DEFAULT_LAYOUT=%s\n' "${XKB_DEFAULT_LAYOUT:-unset}"
  printf 'XKB_DEFAULT_VARIANT=%s\n' "${XKB_DEFAULT_VARIANT:-unset}"
}

_lc_time="$(_tor_privacy_randomise_lc_time || true)"
[ -n "${_lc_time:-}" ] && export LC_TIME="${_lc_time}"
unset _lc_time

if [ "${TOR_PRIVACY_RANDOM_XKB:-0}" = "1" ]; then
  _layout="$(_tor_privacy_pick dk us gb de se no || printf 'dk')"
  export XKB_DEFAULT_LAYOUT="${_layout}"
  unset _layout
fi

alias tdate='tor_privacy_date'
alias tkbd='tor_privacy_keyboard'
EOF

  chmod 0644 "${FP_PROFILE}"
  info "enabled shell-level LC_TIME/date display randomiser"
}

function disable_fingerprint_randomiser() {
  require_root
  rm -f "${FP_PROFILE}"
  info "disabled shell-level display randomiser"
}


# -----------------------------------------------------------------------------
# torsocks command wrapper
# -----------------------------------------------------------------------------
function install_torsocks_wrapper() {
  require_root

  cat > "${TW_BIN}" <<'EOF'
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tw — run commands through Tor when Tor is active.
# -----------------------------------------------------------------------------
set -euo pipefail

TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"

function usage() {
  cat <<'HELP'
tw — run a command through Tor using torsocks

Usage
  tw COMMAND [ARGS...]
  tw --ip
  tw --ip-socks
  tw --check
  tw -h | --help

Environment
  TOR_SOCKS_PORT=9050   SOCKS port to check/use
  TW_STRICT=1           fail closed if Tor is inactive

Behavior
  If Tor is active and 127.0.0.1:$TOR_SOCKS_PORT is listening, commands are
  executed through torsocks unless proxy arguments or proxy environment
  variables are already present. With TW_STRICT=1, tw refuses to run direct.
HELP
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function tor_ready() {
  have systemctl || return 1
  systemctl --quiet is-active tor.service || return 1

  if have ss; then
    ss -ltnH 2>/dev/null | grep -qE ":${TOR_SOCKS_PORT}\b"
  elif have netstat; then
    netstat -lnt 2>/dev/null | grep -qE ":${TOR_SOCKS_PORT}\b"
  else
    return 1
  fi
}

function abort_or_warn() {
  if [[ "${TW_STRICT:-0}" == "1" ]]; then
    printf 'tw: Tor is not active or SOCKS :%s is not listening.\n' \
      "${TOR_SOCKS_PORT}" >&2
    exit 2
  fi

  printf 'tw: Tor unavailable; running without Tor.\n' >&2
}

function has_explicit_proxy() {
  local arg

  if [[ -n "${ALL_PROXY:-}${HTTPS_PROXY:-}${HTTP_PROXY:-}${FTP_PROXY:-}" \
        || -n "${all_proxy:-}${https_proxy:-}${http_proxy:-}${ftp_proxy:-}" \
        || -n "${NO_PROXY:-}${no_proxy:-}" ]]; then
    return 0
  fi

  for arg in "$@"; do
    case "${arg}" in
      --socks5*|--proxy|--proxy1.0|--proxy-anyauth|--noproxy|-x)
        return 0
        ;;
    esac
  done

  return 1
}

function main() {
  if [[ "$#" -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  case "${1}" in
    --ip)
      tor_ready || abort_or_warn
      exec torsocks curl -s https://ifconfig.io/ip
      ;;
    --ip-socks)
      tor_ready || abort_or_warn
      exec curl -s --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" \
        https://ifconfig.io/ip
      ;;
    --check)
      tor_ready || abort_or_warn
      if curl --max-time 30 --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" \
          -s https://check.torproject.org/ | grep -qi 'Congratulations'; then
        printf 'Tor OK: check.torproject.org recognises this connection.\n'
        exit 0
      fi
      printf 'Tor NOT confirmed.\n' >&2
      exit 2
      ;;
  esac

  if ! tor_ready; then
    abort_or_warn
    exec "$@"
  fi

  if [[ "${1}" == "torsocks" ]] || has_explicit_proxy "$@"; then
    exec "$@"
  fi

  exec torsocks "$@"
}

main "$@"
EOF

  chmod 0755 "${TW_BIN}"
  info "installed torsocks wrapper as ${TW_BIN}"
}

# -----------------------------------------------------------------------------
# Install, activate, deactivate
# -----------------------------------------------------------------------------
function install_self() {
  require_root

  install -m 0755 "$0" "${INSTALL_BIN}"
  info "installed controller as ${INSTALL_BIN}"
}

function install_all() {
  local use_killswitch="no"
  local use_mac="no"
  local use_fp="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --killswitch) use_killswitch="yes"; shift ;;
      --mac-random) use_mac="yes"; shift ;;
      --fp-random) use_fp="yes"; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown install option: $1" ;;
    esac
  done

  install_packages
  write_tor_config
  write_nft_rules
  write_nft_unit
  validate_written_config
  install_self
  install_torsocks_wrapper

  [[ "${use_mac}" == "yes" ]] && enable_mac_randomisation
  [[ "${use_fp}" == "yes" ]] && enable_fingerprint_randomiser

  systemctl daemon-reload

  if [[ "${use_killswitch}" == "yes" ]]; then
    activate_session --killswitch
  else
    systemctl start tor.service
  fi

  info "installation completed"
}

function activate_session() {
  require_root
  preflight_base

  local use_killswitch="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --killswitch) use_killswitch="yes"; shift ;;
      *) die "unknown session option: $1" ;;
    esac
  done

  validate_written_config
  systemctl start tor.service

  if [[ "${use_killswitch}" == "yes" ]]; then
    load_killswitch
  fi

  verify_activation "${use_killswitch}"
  info "activated until reboot/poweroff"
}

function activate_persistent() {
  require_root
  preflight_base

  local use_killswitch="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --killswitch) use_killswitch="yes"; shift ;;
      *) die "unknown persist option: $1" ;;
    esac
  done

  validate_written_config
  systemctl enable --now tor.service

  if [[ "${use_killswitch}" == "yes" ]]; then
    write_nft_rules
    write_nft_unit
    validate_written_config
    systemctl enable --now tor-privacy-nft.service
  fi

  verify_activation "${use_killswitch}"
  info "activated and persistent after reboot"
}

function deactivate_all() {
  require_root

  local keep_tor="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --keep-tor) keep_tor="yes"; shift ;;
      *) die "unknown off option: $1" ;;
    esac
  done

  unload_killswitch

  if [[ "${keep_tor}" != "yes" ]]; then
    systemctl disable --now tor.service >/dev/null 2>&1 || true
    info "stopped and disabled tor.service"
  else
    info "kept tor.service unchanged"
  fi

  info "deactivated"
}

function uninstall_all() {
  require_root

  local purge="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --purge) purge="yes"; shift ;;
      *) die "unknown uninstall option: $1" ;;
    esac
  done

  deactivate_all || true
  remove_managed_tor_block
  disable_mac_randomisation || true
  disable_fingerprint_randomiser || true

  systemctl daemon-reload
  rm -f "${NFT_RULES}" "${NFT_UNIT}" "${INSTALL_BIN}" "${TW_BIN}"
  systemctl daemon-reload

  if [[ "${purge}" == "yes" ]]; then
    warn "purge does not remove pacman packages automatically"
    warn "manual package removal, if desired: sudo pacman -Rns tor torsocks nftables macchanger"
  fi

  info "uninstalled tor-privacy files"
}

# -----------------------------------------------------------------------------
# Status and tests
# -----------------------------------------------------------------------------
function unit_enabled() {
  systemctl is-enabled "$1" >/dev/null 2>&1
}

function unit_active() {
  systemctl is-active "$1" >/dev/null 2>&1
}

function print_bool() {
  if "$@"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

function status() {
  local mode="deactivated"

  if unit_active tor.service || nft_tables_loaded; then
    mode="activated until reboot/poweroff"
  fi

  if unit_enabled tor.service && unit_enabled tor-privacy-nft.service; then
    mode="activated and persistent after reboot"
  elif unit_enabled tor.service && ! nft_tables_loaded; then
    mode="Tor persistent; tor-privacy kill-switch inactive"
  fi

  cat <<EOF
Status: ${mode}

Components
  tor.service active:              $(print_bool unit_active tor.service)
  tor.service enabled:             $(print_bool unit_enabled tor.service)
  tor-privacy nft tables loaded:   $(print_bool nft_tables_loaded)
  tor-privacy nft unit enabled:    $(print_bool unit_enabled tor-privacy-nft.service)
  NetworkManager MAC config:       $([[ -f "${NM_MAC_CONF}" ]] && printf yes || printf no)
  session display randomiser:      $([[ -f "${FP_PROFILE}" ]] && printf yes || printf no)
  torsocks wrapper installed:       $([[ -x "${TW_BIN}" ]] && printf yes || printf no)

Ports
EOF

  if have ss; then
    ss -ltnup 2>/dev/null \
      | awk '/:(9050|9040|5353|9051)[[:space:]]/ { print "  " $0 }' \
      || true
  else
    printf '  ss not available\n'
  fi

  cat <<EOF

Files
  Tor config:      ${TORRC}
  nft rules:       ${NFT_RULES}
  nft unit:        ${NFT_UNIT}
  NM MAC config:   ${NM_MAC_CONF}
  shell randomise: ${FP_PROFILE}
  torsocks wrap:   ${TW_BIN}
EOF
}

function show_ip() {
  have curl || die "curl is not installed"
  curl --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" \
    --max-time 20 -fsS "${TOR_FALLBACK_IP_URL}"
}

function check_tor() {
  if tor_socks_confirmed; then
    printf 'Tor OK: SOCKS path is recognised as Tor.\n'
  else
    die "Tor was not confirmed through 127.0.0.1:${TOR_SOCKS_PORT}"
  fi

  if nft_tables_loaded; then
    if transparent_tor_confirmed; then
      printf 'Tor OK: transparent TCP path is recognised as Tor.\n'
    else
      die "kill-switch is loaded, but transparent TCP was not confirmed as Tor"
    fi

    if ipv6_egress_blocked_or_absent; then
      printf 'IPv6 OK: direct IPv6 egress failed or is absent.\n'
    else
      die "IPv6 egress succeeded while kill-switch is loaded"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Doctor report
# -----------------------------------------------------------------------------
CHECK_FAILS=0
CHECK_WARNS=0

function report_check() {
  local level="$1"
  local name="$2"
  local msg="${3:-}"

  case "${level}" in
    PASS) printf '[PASS] %-36s %s\n' "${name}" "${msg}" ;;
    WARN) printf '[WARN] %-36s %s\n' "${name}" "${msg}"; CHECK_WARNS=$((CHECK_WARNS + 1)) ;;
    FAIL) printf '[FAIL] %-36s %s\n' "${name}" "${msg}"; CHECK_FAILS=$((CHECK_FAILS + 1)) ;;
    SKIP) printf '[SKIP] %-36s %s\n' "${name}" "${msg}" ;;
    *) die "internal error: unknown report level ${level}" ;;
  esac
}

function doctor_packages() {
  local -a required=(tor torsocks nft curl ss systemctl pacman)
  local -a optional=(nmcli macchanger NetworkManager)
  local cmd

  for cmd in "${required[@]}"; do
    if have "${cmd}"; then
      report_check PASS "command: ${cmd}" "found"
    else
      report_check FAIL "command: ${cmd}" "missing"
    fi
  done

  for cmd in "${optional[@]}"; do
    if have "${cmd}"; then
      report_check PASS "optional command: ${cmd}" "found"
    else
      report_check WARN "optional command: ${cmd}" "missing; only relevant for MAC features"
    fi
  done
}

function doctor_system() {
  [[ -r /etc/arch-release ]] \
    && report_check PASS "Arch Linux" "/etc/arch-release present" \
    || report_check FAIL "Arch Linux" "not detected"

  [[ -d /run/systemd/system ]] \
    && report_check PASS "systemd runtime" "detected" \
    || report_check FAIL "systemd runtime" "not detected"

  is_root \
    && report_check PASS "root privileges" "available" \
    || report_check WARN "root privileges" "not root; nft syntax checks are limited"
}

function doctor_files() {
  [[ -x "${INSTALL_BIN}" ]] \
    && report_check PASS "controller installed" "${INSTALL_BIN}" \
    || report_check WARN "controller installed" "${INSTALL_BIN} missing"

  [[ -x "${TW_BIN}" ]] \
    && report_check PASS "tw wrapper" "${TW_BIN}" \
    || report_check WARN "tw wrapper" "${TW_BIN} missing"

  torrc_has_managed_block \
    && report_check PASS "Tor managed block" "present in ${TORRC}" \
    || report_check FAIL "Tor managed block" "missing from ${TORRC}"

  if tor_config_valid; then
    report_check PASS "Tor config syntax" "valid"
  else
    report_check FAIL "Tor config syntax" "failed: tor --verify-config -f ${TORRC}"
  fi

  [[ -r "${NFT_RULES}" ]] \
    && report_check PASS "nft rules file" "${NFT_RULES}" \
    || report_check WARN "nft rules file" "${NFT_RULES} missing"

  if [[ -r "${NFT_RULES}" ]]; then
    if ! is_root; then
      report_check SKIP "nft syntax" "requires root"
    elif nft_rules_valid; then
      report_check PASS "nft syntax" "valid"
    else
      report_check FAIL "nft syntax" "failed: nft -c -f ${NFT_RULES}"
    fi
  fi
}

function doctor_services() {
  unit_active tor.service \
    && report_check PASS "tor.service active" "yes" \
    || report_check FAIL "tor.service active" "no"

  unit_enabled tor.service \
    && report_check PASS "tor.service enabled" "persistent" \
    || report_check WARN "tor.service enabled" "not persistent"

  port_listening_tcp "${TOR_SOCKS_PORT}" \
    && report_check PASS "SOCKS port ${TOR_SOCKS_PORT}" "listening" \
    || report_check FAIL "SOCKS port ${TOR_SOCKS_PORT}" "not listening"

  port_listening_tcp "${TOR_TRANS_PORT}" \
    && report_check PASS "TransPort ${TOR_TRANS_PORT}" "listening" \
    || report_check WARN "TransPort ${TOR_TRANS_PORT}" "not listening"

  port_listening_udp "${TOR_DNS_PORT}" \
    && report_check PASS "DNSPort ${TOR_DNS_PORT}" "listening" \
    || report_check WARN "DNSPort ${TOR_DNS_PORT}" "not listening"

  nft_tables_loaded \
    && report_check PASS "kill-switch tables" "loaded" \
    || report_check WARN "kill-switch tables" "not loaded"

  unit_enabled tor-privacy-nft.service \
    && report_check PASS "kill-switch unit" "persistent" \
    || report_check WARN "kill-switch unit" "not persistent"
}

function doctor_mac() {
  [[ -r "${NM_MAC_CONF}" ]] \
    && report_check PASS "NM MAC drop-in" "${NM_MAC_CONF}" \
    || report_check WARN "NM MAC drop-in" "not enabled"

  if have nmcli; then
    local devices
    devices="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
      | grep -E ':(wifi|ethernet):' || true)"
    if [[ -n "${devices}" ]]; then
      report_check PASS "NM network devices" "detected"
      printf '%s\n' "${devices}" | sed 's/^/       /'
    else
      report_check WARN "NM network devices" "none detected by nmcli"
    fi
  else
    report_check SKIP "NM network devices" "nmcli not installed"
  fi
}

function doctor_online() {
  if tor_socks_confirmed; then
    report_check PASS "SOCKS Tor validation" "check.torproject.org says Tor"
  else
    report_check FAIL "SOCKS Tor validation" "not confirmed"
  fi

  if nft_tables_loaded; then
    if transparent_tor_confirmed; then
      report_check PASS "transparent TCP validation" "direct TCP appears torified"
    else
      report_check FAIL "transparent TCP validation" "direct TCP not confirmed as Tor"
    fi

    if ipv6_egress_blocked_or_absent; then
      report_check PASS "IPv6 egress" "blocked or absent"
    else
      report_check FAIL "IPv6 egress" "direct IPv6 succeeded"
    fi

    local sip dip
    sip="$(socks_tor_ip)"
    dip="$(direct_tor_ip)"
    [[ -n "${sip}" ]] && report_check PASS "SOCKS exit IP" "${sip}" \
      || report_check WARN "SOCKS exit IP" "unavailable"
    [[ -n "${dip}" ]] && report_check PASS "direct exit IP" "${dip}" \
      || report_check WARN "direct exit IP" "unavailable"
  else
    report_check SKIP "transparent validation" "kill-switch not loaded"
  fi
}

function doctor() {
  local online="no"
  local strict="no"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --online) online="yes"; shift ;;
      --strict) strict="yes"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage
  tor-privacy doctor [--online] [--strict]

Checks
  default   local package, file, service, socket, nftables, and MAC status
  --online  additionally contacts check.torproject.org and ifconfig.io
  --strict  exit non-zero on warnings as well as failures
EOF
        return 0
        ;;
      *) die "unknown doctor option: $1" ;;
    esac
  done

  CHECK_FAILS=0
  CHECK_WARNS=0

  printf 'tor-privacy doctor\n'
  printf '==================\n\n'

  doctor_system
  printf '\n'
  doctor_packages
  printf '\n'
  doctor_files
  printf '\n'
  doctor_services
  printf '\n'
  doctor_mac

  if [[ "${online}" == "yes" ]]; then
    printf '\n'
    doctor_online
  fi

  printf '\nSummary: %d failure(s), %d warning(s).\n' \
    "${CHECK_FAILS}" "${CHECK_WARNS}"

  if (( CHECK_FAILS > 0 )); then
    return 2
  fi

  if [[ "${strict}" == "yes" && "${CHECK_WARNS}" -gt 0 ]]; then
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 0; }
  shift || true

  case "${cmd}" in
    install)
      install_all "$@"
      ;;
    on|activate)
      case "${1:-}" in
        --session)
          shift
          activate_session "$@"
          ;;
        --persist)
          shift
          activate_persistent "$@"
          ;;
        *)
          die "use: tor-privacy on --session|--persist [--killswitch]"
          ;;
      esac
      ;;
    off|deactivate)
      deactivate_all "$@"
      ;;
    status)
      status
      ;;
    doctor)
      doctor "$@"
      ;;
    ip)
      show_ip
      ;;
    check)
      check_tor
      ;;
    mac-on)
      enable_mac_randomisation
      ;;
    mac-off)
      disable_mac_randomisation
      ;;
    mac-rotate)
      rotate_mac_now "$@"
      ;;
    fp-on)
      enable_fingerprint_randomiser
      ;;
    fp-off)
      disable_fingerprint_randomiser
      ;;
    uninstall)
      uninstall_all "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
