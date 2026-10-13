#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Install idempotent left/right Hyprland workspace movement bindings.
#
# SUPER+ALT+LEFT/RIGHT   Move the focused window and follow it.
# SUPER+SHIFT+LEFT/RIGHT Move the focused window and stay on this workspace.
#
# Left movement stops at workspace 1. Right movement advances by one ID and
# never wraps to an arbitrary workspace number.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM="${0##*/}"
readonly HELPER_NAME="heini-hypr-workspace-step"
readonly HELPER_MARKER="# Managed by ${PROGRAM}"
readonly CONF_MARKER="# Managed by ${PROGRAM}"
readonly LUA_MARKER="-- Managed by ${PROGRAM}"
readonly MAIN_BEGIN="# BEGIN ${PROGRAM} managed include"
readonly MAIN_END="# END ${PROGRAM} managed include"

config_arg=""
tmp_dir=""

function usage() {
  cat <<EOF
Usage: ${PROGRAM} [--config PATH] [--help|--long-help]

Install four Hyprland bindings using the Super (Windows) key and the physical
Left/Right arrows:

  Super+Alt+Left/Right    Move the focused window and follow it.
  Super+Shift+Left/Right  Move the focused window but remain here.

Left from workspace 1 does nothing; it does not wrap to workspace 99. Right
advances one workspace at a time. Both legacy .conf and current .lua configs
are supported.

Options:
  --config PATH  Use this Hyprland config instead of detecting the default.
  -h, --help     Show this help.
  --long-help    Show this detailed help.

The script installs a managed config fragment and helper under your home
directory, then adds one marked include block at the end of the main config.
It backs up the main config only when that file needs to change. Re-running it
updates the managed files without adding duplicate bindings or include lines.

If both hyprland.lua and hyprland.conf exist, pass --config with the file that
Hyprland actually loads. The Fn/Ctrl+L character mapping is not changed.
EOF
}

function die() {
  print_error "$*"
  exit 1
}

function print_error() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

function print_info() {
  printf '%s: %s\n' "$PROGRAM" "$*"
}

function backup_file() {
  local original="$1"
  local stamp
  local backup

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${original}.bak.${stamp}"
  if [[ -e "$backup" ]]; then
    backup="${backup}.$$"
  fi

  cp -a -- "$original" "$backup"
  print_info "backup: $backup"
}

function write_managed_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local marker="$4"
  local temp_file

  if [[ -L "$target_file" ]]; then
    die "refusing to replace symlink: $target_file"
  fi

  if [[ -e "$target_file" ]] &&
    ! grep -Fqx -- "$marker" "$target_file"; then
    die "refusing to overwrite an unmarked file: $target_file"
  fi

  if [[ -f "$target_file" ]] && cmp -s -- "$source_file" "$target_file";
  then
    return 0
  fi

  temp_file="$(mktemp "${target_file}.tmp.XXXXXXXX")"
  cp -- "$source_file" "$temp_file"
  chmod "$mode" "$temp_file"

  if [[ -e "$target_file" ]]; then
    backup_file "$target_file"
  fi

  mv -f -- "$temp_file" "$target_file"
}

function select_config() {
  local hypr_dir
  local lua_config
  local conf_config

  if [[ -n "$config_arg" ]]; then
    config_path="$config_arg"
  elif [[ -n "${HYPRLAND_CONFIG:-}" ]]; then
    config_path="$HYPRLAND_CONFIG"
  else
    hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
    lua_config="${hypr_dir}/hyprland.lua"
    conf_config="${hypr_dir}/hyprland.conf"

    if [[ -f "$lua_config" && -f "$conf_config" ]]; then
      die "both default configs exist; pass --config with the active one"
    elif [[ -f "$lua_config" ]]; then
      config_path="$lua_config"
    elif [[ -f "$conf_config" ]]; then
      config_path="$conf_config"
    else
      die "no default Hyprland config found; pass --config PATH"
    fi
  fi

  [[ -f "$config_path" ]] || die "config file not found: $config_path"
  config_path="$(realpath -e -- "$config_path")"

  case "$config_path" in
    *.lua) config_type="lua" ;;
    *.conf) config_type="conf" ;;
    *) die "config must end in .lua or .conf: $config_path" ;;
  esac

  if [[ "$(stat -c '%u' -- "$config_path")" != "$EUID" ]]; then
    die "config is not owned by $(id -un): $config_path"
  fi

  config_dir="${config_path%/*}"
}

function make_helper() {
  {
    printf '#!/usr/bin/env bash\n%s\n' "$HELPER_MARKER"
    cat <<'HELPER'
# Move the active window one numeric workspace left or right.

set -Eeuo pipefail

function usage() {
  printf 'Usage: %s {left|right} {follow|stay}\n' "${0##*/}" >&2
  exit 2
}

function fail() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
direction="$1"
behavior="$2"

case "$direction" in
  left|right) ;;
  *) usage ;;
esac

case "$behavior" in
  follow) dispatcher="movetoworkspace" ;;
  stay) dispatcher="movetoworkspacesilent" ;;
  *) usage ;;
esac

command -v hyprctl >/dev/null 2>&1 || fail "hyprctl is not on PATH"

workspace_json="$(hyprctl -j activeworkspace 2>/dev/null)" \
  || fail "could not read the active workspace"
id_pattern='"id"[[:space:]]*:[[:space:]]*(-?[0-9]+)'

if [[ "$workspace_json" =~ $id_pattern ]]; then
  current="${BASH_REMATCH[1]}"
else
  fail "could not parse the active workspace ID"
fi

# Named and special workspaces can have non-positive IDs. Leave them alone.
(( current >= 1 )) || exit 0

case "$direction" in
  left)
    # Hyprland numeric workspace IDs start at 1; never wrap around.
    (( current > 1 )) || exit 0
    target=$((current - 1))
    ;;
  right)
    # Stay within Hyprland's documented positive integer ID range.
    (( current < 2147483647 )) || exit 0
    target=$((current + 1))
    ;;
esac

hyprctl dispatch "$dispatcher" "$target" >/dev/null \
  || fail "Hyprland rejected the workspace move to $target"
HELPER
  } > "$tmp_dir/helper"
  chmod 700 "$tmp_dir/helper"
}

function make_conf_fragment() {
  local helper_q

  helper_q="$(printf "'%s'" "${helper_path//\'/\'\\\'\'}")"

  cat > "$tmp_dir/fragment.conf" <<EOF
# Managed by ${PROGRAM}

unbind = SUPER ALT, left
unbind = SUPER ALT, right
unbind = SUPER SHIFT, left
unbind = SUPER SHIFT, right

bind = SUPER ALT, left, exec, ${helper_q} left follow
bind = SUPER ALT, right, exec, ${helper_q} right follow
bind = SUPER SHIFT, left, exec, ${helper_q} left stay
bind = SUPER SHIFT, right, exec, ${helper_q} right stay
EOF
  chmod 600 "$tmp_dir/fragment.conf"
}

function make_lua_fragment() {
  {
    printf '%s\n' "$LUA_MARKER"
    cat <<'LUA'

local helper = os.getenv("HOME")
  .. "/.local/bin/heini-hypr-workspace-step"

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function bind_step(modifiers, key, direction, behavior)
  local combo = modifiers .. " + " .. key
  local command = shell_quote(helper) .. " " .. direction .. " " .. behavior

  hl.unbind(combo)
  hl.bind(combo, hl.dsp.exec_cmd(command))
end

bind_step("SUPER + ALT", "left", "left", "follow")
bind_step("SUPER + ALT", "right", "right", "follow")
bind_step("SUPER + SHIFT", "left", "left", "stay")
bind_step("SUPER + SHIFT", "right", "right", "stay")
LUA
  } > "$tmp_dir/fragment.lua"
  chmod 600 "$tmp_dir/fragment.lua"
}

function replace_main_include() {
  local include_line="$1"
  local filtered="$tmp_dir/main.filtered"
  local updated="$tmp_dir/main.updated"
  local temp_file
  local mode
  local last_char

  if ! awk -v begin="$MAIN_BEGIN" -v end="$MAIN_END" '
    $0 == begin {
      if (inside) bad = 1
      inside = 1
      next
    }
    $0 == end {
      if (!inside) bad = 1
      inside = 0
      next
    }
    !inside { print }
    END {
      if (inside || bad) exit 2
    }
  ' "$config_path" > "$filtered"; then
    die "managed include markers are malformed in $config_path"
  fi

  cat "$filtered" > "$updated"
  if [[ -s "$filtered" ]]; then
    last_char="$(tail -c 1 -- "$filtered" || true)"
    [[ -z "$last_char" ]] || printf '\n' >> "$updated"
  fi
  printf '%s\n%s\n%s\n' \
    "$MAIN_BEGIN" "$include_line" "$MAIN_END" >> "$updated"

  if cmp -s -- "$config_path" "$updated"; then
    print_info "main config already has the current include"
    return 0
  fi

  mode="$(stat -c '%a' -- "$config_path")"
  backup_file "$config_path"
  temp_file="$(mktemp "${config_path}.tmp.XXXXXXXX")"
  cp -- "$updated" "$temp_file"
  chmod "$mode" "$temp_file"
  mv -f -- "$temp_file" "$config_path"
}

function main() {
  local helper_dir
  local helper_source
  local helper_marker
  local fragment_path
  local fragment_marker
  local include_line

  while (($#)); do
    case "$1" in
      --config)
        (($# >= 2)) || die "--config requires a path"
        config_arg="$2"
        shift 2
        ;;
      -h|--help|--long-help)
        usage
        return 0
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
  done

  [[ "$EUID" -ne 0 ]] || die "run this as your regular user, not root"
  [[ -n "${HOME:-}" ]] || die "HOME is not set"

  select_config

  helper_dir="$HOME/.local/bin"
  helper_path="${helper_dir}/${HELPER_NAME}"
  mkdir -p -- "$helper_dir" "$config_dir"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hypr-workspace-nav.XXXXXXXX")"
  trap 'rm -rf -- "$tmp_dir"' EXIT

  make_helper
  write_managed_file \
    "$tmp_dir/helper" "$helper_path" 700 "$HELPER_MARKER"

  if [[ "$config_type" == "conf" ]]; then
    fragment_path="${config_dir}/heini_workspace_navigation.conf"
    fragment_marker="$CONF_MARKER"
    make_conf_fragment
    write_managed_file \
      "$tmp_dir/fragment.conf" "$fragment_path" 600 "$fragment_marker"
    # Hyprland's legacy source directive expects an unquoted path value.
    include_line="source = ${fragment_path}"
  else
    fragment_path="${config_dir}/heini_workspace_navigation.lua"
    fragment_marker="$LUA_MARKER"
    make_lua_fragment
    write_managed_file \
      "$tmp_dir/fragment.lua" "$fragment_path" 600 "$fragment_marker"
    include_line='require("./heini_workspace_navigation")'
  fi

  replace_main_include "$include_line"

  print_info "installed for $config_path"
  print_info "Left from workspace 1 is a no-op; no wraparound is used"

  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] &&
    command -v hyprctl >/dev/null 2>&1; then
    if hyprctl reload >/dev/null 2>&1; then
      print_info "Hyprland config reloaded"
    else
      print_error "could not reload Hyprland; reload it manually"
    fi
  else
    print_info "reload Hyprland or start it to activate the bindings"
  fi
}

main "$@"
