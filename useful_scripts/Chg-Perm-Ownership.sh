#!/usr/bin/env bash

###############################################################################
# chPerms
#
# Safely inspect and change Unix ownership and permissions for one or more
# filesystem targets.
#
# Version: 2.0.0
# Author:  Heini Winther Johnsen
# License: MIT
###############################################################################

set -uo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly VERSION="2.0.0"

SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || printf '%s\n' "$0")"
readonly SCRIPT_PATH

RECURSIVE=false
FORCE=false
DRY_RUN=false
ALLOW_SYSTEM_PATHS=false
REFRESH_REQUESTED=false

OWNER_VALUE=""
GROUP_VALUE=""
PERM_VALUE=""
DIR_PERM_VALUE=""
FILE_PERM_VALUE=""

SHOW_OWNER=false
SHOW_PERMS=false

ORIGINAL_ARGS=("$@")
TARGETS=()
RECURSIVE_ARGS=()

###############################################################################
# Help and messages
###############################################################################

function show_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME [PATH ...] [OPTIONS]
  $PROGRAM_NAME --target PATH[,PATH...] [OPTIONS]

Inspect or change ownership and permissions for one or more files or
directories.

Targets:
  PATH ...                    One or more positional paths.
  -t, --target LIST           Comma-separated paths. Positional paths are safer
                              when a filename itself contains a comma.

Ownership:
  -o, --owner USER[:GROUP]    Set owner, or owner and group together.
                              The value "activeuser" means the invoking user,
                              including when the command runs through sudo.
  -g, --group GROUP           Set group. "activegroup" means the invoking
                              user's primary group.

Permissions:
  -p, --perm MODE             Apply MODE to each target. With --recursive, the
                              same mode is applied to every descendant.
      --dir-perm MODE         Apply MODE only to directories.
      --file-perm MODE        Apply MODE only to regular files.

  MODE may be:
    Numeric                   700, 770, 0750, 2770
    Nine-character            rwxrwx---, rw-rw----
    Symbolic                  u=rwx,g=rx,o=  or  o-rwx

Inspection:
  -c, --current-owner         Show owner and group.
  -a, --active-perms          Show symbolic and numeric permissions.

Recursion and safety:
  -R, --recursive             Recurse into directory targets.
      --noconfirm             Do not ask before an actual recursive change.
  -f, --force                 Alias for --noconfirm.
      --force-recursively     Enable recursion and bypass confirmation.
      --allow-system-paths    Permit actual recursive changes beneath protected
                              system locations such as /usr and /etc.

Other:
  -n, --dry-run               Validate and show planned commands only.
      --refresh-rc            Deprecated compatibility option; does nothing.
      --version               Show version.
  -h, --help                  Show this help.
  --                          End option parsing.

Examples:
  # Make a private directory accessible only to its owner and root:
  $PROGRAM_NAME "\$HOME/repos" --perm 700

  # Allow the owner and the owner's private group:
  $PROGRAM_NAME "\$HOME/repos" --perm 770

  # Recursively remove all permissions granted to "other" without changing
  # existing owner/group permissions or executable bits:
  $PROGRAM_NAME "\$HOME/repos" --perm o-rwx --recursive

  # Use safe, distinct recursive modes for directories and regular files:
  $PROGRAM_NAME "\$HOME/repos" --recursive \\
    --dir-perm 770 --file-perm 660

  # Preview ownership and permission changes:
  sudo $PROGRAM_NAME "\$HOME/repos" --owner activeuser \\
    --group activegroup --perm 770 --dry-run

Important:
  Applying 770 recursively makes every regular file executable. Prefer
  --dir-perm 770 together with --file-perm 660, or use a relative symbolic
  change such as o-rwx.

  Unix mode bits do not remove POSIX ACL entries. Inspect ACLs separately with:
    getfacl -- PATH
EOF
}

function info() {
  printf '%s\n' "$*"
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function error() {
  printf 'Error: %s\n' "$*" >&2
}

function die() {
  error "$*"
  exit 1
}

###############################################################################
# Identity and permission helpers
###############################################################################

function active_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

function active_group() {
  local user

  user="$(active_user)"
  id -gn "$user"
}

function resolve_identities() {
  if [[ "$OWNER_VALUE" == "activeuser" ]]; then
    OWNER_VALUE="$(active_user)"
  elif [[ "$OWNER_VALUE" == activeuser:* ]]; then
    OWNER_VALUE="$(active_user):${OWNER_VALUE#*:}"
  fi

  if [[ "$GROUP_VALUE" == "activegroup" ]]; then
    GROUP_VALUE="$(active_group)"
  fi
}

function validate_owner() {
  local owner="$1"
  local user="${owner%%:*}"
  local embedded_group=""

  if [[ "$owner" == *:* ]]; then
    embedded_group="${owner#*:}"
  fi

  getent passwd "$user" >/dev/null ||
    die "Unknown user: '$user'."

  if [[ -n "$embedded_group" ]]; then
    getent group "$embedded_group" >/dev/null ||
      die "Unknown group: '$embedded_group'."
  fi
}

function validate_group() {
  local group="$1"

  getent group "$group" >/dev/null ||
    die "Unknown group: '$group'."
}

function permission_digit() {
  local triplet="$1"
  local -i digit=0

  [[ "$triplet" == *r* ]] && ((digit += 4))
  [[ "$triplet" == *w* ]] && ((digit += 2))
  [[ "$triplet" == *x* ]] && ((digit += 1))

  printf '%d\n' "$digit"
}

function normalize_mode() {
  local input="$1"
  local -n output_ref="$2"
  local -i user_digit=0
  local -i group_digit=0
  local -i other_digit=0

  if [[ "$input" =~ ^[0-7]{3}$ || "$input" =~ ^[0-7]{4}$ ]]; then
    output_ref="$input"
    return
  fi

  if [[ "$input" =~ ^[rwx-]{9}$ ]]; then
    user_digit="$(permission_digit "${input:0:3}")"
    group_digit="$(permission_digit "${input:3:3}")"
    other_digit="$(permission_digit "${input:6:3}")"
    output_ref="${user_digit}${group_digit}${other_digit}"
    return
  fi

  if [[ "$input" =~ \
^u=([rwx-]{1,3}),g=([rwx-]{1,3}),o=([rwx-]{0,3})$ ]]; then
    user_digit="$(permission_digit "${BASH_REMATCH[1]}")"
    group_digit="$(permission_digit "${BASH_REMATCH[2]}")"
    other_digit="$(permission_digit "${BASH_REMATCH[3]}")"
    output_ref="${user_digit}${group_digit}${other_digit}"
    return
  fi

  if [[ "$input" =~ \
^([ugoa]*[+=-][rwxXstugo]*)(,[ugoa]*[+=-][rwxXstugo]*)*$ ]]; then
    output_ref="$input"
    return
  fi

  die "Invalid permission mode: '$input'."
}

function mode_grants_execute() {
  local mode="$1"
  local ordinary_mode="$mode"

  [[ "$ordinary_mode" =~ ^[0-7]{4}$ ]] &&
    ordinary_mode="${ordinary_mode:1:3}"

  if [[ "$ordinary_mode" =~ ^[0-7]{3}$ ]]; then
    (( (8#$ordinary_mode & 0111) != 0 ))
    return
  fi

  [[ "$ordinary_mode" =~ [+=][rwxXstugo]*x ]]
}

###############################################################################
# Path and command safety
###############################################################################

function target_exists() {
  [[ -e "$1" || -L "$1" ]]
}

function canonical_path() {
  readlink -f -- "$1" 2>/dev/null || realpath -m -- "$1"
}

function is_protected_system_path() {
  local path

  path="$(canonical_path "$1")"

  case "$path" in
    /|/bin|/boot|/dev|/efi|/etc|/lib|/lib64|/proc|/root|/run|/sbin|/sys|\
/usr|/usr/*|/var|/var/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function validate_recursive_targets() {
  local target
  local path

  $RECURSIVE || return

  for target in "${TARGETS[@]}"; do
    target_exists "$target" || continue
    path="$(canonical_path "$target")"

    if [[ "$path" == "/" ]]; then
      die "Refusing to recurse over '/'."
    fi

    if is_protected_system_path "$target" &&
      ! $ALLOW_SYSTEM_PATHS &&
      ! $DRY_RUN; then
      die "Recursive system-path change refused for '$target'. Use" \
        "--allow-system-paths only after reviewing a dry-run."
    fi
  done
}

function print_command() {
  local argument

  printf '[DRY RUN]'
  for argument in "$@"; do
    printf ' %q' "$argument"
  done
  printf '\n'
}

function run_command() {
  if $DRY_RUN; then
    print_command "$@"
    return 0
  fi

  "$@"
}

function confirm_recursive() {
  local response

  $RECURSIVE || return
  $DRY_RUN && return
  $FORCE && return

  if [[ ! -t 0 ]]; then
    die "Recursive changes require a terminal confirmation or --noconfirm."
  fi

  warn "Recursive changes can alter many files."
  read -r -p "Continue? [y/N]: " response
  [[ "$response" == [Yy] ]] ||
    die "Recursive operation cancelled."
}

function warn_about_recursive_modes() {
  $RECURSIVE || return

  if [[ -n "$PERM_VALUE" ]] && mode_grants_execute "$PERM_VALUE"; then
    warn "The recursive mode '$PERM_VALUE' may make regular files executable."
    warn "Prefer --dir-perm and --file-perm for exact recursive modes."
  fi
}

###############################################################################
# Inspection
###############################################################################

function display_ownership() {
  local path="$1"
  local owner
  local group

  owner="$(stat -c '%U' -- "$path" 2>/dev/null)" || return 1
  group="$(stat -c '%G' -- "$path" 2>/dev/null)" || return 1

  printf 'Ownership:\n'
  printf '  Owner: %s\n' "$owner"
  printf '  Group: %s\n' "$group"
}

function display_permissions() {
  local path="$1"
  local symbolic
  local numeric

  symbolic="$(stat -c '%A' -- "$path" 2>/dev/null)" || return 1
  numeric="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1

  printf 'Permissions:\n'
  printf '  Symbolic: %s\n' "$symbolic"
  printf '  Numeric:  %s\n' "$numeric"
  printf '  Detailed: u=%s, g=%s, o=%s\n' \
    "${symbolic:1:3}" "${symbolic:4:3}" "${symbolic:7:3}"
}

function display_requested_state() {
  local path="$1"

  $SHOW_OWNER && display_ownership "$path"
  $SHOW_PERMS && display_permissions "$path"
}

###############################################################################
# Changes
###############################################################################

function apply_ownership() {
  local path="$1"
  local ownership="$OWNER_VALUE"

  if [[ -n "$ownership" ]]; then
    if [[ -n "$GROUP_VALUE" ]]; then
      ownership="${ownership%%:*}:$GROUP_VALUE"
    fi

    run_command chown "${RECURSIVE_ARGS[@]}" -- "$ownership" "$path"
  elif [[ -n "$GROUP_VALUE" ]]; then
    run_command chown "${RECURSIVE_ARGS[@]}" -- ":$GROUP_VALUE" "$path"
  fi
}

function apply_mode_to_type() {
  local path="$1"
  local file_type="$2"
  local mode="$3"
  local find_path="$path"

  [[ "$find_path" == -* ]] && find_path="./$find_path"

  if $RECURSIVE; then
    if $DRY_RUN; then
      print_command find -P "$find_path" -type "$file_type" \
        -exec chmod -- "$mode" "{}" "+"
    else
      find -P "$find_path" -type "$file_type" \
        -exec chmod -- "$mode" {} +
    fi
    return
  fi

  case "$file_type" in
    d)
      if [[ -d "$path" ]]; then
        run_command chmod -- "$mode" "$path"
      fi
      ;;
    f)
      if [[ -f "$path" ]]; then
        run_command chmod -- "$mode" "$path"
      fi
      ;;
  esac

  return 0
}

function apply_permissions() {
  local path="$1"

  if [[ -n "$PERM_VALUE" ]]; then
    run_command chmod "${RECURSIVE_ARGS[@]}" -- "$PERM_VALUE" "$path"
    return
  fi

  if [[ -n "$DIR_PERM_VALUE" ]]; then
    apply_mode_to_type "$path" d "$DIR_PERM_VALUE"
  fi

  if [[ -n "$FILE_PERM_VALUE" ]]; then
    apply_mode_to_type "$path" f "$FILE_PERM_VALUE"
  fi
}

###############################################################################
# Argument parsing
###############################################################################

function require_option_argument() {
  local option="$1"
  local value="${2:-}"

  [[ -n "$value" ]] || die "Missing argument for '$option'."
}

function add_comma_targets() {
  local list="$1"
  local item
  local parsed=()

  IFS=',' read -r -a parsed <<< "$list"

  for item in "${parsed[@]}"; do
    [[ -n "$item" ]] || die "Empty path in target list '$list'."
    TARGETS+=("$item")
  done
}

function parse_arguments() {
  local end_options=false

  while (($# > 0)); do
    if $end_options; then
      TARGETS+=("$1")
      shift
      continue
    fi

    case "$1" in
      --)
        end_options=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --version)
        printf '%s version %s\n' "$PROGRAM_NAME" "$VERSION"
        exit 0
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -R|--recursive|--recursively-apply|--recurse-action)
        RECURSIVE=true
        shift
        ;;
      --force-recursively|--recursively-force)
        RECURSIVE=true
        FORCE=true
        shift
        ;;
      -f|--force|--noconfirm)
        FORCE=true
        shift
        ;;
      --allow-system-paths)
        ALLOW_SYSTEM_PATHS=true
        shift
        ;;
      --refresh|--refresh-rc)
        REFRESH_REQUESTED=true
        shift
        ;;
      -c|--current-owner|currentowner|currentownership)
        SHOW_OWNER=true
        shift
        ;;
      -a|--active-perms|--active-permissions|currentperms)
        SHOW_PERMS=true
        shift
        ;;
      -o|--owner|ownership|owner)
        require_option_argument "$1" "${2:-}"
        OWNER_VALUE="$2"
        shift 2
        ;;
      -g|--group)
        require_option_argument "$1" "${2:-}"
        GROUP_VALUE="$2"
        shift 2
        ;;
      -p|--perm|--perms|--permission|permissions|perms|perm)
        require_option_argument "$1" "${2:-}"
        PERM_VALUE="$2"
        shift 2
        ;;
      --dir-perm|--directory-perm)
        require_option_argument "$1" "${2:-}"
        DIR_PERM_VALUE="$2"
        shift 2
        ;;
      --file-perm)
        require_option_argument "$1" "${2:-}"
        FILE_PERM_VALUE="$2"
        shift 2
        ;;
      -t|--target)
        require_option_argument "$1" "${2:-}"
        add_comma_targets "$2"
        shift 2
        ;;
      -*)
        die "Unknown option: '$1'. Use --help for usage."
        ;;
      *)
        TARGETS+=("$1")
        shift
        ;;
    esac
  done
}

###############################################################################
# Validation and privilege handling
###############################################################################

function validate_arguments() {
  local normalized=""
  local target

  ((${#TARGETS[@]} > 0)) ||
    die "No target supplied. Use --help for usage."

  if [[ -n "$PERM_VALUE" &&
    ( -n "$DIR_PERM_VALUE" || -n "$FILE_PERM_VALUE" ) ]]; then
    die "--perm cannot be combined with --dir-perm or --file-perm."
  fi

  if [[ -n "$OWNER_VALUE" ]]; then
    validate_owner "$OWNER_VALUE"
  fi

  if [[ -n "$GROUP_VALUE" ]]; then
    validate_group "$GROUP_VALUE"
  fi

  if [[ -n "$PERM_VALUE" ]]; then
    normalize_mode "$PERM_VALUE" normalized
    PERM_VALUE="$normalized"
  fi

  if [[ -n "$DIR_PERM_VALUE" ]]; then
    normalize_mode "$DIR_PERM_VALUE" normalized
    DIR_PERM_VALUE="$normalized"
  fi

  if [[ -n "$FILE_PERM_VALUE" ]]; then
    normalize_mode "$FILE_PERM_VALUE" normalized
    FILE_PERM_VALUE="$normalized"
  fi

  for target in "${TARGETS[@]}"; do
    target_exists "$target" ||
      die "Target does not exist: '$target'."
  done

  validate_recursive_targets
}

function ownership_change_requested() {
  [[ -n "$OWNER_VALUE" || -n "$GROUP_VALUE" ]]
}

function elevate_if_needed() {
  ownership_change_requested || return
  ((EUID == 0)) && return

  if $DRY_RUN; then
    warn "Ownership changes require root when actually applied."
    return
  fi

  if [[ ! -t 0 ]]; then
    die "Ownership changes require root; rerun with sudo."
  fi

  info "Ownership changes require root; restarting through sudo."
  exec sudo -- "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

###############################################################################
# Main
###############################################################################

function main() {
  local target
  local operations_requested=false
  local operation_failed=false

  parse_arguments "$@"
  resolve_identities
  validate_arguments

  $RECURSIVE && RECURSIVE_ARGS=(--recursive --preserve-root)

  if ownership_change_requested ||
    [[ -n "$PERM_VALUE" ||
      -n "$DIR_PERM_VALUE" ||
      -n "$FILE_PERM_VALUE" ]]; then
    operations_requested=true
  fi

  if ! $operations_requested; then
    SHOW_OWNER=true
    SHOW_PERMS=true
  fi

  $REFRESH_REQUESTED &&
    warn "--refresh-rc is deprecated; permission changes require no RC reload."

  warn_about_recursive_modes
  elevate_if_needed
  confirm_recursive

  for target in "${TARGETS[@]}"; do
    printf '=== %s ===\n' "$target"

    if $SHOW_OWNER || $SHOW_PERMS; then
      display_requested_state "$target" || operation_failed=true
    fi

    if $operations_requested; then
      apply_ownership "$target" || operation_failed=true
      apply_permissions "$target" || operation_failed=true

      if ! $DRY_RUN; then
        display_ownership "$target" || operation_failed=true
        display_permissions "$target" || operation_failed=true
      fi
    fi

    printf '\n'
  done

  $operation_failed && return 1
  return 0
}

main "$@"
