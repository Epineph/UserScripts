#!/usr/bin/env bash

###############################################################################
# chPerms
#
# Safely inspect and change Unix ownership and permissions for one or more
# filesystem targets.
#
# Version: 2.1.0
# Author:  Heini Winther Johnsen
# License: MIT
###############################################################################

set -uo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly VERSION="2.1.0"

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

function show_examples() {
  cat <<EOF
EXAMPLES AND USE CASES

1. Inspect without changing anything

   With no operation option, $PROGRAM_NAME displays both ownership and mode:

     $PROGRAM_NAME "\$HOME/repos"

   Request only one kind of information:

     $PROGRAM_NAME "\$HOME/repos" --current-owner
     $PROGRAM_NAME "\$HOME/repos" --active-perms

2. Make a directory private

   Permit only the owner. Root retains access independently of these bits:

     $PROGRAM_NAME "\$HOME/repos" --perm 700

   Permit the owner and members of the directory's current group:

     $PROGRAM_NAME "\$HOME/repos" --perm 770

   Changing only the top-level directory is normally sufficient to prevent
   other users from traversing into anything beneath it.

3. Remove access for "other" throughout an existing tree

   Preview first:

     $PROGRAM_NAME "\$HOME/repos" --recursive --perm o-rwx --dry-run

   Apply with an interactive confirmation:

     $PROGRAM_NAME "\$HOME/repos" --recursive --perm o-rwx

   This relative mode removes only the permissions assigned to "other".
   Existing owner/group modes and executable bits remain otherwise unchanged.

4. Repair a code repository without making every file executable

   Ensure owner/group read-write access, give traversal to directories, retain
   execution on files that are already executable, and remove other access:

     $PROGRAM_NAME "\$HOME/repos" --recursive \\
       --perm u+rwX,g+rwX,o-rwx

   Uppercase X grants execute only to directories and to files for which at
   least one execute bit is already set. It does not turn ordinary source files
   into executable files.

5. Give directories and files deliberately different modes

   For a tree containing data rather than executable scripts:

     $PROGRAM_NAME "\$HOME/data" --recursive \\
       --dir-perm 770 --file-perm 660

   Directories need execute permission for traversal. Regular data files
   usually do not. This is safer than applying 770 recursively.

6. Standardize SSH directory and file modes

   Preview:

     $PROGRAM_NAME "\$HOME/.ssh" --recursive \\
       --dir-perm 700 --file-perm 600 --dry-run

   Apply:

     $PROGRAM_NAME "\$HOME/.ssh" --recursive \\
       --dir-perm 700 --file-perm 600

   Review unusual files first. Public keys may conventionally be 644, although
   600 remains functional and more restrictive.

7. Repair ownership after files were created through sudo

   "activeuser" and "activegroup" resolve to the user who invoked sudo:

     sudo $PROGRAM_NAME "\$HOME/repos" --recursive \\
       --owner activeuser --group activegroup --dry-run

   Remove --dry-run after confirming the target and planned command:

     sudo $PROGRAM_NAME "\$HOME/repos" --recursive \\
       --owner activeuser --group activegroup

8. Configure a collaborative project with group inheritance

   Assume the group "research" already exists. Set ownership, add the setgid
   bit to directories, preserve existing executable files, and deny others:

     sudo $PROGRAM_NAME /srv/research-project --recursive \\
       --owner activeuser --group research \\
       --dir-perm u+rwx,g+rws,o-rwx \\
       --file-perm u+rw,g+rw,o-rwx

   The setgid bit on a directory causes newly created entries to inherit that
   directory's group. It does not override the creating process's umask.

9. Apply changes to several targets

   Positional paths are preferred and safely support spaces:

     $PROGRAM_NAME "\$HOME/Project Alpha" "\$HOME/Project Beta" --perm 700

   A comma-separated target list is also supported:

     $PROGRAM_NAME --target "\$HOME/dir1,\$HOME/dir2" --perm 700

   Do not use --target when a filename itself contains a comma.

10. Handle a target whose name begins with a hyphen

   Put all options before --; everything after -- is interpreted as a path:

     $PROGRAM_NAME --perm 600 -- "-draft"

11. Repair the top-level /usr/local/bin directory

   A conventional top-level configuration is root:root with mode 755:

     sudo $PROGRAM_NAME /usr/local/bin \\
       --owner root --group root --perm 755 --dry-run

     sudo $PROGRAM_NAME /usr/local/bin \\
       --owner root --group root --perm 755

   This example is deliberately non-recursive. Do not recursively rewrite a
   system tree merely to repair its top-level directory.

12. Perform an exceptional recursive system-path operation

   Dry-runs are allowed without an override:

     sudo $PROGRAM_NAME /usr/local/share/example --recursive \\
       --perm o-rwx --dry-run

   An actual recursive change below a protected system path additionally needs:

     sudo $PROGRAM_NAME /usr/local/share/example --recursive \\
       --perm o-rwx --allow-system-paths

   The filesystem root "/" is always refused as a recursive target.

Run "$PROGRAM_NAME --help" for mode semantics, safety rules, and limitations.
EOF
}

function show_help() {
  cat <<EOF
NAME
  $PROGRAM_NAME - inspect and safely change Unix ownership and permissions

SYNOPSIS
  $PROGRAM_NAME [PATH ...] [OPTIONS]
  $PROGRAM_NAME --target PATH[,PATH...] [OPTIONS]

DESCRIPTION
  $PROGRAM_NAME inspects or changes ownership and Unix mode bits for one or
  more filesystem targets. Operations are non-recursive unless --recursive is
  explicitly supplied.

  If no ownership or permission change is requested, the program displays the
  current owner, group, symbolic mode, and numeric mode.

TARGETS
  PATH ...
      One or more positional paths. Quote paths containing whitespace.

  -t, --target LIST
      Comma-separated paths. This may be combined with positional paths.
      Positional paths are safer when a filename itself contains a comma.

  --
      End option parsing. Use this before a path beginning with a hyphen.

OWNERSHIP
  -o, --owner USER[:GROUP]
      Set the owner, or owner and group together.

      "activeuser" resolves to the invoking user. When running through sudo,
      this means SUDO_USER rather than root.

  -g, --group GROUP
      Set only the group. "activegroup" resolves to the invoking user's primary
      group.

  If --owner includes a group and --group is also given, --group takes
  precedence. Ownership changes require root. In an interactive terminal, the
  program restarts itself through sudo; otherwise it exits.

PERMISSIONS
  -p, --perm MODE
      Apply MODE to each target. With --recursive, apply the same MODE to all
      descendants. This is appropriate for relative changes such as o-rwx, but
      exact modes must be considered carefully.

  --dir-perm MODE
      Apply MODE only to directories. With --recursive, use find to select
      directories beneath each target.

  --file-perm MODE
      Apply MODE only to regular files. With --recursive, use find to select
      regular files beneath each target. Symlinks, sockets, and device nodes are
      not selected.

MODE FORMATS
  Numeric:
      700       Owner rwx; group and other have no access.
      750       Owner rwx; group read/traverse; other no access.
      770       Owner and group rwx; other no access.
      2770      As 770, plus setgid/group inheritance on a directory.

      For each ordinary digit:
        read = 4, write = 2, execute/traverse = 1

      The optional leading digit controls special bits:
        setuid = 4, setgid = 2, sticky = 1

  Nine-character:
      rwxrwx---
      rw-rw----

      Supply the nine permission characters only. Do not include the file-type
      character shown at the beginning of ls -l output.

  Symbolic assignment:
      u=rwx,g=rx,o=
      u=rwx,g=rwx,o=---

      Assignment replaces the selected classes' existing permission bits.

  Relative symbolic change:
      o-rwx                 Remove all access granted to other.
      g+rw                  Add group read/write without removing other bits.
      u+rwX,g+rwX,o-rwx     A practical recursive repository policy.
      g+s                   Add setgid without replacing ordinary bits.

      Classes are u (owner), g (group), o (other), and a (all). Operators are
      + (add), - (remove), and = (replace).

      Lowercase x always represents execute/traverse. Uppercase X grants
      execute only to directories or when some execute bit is already present.

DIRECTORY PERMISSIONS
  On a directory, the familiar letters have directory-specific consequences:

    r   List entry names.
    w   Create, rename, or remove entries, normally in combination with x.
    x   Traverse/search the directory and access known entries beneath it.

  Removing x from other users on a top-level private directory prevents them
  from reaching its descendants through that path, even when a descendant file
  itself has a permissive mode.

INSPECTION
  -c, --current-owner
      Show owner and group.

  -a, --active-perms
      Show symbolic, numeric, and per-class permissions.

  When used with a change, requested inspection is shown before the operation.
  After a real change, the resulting top-level state is shown automatically.

RECURSION AND SAFETY
  -R, --recursive
      Recurse into directory targets.

  --noconfirm
  -f, --force
      Bypass the interactive confirmation for an actual recursive change.
      This suppresses a safeguard; it does not make a command intrinsically
      safe.

  --force-recursively
  --recursively-force
      Enable recursion and bypass confirmation.

  --allow-system-paths
      Permit actual recursive changes beneath protected system locations such
      as /usr, /etc, and /var. Dry-runs do not require this option. Recursive
      operations targeting "/" are always refused.

DRY-RUN
  -n, --dry-run
      Validate arguments and print shell-escaped commands without executing
      them. A dry-run never requests recursive confirmation and never invokes
      sudo merely to preview an ownership change.

OTHER OPTIONS
  --examples, --use-cases
      Display the categorized examples without the complete reference.

  --refresh, --refresh-rc
      Deprecated compatibility option. It does nothing because permission and
      ownership changes require no shell configuration reload.

  --version
      Display the program version.

  -h, --help
      Display this complete help text.

EOF

  show_examples

  cat <<EOF

COMMON ERRORS
  1. Do not apply 770 recursively unless every regular file should become
     executable. Prefer separate directory/file modes or a symbolic mode using
     uppercase X.

  2. Do not apply 660 recursively to a directory tree. Directories would lose
     execute/traverse permission and become inaccessible.

  3. Root does not need group permission and need not belong to a private
     group. Do not add an ordinary user to the root group merely for this use
     case.

  4. Do not make /usr/local/bin user-owned merely to simplify installation.
     Keep the directory root-owned and use sudo install for system-wide tools.

  5. --noconfirm removes a prompt; it does not validate the intended scope.
     Use --dry-run before unfamiliar recursive operations.

LIMITATIONS
  * Unix mode bits do not remove POSIX ACL entries. Inspect them separately:

      getfacl -- PATH

  * Recursive operations can cross nested mount points. Review the target tree
    before applying a recursive change.

  * This program does not alter the process umask. The umask continues to
    influence permissions on newly created files.

  * Permission and ownership changes are not transactional. An interruption
    can leave a recursively processed tree partially changed.

EXIT STATUS
  0   All requested validation, inspection, and operations succeeded.
  1   Invalid input, refused operation, failed command, or cancelled recursion.
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
    /|\
    /bin|/bin/*|\
    /boot|/boot/*|\
    /dev|/dev/*|\
    /efi|/efi/*|\
    /etc|/etc/*|\
    /lib|/lib/*|\
    /lib64|/lib64/*|\
    /proc|/proc/*|\
    /root|/root/*|\
    /run|/run/*|\
    /sbin|/sbin/*|\
    /sys|/sys/*|\
    /usr|/usr/*|\
    /var|/var/*)
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
      --examples|--use-cases)
        show_examples
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
