#!/usr/bin/env bash
set -euo pipefail

function show_help() {
  cat <<'EOF'
Usage:
  hypr-append-keybind-block [OPTIONS]

Description:
  Append a specific Hyprland keybind block to:

    ~/.config/hypr/UserConfigs/UserKeybinds.conf

  only if that block does not already appear to be present.

Options:
  -f, --file PATH   Target file to modify
  -h, --help        Show this help

Behavior:
  - Creates parent directories if needed
  - Detects whether the block already exists
  - Refuses to append if a partial / ambiguous match is found
  - Appends the block once, idempotently

Examples:
  hypr-append-keybind-block
  hypr-append-keybind-block --file "$HOME/.config/hypr/UserConfigs/UserKeybinds.conf"
  hypr-append-keybind-block -f /tmp/UserKeybinds.conf
EOF
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function parse_args() {
  TARGET_FILE="${HOME}/.config/hypr/UserConfigs/UserKeybinds.conf"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--file)
        [ "$#" -ge 2 ] || die "Missing value for $1"
        TARGET_FILE="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

function ensure_parent_dir() {
  local parent_dir
  parent_dir="$(dirname -- "$TARGET_FILE")"
  mkdir -p -- "$parent_dir"
}

function file_exists_or_create() {
  if [ ! -e "$TARGET_FILE" ]; then
    : >"$TARGET_FILE"
  fi
}

function has_workspace_heading() {
  grep -Fq \
    '# Workspace-send with arrows' \
    "$TARGET_FILE"
}

function has_md_fence_bind() {
  grep -Eq \
    '^[[:space:]]*bind = \$main[Mm]od CTRL ALT, H, exec, md-fence-insert html[[:space:]]*$' \
    "$TARGET_FILE"
}

function append_spacing_if_needed() {
  if [ -s "$TARGET_FILE" ]; then
    if [ -n "$(tail -c 1 -- "$TARGET_FILE" 2>/dev/null || true)" ]; then
      printf '\n' >>"$TARGET_FILE"
    fi
    printf '\n' >>"$TARGET_FILE"
  fi
}

function append_block() {
  cat >>"$TARGET_FILE" <<'EOF'
# -----------------------------------------------------------------------------
# Workspace-send with arrows
#   $mainMod + CTRL  + ←/→ : move focused window to adjacent workspace (stay)
#   $mainMod + SHIFT + ←/→ : move focused window to adjacent workspace (follow)
#
# Uses r±1 = “workspace on monitor including empty workspaces, relative”.
# -----------------------------------------------------------------------------

# Clear JaKooLit defaults that collide:
# - CTRL arrows = movewindow
# - ALT  arrows = swapwindow
# - SHIFT arrows = resizeactive
unbind = $mainMod CTRL,  left
unbind = $mainMod CTRL,  right
unbind = $mainMod ALT,   left
unbind = $mainMod ALT,   right
unbind = $mainMod SHIFT, left
unbind = $mainMod SHIFT, right

# Your intended behavior:
bindd = $mainMod CTRL,  left,  send window left (silent),  \
  movetoworkspacesilent, r-1
bindd = $mainMod CTRL,  right, send window right (silent), \
  movetoworkspacesilent, r+1
bindd = $mainMod SHIFT, left,  send window left + follow,  \
  movetoworkspace,       r-1
bindd = $mainMod SHIFT, right, send window right + follow, \
  movetoworkspace,       r+1

bind = $mainMod CTRL ALT, Q, exec, md-fence-insert
bind = $mainMod CTRL ALT, R, exec, md-fence-insert r
bind = $mainMod CTRL ALT, P, exec, md-fence-insert python
bind = $mainMod CTRL ALT, B, exec, md-fence-insert bash
bind = $mainMod CTRL ALT, J, exec, md-fence-insert javascript
bind = $mainMod CTRL ALT, S, exec, md-fence-insert sql
bind = $mainMod CTRL ALT, C, exec, md-fence-insert c
bind = $mainMod CTRL ALT, H, exec, md-fence-insert html
EOF
}

function main() {
  parse_args "$@"
  ensure_parent_dir
  file_exists_or_create

  local has_heading="false"
  local has_fence="false"

  if has_workspace_heading; then
    has_heading="true"
  fi

  if has_md_fence_bind; then
    has_fence="true"
  fi

  if [ "$has_heading" = "true" ] && [ "$has_fence" = "true" ]; then
    printf 'Block already present. No changes made.\n'
    exit 0
  fi

  if [ "$has_heading" = "true" ] || [ "$has_fence" = "true" ]; then
    die "Partial match detected in target file. Refusing to append duplicate \
block."
  fi

  append_spacing_if_needed
  append_block

  printf 'Appended block to: %s\n' "$TARGET_FILE"
}

main "$@"