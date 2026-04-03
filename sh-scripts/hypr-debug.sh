#!/usr/bin/env bash
set -uo pipefail

outfile="$HOME/hypr-debug-$(date +%F_%H-%M-%S).log"

{
  echo "=== uname ==="
  uname -a
  echo

  echo "=== packages (hyprland / polkit / uwsm) ==="
  pacman -Qs 'hyprland|polkit|uwsm'
  echo

  echo "=== wayland session file ==="
  grep -i '^Exec' /usr/share/wayland-sessions/hyprland.desktop ||
    echo "No hyprland.desktop?"
  echo

  echo "=== polkit.service ==="
  systemctl status polkit.service --no-pager || true
  echo

  echo "=== display manager units ==="
  systemctl status sddm.service greetd.service ly.service gdm.service \
    --no-pager 2>/dev/null || true
  echo

  echo "=== journal (last 200 lines, filtered) ==="
  sudo journalctl -b | grep -Ei 'sddm|greetd|ly|hyprland|polkit|pam|auth|uwsm' |
    tail -n 200 || true
} >"$outfile"

printf 'Wrote debug info to %s\n' "$outfile"
