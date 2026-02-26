#!/usr/bin/env bash
#===============================================================================
# chPerms - Change ownership, group, and/or permissions for one or more targets.
#
# Key upgrades vs v1.4.0:
#   - One summary per target (no repetitive stat spam).
#   - Explicit "no change" reporting per target, even when included.
#   - Recursive runs can report how many items changed (without printing each).
#   - Optional verbose modes to show changed *directories* (default) or all items.
#   - Multi-block support: different ops for different target lists in one command.
#   - Faster execution: ownership/group combined into one chown; perms combined
#     into one chmod; operations run once per block (not once per target).
#
# License: MIT
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Globals
#------------------------------------------------------------------------------
VERSION="1.5.0"

DRY_RUN=false
NOCONFIRM=false
FORCE=false
REFRESH_RC=false

# Verbosity:
#   0 = summary only (default)
#   1 = also list changed directories (bounded)
#   2 = also print every changed item line (can be very noisy)
VERBOSE=0
MAX_VERBOSE_DIRS=50

# Fast mode:
#   If true, do not use chown/chmod change-reporting (-c). This is faster when
#   millions of items are affected, but you lose accurate per-target counts.
FAST=false

# Multi-block parsing:
#   If true, a new target list *after operations* starts a new block implicitly.
AUTO_NEXT=false

# Original args for sudo re-exec.
ORIG_ARGS=("$@")

# Blocks (indexed arrays; each block has its own settings).
BLOCK_COUNT=0
declare -a B_TGTS
declare -a B_OWNER
declare -a B_GROUP
declare -a B_PERM_RAW
declare -a B_PERM_OCT
declare -a B_RECURSIVE
declare -a B_SHOW_OWNER
declare -a B_SHOW_PERMS

CURRENT_BLOCK=-1

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function show_help() {
  cat <<'EOF'
Usage:
  chPerms [PATH(S)...] [OPTIONS]...
  chPerms -t <LIST>    [OPTIONS]...
  chPerms ... --next -t <LIST> [OPTIONS]...

Change ownership and/or group and/or permissions for one or more paths.

Targets:
  PATH(S)                 Space-separated paths.
  -t, --target <LIST>     Comma-separated list of paths (e.g. dir1,dir2,dir3).

Operations (block-scoped):
  -o, --owner <USER>      Change owner to <USER>. "user:group" also works.
                          If <USER> is "activeuser", use the invoking user
                          (prefers $SUDO_USER if set).
  -g, --group <GROUP>     Change group to <GROUP>.
  -p, --perm <PERMS>      Set permissions. Accepted formats:
                            - octal: 755
                            - 9-char: rwxr-xr-x
                            - extended: u=rwx,g=rx,o=rx

Informational (block-scoped):
  -c, --current-owner     Show current owner/group.
  -a, --active-perms      Show current permissions (symbolic + numeric).

Recursion (block-scoped):
  -R, --recursive         Apply changes recursively (prompts once unless
                          --noconfirm or --force is used).

Global behavior:
  --dry-run, -n           Preview actions without applying them.
  --noconfirm             Skip recursive confirmation prompt.
  --force                 Alias for --noconfirm (kept for convenience).
  -v, --verbose           Additionally list changed *directories* (bounded).
  --verbose-all           Print every changed item line (noisy).
  --max-verbose-dirs <N>  Max directories printed per target (default: 50).
  --fast                  Faster: do not compute accurate per-item change counts.
  --next, --then          Start a new block (new targets + new operations).
  --auto-next             Implicitly start a new block when a new target appears
                          after operations have been specified.
  --refresh, --refresh-rc  Attempt to source ~/.zshrc or ~/.bashrc in a subshell.
                          (This does not affect your already-running shell.)
  --version               Print version and exit.
  --help                  Show this help text and exit.

Examples:
  1) Apply one plan to many targets:
     sudo chPerms -t "$HOME/bin,$HOME/repos" -o heini -g root -p 755 -R

  2) Same, but show changed directories (not every file):
     sudo chPerms -t "$HOME/bin,$HOME/repos" -o heini -g root -p 755 -R -v

  3) Dry-run:
     chPerms -t "$HOME/bin,$HOME/repos" -o heini -g root -p 755 -R --dry-run

  4) Two different plans in one command (two blocks):
     sudo chPerms \
       -t "$HOME/bin,$HOME/repos" -o heini -g root -p 755 -R \
       --next \
       -t "/usr/local/bin" -o heini -g root -p 755

  5) Fast mode (skips exact per-item counting):
     sudo chPerms -t "$HOME/repos" -o heini -g root -p 755 -R --fast
EOF
}

function new_block() {
  CURRENT_BLOCK=$BLOCK_COUNT
  B_TGTS[$CURRENT_BLOCK]=""
  B_OWNER[$CURRENT_BLOCK]=""
  B_GROUP[$CURRENT_BLOCK]=""
  B_PERM_RAW[$CURRENT_BLOCK]=""
  B_PERM_OCT[$CURRENT_BLOCK]=""
  B_RECURSIVE[$CURRENT_BLOCK]="false"
  B_SHOW_OWNER[$CURRENT_BLOCK]="false"
  B_SHOW_PERMS[$CURRENT_BLOCK]="false"
  ((BLOCK_COUNT++))
}

function block_has_targets() {
  local idx="$1"
  [[ -n "${B_TGTS[$idx]}" ]]
}

function block_has_ops() {
  local idx="$1"
  [[ -n "${B_OWNER[$idx]}" ]] \
    || [[ -n "${B_GROUP[$idx]}" ]] \
    || [[ -n "${B_PERM_RAW[$idx]}" ]] \
    || [[ "${B_RECURSIVE[$idx]}" == "true" ]] \
    || [[ "${B_SHOW_OWNER[$idx]}" == "true" ]] \
    || [[ "${B_SHOW_PERMS[$idx]}" == "true" ]]
}

function add_targets_csv() {
  local idx="$1"
  local csv="$2"
  local IFS=','

  read -ra _tmp <<< "$csv"
  for t in "${_tmp[@]}"; do
    [[ -n "$t" ]] || continue
    B_TGTS[$idx]+=$'\n'"$t"
  done
}

function add_target_one() {
  local idx="$1"
  local t="$2"
  [[ -n "$t" ]] || return 0
  B_TGTS[$idx]+=$'\n'"$t"
}

function confirm_recursive_once() {
  local any_recursive=false
  local i

  for ((i=0; i<BLOCK_COUNT; i++)); do
    if [[ "${B_RECURSIVE[$i]}" == "true" ]]; then
      any_recursive=true
      break
    fi
  done

  if ! $any_recursive; then
    return 0
  fi

  if $NOCONFIRM || $FORCE; then
    return 0
  fi

  printf '%s\n' \
    "You requested a recursive operation (-R). This may affect many files and" \
    "can break your system if used incorrectly."
  read -r -p "Continue? [y/N]: " response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    printf '%s\n' "Recursive operation cancelled."
    exit 1
  fi
}

function stat_owner_group_perm() {
  local path="$1"
  local -n out_owner="$2"
  local -n out_group="$3"
  local -n out_perm="$4"

  out_owner="$(stat -c %U -- "$path" 2>/dev/null || true)"
  out_group="$(stat -c %G -- "$path" 2>/dev/null || true)"
  out_perm="$(stat -c %a -- "$path" 2>/dev/null || true)"
}

function triad_to_digit() {
  local tri="$1"
  local -i v=0
  [[ "$tri" == *r* ]] && ((v+=4))
  [[ "$tri" == *w* ]] && ((v+=2))
  [[ "$tri" == *x* ]] && ((v+=1))
  printf '%d' "$v"
}

function perm_to_octal() {
  local p="$1"

  if [[ "$p" =~ ^[0-7]{3}$ ]]; then
    printf '%s' "$p"
    return 0
  fi

  if [[ "$p" =~ ^[rwx-]{9}$ ]]; then
    local u g o
    u="$(triad_to_digit "${p:0:3}")"
    g="$(triad_to_digit "${p:3:3}")"
    o="$(triad_to_digit "${p:6:3}")"
    printf '%s%s%s' "$u" "$g" "$o"
    return 0
  fi

  if [[ "$p" =~ ^u=([rwx-]{1,3}),g=([rwx-]{1,3}),o=([rwx-]{1,3})$ ]]; then
    local u g o
    u="$(triad_to_digit "${BASH_REMATCH[1]}")"
    g="$(triad_to_digit "${BASH_REMATCH[2]}")"
    o="$(triad_to_digit "${BASH_REMATCH[3]}")"
    printf '%s%s%s' "$u" "$g" "$o"
    return 0
  fi

  die "Invalid permissions format: '$p'"
}

function canon_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    printf '%s' "$p"
  fi
}

function extract_quoted_path() {
  local line="$1"
  if [[ "$line" =~ \'([^\']+)\' ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

function match_target_idx() {
  local path="$1"
  local -n tgts="$2"

  local best=-1
  local best_len=0
  local i t

  for i in "${!tgts[@]}"; do
    t="${tgts[$i]}"
    if [[ "$path" == "$t" || "$path" == "$t/"* ]]; then
      if (( ${#t} > best_len )); then
        best="$i"
        best_len="${#t}"
      fi
    fi
  done

  printf '%d' "$best"
}

function dir_of_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    printf '%s' "$p"
  else
    dirname -- "$p"
  fi
}

function print_plan_header() {
  local idx="$1"
  local owner="${B_OWNER[$idx]}"
  local group="${B_GROUP[$idx]}"
  local perm_raw="${B_PERM_RAW[$idx]}"
  local perm_oct="${B_PERM_OCT[$idx]}"
  local rec="${B_RECURSIVE[$idx]}"

  printf '=== Block %d ===\n' "$((idx+1))"
  printf 'Plan:\n'
  printf '  Recursive: %s\n' "$rec"

  if [[ -n "$owner" ]]; then
    printf "  Owner:     %s\n" "$owner"
  else
    printf "  Owner:     (none)\n"
  fi

  if [[ -n "$group" ]]; then
    printf "  Group:     %s\n" "$group"
  else
    printf "  Group:     (none)\n"
  fi

  if [[ -n "$perm_raw" ]]; then
    printf "  Perms:     %s (= %s)\n" "$perm_raw" "$perm_oct"
  else
    printf "  Perms:     (none)\n"
  fi

  printf "  Dry-run:   %s\n" "$DRY_RUN"
  printf "  Fast:      %s\n" "$FAST"
  printf "  Verbose:   %s\n" "$VERBOSE"
  printf '\n'
}

function summarize_target_line() {
  local label="$1"
  local changed="$2"
  local detail="$3"

  if [[ "$changed" == "changed" ]]; then
    printf "  %-10s %s\n" "$label:" "$detail"
  elif [[ "$changed" == "unchanged" ]]; then
    printf "  %-10s %s\n" "$label:" "$detail"
  else
    printf "  %-10s %s\n" "$label:" "$detail"
  fi
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------
new_block
END_OF_OPTS=false

while [[ $# -gt 0 ]]; do
  if $END_OF_OPTS; then
    if $AUTO_NEXT && block_has_targets "$CURRENT_BLOCK" \
      && block_has_ops "$CURRENT_BLOCK"; then
      new_block
    fi
    add_target_one "$CURRENT_BLOCK" "$1"
    shift
    continue
  fi

  case "$1" in
    --help)
      show_help
      exit 0
      ;;
    --version)
      printf 'chPerms version %s\n' "$VERSION"
      exit 0
      ;;
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    --noconfirm)
      NOCONFIRM=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    --verbose-all)
      VERBOSE=2
      shift
      ;;
    --max-verbose-dirs)
      [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || die "Missing integer for $1"
      MAX_VERBOSE_DIRS="$2"
      shift 2
      ;;
    --fast)
      FAST=true
      shift
      ;;
    --next|--then|--block)
      if block_has_targets "$CURRENT_BLOCK" || block_has_ops "$CURRENT_BLOCK"; then
        new_block
      fi
      shift
      ;;
    --auto-next)
      AUTO_NEXT=true
      shift
      ;;
    --refresh|--refresh-rc)
      REFRESH_RC=true
      shift
      ;;
    -R|--recursive|--recursively-apply|--recurse-action|--force-recursively|\
--recursively-force)
      B_RECURSIVE[$CURRENT_BLOCK]="true"
      if [[ "$1" == "--force-recursively" || "$1" == "--recursively-force" ]]; then
        FORCE=true
      fi
      shift
      ;;
    -c|--current-owner|currentowner|currentownership)
      B_SHOW_OWNER[$CURRENT_BLOCK]="true"
      shift
      ;;
    -a|--active-perms|--active-permissions|currentperms)
      B_SHOW_PERMS[$CURRENT_BLOCK]="true"
      shift
      ;;
    -o|--owner|ownership|owner)
      [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die "Missing argument for $1"
      B_OWNER[$CURRENT_BLOCK]="$2"
      shift 2
      ;;
    -g|--group)
      [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die "Missing argument for $1"
      B_GROUP[$CURRENT_BLOCK]="$2"
      shift 2
      ;;
    -p|--perm|--perms|--permission|permissions|perms|perm)
      [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die "Missing argument for $1"
      B_PERM_RAW[$CURRENT_BLOCK]="$2"
      shift 2
      ;;
    -t|--target)
      [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die "Missing argument for $1"
      add_targets_csv "$CURRENT_BLOCK" "$2"
      shift 2
      ;;
    --)
      END_OF_OPTS=true
      shift
      ;;
    -*)
      die "Unknown option: '$1'"
      ;;
    *)
      if $AUTO_NEXT && block_has_targets "$CURRENT_BLOCK" \
        && block_has_ops "$CURRENT_BLOCK"; then
        new_block
      fi
      add_target_one "$CURRENT_BLOCK" "$1"
      shift
      ;;
  esac
done

# Trim trailing empty blocks (e.g. if command ends with --next).
while ((BLOCK_COUNT > 0)); do
  local_last=$((BLOCK_COUNT - 1))
  if block_has_targets "$local_last" || block_has_ops "$local_last"; then
    break
  fi
  unset 'B_TGTS[local_last]'
  unset 'B_OWNER[local_last]'
  unset 'B_GROUP[local_last]'
  unset 'B_PERM_RAW[local_last]'
  unset 'B_PERM_OCT[local_last]'
  unset 'B_RECURSIVE[local_last]'
  unset 'B_SHOW_OWNER[local_last]'
  unset 'B_SHOW_PERMS[local_last]'
  ((BLOCK_COUNT--))
done

((BLOCK_COUNT > 0)) || die "No targets provided. Use PATH(S) or -t/--target."

# Compute and validate perms for each block early.
for ((i=0; i<BLOCK_COUNT; i++)); do
  if [[ -n "${B_PERM_RAW[$i]}" ]]; then
    B_PERM_OCT[$i]="$(perm_to_octal "${B_PERM_RAW[$i]}")"
  fi
done

# Decide if we should sudo re-exec (only owner/group needs it reliably).
requires_sudo=false
for ((i=0; i<BLOCK_COUNT; i++)); do
  if [[ -n "${B_OWNER[$i]}" || -n "${B_GROUP[$i]}" ]]; then
    requires_sudo=true
    break
  fi
done

if $requires_sudo && [[ $EUID -ne 0 ]]; then
  printf '%s\n' \
    "Some operations (owner/group changes) require elevated privileges."
  read -r -p "Re-run with sudo now? [y/N]: " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    if command -v realpath >/dev/null 2>&1; then
      SELF="$(realpath -e -- "$0" 2>/dev/null || printf '%s' "$0")"
    else
      SELF="$0"
    fi
    exec sudo -E -- "$SELF" "${ORIG_ARGS[@]}"
  else
    warn "Continuing without sudo; owner/group changes may fail."
  fi
fi

confirm_recursive_once

#------------------------------------------------------------------------------
# Apply blocks
#------------------------------------------------------------------------------
for ((b=0; b<BLOCK_COUNT; b++)); do
  # Extract targets (skip the leading newline).
  mapfile -t _raw_targets < <(printf '%s' "${B_TGTS[$b]}" | sed '/^$/d')
  ((${#_raw_targets[@]} > 0)) || continue

  # Canonicalize and split into existing vs missing.
  declare -a tgts=()
  declare -a tgts_orig=()
  declare -a missing=()

  for t in "${_raw_targets[@]}"; do
    tc="$(canon_path "$t")"
    if [[ -e "$tc" ]]; then
      tgts+=("$tc")
      tgts_orig+=("$t")
    else
      missing+=("$t")
    fi
  done

  # Owner "activeuser" normalization.
  owner="${B_OWNER[$b]}"
  if [[ "$owner" == "activeuser" ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      owner="$SUDO_USER"
    else
      owner="$(id -un)"
    fi
  fi

  group="${B_GROUP[$b]}"
  perm_raw="${B_PERM_RAW[$b]}"
  perm_oct="${B_PERM_OCT[$b]}"
  rec="${B_RECURSIVE[$b]}"

  # Prevent ambiguous owner "user:grp" + separate -g.
  if [[ "$owner" =~ ^[^:]+:[^:]+$ && -n "$group" ]]; then
    die "Ambiguous: --owner '$owner' already sets group; remove --group."
  fi

  # Apply updated owner into block for printing.
  B_OWNER[$b]="$owner"
  B_GROUP[$b]="$group"

  print_plan_header "$b"

  # Show missing targets first (still included, explicitly).
  if ((${#missing[@]} > 0)); then
    printf 'Missing targets (skipped):\n'
    for m in "${missing[@]}"; do
      printf '  - %s\n' "$m"
    done
    printf '\n'
  fi

  if ((${#tgts[@]} == 0)); then
    printf 'No existing targets in this block. Nothing to do.\n\n'
    continue
  fi

  # Pre-stats per target.
  declare -a pre_u pre_g pre_p
  declare -a post_u post_g post_p
  for i in "${!tgts[@]}"; do
    pre_u[$i]=""
    pre_g[$i]=""
    pre_p[$i]=""
    stat_owner_group_perm "${tgts[$i]}" pre_u[$i] pre_g[$i] pre_p[$i]
  done

  # Optional: show current owner/perms (top-level only).
  if [[ "${B_SHOW_OWNER[$b]}" == "true" ]]; then
    for i in "${!tgts[@]}"; do
      printf "-- %s\n" "${tgts[$i]}"
      printf "  Owner: %s\n" "${pre_u[$i]}"
      printf "  Group: %s\n" "${pre_g[$i]}"
    done
    printf '\n'
  fi

  if [[ "${B_SHOW_PERMS[$b]}" == "true" ]]; then
    for i in "${!tgts[@]}"; do
      sym="$(stat -c %A -- "${tgts[$i]}" 2>/dev/null || true)"
      printf "-- %s\n" "${tgts[$i]}"
      printf "  Symbolic: %s\n" "$sym"
      printf "  Numeric:  %s\n" "${pre_p[$i]}"
    done
    printf '\n'
  fi

  # Change counters and directory sets.
  declare -a chown_cnt chmod_cnt
  for i in "${!tgts[@]}"; do
    chown_cnt[$i]=0
    chmod_cnt[$i]=0
  done

  declare -A chown_dirs=()
  declare -A chmod_dirs=()

  # chown (combined owner/group) once per block
  do_chown=false
  chown_spec=""

  if [[ -n "$owner" && -n "$group" ]]; then
    do_chown=true
    chown_spec="${owner}:${group}"
  elif [[ -n "$owner" ]]; then
    do_chown=true
    chown_spec="$owner"
  elif [[ -n "$group" ]]; then
    do_chown=true
    chown_spec=":${group}"
  fi

  rec_flag=""
  if [[ "$rec" == "true" ]]; then
    rec_flag="-R"
  fi

  if $do_chown; then
    if $DRY_RUN; then
      printf '[DRY RUN] chown %s %s -- (%d target(s))\n\n' \
        "$rec_flag" "$chown_spec" "${#tgts[@]}"
    else
      if $FAST; then
        LC_ALL=C chown $rec_flag -- "$chown_spec" -- "${tgts[@]}"
      else
        while IFS= read -r line; do
          p="$(extract_quoted_path "$line" || true)"
          [[ -n "$p" ]] || continue
          idx="$(match_target_idx "$p" tgts)"
          if ((idx >= 0)); then
            ((chown_cnt[$idx]++))
            if ((VERBOSE >= 1)); then
              d="$(dir_of_path "$p")"
              chown_dirs["$idx|$d"]=1
            fi
          fi
          if ((VERBOSE >= 2)); then
            printf '%s\n' "$line"
          fi
        done < <(LC_ALL=C chown -c $rec_flag -- "$chown_spec" -- "${tgts[@]}")
      fi
    fi
  fi

  # chmod once per block
  do_chmod=false
  if [[ -n "$perm_oct" ]]; then
    do_chmod=true
  fi

  if $do_chmod; then
    if $DRY_RUN; then
      printf '[DRY RUN] chmod %s %s -- (%d target(s))\n\n' \
        "$rec_flag" "$perm_oct" "${#tgts[@]}"
    else
      if $FAST; then
        LC_ALL=C chmod $rec_flag -- "$perm_oct" -- "${tgts[@]}"
      else
        while IFS= read -r line; do
          p="$(extract_quoted_path "$line" || true)"
          [[ -n "$p" ]] || continue
          idx="$(match_target_idx "$p" tgts)"
          if ((idx >= 0)); then
            ((chmod_cnt[$idx]++))
            if ((VERBOSE >= 1)); then
              d="$(dir_of_path "$p")"
              chmod_dirs["$idx|$d"]=1
            fi
          fi
          if ((VERBOSE >= 2)); then
            printf '%s\n' "$line"
          fi
        done < <(LC_ALL=C chmod -c $rec_flag -- "$perm_oct" -- "${tgts[@]}")
      fi
    fi
  fi

  # Post-stats per target.
  for i in "${!tgts[@]}"; do
    post_u[$i]=""
    post_g[$i]=""
    post_p[$i]=""
    stat_owner_group_perm "${tgts[$i]}" post_u[$i] post_g[$i] post_p[$i]
  done

  # Per-target summary.
  printf 'Results:\n'
  changed_targets=0
  unchanged_targets=0

  for i in "${!tgts[@]}"; do
    t="${tgts[$i]}"
    printf -- '-- %s\n' "$t"

    # Ownership/group reporting
    if $do_chown; then
      top_changed=false
      [[ "${pre_u[$i]}" != "${post_u[$i]}" ]] && top_changed=true
      [[ "${pre_g[$i]}" != "${post_g[$i]}" ]] && top_changed=true

      if $DRY_RUN; then
        summarize_target_line "Ownership" "dryrun" \
          "planned -> ${chown_spec} (top: ${pre_u[$i]}:${pre_g[$i]})"
      else
        if $FAST; then
          # In fast mode, per-item counts are not computed.
          if $top_changed; then
            summarize_target_line "Ownership" "changed" \
              "${pre_u[$i]}:${pre_g[$i]} -> ${post_u[$i]}:${post_g[$i]} " \
              "(children: unknown; --fast)"
          else
            summarize_target_line "Ownership" "unchanged" \
              "${post_u[$i]}:${post_g[$i]} (children: unknown; --fast)"
          fi
        else
          if $top_changed; then
            summarize_target_line "Ownership" "changed" \
              "${pre_u[$i]}:${pre_g[$i]} -> ${post_u[$i]}:${post_g[$i]} " \
              "(changed items: ${chown_cnt[$i]})"
          else
            summarize_target_line "Ownership" "unchanged" \
              "${post_u[$i]}:${post_g[$i]} (changed items: ${chown_cnt[$i]})"
          fi
        fi
      fi
    else
      summarize_target_line "Ownership" "skipped" "not requested"
    fi

    # Permissions reporting
    if $do_chmod; then
      top_changed=false
      [[ "${pre_p[$i]}" != "${post_p[$i]}" ]] && top_changed=true

      if $DRY_RUN; then
        summarize_target_line "Perms" "dryrun" \
          "planned -> ${perm_raw} (= ${perm_oct}) (top: ${pre_p[$i]})"
      else
        if $FAST; then
          if $top_changed; then
            summarize_target_line "Perms" "changed" \
              "${pre_p[$i]} -> ${post_p[$i]} (children: unknown; --fast)"
          else
            summarize_target_line "Perms" "unchanged" \
              "${post_p[$i]} (children: unknown; --fast)"
          fi
        else
          if $top_changed; then
            summarize_target_line "Perms" "changed" \
              "${pre_p[$i]} -> ${post_p[$i]} (changed items: ${chmod_cnt[$i]})"
          else
            summarize_target_line "Perms" "unchanged" \
              "${post_p[$i]} (changed items: ${chmod_cnt[$i]})"
          fi
        fi
      fi
    else
      summarize_target_line "Perms" "skipped" "not requested"
    fi

    # Aggregate changed vs unchanged targets.
    did_change=false

    if $DRY_RUN; then
      did_change=true
    else
      if $do_chown; then
        if [[ "${pre_u[$i]}" != "${post_u[$i]}" || \
              "${pre_g[$i]}" != "${post_g[$i]}" ]]; then
          did_change=true
        elif ! $FAST && ((${chown_cnt[$i]} > 0)); then
          did_change=true
        fi
      fi
      if $do_chmod; then
        if [[ "${pre_p[$i]}" != "${post_p[$i]}" ]]; then
          did_change=true
        elif ! $FAST && ((${chmod_cnt[$i]} > 0)); then
          did_change=true
        fi
      fi
    fi

    if $did_change; then
      ((changed_targets++))
    else
      ((unchanged_targets++))
    fi

    # Verbose directory listing (bounded)
    if ((VERBOSE >= 1)) && ! $DRY_RUN && ! $FAST; then
      if $do_chown; then
        count=0
        printed=false
        for k in "${!chown_dirs[@]}"; do
          [[ "$k" == "$i|"* ]] || continue
          d="${k#*$i|}"
          if ! $printed; then
            printf '  Changed dirs (ownership):\n'
            printed=true
          fi
          printf '    - %s\n' "$d"
          ((count++))
          if ((count >= MAX_VERBOSE_DIRS)); then
            printf '    - (truncated at %d)\n' "$MAX_VERBOSE_DIRS"
            break
          fi
        done
      fi

      if $do_chmod; then
        count=0
        printed=false
        for k in "${!chmod_dirs[@]}"; do
          [[ "$k" == "$i|"* ]] || continue
          d="${k#*$i|}"
          if ! $printed; then
            printf '  Changed dirs (perms):\n'
            printed=true
          fi
          printf '    - %s\n' "$d"
          ((count++))
          if ((count >= MAX_VERBOSE_DIRS)); then
            printf '    - (truncated at %d)\n' "$MAX_VERBOSE_DIRS"
            break
          fi
        done
      fi
    fi

    printf '\n'
  done

  printf 'Block %d summary: %d changed, %d unchanged, %d missing.\n\n' \
    "$((b+1))" "$changed_targets" "$unchanged_targets" "${#missing[@]}"

  unset tgts tgts_orig missing
  unset pre_u pre_g pre_p post_u post_g post_p
  unset chown_cnt chmod_cnt chown_dirs chmod_dirs
done

#------------------------------------------------------------------------------
# Optional refresh-rc (subshell only; does not affect the current shell)
#------------------------------------------------------------------------------
if $REFRESH_RC; then
  if [[ -n "${SUDO_USER:-}" ]]; then
    local_user="$SUDO_USER"
  else
    local_user="$USER"
  fi

  user_home="$(eval echo "~$local_user")"
  shell_basename="$(basename "${SHELL:-bash}")"

  rc_file=""
  if [[ "$shell_basename" == "zsh" ]]; then
    rc_file="$user_home/.zshrc"
  else
    rc_file="$user_home/.bashrc"
  fi

  if [[ -f "$rc_file" ]]; then
    printf "Sourcing %s in a subshell (no effect on current shell).\n" "$rc_file"
    # shellcheck disable=SC1090
    ( source "$rc_file" )
  else
    warn "No rc file found at '$rc_file'. Skipping."
  fi
fi
