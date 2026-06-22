#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tor-privacy-v3.0
# -----------------------------------------------------------------------------
# Arch Linux Tor privacy controller.
#
# Goals:
#   - repair broken tor.service startup caused by stale/duplicate managed torrc
#     blocks from older scripts;
#   - provide explicit Tor wrappers for CLI tools;
#   - provide a Tor Browser launcher that uses the system Tor SOCKS listener;
#   - optionally provide a reversible nftables leak guard;
#   - optionally configure conservative NetworkManager MAC randomisation;
#   - never delete logs, browser history, or user data.
#
# Non-goals:
#   - this is not anti-forensics;
#   - this is not magic anonymity;
#   - this does not make non-Tor browsers equivalent to Tor Browser.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly APP_NAME="tor-privacy-v3.0"
readonly INSTALL_BIN="/usr/local/bin/tor-privacy"
readonly TW_BIN="/usr/local/bin/tw"

readonly STATE_DIR="${TOR_PRIVACY_STATE_DIR:-/var/lib/tor-privacy}"
readonly BACKUP_DIR="${STATE_DIR}/backups"

readonly TORRC="/etc/tor/torrc"
readonly TOR_SERVICE="tor.service"

readonly TOR_BLOCK_BEGIN="# >>> tor-privacy-v3 managed block >>>"
readonly TOR_BLOCK_END="# <<< tor-privacy-v3 managed block <<<"

readonly OLD_V2_PRIVACY_BEGIN="# >>> tor-privacy-v2 managed block >>>"
readonly OLD_V2_PRIVACY_END="# <<< tor-privacy-v2 managed block <<<"
readonly OLD_PRIVACY_BEGIN="# >>> tor-privacy managed block >>>"
readonly OLD_PRIVACY_END="# <<< tor-privacy managed block <<<"
readonly OLD_RESEARCH_BEGIN="# BEGIN managed by tor-research"
readonly OLD_RESEARCH_END="# END managed by tor-research"

readonly OLD_V2_NFT_RULES="/etc/tor/tor-privacy-v2.nft"
readonly NFT_RULES="/etc/tor/tor-privacy-v3.nft"
readonly NFT_UNIT="/etc/systemd/system/tor-privacy-nft.service"
readonly NFT_TABLE_NAT="torprivacy_v3_nat"
readonly NFT_TABLE_FILTER="torprivacy_v3_filter"

readonly NM_MAC_CONF="/etc/NetworkManager/conf.d/90-tor-privacy-mac.conf"

readonly TOR_SOCKS_HOST="127.0.0.1"
readonly TOR_SOCKS_PORT="9050"
readonly TOR_TRANS_PORT="9040"
readonly TOR_DNS_PORT="9053"
readonly TOR_CONTROL_HOST="127.0.0.1"
readonly TOR_CONTROL_PORT="9051"
readonly TOR_CONTROL_PASSWORD="${TOR_PRIVACY_CONTROL_PASSWORD:-torprivacy-system-tor-v3}"
readonly TOR_SOCKS_URL="socks5h://${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}"
readonly TOR_CONTROL_URL="${TOR_CONTROL_HOST}:${TOR_CONTROL_PORT}"
readonly TOR_CHECK_URL="https://check.torproject.org/api/ip"
readonly TOR_FALLBACK_IP_URL="https://ifconfig.io/ip"

readonly TOR_BROWSER_PREF_BEGIN="// >>> tor-privacy system-Tor prefs >>>"
readonly TOR_BROWSER_PREF_END="// <<< tor-privacy system-Tor prefs <<<"

DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# VPN-underlay support keeps an already-active VPN alive under the nftables
# leak guard. Only the encrypted VPN endpoint is excepted; ordinary application
# traffic is still forced through Tor.
VPN_UNDERLAY_AUTO=yes
VPN_UNDERLAY_REQUESTED=no
VPN_DETECT_ERROR=""
VPN_ENDPOINTS=()

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
function usage() {
  local pager
  pager="${HELP_PAGER:-cat}"

  cat <<'HELP' | ${pager}
tor-privacy — Arch Linux Tor privacy controller

USAGE
  tor-privacy [global-options] COMMAND [command-options]

GLOBAL OPTIONS
  -n, --dry-run
      Print the commands that would run, but do not change the system.

  -y, --yes
      Skip confirmation prompts.

  -v, --verbose
      Print additional diagnostic information.

  -h, -H, --help
      Show this help text.

CORE COMMANDS
  install [--killswitch] [--persist] [--allow-lan] [--mac-random] [--no-start]
          [--vpn-underlay] [--vpn-endpoint PROTO:IP:PORT]
      Install/check packages, write the corrected Tor config, install this
      controller as /usr/local/bin/tor-privacy, install the tw wrapper, and
      optionally activate Tor and the nftables leak guard.

  repair [--allow-lan]
      Back up /etc/tor/torrc, remove old tor-privacy and tor-research managed
      blocks, write one clean managed block, validate Tor and nftables syntax,
      then restart tor.service. This is the command to run when tor.service
      fails after older versions of these scripts.

  start | on [--killswitch] [--persist] [--allow-lan]
             [--vpn-underlay] [--vpn-endpoint PROTO:IP:PORT]
      Start Tor. With --killswitch, load the nftables leak guard. With
      --persist, enable Tor and the leak guard after reboot.

      Do not stack --killswitch on top of ProtonVPN's own killswitch. v3.0
      refuses that combination by default because it can drop the VPN.

      --vpn-underlay
          Explicitly request active WireGuard endpoint detection, such as
          Proton VPN's proton0. Detection also runs automatically when root
          commands generate leak-guard rules; this option makes missing
          detection visible as a warning.

      --vpn-endpoint PROTO:IP:PORT
          Manually allow one VPN endpoint. Use this for OpenVPN or if automatic
          WireGuard detection fails. Examples:
            --vpn-endpoint udp:185.159.159.140:51820
            --vpn-endpoint udp:185.159.159.140:1194
            --vpn-endpoint tcp:185.159.159.140:443

  stop | off [--keep-tor]
      Remove the managed nftables leak guard. Unless --keep-tor is passed,
      stop and disable tor.service.

  strict-on [--persist] [--allow-lan]
            [--vpn-underlay] [--vpn-endpoint PROTO:IP:PORT]
      Load only the nftables leak guard. Tor is started first if necessary.

  strict-off
      Remove only the managed nftables leak guard.

  status
      Show Tor, socket, nftables, NetworkManager, and file status.

  doctor [--online] [--journal]
      Run local checks. With --online, validate Tor routing. With --journal,
      print recent systemd logs for tor.service and the nftables unit.

  logs
      Print recent journal entries for tor.service and tor-privacy-nft.service.

  backup
      Back up /etc/tor/torrc, the managed nftables rule file, the managed
      systemd unit, and the current nftables ruleset.

  uninstall [--purge]
      Disable managed rules, remove managed torrc blocks, remove installed
      controller/wrapper files, and optionally print package removal guidance.

RESEARCH COMMANDS
  env
      Print proxy variables for the current shell:
        eval "$(tor-privacy env)"

  shell
      Start an interactive shell with proxy variables set.

  run COMMAND [ARGS...]
      Run a command through torsocks.

  curl URL [curl-args...]
      Run curl through Tor with remote DNS resolution.

  wget URL [wget-args...]
      Run wget through Tor by proxy environment.

  git-clone REPO [DIR]
      Clone a Git repository through Tor using Git proxy settings.

  git-ls REPO
      Run git ls-remote through Tor.

  check
      Query Tor Project's JSON check endpoint through Tor.

  ip
      Print the Tor-routed apparent IPv4 address.

  vpn-detect
      Detect currently active WireGuard VPN endpoint exceptions that would be
      used by --vpn-underlay.

BROWSER COMMANDS
  browser [tor-browser-args...]
      Configure the installed Tor Browser profile to use this script's system
      Tor SOCKS listener and local ControlPort, then launch Tor Browser with
      TOR_SKIP_LAUNCH=1 and TOR_CONTROL_PASSWD set.
      Run this as your desktop user, not with sudo. With ProtonVPN active,
      start Tor first without the v3 nftables guard:
        sudo tor-privacy browser-start

  browser-config
      Only write/update the Tor Browser system-Tor profile preferences.

  browser-start [--persist]
      Start only tor.service and the browser-ready SOCKS/ControlPort config.
      This deliberately does not load the v3 nftables guard, making it the
      safer workflow when ProtonVPN's own killswitch is already active.

  browser-doctor
      Check Tor Browser profile, managed prefs, Tor SOCKS, and Tor ControlPort
      readiness without launching the browser.

NETWORKMANAGER COMMANDS
  mac-on
      Enable conservative NetworkManager MAC randomisation defaults.

  mac-off
      Remove the managed NetworkManager MAC randomisation drop-in.

  mac-rotate --iface IFACE
      Randomise one interface now using macchanger and reconnect via nmcli.

EXAMPLES
  sudo tor-privacy repair
  sudo tor-privacy install --no-start
  sudo tor-privacy install --killswitch --persist --mac-random
  sudo tor-privacy start
  sudo tor-privacy start --killswitch
  sudo tor-privacy start --killswitch --vpn-underlay
  sudo tor-privacy start --killswitch --vpn-endpoint udp:185.159.159.140:51820
  sudo tor-privacy start --killswitch --persist
  sudo tor-privacy strict-on
  sudo tor-privacy strict-on --allow-lan
  sudo tor-privacy browser-start
  tor-privacy status
  tor-privacy doctor --online
  tor-privacy check
  tor-privacy curl https://check.torproject.org/api/ip
  tor-privacy git-ls https://github.com/torproject/tor.git
  tor-privacy browser
  tor-privacy browser-doctor
  eval "$(tor-privacy env)"
  tor-privacy shell
  sudo tor-privacy off
  sudo tor-privacy uninstall

IMPORTANT LIMITS
  - Use Tor Browser for websites. This script is best for CLI tools and for
    preventing accidental clearnet egress during a research session.
  - Proxy environment variables are advisory; some programs ignore them.
  - The nftables leak guard is the meaningful fail-closed layer.
  - Browser fingerprinting is not solved by system-wide routing.
  - Existing browser profiles, cookies, accounts, downloads, logs, and habits
    can identify you regardless of routing.
  - This script deliberately does not erase evidence or history.
HELP
}

# -----------------------------------------------------------------------------
# Output, errors, and generic helpers
# -----------------------------------------------------------------------------
function info() {
  printf '==> %s\n' "$*"
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function on_error() {
  local exit_code
  local line_no
  local command_text

  exit_code="${1:-1}"
  line_no="${2:-unknown}"
  command_text="${3:-unknown command}"

  # Bash ERR traps can be reached after helper commands such as `local` have
  # already overwritten `$?`. Passing `$?` explicitly from the trap preserves
  # the actual failing status and avoids the misleading "exit code 0" report.
  if [[ "${exit_code}" -eq 0 ]]; then
    return 0
  fi

  printf 'error: %s failed near line %s with exit code %s\n' \
    "${APP_NAME}" "${line_no}" "${exit_code}" >&2
  printf 'error: failing command: %s\n' "${command_text}" >&2
  exit "${exit_code}"
}

trap 'on_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

function verbose() {
  if [[ "${VERBOSE}" == true ]]; then
    printf '%s\n' "$*" >&2
  fi

  return 0
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function require_cmd() {
  local cmd
  cmd="$1"
  have "${cmd}" || die "missing required command: ${cmd}"
}

function is_root() {
  [[ "${EUID}" -eq 0 ]]
}

function require_root() {
  is_root || die "this command must be run as root; use sudo"
}

function run_cmd() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  verbose "running: $*"
  "$@"
}

function run_root() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run-root]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  require_root
  verbose "running as root: $*"
  "$@"
}

function confirm() {
  local prompt reply
  prompt="${1:-Continue?}"

  [[ "${ASSUME_YES}" == true ]] && return 0

  read -r -p "${prompt} [y/N] " reply
  case "${reply,,}" in
    y | yes) return 0 ;;
    *) die "aborted by user" ;;
  esac
}

function timestamp() {
  date '+%Y%m%d_%H%M%S'
}

function ensure_state_dirs() {
  run_root install -d -m 0755 "${STATE_DIR}" "${BACKUP_DIR}"
}

function require_arch_systemd() {
  [[ -r /etc/arch-release ]] \
    || die "this controller is intentionally Arch Linux-specific"
  [[ -d /run/systemd/system ]] \
    || die "systemd does not appear to be running"
}

function tor_user() {
  if getent passwd tor >/dev/null 2>&1; then
    printf 'tor\n'
    return 0
  fi

  if getent passwd toranon >/dev/null 2>&1; then
    printf 'toranon\n'
    return 0
  fi

  return 1
}

function tor_uid() {
  local user
  user="$(tor_user)" || return 1
  id -u "${user}"
}

function ensure_tor_data_dir() {
  local user group
  user="$(tor_user)" || die "Tor user not found; install the tor package first"
  group="$(id -gn "${user}")"
  run_root install -d -o "${user}" -g "${group}" -m 0700 /var/lib/tor
}

function unit_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

function unit_enabled() {
  systemctl is-enabled --quiet "$1" >/dev/null 2>&1
}

function print_bool() {
  if "$@"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

function port_listening_tcp() {
  local port
  port="$1"
  have ss || return 1
  ss -ltnH 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p"$" || $4 ~ p"\\]$" { ok = 1 }
        END { exit(ok ? 0 : 1) }'
}

function port_listening_udp() {
  local port
  port="$1"
  have ss || return 1
  ss -lunH 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p"$" || $4 ~ p"\\]$" { ok = 1 }
        END { exit(ok ? 0 : 1) }'
}

# -----------------------------------------------------------------------------
# VPN underlay support
# -----------------------------------------------------------------------------
function reset_vpn_underlay_options() {
  VPN_UNDERLAY_AUTO=yes
  VPN_UNDERLAY_REQUESTED=no
  VPN_DETECT_ERROR=""
  VPN_ENDPOINTS=()
}

function add_vpn_endpoint() {
  local endpoint
  endpoint="$1"

  [[ -n "${endpoint}" ]] || die "empty VPN endpoint"

  case "${endpoint}" in
    udp:* | tcp:*) ;;
    *)
      die "VPN endpoint must be PROTO:IP:PORT, e.g. udp:1.2.3.4:51820"
      ;;
  esac

  local item
  for item in "${VPN_ENDPOINTS[@]:-}"; do
    [[ "${item}" == "${endpoint}" ]] && return 0
  done

  VPN_ENDPOINTS+=("${endpoint}")
}

function parse_vpn_underlay_arg() {
  case "${1,,}" in
    --vpn-underlay | --proton-underlay | --detect-vpn)
      VPN_UNDERLAY_AUTO=yes
      VPN_UNDERLAY_REQUESTED=yes
      return 0
      ;;
    --no-vpn-underlay)
      VPN_UNDERLAY_AUTO=no
      VPN_UNDERLAY_REQUESTED=no
      VPN_DETECT_ERROR=""
      VPN_ENDPOINTS=()
      return 0
      ;;
  esac

  return 1
}

function parse_vpn_endpoint_parts() {
  local endpoint rest proto host port
  endpoint="$1"

  proto="${endpoint%%:*}"
  rest="${endpoint#*:}"

  if [[ "${rest}" == \[*\]:* ]]; then
    host="${rest%%]:*}"
    host="${host#[}"
    port="${rest##*:}"
  else
    host="${rest%:*}"
    port="${rest##*:}"

    if [[ "${host}" == *:* ]]; then
      die "IPv6 VPN endpoints must use brackets: ${proto}:[addr]:port"
    fi
  fi

  [[ "${proto}" == "udp" || "${proto}" == "tcp" ]] \
    || die "unsupported VPN endpoint protocol: ${proto}"
  [[ "${host}" =~ ^[0-9A-Fa-f:.]+$ ]] \
    || die "VPN endpoint host must be an IP address, not: ${host}"
  [[ "${port}" =~ ^[0-9]+$ ]] \
    || die "VPN endpoint port must be numeric: ${port}"
  (( port >= 1 && port <= 65535 )) \
    || die "VPN endpoint port out of range: ${port}"

  printf '%s\t%s\t%s\n' "${proto}" "${host}" "${port}"
}

function detect_wireguard_vpn_endpoints() {
  VPN_DETECT_ERROR=""

  if ! have wg; then
    VPN_DETECT_ERROR="wg command not found"
    return 0
  fi

  local iface _peer endpoint output
  if ! output="$(wg show all endpoints 2>&1)"; then
    VPN_DETECT_ERROR="${output//$'\n'/ }"
    return 0
  fi

  while read -r iface _peer endpoint; do
    [[ -n "${iface:-}" && -n "${endpoint:-}" ]] || continue
    [[ "${endpoint}" == "(none)" ]] && continue

    # WireGuard endpoints are UDP by design. `wg show all endpoints` prints
    # IPv4 as a.b.c.d:port and IPv6 as [addr]:port, which matches our parser.
    add_vpn_endpoint "udp:${endpoint}"
  done <<< "${output}"
}

function prepare_vpn_underlay_endpoints() {
  [[ "${VPN_UNDERLAY_AUTO}" == "yes" ]] || return 0

  local before
  before="${#VPN_ENDPOINTS[@]}"

  detect_wireguard_vpn_endpoints

  if [[ "${VPN_UNDERLAY_REQUESTED}" == "yes" \
      && -n "${VPN_DETECT_ERROR}" ]]; then
    warn "WireGuard endpoint detection failed: ${VPN_DETECT_ERROR}"
  fi

  if [[ "${VPN_UNDERLAY_REQUESTED}" == "yes" ]] \
      && (("${#VPN_ENDPOINTS[@]}" == before)); then
    warn "VPN underlay was requested, but no WireGuard endpoint was detected"
    warn "for Proton OpenVPN, add --vpn-endpoint udp:IP:1194 or tcp:IP:443"
  fi
}

function emit_vpn_underlay_rules() {
  local mode endpoint proto host port family
  mode="$1"

  (("${#VPN_ENDPOINTS[@]}" > 0)) || return 0

  printf '    # VPN underlay endpoint exceptions. These keep the encrypted VPN\n'
  printf '    # tunnel alive; they do not allow ordinary clearnet application use.\n'

  for endpoint in "${VPN_ENDPOINTS[@]}"; do
    IFS=$'\t' read -r proto host port \
      < <(parse_vpn_endpoint_parts "${endpoint}")

    if [[ "${host}" == *:* ]]; then
      family="ip6"
    else
      family="ip"
    fi

    if [[ "${mode}" == "nat" ]]; then
      [[ "${family}" == "ip" ]] || continue
      printf '    %s daddr %s %s dport %s return\n' \
        "${family}" "${host}" "${proto}" "${port}"
    else
      printf '    %s daddr %s %s dport %s accept\n' \
        "${family}" "${host}" "${proto}" "${port}"
    fi
  done

  printf '\n'
}

function print_vpn_underlay_status() {
  if (("${#VPN_ENDPOINTS[@]}" == 0)); then
    printf 'none'
    return 0
  fi

  local endpoint joined
  joined=""
  for endpoint in "${VPN_ENDPOINTS[@]}"; do
    if [[ -z "${joined}" ]]; then
      joined="${endpoint}"
    else
      joined="${joined}, ${endpoint}"
    fi
  done

  printf '%s' "${joined}"
}

# -----------------------------------------------------------------------------
# Backup and config cleanup
# -----------------------------------------------------------------------------
function backup_file_if_exists() {
  local path base dest
  path="$1"
  [[ -e "${path}" ]] || return 0

  base="$(basename "${path}")"
  dest="${BACKUP_DIR}/$(timestamp)_${base}"
  run_root cp -a "${path}" "${dest}"
  info "backup: ${dest}"
}

function backup_cmd() {
  require_root
  ensure_state_dirs

  backup_file_if_exists "${TORRC}"
  backup_file_if_exists "${NFT_RULES}"
  backup_file_if_exists "${NFT_UNIT}"
  backup_file_if_exists "${NM_MAC_CONF}"

  if have nft; then
    local dest
    dest="${BACKUP_DIR}/$(timestamp)_nft-ruleset.nft"
    if [[ "${DRY_RUN}" == true ]]; then
      printf '[dry-run-root] nft list ruleset > %q\n' "${dest}"
    else
      nft list ruleset > "${dest}" 2>/dev/null || true
      info "backup: ${dest}"
    fi
  fi
}

function ensure_torrc_exists() {
  run_root install -d -m 0755 /etc/tor
  if [[ ! -e "${TORRC}" ]]; then
    run_root install -m 0644 /dev/null "${TORRC}"
  fi
}

function torrc_has_any_managed_block() {
  [[ -r "${TORRC}" ]] || return 1
  grep -Eq \
    '^(# >>> tor-privacy-v3 managed block >>>|# >>> tor-privacy-v2 managed block >>>|# >>> tor-privacy managed block >>>|# BEGIN managed by tor-research)$' \
    "${TORRC}"
}

function remove_managed_tor_blocks() {
  require_root
  ensure_torrc_exists

  if ! torrc_has_any_managed_block; then
    verbose "no managed Tor block found in ${TORRC}"
    return 0
  fi

  backup_file_if_exists "${TORRC}"

  local tmp
  tmp="$(mktemp)"

  awk \
    -v b1="${TOR_BLOCK_BEGIN}" -v e1="${TOR_BLOCK_END}" \
    -v b2="${OLD_V2_PRIVACY_BEGIN}" -v e2="${OLD_V2_PRIVACY_END}" \
    -v b3="${OLD_PRIVACY_BEGIN}" -v e3="${OLD_PRIVACY_END}" \
    -v b4="${OLD_RESEARCH_BEGIN}" -v e4="${OLD_RESEARCH_END}" '
      $0 == b1 || $0 == b2 || $0 == b3 || $0 == b4 { skip = 1; next }
      $0 == e1 || $0 == e2 || $0 == e3 || $0 == e4 { skip = 0; next }
      skip != 1 { print }
    ' "${TORRC}" > "${tmp}"

  run_root install -m 0644 "${tmp}" "${TORRC}"
  rm -f "${tmp}"
  info "removed old managed Tor blocks from ${TORRC}"
}

function tor_hashed_control_password() {
  require_cmd tor
  tor --hash-password "${TOR_CONTROL_PASSWORD}" \
    | awk '/^16:/ { print; found = 1; exit } END { exit(found ? 0 : 1) }'
}

function write_tor_config() {
  require_root
  ensure_torrc_exists
  ensure_tor_data_dir
  remove_managed_tor_blocks

  local control_hash
  control_hash="$(tor_hashed_control_password)" \
    || die "failed to hash Tor ControlPort password"

  cat >> "${TORRC}" <<EOF

${TOR_BLOCK_BEGIN}
# Client-only Tor configuration generated by tor-privacy-v3.
# Do not edit this block manually; edit the script and rerun repair/install.
ClientOnly 1
DataDirectory /var/lib/tor
User $(tor_user || printf 'tor')
AvoidDiskWrites 1
SafeSocks 1
WarnUnsafeSocks 1

# SOCKS proxy for torsocks, curl --socks5-hostname, Git proxy settings, etc.
# IsolateSOCKSAuth lets wrappers obtain separate circuits by using different
# SOCKS credentials; torsocks/curl still work without explicit credentials.
SocksPort ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT} IsolateSOCKSAuth

# Transparent proxy endpoints used only when the nftables leak guard is active.
# DNSPort intentionally avoids 5353 because 5353 is mDNS/Chromium territory.
TransPort ${TOR_SOCKS_HOST}:${TOR_TRANS_PORT}
DNSPort ${TOR_SOCKS_HOST}:${TOR_DNS_PORT}
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1

# Local control port used by Tor Browser's documented system-Tor mode.
# It is loopback-only and password-authenticated.
ControlPort ${TOR_CONTROL_URL}
HashedControlPassword ${control_hash}
CookieAuthentication 1
${TOR_BLOCK_END}
EOF

  info "wrote managed Tor block to ${TORRC}"
}

function tor_config_valid() {
  have tor || return 1
  [[ -r "${TORRC}" ]] || return 1
  tor --verify-config -f "${TORRC}" >/dev/null 2>&1
}

function print_tor_config_error() {
  warn "Tor rejected ${TORRC}. Full validation output follows:"
  tor --verify-config -f "${TORRC}" 2>&1 | sed 's/^/  /' >&2 || true
}

function validate_tor_config_or_die() {
  if ! tor_config_valid; then
    print_tor_config_error
    die "fix ${TORRC} before starting ${TOR_SERVICE}"
  fi
}

# -----------------------------------------------------------------------------
# nftables leak guard
# -----------------------------------------------------------------------------
function delete_managed_nft_tables() {
  require_root
  have nft || return 0

  run_cmd nft delete table ip torprivacy_nat >/dev/null 2>&1 || true
  run_cmd nft delete table inet torprivacy_filter >/dev/null 2>&1 || true
  run_cmd nft delete table inet tor_research >/dev/null 2>&1 || true
  run_cmd nft delete table ip torprivacy_v2_nat >/dev/null 2>&1 || true
  run_cmd nft delete table inet torprivacy_v2_filter >/dev/null 2>&1 || true
  run_cmd nft delete table ip "${NFT_TABLE_NAT}" >/dev/null 2>&1 || true
  run_cmd nft delete table inet "${NFT_TABLE_FILTER}" >/dev/null 2>&1 || true
}

function write_nft_rules() {
  require_root
  require_cmd nft

  local allow_lan torid local4 local6
  allow_lan="${1:-no}"
  torid="$(tor_uid)" || die "Tor user not found; install the tor package first"
  prepare_vpn_underlay_endpoints

  local4='0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4'
  local6='::1/128, fe80::/10, ff00::/8'

  if [[ "${allow_lan}" == "yes" ]]; then
    local4='0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4'
    local6='::1/128, fc00::/7, fe80::/10, ff00::/8'
  fi

  run_root install -d -m 0755 /etc/tor

  cat > "${NFT_RULES}" <<EOF
#!/usr/bin/nft -f
# -----------------------------------------------------------------------------
# tor-privacy-v3 nftables leak guard
# Generated by tor-privacy-v3. Do not edit manually.
# -----------------------------------------------------------------------------

table ip ${NFT_TABLE_NAT} {
  define local4 = { ${local4} }

  chain output {
    type nat hook output priority dstnat; policy accept;

    meta skuid ${torid} return
    oifname "lo" return
    ip daddr \$local4 return

$(emit_vpn_underlay_rules nat)
    udp dport 53 redirect to :${TOR_DNS_PORT}
    tcp flags & (fin | syn | rst | ack) == syn redirect to :${TOR_TRANS_PORT}
  }
}

table inet ${NFT_TABLE_FILTER} {
  set local4 {
    type ipv4_addr
    flags interval
    elements = { ${local4} }
  }

  set local6 {
    type ipv6_addr
    flags interval
    elements = { ${local6} }
  }

  chain output {
    type filter hook output priority filter; policy drop;

    # Tor daemon may reach guards, relays, bridges, and directory authorities.
    meta skuid ${torid} accept

    # Local IPC/loopback is not a network anonymity leak.
    oifname "lo" accept
    ip daddr 127.0.0.1 tcp dport { ${TOR_SOCKS_PORT}, ${TOR_TRANS_PORT}, ${TOR_CONTROL_PORT} } accept
    ip daddr 127.0.0.1 udp dport ${TOR_DNS_PORT} accept

    # DHCP is needed after MAC rotation or reconnects.
    udp sport 68 udp dport 67 accept

$(emit_vpn_underlay_rules filter)
EOF

  if [[ "${allow_lan}" == "yes" ]]; then
    cat >> "${NFT_RULES}" <<'EOF'
    # Optional usability mode: allow LAN/private destinations.
    ip daddr @local4 accept
    ip6 daddr @local6 accept

EOF
  fi

  cat >> "${NFT_RULES}" <<EOF
    # Everything else from ordinary processes is blocked. TCP and DNS should
    # have been redirected to Tor by the NAT output chain above.
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

  run_root chmod 0644 "${NFT_RULES}"
  info "wrote nftables rules to ${NFT_RULES}"
}

function write_nft_unit() {
  require_root

  cat > "${NFT_UNIT}" <<EOF
[Unit]
Description=tor-privacy-v3 nftables Tor leak guard
Documentation=man:nft(8)
Wants=${TOR_SERVICE}
After=${TOR_SERVICE}

[Service]
Type=oneshot
ExecStartPre=/usr/bin/bash -c '/usr/bin/nft delete table ip torprivacy_nat 2>/dev/null || true; /usr/bin/nft delete table inet torprivacy_filter 2>/dev/null || true; /usr/bin/nft delete table inet tor_research 2>/dev/null || true; /usr/bin/nft delete table ip torprivacy_v2_nat 2>/dev/null || true; /usr/bin/nft delete table inet torprivacy_v2_filter 2>/dev/null || true; /usr/bin/nft delete table ip ${NFT_TABLE_NAT} 2>/dev/null || true; /usr/bin/nft delete table inet ${NFT_TABLE_FILTER} 2>/dev/null || true'
ExecStart=/usr/bin/nft -f ${NFT_RULES}
ExecStop=/usr/bin/bash -c '/usr/bin/nft delete table ip ${NFT_TABLE_NAT} 2>/dev/null || true; /usr/bin/nft delete table inet ${NFT_TABLE_FILTER} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  run_root chmod 0644 "${NFT_UNIT}"
  run_root systemctl daemon-reload
  info "wrote systemd unit to ${NFT_UNIT}"
}

function nft_rules_valid() {
  have nft || return 1
  [[ -r "${NFT_RULES}" ]] || return 1
  is_root || return 2
  nft -c -f "${NFT_RULES}" >/dev/null 2>&1
}

function validate_nft_rules_or_die() {
  [[ -r "${NFT_RULES}" ]] || return 0

  local nft_status
  if nft_rules_valid; then
    return 0
  else
    nft_status="$?"
  fi

  if [[ "${nft_status}" -eq 2 ]]; then
    warn "nftables syntax check skipped because this process is not root"
    return 0
  fi

  warn "nftables rejected ${NFT_RULES}. Full check output follows:"
  nft -c -f "${NFT_RULES}" 2>&1 | sed 's/^/  /' >&2 || true
  die "fix ${NFT_RULES} before starting the leak guard"
}

function nft_tables_loaded() {
  have nft || return 1
  nft list table ip "${NFT_TABLE_NAT}" >/dev/null 2>&1 \
    && nft list table inet "${NFT_TABLE_FILTER}" >/dev/null 2>&1
}

function protonvpn_killswitch_active() {
  [[ -e /sys/class/net/pvpnksintrf0 ]] && return 0
  [[ -e /sys/class/net/ipv6leakintrf0 ]] && return 0

  have nmcli || return 1
  nmcli -t -f NAME,STATE connection show --active 2>/dev/null \
    | grep -Eq '^(pvpn-killswitch|pvpn-killswitch-ipv6):'
}

function refuse_protonvpn_killswitch_stack() {
  [[ "${TOR_PRIVACY_FORCE_NFT_WITH_PROTON:-0}" == "1" ]] && return 0

  if protonvpn_killswitch_active; then
    die "ProtonVPN killswitch is active; use: sudo tor-privacy browser-start"
  fi
}

function start_killswitch() {
  local persist allow_lan
  persist="${1:-no}"
  allow_lan="${2:-no}"

  require_root
  refuse_protonvpn_killswitch_stack
  write_nft_rules "${allow_lan}"
  write_nft_unit
  validate_nft_rules_or_die

  if [[ "${persist}" == "yes" ]]; then
    run_root systemctl enable --now tor-privacy-nft.service
  else
    run_root systemctl start tor-privacy-nft.service
  fi

  info "nftables leak guard is active"
}

function stop_killswitch() {
  require_root

  if have systemctl; then
    run_root systemctl disable --now tor-privacy-nft.service \
      >/dev/null 2>&1 || true
  fi

  delete_managed_nft_tables
  info "nftables leak guard is inactive"
}

# -----------------------------------------------------------------------------
# Tor service management
# -----------------------------------------------------------------------------
function print_recent_logs() {
  if have journalctl; then
    printf '\nRecent tor.service logs\n'
    printf '%s\n' '-----------------------'
    journalctl -u "${TOR_SERVICE}" -b --no-pager -n 80 2>/dev/null || true

    printf '\nRecent tor-privacy-nft.service logs\n'
    printf '%s\n' '-----------------------------------'
    journalctl -u tor-privacy-nft.service -b --no-pager -n 80 2>/dev/null \
      || true
  fi
}

function start_tor_service() {
  local persist
  persist="${1:-no}"

  require_root
  validate_tor_config_or_die

  if [[ "${persist}" == "yes" ]]; then
    if ! run_root systemctl enable --now "${TOR_SERVICE}"; then
      print_recent_logs >&2
      die "failed to enable/start ${TOR_SERVICE}"
    fi
  else
    if ! run_root systemctl restart "${TOR_SERVICE}"; then
      print_recent_logs >&2
      die "failed to restart ${TOR_SERVICE}"
    fi
  fi

  if ! port_listening_tcp "${TOR_SOCKS_PORT}"; then
    print_recent_logs >&2
    die "Tor started, but SOCKS ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT} is closed"
  fi

  info "Tor is active; SOCKS is listening on ${TOR_SOCKS_URL}"
}

function install_packages() {
  local with_mac
  with_mac="${1:-no}"

  require_root
  require_arch_systemd
  require_cmd pacman

  local -a packages=(
    tor
    torsocks
    nftables
    curl
    ca-certificates
    iproute2
    jq
    git
    wget
  )

  if [[ "${with_mac}" == "yes" ]]; then
    packages+=(networkmanager macchanger)
  fi

  info "installing/checking required packages"
  run_root pacman -S --needed "${packages[@]}"
}

# -----------------------------------------------------------------------------
# NetworkManager MAC randomisation
# -----------------------------------------------------------------------------
function enable_mac_randomisation() {
  require_root
  require_cmd systemctl

  run_root install -d -m 0755 /etc/NetworkManager/conf.d

  cat > "${NM_MAC_CONF}" <<'EOF'
# -----------------------------------------------------------------------------
# tor-privacy-v3 NetworkManager MAC randomisation defaults
# -----------------------------------------------------------------------------
[device-90-tor-privacy]
wifi.scan-rand-mac-address=yes

[connection-90-tor-privacy]
connection.stable-id=${RANDOM}
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv4.dhcp-client-id=stable
ipv6.dhcp-duid=stable-uuid
ipv6.ip6-privacy=2
EOF

  run_root chmod 0644 "${NM_MAC_CONF}"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    run_root systemctl reload NetworkManager.service >/dev/null 2>&1 \
      || run_root systemctl restart NetworkManager.service
  else
    warn "NetworkManager.service not found; config written but not reloaded"
  fi

  info "enabled NetworkManager MAC randomisation defaults"
}

function disable_mac_randomisation() {
  require_root
  run_root rm -f "${NM_MAC_CONF}"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    run_root systemctl reload NetworkManager.service >/dev/null 2>&1 \
      || run_root systemctl restart NetworkManager.service
  fi

  info "disabled managed NetworkManager MAC randomisation defaults"
}

function rotate_mac_now() {
  require_root
  require_cmd macchanger
  require_cmd ip

  local iface
  iface=""

  while (($#)); do
    case "${1,,}" in
      --iface | -i)
        iface="${2:-}"
        shift 2
        ;;
      -h | -help | --help)
        cat <<'HELP'
Usage
  sudo tor-privacy mac-rotate --iface IFACE

This disconnects IFACE, randomises its MAC address with macchanger, brings the
interface up, and asks NetworkManager to reconnect it when nmcli is available.
HELP
        return 0
        ;;
      *) die "unknown mac-rotate option: $1" ;;
    esac
  done

  [[ -n "${iface}" ]] || die "missing --iface IFACE"
  [[ -d "/sys/class/net/${iface}" ]] || die "no such interface: ${iface}"

  if have nmcli; then
    run_root nmcli device disconnect "${iface}" >/dev/null 2>&1 || true
  fi

  run_root ip link set dev "${iface}" down
  run_root macchanger -r "${iface}"
  run_root ip link set dev "${iface}" up

  if have nmcli; then
    run_root nmcli device connect "${iface}" >/dev/null 2>&1 || true
  fi
}

# -----------------------------------------------------------------------------
# CLI wrappers
# -----------------------------------------------------------------------------
function install_torsocks_wrapper() {
  require_root

  cat > "${TW_BIN}" <<'EOF'
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tw — run a command through Tor with torsocks when Tor is available.
# -----------------------------------------------------------------------------
set -euo pipefail

TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
TOR_SOCKS_HOST="${TOR_SOCKS_HOST:-127.0.0.1}"

function usage() {
  cat <<'HELP'
tw — run a command through Tor using torsocks

Usage
  tw COMMAND [ARGS...]
  tw --check
  tw --ip
  tw --help

Environment
  TW_STRICT=1           refuse to run direct if Tor is unavailable
  TOR_SOCKS_HOST=127.0.0.1
  TOR_SOCKS_PORT=9050
HELP
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function tor_ready() {
  have systemctl || return 1
  systemctl --quiet is-active tor.service || return 1

  if have ss; then
    ss -ltnH 2>/dev/null | grep -qE ":${TOR_SOCKS_PORT}([[:space:]]|$)"
  else
    return 1
  fi
}

function fail_or_warn() {
  if [[ "${TW_STRICT:-0}" == "1" ]]; then
    printf 'tw: Tor is inactive or SOCKS :%s is closed.\n' \
      "${TOR_SOCKS_PORT}" >&2
    exit 2
  fi

  printf 'tw: Tor unavailable; running without Tor.\n' >&2
}

function has_explicit_proxy() {
  local arg

  if [[ -n "${ALL_PROXY:-}${HTTPS_PROXY:-}${HTTP_PROXY:-}${FTP_PROXY:-}" \
        || -n "${all_proxy:-}${https_proxy:-}${http_proxy:-}${ftp_proxy:-}" ]]; then
    return 0
  fi

  for arg in "$@"; do
    case "${arg}" in
      --socks5* | --proxy | --proxy1.0 | --proxy-anyauth | --noproxy | -x)
        return 0
        ;;
    esac
  done

  return 1
}

function main() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 0
  fi

  case "${1,,}" in
    -h | -help | --help)
      usage
      exit 0
      ;;
    --check)
      tor_ready || { fail_or_warn; exit 2; }
      curl --max-time 30 --socks5-hostname \
        "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
        -fsS https://check.torproject.org/api/ip
      exit 0
      ;;
    --ip)
      tor_ready || { fail_or_warn; exit 2; }
      curl --max-time 30 --socks5-hostname \
        "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
        -fsS https://ifconfig.io/ip
      exit 0
      ;;
  esac

  if ! tor_ready; then
    fail_or_warn
    exec "$@"
  fi

  if [[ "${1}" == "torsocks" ]] || has_explicit_proxy "$@"; then
    exec "$@"
  fi

  exec torsocks "$@"
}

main "$@"
EOF

  run_root chmod 0755 "${TW_BIN}"
  info "installed torsocks wrapper as ${TW_BIN}"
}

function env_cmd() {
  cat <<EOF
export ALL_PROXY='${TOR_SOCKS_URL}'
export HTTP_PROXY='${TOR_SOCKS_URL}'
export HTTPS_PROXY='${TOR_SOCKS_URL}'
export FTP_PROXY='${TOR_SOCKS_URL}'
export all_proxy='${TOR_SOCKS_URL}'
export http_proxy='${TOR_SOCKS_URL}'
export https_proxy='${TOR_SOCKS_URL}'
export ftp_proxy='${TOR_SOCKS_URL}'
export NO_PROXY='localhost,127.0.0.1,::1'
export no_proxy='localhost,127.0.0.1,::1'
EOF
}

function shell_cmd() {
  require_cmd bash
  eval "$(env_cmd)"
  export PS1="[tor] ${PS1:-\\u@\\h:\\w\\$ }"
  exec "${SHELL:-/usr/bin/env bash}"
}

function run_torsocks_cmd() {
  (($# > 0)) || die "missing command after run"
  require_cmd torsocks
  torsocks "$@"
}

function curl_cmd() {
  (($# > 0)) || die "missing URL for curl"
  require_cmd curl
  curl --location --fail-with-body \
    --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" "$@"
}

function wget_cmd() {
  (($# > 0)) || die "missing URL for wget"
  require_cmd wget
  ALL_PROXY="${TOR_SOCKS_URL}" \
    HTTPS_PROXY="${TOR_SOCKS_URL}" \
    HTTP_PROXY="${TOR_SOCKS_URL}" \
    wget "$@"
}

function git_clone_cmd() {
  (($# >= 1)) || die "missing repository URL"
  require_cmd git
  git -c "http.proxy=${TOR_SOCKS_URL}" \
    -c "https.proxy=${TOR_SOCKS_URL}" \
    -c "protocol.version=2" clone "$@"
}

function git_ls_cmd() {
  (($# >= 1)) || die "missing repository URL"
  require_cmd git
  git -c "http.proxy=${TOR_SOCKS_URL}" \
    -c "https.proxy=${TOR_SOCKS_URL}" \
    -c "protocol.version=2" ls-remote "$@"
}

function check_cmd() {
  require_cmd curl
  curl --silent --show-error --max-time 30 \
    --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
    "${TOR_CHECK_URL}" | if have jq; then jq .; else cat; fi
}

function ip_cmd() {
  require_cmd curl
  curl --silent --show-error --max-time 30 \
    --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
    "${TOR_FALLBACK_IP_URL}"
}

# -----------------------------------------------------------------------------
# Tor Browser integration
# -----------------------------------------------------------------------------
function require_not_root() {
  ! is_root || die "run this command as your desktop user, not with sudo"
}

function tor_browser_control_password_env() {
  if [[ -n "${TOR_CONTROL_PASSWD:-}" ]]; then
    case "${TOR_CONTROL_PASSWD}" in
      \"*) printf '%s\n' "${TOR_CONTROL_PASSWD}" ;;
      *) printf '"%s"\n' "${TOR_CONTROL_PASSWD}" ;;
    esac
  else
    printf '"%s"\n' "${TOR_CONTROL_PASSWORD}"
  fi
}

function tor_browser_start_script() {
  local candidate tbb_root

  if [[ -n "${TOR_BROWSER_START:-}" ]]; then
    [[ -x "${TOR_BROWSER_START}" ]] \
      || die "TOR_BROWSER_START is not executable: ${TOR_BROWSER_START}"
    printf '%s\n' "${TOR_BROWSER_START}"
    return 0
  fi

  tbb_root="${HOME}/.local/share/torbrowser/tbb/x86_64"

  for candidate in \
    "${tbb_root}/tor-browser/Browser/start-tor-browser" \
    "${HOME}/tor-browser/Browser/start-tor-browser" \
    "${HOME}/Downloads/tor-browser/Browser/start-tor-browser"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

function tor_browser_profile_dir() {
  local start_script browser_dir profile_dir

  if [[ -n "${TOR_BROWSER_PROFILE_DIR:-}" ]]; then
    printf '%s\n' "${TOR_BROWSER_PROFILE_DIR}"
    return 0
  fi

  start_script="$(tor_browser_start_script)" || return 1
  browser_dir="$(cd "$(dirname "${start_script}")" && pwd)"
  profile_dir="${browser_dir}/TorBrowser/Data/Browser/profile.default"

  printf '%s\n' "${profile_dir}"
}

function tor_browser_profile_locked() {
  local profile_dir lock
  profile_dir="$1"

  for lock in \
    "${profile_dir}/lock" \
    "${profile_dir}/parent.lock" \
    "${profile_dir}/.parentlock"; do
    [[ -e "${lock}" ]] && return 0
  done

  return 1
}

function tor_browser_process_running() {
  have pgrep || return 2

  pgrep -u "$(id -u)" -f \
    '/tor-browser/Browser/(firefox|start-tor-browser)|/TorBrowser/' \
    >/dev/null 2>&1
}

function remove_tor_browser_profile_locks() {
  local profile_dir lock
  profile_dir="$1"

  for lock in \
    "${profile_dir}/lock" \
    "${profile_dir}/parent.lock" \
    "${profile_dir}/.parentlock"; do
    [[ -e "${lock}" || -L "${lock}" ]] || continue
    rm -f "${lock}"
  done
}

function require_tor_browser_profile_closed() {
  local profile_dir
  profile_dir="$1"

  [[ "${TOR_BROWSER_IGNORE_LOCK:-0}" == "1" ]] && return 0

  if tor_browser_profile_locked "${profile_dir}"; then
    if tor_browser_process_running; then
      die "Tor Browser profile appears to be running; close Tor Browser first"
    fi

    warn "Tor Browser profile lock was stale; removing lock files"
    remove_tor_browser_profile_locks "${profile_dir}"
  fi
}

function user_file_has_managed_block() {
  local file
  file="$1"

  [[ -f "${file}" ]] || return 1
  grep -Fxq "${TOR_BROWSER_PREF_BEGIN}" "${file}"
}

function write_tor_browser_system_tor_prefs() {
  require_not_root

  local profile_dir userjs tmp backup
  profile_dir="$(tor_browser_profile_dir)" \
    || die "Tor Browser bundle not found; install/run torbrowser-launcher first"
  userjs="${profile_dir}/user.js"

  require_tor_browser_profile_closed "${profile_dir}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "would write Tor Browser system-Tor preferences to ${userjs}"
    return 0
  fi

  install -d -m 0700 "${profile_dir}"

  if [[ -f "${userjs}" ]] && ! user_file_has_managed_block "${userjs}"; then
    backup="${userjs}.$(timestamp).tor-privacy.bak"
    cp -p "${userjs}" "${backup}"
    info "backup: ${backup}"
  fi

  tmp="$(mktemp)"
  if [[ -f "${userjs}" ]]; then
    awk \
      -v b="${TOR_BROWSER_PREF_BEGIN}" \
      -v e="${TOR_BROWSER_PREF_END}" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip != 1 { print }
      ' "${userjs}" > "${tmp}"
  fi

  cat >> "${tmp}" <<EOF

${TOR_BROWSER_PREF_BEGIN}
// Use the already-running system Tor. This avoids launching Tor Browser's
// bundled Tor process, which the tor-privacy leak guard intentionally blocks.
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "${TOR_SOCKS_HOST}");
user_pref("network.proxy.socks_port", ${TOR_SOCKS_PORT});
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, ::1");
user_pref("extensions.torbutton.inserted_button", true);
user_pref("extensions.torlauncher.start_tor", false);
user_pref("extensions.torlauncher.prompt_at_startup", false);
user_pref("extensions.torlauncher.control_port", ${TOR_CONTROL_PORT});
user_pref("extensions.torlauncher.loglevel", 2);
user_pref("extensions.torlauncher.logmethod", 0);
user_pref("extensions.torbutton.launch_warning", false);
user_pref("extensions.torbutton.loglevel", 2);
user_pref("extensions.torbutton.logmethod", 0);
user_pref("torbrowser.about_torconnect.user_has_ever_clicked_connect", true);
${TOR_BROWSER_PREF_END}
EOF

  install -m 0600 "${tmp}" "${userjs}"
  rm -f "${tmp}"
  info "wrote Tor Browser system-Tor preferences to ${userjs}"
}

function tor_browser_config_cmd() {
  (($# == 0)) || die "browser-config does not take arguments"
  write_tor_browser_system_tor_prefs
}

function browser_start_cmd() {
  local persist
  persist=no

  while (($#)); do
    case "${1,,}" in
      --persist | --persistent) persist=yes; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown browser-start option: $1" ;;
    esac
  done

  require_root
  require_arch_systemd
  require_cmd tor

  ensure_state_dirs
  backup_cmd
  write_tor_config
  validate_tor_config_or_die
  start_tor_service "${persist}"

  info "browser-ready Tor is active without the v3 nftables guard"
}

function tor_browser_doctor_cmd() {
  (($# == 0)) || die "browser-doctor does not take arguments"
  require_not_root

  local start_script profile_dir userjs
  start_script="$(tor_browser_start_script)" \
    || die "Tor Browser bundle not found; install/run torbrowser-launcher first"
  profile_dir="$(tor_browser_profile_dir)" \
    || die "Tor Browser profile not found"
  userjs="${profile_dir}/user.js"

  printf 'Tor Browser system-Tor doctor\n'
  printf '=============================\n\n'
  printf 'start script:       %s\n' "${start_script}"
  printf 'profile:            %s\n' "${profile_dir}"
  printf 'profile locked:     %s\n' \
    "$(print_bool tor_browser_profile_locked "${profile_dir}")"
  printf 'managed prefs:      %s\n' \
    "$(print_bool user_file_has_managed_block "${userjs}")"
  printf 'tor.service active: %s\n' "$(print_bool unit_active "${TOR_SERVICE}")"
  printf 'SOCKS %s open:       %s\n' \
    "${TOR_SOCKS_PORT}" "$(print_bool port_listening_tcp "${TOR_SOCKS_PORT}")"
  printf 'Control %s open:     %s\n' \
    "${TOR_CONTROL_PORT}" \
    "$(print_bool port_listening_tcp "${TOR_CONTROL_PORT}")"
}

function tor_browser_cmd() {
  require_not_root

  local start_script
  start_script="$(tor_browser_start_script)" \
    || die "Tor Browser bundle not found; install/run torbrowser-launcher first"

  if ! unit_active "${TOR_SERVICE}" \
      || ! port_listening_tcp "${TOR_SOCKS_PORT}" \
      || ! port_listening_tcp "${TOR_CONTROL_PORT}"; then
    die "system Tor is not browser-ready; run: sudo tor-privacy browser-start"
  fi

  write_tor_browser_system_tor_prefs

  export TOR_SKIP_LAUNCH=1
  export TOR_SOCKS_HOST
  export TOR_SOCKS_PORT
  export TOR_CONTROL_HOST
  export TOR_CONTROL_PORT
  TOR_CONTROL_PASSWD="$(tor_browser_control_password_env)"
  export TOR_CONTROL_PASSWD

  info "launching Tor Browser through system Tor at ${TOR_SOCKS_URL}"
  info "using Tor control port at ${TOR_CONTROL_URL}"
  exec "${start_script}" "$@"
}

# -----------------------------------------------------------------------------
# High-level commands
# -----------------------------------------------------------------------------
function parse_start_options() {
  reset_vpn_underlay_options
  USE_KILLSWITCH=no
  USE_PERSIST=no
  USE_ALLOW_LAN=no

  while (($#)); do
    case "${1,,}" in
      --killswitch | --strict)
        USE_KILLSWITCH=yes
        shift
        ;;
      --persist | --persistent)
        USE_PERSIST=yes
        shift
        ;;
      --allow-lan)
        USE_ALLOW_LAN=yes
        shift
        ;;
      --vpn-endpoint)
        add_vpn_endpoint "${2:-}"
        shift 2
        ;;
      --vpn-underlay | --proton-underlay | --detect-vpn | --no-vpn-underlay)
        parse_vpn_underlay_arg "$1"
        shift
        ;;
      -h | -help | --help)
        usage
        exit 0
        ;;
      *) die "unknown start option: $1" ;;
    esac
  done
}

function repair_cmd() {
  local allow_lan
  reset_vpn_underlay_options
  allow_lan=no

  while (($#)); do
    case "${1,,}" in
      --allow-lan) allow_lan=yes; shift ;;
      --vpn-endpoint) add_vpn_endpoint "${2:-}"; shift 2 ;;
      --vpn-underlay | --proton-underlay | --detect-vpn | --no-vpn-underlay)
        parse_vpn_underlay_arg "$1"; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown repair option: $1" ;;
    esac
  done

  require_root
  require_arch_systemd
  require_cmd tor
  require_cmd systemctl

  ensure_state_dirs
  backup_cmd
  write_tor_config
  write_nft_rules "${allow_lan}"
  write_nft_unit
  validate_tor_config_or_die
  validate_nft_rules_or_die
  start_tor_service no
}

function install_self() {
  require_root
  run_root install -m 0755 "$0" "${INSTALL_BIN}"
  info "installed controller as ${INSTALL_BIN}"
}

function install_cmd() {
  local use_killswitch use_persist use_allow_lan use_mac no_start
  reset_vpn_underlay_options
  use_killswitch=no
  use_persist=no
  use_allow_lan=no
  use_mac=no
  no_start=no

  while (($#)); do
    case "${1,,}" in
      --killswitch | --strict) use_killswitch=yes; shift ;;
      --persist | --persistent) use_persist=yes; shift ;;
      --allow-lan) use_allow_lan=yes; shift ;;
      --vpn-endpoint) add_vpn_endpoint "${2:-}"; shift 2 ;;
      --vpn-underlay | --proton-underlay | --detect-vpn | --no-vpn-underlay)
        parse_vpn_underlay_arg "$1"; shift ;;
      --mac-random) use_mac=yes; shift ;;
      --no-start) no_start=yes; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown install option: $1" ;;
    esac
  done

  require_root
  install_packages "${use_mac}"
  ensure_state_dirs
  backup_cmd
  write_tor_config
  write_nft_rules "${use_allow_lan}"
  write_nft_unit
  validate_tor_config_or_die
  validate_nft_rules_or_die
  install_self
  install_torsocks_wrapper

  [[ "${use_mac}" == yes ]] && enable_mac_randomisation

  if [[ "${no_start}" == yes ]]; then
    info "installation completed; Tor was not started because --no-start was set"
    return 0
  fi

  start_tor_service "${use_persist}"

  if [[ "${use_killswitch}" == yes ]]; then
    start_killswitch "${use_persist}" "${use_allow_lan}"
  fi

  info "installation completed"
}

function start_cmd() {
  parse_start_options "$@"
  require_root
  require_arch_systemd
  require_cmd tor

  ensure_state_dirs
  backup_cmd
  write_tor_config
  write_nft_rules "${USE_ALLOW_LAN}"
  write_nft_unit
  validate_tor_config_or_die
  validate_nft_rules_or_die
  start_tor_service "${USE_PERSIST}"

  if [[ "${USE_KILLSWITCH}" == yes ]]; then
    start_killswitch "${USE_PERSIST}" "${USE_ALLOW_LAN}"
  fi
}

function stop_cmd() {
  local keep_tor
  keep_tor=no

  while (($#)); do
    case "${1,,}" in
      --keep-tor) keep_tor=yes; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown stop option: $1" ;;
    esac
  done

  require_root
  stop_killswitch

  if [[ "${keep_tor}" != yes ]]; then
    run_root systemctl disable --now "${TOR_SERVICE}" >/dev/null 2>&1 || true
    info "stopped and disabled ${TOR_SERVICE}"
  else
    info "kept ${TOR_SERVICE} unchanged"
  fi
}

function strict_on_cmd() {
  local persist allow_lan
  reset_vpn_underlay_options
  persist=no
  allow_lan=no

  while (($#)); do
    case "${1,,}" in
      --persist | --persistent) persist=yes; shift ;;
      --allow-lan) allow_lan=yes; shift ;;
      --vpn-endpoint) add_vpn_endpoint "${2:-}"; shift 2 ;;
      --vpn-underlay | --proton-underlay | --detect-vpn | --no-vpn-underlay)
        parse_vpn_underlay_arg "$1"; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown strict-on option: $1" ;;
    esac
  done

  require_root
  if ! unit_active "${TOR_SERVICE}"; then
    write_tor_config
    validate_tor_config_or_die
    start_tor_service "${persist}"
  fi

  start_killswitch "${persist}" "${allow_lan}"
}

function uninstall_cmd() {
  local purge
  purge=no

  while (($#)); do
    case "${1,,}" in
      --purge) purge=yes; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown uninstall option: $1" ;;
    esac
  done

  require_root
  confirm "Remove tor-privacy-v3 managed files and disable managed services?"

  stop_killswitch || true
  run_root systemctl disable --now "${TOR_SERVICE}" >/dev/null 2>&1 || true
  remove_managed_tor_blocks || true
  run_root rm -f \
    "${NFT_RULES}" "${OLD_V2_NFT_RULES}" "${NFT_UNIT}" \
    "${INSTALL_BIN}" "${TW_BIN}"
  run_root systemctl daemon-reload
  info "removed tor-privacy managed files"

  if [[ "${purge}" == yes ]]; then
    warn "packages were not removed automatically"
    warn "manual removal, if desired: sudo pacman -Rns tor torsocks nftables"
  fi
}

function vpn_detect_cmd() {
  reset_vpn_underlay_options
  VPN_UNDERLAY_AUTO=yes
  VPN_UNDERLAY_REQUESTED=yes
  prepare_vpn_underlay_endpoints

  cat <<EOF
Detected VPN underlay endpoints
  $(print_vpn_underlay_status)

Use
  sudo tor-privacy start --killswitch --vpn-underlay

If this prints "none" and Proton is using OpenVPN, find the endpoint with:
  sudo ss -Htunp | grep -Ei 'openvpn|proton'

If WireGuard detection fails with a permission error, rerun vpn-detect with
sudo or use start/strict-on with sudo, which is required for nftables anyway.

Then pass it manually, for example:
  sudo tor-privacy start --killswitch --vpn-endpoint udp:IP:1194
  sudo tor-privacy start --killswitch --vpn-endpoint tcp:IP:443
EOF
}

# -----------------------------------------------------------------------------
# Status and doctor
# -----------------------------------------------------------------------------
function managed_block_count() {
  [[ -r "${TORRC}" ]] || { printf '0'; return 0; }
  grep -Ec \
    '^(# >>> tor-privacy-v3 managed block >>>|# >>> tor-privacy-v2 managed block >>>|# >>> tor-privacy managed block >>>|# BEGIN managed by tor-research)$' \
    "${TORRC}" || true
}

function status_cmd() {
  local mode
  mode="deactivated"
  prepare_vpn_underlay_endpoints

  if unit_active "${TOR_SERVICE}" || nft_tables_loaded; then
    mode="active until reboot/poweroff"
  fi

  if unit_enabled "${TOR_SERVICE}" && unit_enabled tor-privacy-nft.service; then
    mode="persistent Tor + persistent leak guard"
  elif unit_enabled "${TOR_SERVICE}"; then
    mode="Tor persistent; leak guard inactive"
  fi

  cat <<EOF
Status: ${mode}

Components
  tor.service active:              $(print_bool unit_active "${TOR_SERVICE}")
  tor.service enabled:             $(print_bool unit_enabled "${TOR_SERVICE}")
  SOCKS ${TOR_SOCKS_PORT} listening:          $(print_bool port_listening_tcp "${TOR_SOCKS_PORT}")
  TransPort ${TOR_TRANS_PORT} listening:      $(print_bool port_listening_tcp "${TOR_TRANS_PORT}")
  DNSPort ${TOR_DNS_PORT} listening:          $(print_bool port_listening_udp "${TOR_DNS_PORT}")
  ControlPort ${TOR_CONTROL_PORT} listening:  $(print_bool port_listening_tcp "${TOR_CONTROL_PORT}")
  v3 nft tables loaded:            $(print_bool nft_tables_loaded)
  nft unit enabled:                $(print_bool unit_enabled tor-privacy-nft.service)
  VPN underlay endpoints:          $(print_vpn_underlay_status)
  NetworkManager MAC config:       $([[ -f "${NM_MAC_CONF}" ]] && printf yes || printf no)
  tw wrapper installed:            $([[ -x "${TW_BIN}" ]] && printf yes || printf no)
  managed torrc blocks:            $(managed_block_count)
  Tor user:                        $(tor_user 2>/dev/null || printf 'not found')

Ports matching 9040/9050/9051/9053/5353
EOF

  if have ss; then
    ss -ltnup 2>/dev/null \
      | awk '/:(9040|9050|9051|9053|5353)[[:space:]]/ { print "  " $0 }' \
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
  torsocks wrap:   ${TW_BIN}
  backups:         ${BACKUP_DIR}
EOF
}

CHECK_FAILS=0
CHECK_WARNS=0

function report() {
  local level name msg
  level="$1"
  name="$2"
  msg="${3:-}"

  case "${level}" in
    PASS) printf '[PASS] %-34s %s\n' "${name}" "${msg}" ;;
    WARN)
      printf '[WARN] %-34s %s\n' "${name}" "${msg}"
      CHECK_WARNS=$((CHECK_WARNS + 1))
      ;;
    FAIL)
      printf '[FAIL] %-34s %s\n' "${name}" "${msg}"
      CHECK_FAILS=$((CHECK_FAILS + 1))
      ;;
    SKIP) printf '[SKIP] %-34s %s\n' "${name}" "${msg}" ;;
    *) die "internal error: unknown report level ${level}" ;;
  esac
}

function doctor_cmd() {
  local online journal cmd
  online=no
  journal=no

  while (($#)); do
    case "${1,,}" in
      --online) online=yes; shift ;;
      --journal) journal=yes; shift ;;
      -h | -help | --help) usage; return 0 ;;
      *) die "unknown doctor option: $1" ;;
    esac
  done

  CHECK_FAILS=0
  CHECK_WARNS=0

  printf 'tor-privacy doctor\n'
  printf '==================\n\n'

  [[ -r /etc/arch-release ]] \
    && report PASS "Arch Linux" "/etc/arch-release present" \
    || report FAIL "Arch Linux" "not detected"

  [[ -d /run/systemd/system ]] \
    && report PASS "systemd runtime" "detected" \
    || report FAIL "systemd runtime" "not detected"

  for cmd in bash systemctl tor torsocks nft curl ss awk grep sed install; do
    have "${cmd}" \
      && report PASS "command: ${cmd}" "found" \
      || report FAIL "command: ${cmd}" "missing"
  done

  printf '\n'

  tor_user >/dev/null 2>&1 \
    && report PASS "Tor user" "$(tor_user) uid=$(tor_uid)" \
    || report FAIL "Tor user" "not found"

  [[ -r "${TORRC}" ]] \
    && report PASS "Tor config" "${TORRC}" \
    || report FAIL "Tor config" "missing: ${TORRC}"

  [[ "$(managed_block_count)" -le 1 ]] \
    && report PASS "managed torrc blocks" "$(managed_block_count)" \
    || report FAIL "managed torrc blocks" "$(managed_block_count); run: sudo tor-privacy repair"

  if tor_config_valid; then
    report PASS "Tor config syntax" "valid"
  else
    report FAIL "Tor config syntax" "run: sudo tor --verify-config -f ${TORRC}"
  fi

  unit_active "${TOR_SERVICE}" \
    && report PASS "tor.service active" "yes" \
    || report FAIL "tor.service active" "no"

  unit_enabled "${TOR_SERVICE}" \
    && report PASS "tor.service enabled" "yes" \
    || report WARN "tor.service enabled" "no"

  port_listening_tcp "${TOR_SOCKS_PORT}" \
    && report PASS "SOCKS ${TOR_SOCKS_PORT}" "listening" \
    || report FAIL "SOCKS ${TOR_SOCKS_PORT}" "closed"

  port_listening_tcp "${TOR_TRANS_PORT}" \
    && report PASS "TransPort ${TOR_TRANS_PORT}" "listening" \
    || report WARN "TransPort ${TOR_TRANS_PORT}" "closed"

  port_listening_udp "${TOR_DNS_PORT}" \
    && report PASS "DNSPort ${TOR_DNS_PORT}" "listening" \
    || report WARN "DNSPort ${TOR_DNS_PORT}" "closed"

  port_listening_tcp "${TOR_CONTROL_PORT}" \
    && report PASS "ControlPort ${TOR_CONTROL_PORT}" "listening" \
    || report WARN "ControlPort ${TOR_CONTROL_PORT}" "closed"

  nft_tables_loaded \
    && report PASS "v3 nft tables" "loaded" \
    || report WARN "v3 nft tables" "not loaded"

  [[ -r "${NFT_RULES}" ]] \
    && report PASS "nft rules file" "${NFT_RULES}" \
    || report WARN "nft rules file" "missing"

  if [[ -r "${NFT_RULES}" ]]; then
    if ! is_root; then
      report SKIP "nft syntax" "requires sudo"
    elif nft_rules_valid; then
      report PASS "nft syntax" "valid"
    else
      report FAIL "nft syntax" "run: sudo nft -c -f ${NFT_RULES}"
    fi
  fi

  [[ -f "${NM_MAC_CONF}" ]] \
    && report PASS "NM MAC config" "enabled" \
    || report WARN "NM MAC config" "not enabled"

  if [[ "${online}" == yes ]]; then
    printf '\nOnline checks\n'
    printf '%s\n' '-------------'

    if check_cmd >/tmp/tor-privacy-check.json 2>/dev/null \
      && grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true' \
        /tmp/tor-privacy-check.json; then
      report PASS "Tor route" "check.torproject.org says Tor"
    else
      report FAIL "Tor route" "not confirmed"
    fi
    rm -f /tmp/tor-privacy-check.json
  fi

  printf '\nSummary: %d failure(s), %d warning(s).\n' \
    "${CHECK_FAILS}" "${CHECK_WARNS}"

  if [[ "${journal}" == yes ]]; then
    print_recent_logs
  fi

  (( CHECK_FAILS == 0 ))
}

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------
function parse_global_options() {
  REMAINING_ARGS=()

  while (($#)); do
    case "${1,,}" in
      -n | --dry-run)
        DRY_RUN=true
        shift
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      -v | --verbose)
        VERBOSE=true
        shift
        ;;
      -h | -help | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown global option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  REMAINING_ARGS=("$@")
}

function main() {
  parse_global_options "$@"
  set -- "${REMAINING_ARGS[@]}"

  local cmd
  cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 0; }
  shift || true

  case "${cmd,,}" in
    install) install_cmd "$@" ;;
    repair | fix) repair_cmd "$@" ;;
    start | on | activate) start_cmd "$@" ;;
    stop | off | deactivate) stop_cmd "$@" ;;
    strict-on | killswitch-on) strict_on_cmd "$@" ;;
    strict-off | killswitch-off) stop_killswitch "$@" ;;
    status) status_cmd "$@" ;;
    doctor) doctor_cmd "$@" ;;
    logs | journal) print_recent_logs "$@" ;;
    backup) backup_cmd "$@" ;;
    env) env_cmd "$@" ;;
    shell) shell_cmd "$@" ;;
    run) run_torsocks_cmd "$@" ;;
    curl) curl_cmd "$@" ;;
    wget) wget_cmd "$@" ;;
    git-clone) git_clone_cmd "$@" ;;
    git-ls) git_ls_cmd "$@" ;;
    check) check_cmd "$@" ;;
    ip) ip_cmd "$@" ;;
    vpn-detect) vpn_detect_cmd "$@" ;;
    browser | tor-browser) tor_browser_cmd "$@" ;;
    browser-config | tor-browser-config) tor_browser_config_cmd "$@" ;;
    browser-start | tor-browser-start) browser_start_cmd "$@" ;;
    browser-doctor | tor-browser-doctor) tor_browser_doctor_cmd "$@" ;;
    mac-on) enable_mac_randomisation "$@" ;;
    mac-off) disable_mac_randomisation "$@" ;;
    mac-rotate) rotate_mac_now "$@" ;;
    uninstall) uninstall_cmd "$@" ;;
    help | -h | -help | --help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
