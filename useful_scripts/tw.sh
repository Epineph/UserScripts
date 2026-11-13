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
