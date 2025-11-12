#!/usr/bin/env bash
# aur-diagnose.sh — Minimal AUR access diagnostics (no destructive changes)
set -euo pipefail

function have()
{
  command -v "$1" &> /dev/null
}

function say()
{
  printf '==> %s\n' "$*"
}

function warn()
{
  printf '!!  %s\n' "$*" >&2
}

function check_dns()
{
  say "DNS: resolving aur.archlinux.org"
  if getent ahosts aur.archlinux.org; then
    say "DNS OK"
  else
    warn "DNS resolution FAILED"
    return 1
  fi
}

function check_ipv_paths()
{
  say "HTTP HEAD over IPv4"
  curl -4fsSI https://aur.archlinux.org/ > /dev/null && say "IPv4 OK" \
    || warn "IPv4 FAIL"
  say "HTTP HEAD over IPv6"
  curl -6fsSI https://aur.archlinux.org/ > /dev/null && say "IPv6 OK" \
    || warn "IPv6 FAIL"
}

function check_time_tls()
{
  say "Timedatectl"
  timedatectl status | sed -n '1,12p'
  say "TLS handshake (openssl)"
  if have openssl; then
    openssl s_client -connect aur.archlinux.org:443 -servername aur.archlinux.org -brief < /dev/null \
      | sed -n '1,12p' || true
  else
    warn "openssl not found; skipping"
  fi
}

function check_rpc_git()
{
  say "AUR RPC"
  curl -fsS 'https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=paru' \
    | jq -r '.resultcount' && say "RPC OK" || warn "RPC FAIL"
  say "Git clone (read-only HTTPS)"
  rm -rf /tmp/_aurtest && git clone -q https://aur.archlinux.org/paru.git /tmp/_aurtest \
    && say "Git OK" \
    || warn "Git FAIL"
}

function check_proxy_hosts()
{
  say "Proxy-related env (filtered)"
  env | grep -Ei '^(http|https|all)_proxy|NO_PROXY|SSL_CERT_FILE|CURL_CA_BUNDLE' || true
  say "Git proxy config"
  git config --global --get-regexp 'http.*proxy|https.*proxy|http.version' || true
  say "/etc/hosts pinning"
  grep -n aur.archlinux.org /etc/hosts || echo "No pin in /etc/hosts"
}

check_dns || true
check_ipv_paths || true
check_time_tls || true
check_rpc_git || true
check_proxy_hosts || true
say "Done."
