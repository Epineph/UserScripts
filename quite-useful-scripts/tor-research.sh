#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tor-research
# ---------------------------------------------------------------------------
# Reversible Tor-oriented research mode for Arch Linux.
#
# Purpose:
#   - Make legal, privacy-preserving reading and OSINT research safer.
#   - Route explicit CLI tools through Tor.
#   - Optionally block ordinary clearnet egress while Tor remains usable.
#   - Provide status, checks, backups, and a clean revert path.
#
# Non-goals:
#   - This is not an anti-forensic tool.
#   - This does not delete logs, browser history, journal entries, or evidence.
#   - This does not make a user "invisible"; it reduces accidental leakage.
#
# Design:
#   - Tor service provides SOCKS on 127.0.0.1:9050.
#   - CLI tools use socks5h://127.0.0.1:9050, so DNS resolution is remote.
#   - Optional nftables strict mode permits Tor daemon egress but blocks
#     public clearnet TCP/UDP/ICMP from other users/processes.
#   - Revert deletes only the managed nftables table: inet tor_research.
# ---------------------------------------------------------------------------

set -Eeuo pipefail

readonly APP="tor-research"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${APP}"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${APP}"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP}"
readonly BACKUP_DIR="${STATE_DIR}/backups"

readonly TOR_SOCKS_HOST="127.0.0.1"
readonly TOR_SOCKS_PORT="9050"
readonly TOR_SOCKS_URL="socks5h://${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}"

readonly NFT_TABLE_FAMILY="inet"
readonly NFT_TABLE_NAME="tor_research"

readonly MANAGED_BEGIN="# BEGIN managed by tor-research"
readonly MANAGED_END="# END managed by tor-research"

DRY_RUN=false
VERBOSE=false
ASSUME_YES=false

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function helpout() {
  local pager
  pager="${HELP_PAGER:-cat}"

  cat <<'EOF' | ${pager}
tor-research - reversible Tor-oriented research mode for Arch Linux

USAGE
  tor-research [global-options] <command> [command-options]

GLOBAL OPTIONS
  -n, --dry-run
      Print actions without changing the system.

  -y, --yes
      Do not prompt for confirmation where confirmation is normally used.

  -v, --verbose
      Print additional details.

  -h, --help
      Show this help text.

CORE COMMANDS
  install
      Install/check required packages and ensure Tor has a local SOCKS port.

  start
      Start tor.service and verify that the SOCKS port is reachable.

  stop
      Stop tor.service. This does not remove firewall rules.

  status
      Show Tor, SOCKS, nftables, and wrapper status.

  doctor
      Run local sanity checks and print concrete repair suggestions.

  backup
      Save current Tor and nftables state under:
        ~/.local/state/tor-research/backups/

  strict-on [--block-lan]
      Add a temporary nftables table that blocks public clearnet TCP, UDP,
      and ICMP egress for ordinary processes while allowing the Tor daemon.

      Default:
        - allows loopback;
        - allows local/private network ranges;
        - allows the Tor daemon user to reach the Internet;
        - blocks ordinary public clearnet TCP/UDP/ICMP;
        - blocks direct DNS to public destinations.

      With --block-lan:
        - allows loopback only;
        - blocks LAN/private ranges too, except Tor daemon egress.

  strict-off
      Delete only the managed nftables table:
        table inet tor_research

  revert [--keep-tor-running]
      Disable strict mode, remove the managed Tor config block, and stop Tor
      unless --keep-tor-running is given.

RESEARCH COMMANDS
  env
      Print proxy environment variables for a shell:
        eval "$(tor-research env)"

  shell
      Start an interactive shell with proxy environment variables set.

  run <command> [args...]
      Run a command with torsocks. Useful for many TCP CLI tools.

  curl <url> [curl-args...]
      Run curl through Tor with remote DNS resolution.

  wget <url> [wget-args...]
      Run wget through Tor with remote DNS resolution.

  git-clone <repo-url> [directory]
      Clone a Git repository through Tor using Git HTTP(S) proxy settings.

  git-ls <repo-url>
      Run git ls-remote through Tor.

  check
      Query Tor Project's check endpoint through Tor.

  leak-test
      Check whether direct public traffic is blocked when strict mode is on.

  browser
      Print Tor Browser guidance and try to launch it if a known launcher is
      installed. Tor Browser is preferred for websites; CLI wrappers are for
      command-line research and downloads.

EXAMPLES
  tor-research install
  tor-research start
  tor-research check
  tor-research strict-on
  tor-research leak-test
  tor-research curl https://check.torproject.org/api/ip
  tor-research git-ls https://github.com/torproject/tor.git
  tor-research git-clone https://github.com/torproject/tor.git
  eval "$(tor-research env)"
  tor-research shell
  tor-research strict-off
  tor-research revert

IMPORTANT LIMITS
  - Tor is not magic invisibility.
  - Do not log into personally identifying accounts in the same research
    context if unlinkability matters.
  - Browser fingerprinting is best handled by Tor Browser, not by ordinary
    Firefox/Chromium with a proxy.
  - Proxy environment variables are advisory; not every program obeys them.
  - strict-on is the meaningful guard against accidental clearnet leakage.
  - This script does not erase logs or browser history.

EOF
}

# ---------------------------------------------------------------------------
# Output and failure handling
# ---------------------------------------------------------------------------

function info() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'warning: %s\n' "$*" >&2
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  printf 'error: %s failed near line %s with exit code %s\n' \
    "$APP" "$line_no" "$exit_code" >&2
  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

function verbose() {
  if [[ "${VERBOSE}" == true ]]; then
    printf '%s\n' "$*" >&2
  fi
}

function confirm() {
  local prompt="${1:-Continue?}"

  if [[ "${ASSUME_YES}" == true ]]; then
    return 0
  fi

  local reply
  read -r -p "${prompt} [y/N] " reply
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) die "aborted by user" ;;
  esac
}

# ---------------------------------------------------------------------------
# Preconditions and command execution
# ---------------------------------------------------------------------------

function ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$CACHE_DIR" "$STATE_DIR" "$BACKUP_DIR"
}

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function require_cmd() {
  local cmd="$1"
  have_cmd "$cmd" || die "missing required command: ${cmd}"
}

function as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi

  require_cmd sudo
  sudo "$@"
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

  verbose "running as root: $*"
  as_root "$@"
}

function pacman_install() {
  local packages=("$@")

  require_cmd pacman
  run_root pacman -Syu --needed "${packages[@]}"
}

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

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
  id -u "$user"
}

function tor_service_name() {
  if systemctl list-unit-files tor.service >/dev/null 2>&1; then
    printf 'tor.service\n'
    return 0
  fi

  printf 'tor.service\n'
}

function socks_is_open() {
  if have_cmd ss; then
    ss -H -ltn "sport = :${TOR_SOCKS_PORT}" 2>/dev/null \
      | grep -q "${TOR_SOCKS_PORT}"
    return
  fi

  timeout 2 bash -c \
    ":</dev/tcp/${TOR_SOCKS_HOST}/${TOR_SOCKS_PORT}" >/dev/null 2>&1
}

function nft_table_exists() {
  have_cmd nft || return 1
  run_root nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" \
    >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Backup and Tor configuration
# ---------------------------------------------------------------------------

function timestamp() {
  date '+%Y%m%d_%H%M%S'
}

function backup_file_if_exists() {
  local path="$1"
  local base
  base="$(basename "$path")"

  [[ -e "$path" ]] || return 0

  local dest="${BACKUP_DIR}/$(timestamp)_${base}"
  run_root cp -a "$path" "$dest"
  info "backup: ${dest}"
}

function backup_cmd() {
  ensure_dirs

  if [[ -e /etc/tor/torrc ]]; then
    backup_file_if_exists /etc/tor/torrc
  fi

  if have_cmd nft; then
    local dest="${BACKUP_DIR}/$(timestamp)_nft-ruleset.nft"
    if [[ "${DRY_RUN}" == true ]]; then
      info "[dry-run-root] nft list ruleset > ${dest}"
    else
      as_root nft list ruleset > "$dest"
      info "backup: ${dest}"
    fi
  fi
}

function ensure_torrc_socks() {
  ensure_dirs

  local torrc="/etc/tor/torrc"

  if [[ ! -e "$torrc" ]]; then
    run_root install -Dm0644 /dev/null "$torrc"
  fi

  if run_root grep -qF "$MANAGED_BEGIN" "$torrc"; then
    verbose "managed Tor block already exists in ${torrc}"
    return 0
  fi

  backup_file_if_exists "$torrc"

  local block
  block="$(
    cat <<EOF
${MANAGED_BEGIN}
SocksPort ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}
ClientOnly 1
AvoidDiskWrites 1
${MANAGED_END}
EOF
  )"

  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run-root] append managed block to %s\n' "$torrc"
    printf '%s\n' "$block"
    return 0
  fi

  printf '\n%s\n' "$block" | as_root tee -a "$torrc" >/dev/null
  info "updated: ${torrc}"
}

function remove_torrc_managed_block() {
  local torrc="/etc/tor/torrc"

  [[ -e "$torrc" ]] || return 0

  if ! run_root grep -qF "$MANAGED_BEGIN" "$torrc"; then
    verbose "no managed Tor block found in ${torrc}"
    return 0
  fi

  backup_file_if_exists "$torrc"

  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run-root] remove managed block from %s\n' "$torrc"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  as_root awk \
    -v begin="$MANAGED_BEGIN" \
    -v end="$MANAGED_END" \
    '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "$torrc" > "$tmp"

  as_root install -m 0644 "$tmp" "$torrc"
  rm -f "$tmp"
  info "removed managed block from: ${torrc}"
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

function install_cmd() {
  ensure_dirs

  info "Installing/checking Arch packages..."
  pacman_install tor torsocks nftables curl ca-certificates iproute2 jq

  ensure_torrc_socks

  info "Enabling Tor service at boot..."
  run_root systemctl enable "$(tor_service_name)"

  info "Starting Tor service..."
  run_root systemctl restart "$(tor_service_name)"

  if socks_is_open; then
    info "SOCKS listener is available at ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}"
  else
    warn "Tor started, but SOCKS port ${TOR_SOCKS_PORT} is not listening yet."
    warn "Run: tor-research doctor"
  fi
}

function start_cmd() {
  ensure_dirs
  ensure_torrc_socks
  run_root systemctl start "$(tor_service_name)"

  if socks_is_open; then
    info "Tor is running and SOCKS is listening on ${TOR_SOCKS_URL}"
  else
    die "Tor SOCKS port is not reachable; run: tor-research doctor"
  fi
}

function stop_cmd() {
  confirm "Stop Tor service? Existing strict firewall rules will remain"
  run_root systemctl stop "$(tor_service_name)"
  info "Tor stopped. Use 'tor-research strict-off' or 'revert' if needed."
}

# ---------------------------------------------------------------------------
# nftables strict mode
# ---------------------------------------------------------------------------

function strict_on_cmd() {
  local block_lan=false

  while (($#)); do
    case "$1" in
      --block-lan) block_lan=true; shift ;;
      *) die "unknown strict-on option: $1" ;;
    esac
  done

  require_cmd nft

  local uid
  uid="$(tor_uid)" || die "Tor user not found. Run: tor-research install"

  if ! socks_is_open; then
    warn "Tor SOCKS port is not open. Starting Tor first."
    start_cmd
  fi

  backup_cmd

  if nft_table_exists; then
    run_root nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME"
  fi

  local local_accept_rules=""
  if [[ "$block_lan" == false ]]; then
    local_accept_rules='
    ip daddr @local4 accept
    ip6 daddr @local6 accept'
  fi

  local ruleset
  ruleset="$(
    cat <<EOF
table inet ${NFT_TABLE_NAME} {
  set local4 {
    type ipv4_addr
    flags interval
    elements = {
      0.0.0.0/8,
      10.0.0.0/8,
      100.64.0.0/10,
      127.0.0.0/8,
      169.254.0.0/16,
      172.16.0.0/12,
      192.168.0.0/16,
      224.0.0.0/4,
      240.0.0.0/4
    }
  }

  set local6 {
    type ipv6_addr
    flags interval
    elements = {
      ::1/128,
      fc00::/7,
      fe80::/10,
      ff00::/8
    }
  }

  chain output {
    type filter hook output priority -10; policy accept;

    oifname "lo" accept
    meta skuid ${uid} accept
${local_accept_rules}

    udp dport 53 reject comment "tor-research: block direct DNS"
    tcp dport 53 reject comment "tor-research: block direct DNS"

    ip protocol { tcp, udp, icmp } reject \
      comment "tor-research: block public clearnet IPv4"
    ip6 nexthdr { tcp, udp, icmpv6 } reject \
      comment "tor-research: block public clearnet IPv6"
  }
}
EOF
  )"

  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run-root] nft -f - <<NFT\n%s\nNFT\n' "$ruleset"
    return 0
  fi

  printf '%s\n' "$ruleset" | as_root nft -f -
  info "strict mode enabled: table ${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME}"
  if [[ "$block_lan" == true ]]; then
    info "LAN/private ranges are blocked except loopback and Tor daemon egress."
  else
    info "LAN/private ranges are allowed for usability."
  fi
}

function strict_off_cmd() {
  require_cmd nft

  if nft_table_exists; then
    run_root nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME"
    info "strict mode disabled: deleted table ${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME}"
  else
    info "strict mode already disabled."
  fi
}

function revert_cmd() {
  local keep_tor_running=false

  while (($#)); do
    case "$1" in
      --keep-tor-running) keep_tor_running=true; shift ;;
      *) die "unknown revert option: $1" ;;
    esac
  done

  ensure_dirs
  info "Reverting tor-research managed changes..."

  if have_cmd nft; then
    strict_off_cmd
  else
    warn "nft not found; cannot check managed firewall table."
  fi

  remove_torrc_managed_block

  if [[ "$keep_tor_running" == false ]]; then
    if have_cmd systemctl; then
      run_root systemctl stop "$(tor_service_name)" || true
      info "Tor service stopped."
    fi
  fi

  info "Revert complete. Packages were not uninstalled."
}

# ---------------------------------------------------------------------------
# Proxy wrappers
# ---------------------------------------------------------------------------

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
  start_cmd >/dev/null
  info "Starting proxy-environment shell."
  info "Use 'exit' to leave it. Use strict-on for stronger leak prevention."

  # shellcheck disable=SC2046
  eval "$(env_cmd)"
  export PS1="[tor-research] ${PS1:-\\u@\\h:\\w\\$ }"
  exec "${SHELL:-/usr/bin/env bash}"
}

function run_torsocks_cmd() {
  (($# > 0)) || die "missing command after 'run'"

  start_cmd >/dev/null
  require_cmd torsocks

  TORSOCKS_LOG_LEVEL=1 torsocks "$@"
}

function curl_cmd() {
  (($# > 0)) || die "missing URL for curl"

  start_cmd >/dev/null
  require_cmd curl

  curl \
    --location \
    --fail-with-body \
    --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
    "$@"
}

function wget_cmd() {
  (($# > 0)) || die "missing URL for wget"

  start_cmd >/dev/null
  require_cmd wget

  ALL_PROXY="$TOR_SOCKS_URL" \
  HTTPS_PROXY="$TOR_SOCKS_URL" \
  HTTP_PROXY="$TOR_SOCKS_URL" \
    wget "$@"
}

function git_proxy_args() {
  printf '%s\0' \
    -c "http.proxy=${TOR_SOCKS_URL}" \
    -c "https.proxy=${TOR_SOCKS_URL}" \
    -c "protocol.version=2"
}

function git_clone_cmd() {
  (($# >= 1)) || die "missing repository URL"

  start_cmd >/dev/null
  require_cmd git

  git \
    -c "http.proxy=${TOR_SOCKS_URL}" \
    -c "https.proxy=${TOR_SOCKS_URL}" \
    -c "protocol.version=2" \
    clone "$@"
}

function git_ls_cmd() {
  (($# >= 1)) || die "missing repository URL"

  start_cmd >/dev/null
  require_cmd git

  git \
    -c "http.proxy=${TOR_SOCKS_URL}" \
    -c "https.proxy=${TOR_SOCKS_URL}" \
    -c "protocol.version=2" \
    ls-remote "$@"
}

# ---------------------------------------------------------------------------
# Checks and browser
# ---------------------------------------------------------------------------

function check_cmd() {
  start_cmd >/dev/null
  require_cmd curl

  info "Checking Tor route via Tor Project endpoint..."
  curl \
    --silent \
    --show-error \
    --max-time 20 \
    --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
    https://check.torproject.org/api/ip \
    | if have_cmd jq; then jq .; else cat; fi
}

function leak_test_cmd() {
  require_cmd curl

  info "1. Tor-routed check should succeed:"
  if check_cmd; then
    info "Tor-routed request succeeded."
  else
    warn "Tor-routed request failed."
  fi

  info ""
  info "2. Direct clearnet check should fail when strict mode is enabled:"
  if curl --silent --max-time 7 https://api.ipify.org >/tmp/tor-research.direct 2>/dev/null; then
    warn "Direct public clearnet request succeeded."
    warn "If you want a stronger guard, run: tor-research strict-on"
    warn "Direct IP was: $(cat /tmp/tor-research.direct)"
    rm -f /tmp/tor-research.direct
    return 1
  fi

  rm -f /tmp/tor-research.direct
  info "Direct public clearnet request failed or timed out."
  info "That is expected when strict mode is enabled."
}

function browser_cmd() {
  cat <<'EOF'
Tor Browser guidance

For websites, use Tor Browser rather than ordinary Firefox/Chromium with a
proxy. Tor Browser is designed to reduce browser fingerprinting and isolate
site state better than ad-hoc proxy settings.

Recommended:
  1. Download Tor Browser from the official Tor Project site.
  2. Verify the signature before trusting the download.
  3. Use Tor Browser for journalism, forums, and reading.
  4. Use this script mainly for CLI research: curl, git, wget, papers, APIs.

Trying known launchers now...
EOF

  local launchers=(
    tor-browser
    torbrowser-launcher
    start-tor-browser
  )

  local launcher
  for launcher in "${launchers[@]}"; do
    if have_cmd "$launcher"; then
      info "launching: ${launcher}"
      run_cmd "$launcher" >/dev/null 2>&1 &
      return 0
    fi
  done

  if have_cmd flatpak; then
    if flatpak info com.github.micahflee.torbrowser-launcher \
      >/dev/null 2>&1; then
      run_cmd flatpak run com.github.micahflee.torbrowser-launcher \
        >/dev/null 2>&1 &
      return 0
    fi
  fi

  warn "No known Tor Browser launcher found."
  warn "Install Tor Browser manually and verify its signature."
}

# ---------------------------------------------------------------------------
# Status and doctor
# ---------------------------------------------------------------------------

function service_status_text() {
  if systemctl is-active --quiet "$(tor_service_name)"; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

function status_cmd() {
  ensure_dirs

  info "tor-research status"
  info "  config dir:     ${CONFIG_DIR}"
  info "  state dir:      ${STATE_DIR}"
  info "  Tor service:    $(service_status_text)"

  if socks_is_open; then
    info "  SOCKS port:     open (${TOR_SOCKS_URL})"
  else
    info "  SOCKS port:     closed (${TOR_SOCKS_URL})"
  fi

  if have_cmd nft && nft_table_exists; then
    info "  strict mode:    enabled (${NFT_TABLE_FAMILY} ${NFT_TABLE_NAME})"
  else
    info "  strict mode:    disabled"
  fi

  if tor_user >/dev/null 2>&1; then
    info "  Tor user:       $(tor_user) uid=$(tor_uid)"
  else
    info "  Tor user:       not found"
  fi

  info "  proxy URL:      ${TOR_SOCKS_URL}"
}

function doctor_cmd() {
  local failed=0

  info "tor-research doctor"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "  OS:             ${PRETTY_NAME:-unknown}"
  fi

  local commands=(bash sudo systemctl pacman tor torsocks nft curl ss)
  local cmd
  for cmd in "${commands[@]}"; do
    if have_cmd "$cmd"; then
      info "  command ${cmd}: found"
    else
      warn "command missing: ${cmd}"
      failed=1
    fi
  done

  if tor_user >/dev/null 2>&1; then
    info "  Tor user:       $(tor_user) uid=$(tor_uid)"
  else
    warn "Tor user missing. Try: tor-research install"
    failed=1
  fi

  if systemctl is-active --quiet "$(tor_service_name)"; then
    info "  Tor service:    active"
  else
    warn "Tor service inactive. Try: tor-research start"
    failed=1
  fi

  if socks_is_open; then
    info "  SOCKS:          open on ${TOR_SOCKS_URL}"
  else
    warn "SOCKS port closed. Try: tor-research start"
    failed=1
  fi

  if have_cmd nft && nft_table_exists; then
    info "  strict mode:    enabled"
  else
    info "  strict mode:    disabled"
  fi

  if [[ "$failed" -eq 0 ]]; then
    info "doctor result: OK"
  else
    warn "doctor result: problems found"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

function parse_global_options() {
  while (($#)); do
    case "$1" in
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        helpout
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
  ensure_dirs
  parse_global_options "$@"
  set -- "${REMAINING_ARGS[@]}"

  local command="${1:-}"
  [[ -n "$command" ]] || {
    helpout
    exit 0
  }
  shift || true

  case "$command" in
    help|--help|-h) helpout ;;
    install) install_cmd "$@" ;;
    start) start_cmd "$@" ;;
    stop) stop_cmd "$@" ;;
    status) status_cmd "$@" ;;
    doctor) doctor_cmd "$@" ;;
    backup) backup_cmd "$@" ;;
    strict-on) strict_on_cmd "$@" ;;
    strict-off) strict_off_cmd "$@" ;;
    revert) revert_cmd "$@" ;;
    env) env_cmd "$@" ;;
    shell) shell_cmd "$@" ;;
    run) run_torsocks_cmd "$@" ;;
    curl) curl_cmd "$@" ;;
    wget) wget_cmd "$@" ;;
    git-clone) git_clone_cmd "$@" ;;
    git-ls) git_ls_cmd "$@" ;;
    check) check_cmd "$@" ;;
    leak-test) leak_test_cmd "$@" ;;
    browser) browser_cmd "$@" ;;
    *)
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
