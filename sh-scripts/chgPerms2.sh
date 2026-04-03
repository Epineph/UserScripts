#!/usr/bin/env bash
#===============================================================================
# chPerms - Change ownership, group, and/or permissions for one or more targets.
#
# Version: 1.6.0
# License: MIT
#
# FIXES vs your current state:
#   1) Stops “never ends” behavior by NOT defaulting to `chown/chmod -c -R`
#      (which can emit *one line per changed file* and takes ages on big trees).
#      Per-item counting is now OPT-IN via --audit (or auto-enabled by -v).
#   2) Keeps strict mode + ERR trap without the earlier arithmetic pitfalls.
#   3) Coprocess runner correctly supports ENV=VAL prefixes (LC_ALL=C).
#===============================================================================

set -Eeuo pipefail

#------------------------------------------------------------------------------
# Globals
#------------------------------------------------------------------------------
VERSION="1.6.0"

DRY_RUN=false
NOCONFIRM=false
FORCE=false
REFRESH_RC=false

VERBOSE=0
MAX_VERBOSE_DIRS=50

FAST=false
AUTO_NEXT=false
DEBUG=false

# New:
#   AUDIT=false  -> do not use chown/chmod -c (fast, no per-item counts)
#   AUDIT=true   -> parse -c output (slow on large recursive trees)
AUDIT=false

ORIG_ARGS=("$@")

BLOCK_COUNT=0
declare -a B_TGTS B_OWNER B_GROUP B_PERM_RAW B_PERM_OCT
declare -a B_RECURSIVE B_SHOW_OWNER B_SHOW_PERMS
CURRENT_BLOCK=-1

#------------------------------------------------------------------------------
# Traps
#------------------------------------------------------------------------------
function on_err() {
  local ec="$?"
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  printf 'Error: exit=%s line=%s cmd=%s\n' "$ec" "$line" "$cmd" >&2
  exit "$ec"
}
trap on_err ERR

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

Targets:
  PATH(S)                 Space-separated paths.
  -t, --target <LIST>     Comma-separated list of paths.

Operations (block-scoped):
  -o, --owner <USER>      Change owner to <USER> (or user:group).
                          "activeuser" uses $SUDO_USER if set, else id -un.
  -g, --group <GROUP>     Change group to <GROUP>.
  -p, --perm <PERMS>      755 | rwxr-xr-x | u=rwx,g=rx,o=rx

Informational (block-scoped):
  -c, --current-owner     Show current owner/group (top-level only).
  -a, --active-perms      Show current permissions (top-level only).

Recursion (block-scoped):
  -R, --recursive         Apply changes recursively.

Global:
  --dry-run, -n           Preview without applying.
  --noconfirm             Skip recursive confirmation prompt.
  --force                 Alias for --noconfirm.
  -v, --verbose           Also list changed directories (bounded).
                          (Implies --audit unless --fast.)
  --verbose-all           Print every changed item line (very noisy).
                          (Implies --audit unless --fast.)
  --max-verbose-dirs <N>  Limit directory list per target (default: 50).

  --audit                 Enable per-item change counting using chown/chmod -c.
                          WARNING: can be very slow on large recursive trees.

  --fast                  Fast mode: skip per-item counting even if --audit.
  --next, --then          Start a new block (targets+ops can differ per block).
  --auto-next             Start new block when new target appears after ops.
  --debug                 Print parse summary.
  --refresh, --refresh-rc  Source ~/.zshrc or ~/.bashrc in a subshell.
  --version               Print version.
  --help                  Show help.
EOF
}

function new_block() {
  CURRENT_BLOCK="$BLOCK_COUNT"
  B_TGTS[$CURRENT_BLOCK]=""
  B_OWNER[$CURRENT_BLOCK]=""
  B_GROUP[$CURRENT_BLOCK]=""
  B_PERM_RAW[$CURRENT_BLOCK]=""
  B_PERM_OCT[$CURRENT_BLOCK]=""
  B_RECURSIVE[$CURRENT_BLOCK]="false"
  B_SHOW_OWNER[$CURRENT_BLOCK]="false"
  B_SHOW_PERMS[$CURRENT_BLOCK]="false"
  BLOCK_COUNT=$((BLOCK_COUNT + 1))
}

function block_has_targets() {
  local idx="$1"
  [[ -n "${B_TGTS[$idx]-}" ]]
}

function block_has_ops() {
  local idx="$1"
  [[ -n "${B_OWNER[$idx]-}" ]] \
    || [[ -n "${B_GROUP[$idx]-}" ]] \
    || [[ -n "${B_PERM_RAW[$idx]-}" ]] \
    || [[ "${B_RECURSIVE[$idx]-false}" == "true" ]] \
    || [[ "${B_SHOW_OWNER[$idx]-false}" == "true" ]] \
    || [[ "${B_SHOW_PERMS[$idx]-false}" == "true" ]]
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
    if [[ "${B_RECURSIVE[$i]-false}" == "true" ]]; then
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
  local arr_name="$2"
  local -n _tgts_ref="$arr_name"

  local best=-1
  local best_len=0
  local i t

  for i in "${!_tgts_ref[@]}"; do
    t="${_tgts_ref[$i]}"
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
  local owner="${B_OWNER[$idx]-}"
  local group="${B_GROUP[$idx]-}"
  local perm_raw="${B_PERM_RAW[$idx]-}"
  local perm_oct="${B_PERM_OCT[$idx]-}"
  local rec="${B_RECURSIVE[$idx]-false}"

  printf '=== Block %d ===\n' "$((idx+1))"
  printf 'Plan:\n'
  printf '  Recursive: %s\n' "$rec"
  printf '  Owner:     %s\n' "${owner:-"(none)"}"
  printf '  Group:     %s\n' "${group:-"(none)"}"
  if [[ -n "$perm_raw" ]]; then
    printf '  Perms:     %s (= %s)\n' "$perm_raw" "$perm_oct"
  else
    printf '  Perms:     (none)\n'
  fi
  printf '  Dry-run:   %s\n' "$DRY_RUN"
  printf '  Fast:      %s\n' "$FAST"
  printf '  Verbose:   %s\n' "$VERBOSE"
  printf '  Audit:     %s\n' "$AUDIT"
  printf '\n'
}

function summarize_target_line() {
  local label="$1"
  local detail="$2"
  printf '  %-10s %s\n' "$label:" "$detail"
}

function count_all_targets() {
  local total=0
  local b s n
  for ((b=0; b<BLOCK_COUNT; b++)); do
    s="${B_TGTS[$b]-}"
    if [[ -n "$s" ]]; then
      n="$(printf '%s\n' "$s" | sed '/^$/d' | wc -l | tr -d ' ')"
      total=$((total + n))
    fi
  done
  printf '%d' "$total"
}

function run_streamed_cmd() {
  # Usage:
  #   run_streamed_cmd OUT_FD OUT_PID [ENV=VAL ...] cmd args...
  local -n _out_fd="$1"
  local -n _out_pid="$2"
  shift 2

  coproc _CP { env "$@"; }
  _out_fd="${_CP[0]}"
  _out_pid="${_CP_PID}"

  # Close write end (stdin) of coprocess in parent (defensive).
  local wfd="${_CP[1]}"
  eval "exec ${wfd}>&-"
}

function close_read_fd() {
  local fd="$1"
  eval "exec ${fd}<&-"
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
    --help) show_help; exit 0 ;;
    --version) printf 'chPerms version %s\n' "$VERSION"; exit 0 ;;
    --debug) DEBUG=true; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --noconfirm) NOCONFIRM=true; shift ;;
    --force) FORCE=true; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --verbose-all) VERBOSE=2; shift ;;
    --max-verbose-dirs)
      [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || die "Missing integer for $1"
      MAX_VERBOSE_DIRS="$2"
      shift 2
      ;;
    --audit) AUDIT=true; shift ;;
    --fast) FAST=true; shift ;;
    --next|--then|--block)
      if block_has_targets "$CURRENT_BLOCK" || block_has_ops "$CURRENT_BLOCK"; then
        new_block
      fi
      shift
      ;;
    --auto-next) AUTO_NEXT=true; shift ;;
    --refresh|--refresh-rc) REFRESH_RC=true; shift ;;
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
    --) END_OF_OPTS=true; shift ;;
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

# Verbose implies audit (unless --fast).
if ((VERBOSE >= 1)) && ! $FAST; then
  AUDIT=true
fi
if $FAST && $AUDIT; then
  warn "--fast disables per-item counting; ignoring --audit."
  AUDIT=false
fi

# Compute perms per block
for ((i=0; i<BLOCK_COUNT; i++)); do
  if [[ -n "${B_PERM_RAW[$i]-}" ]]; then
    B_PERM_OCT[$i]="$(perm_to_octal "${B_PERM_RAW[$i]}")"
  fi
done

TOTAL_TARGETS="$(count_all_targets)"
(( TOTAL_TARGETS > 0 )) || die "No targets parsed. Check -t/--target quoting."

if $DEBUG; then
  printf 'Debug: blocks=%d total_targets=%d\n' "$BLOCK_COUNT" "$TOTAL_TARGETS"
  for ((i=0; i<BLOCK_COUNT; i++)); do
    n="$(printf '%s\n' "${B_TGTS[$i]-}" | sed '/^$/d' | wc -l | tr -d ' ')"
    printf '  block[%d]: targets=%s owner=%s group=%s perm=%s rec=%s\n' \
      "$i" "$n" "${B_OWNER[$i]-}" "${B_GROUP[$i]-}" "${B_PERM_RAW[$i]-}" \
      "${B_RECURSIVE[$i]-false}"
  done
  printf '\n'
fi

# Sudo re-exec if needed
requires_sudo=false
for ((i=0; i<BLOCK_COUNT; i++)); do
  if [[ -n "${B_OWNER[$i]-}" || -n "${B_GROUP[$i]-}" ]]; then
    requires_sudo=true
    break
  fi
done

if $requires_sudo && [[ $EUID -ne 0 ]]; then
  printf '%s\n' \
    "Some operations (owner/group changes) require elevated privileges."
  read -r -p "Re-run with sudo now? [y/N]: " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    exec sudo -E -- "$0" "${ORIG_ARGS[@]}"
  else
    warn "Continuing without sudo; owner/group changes may fail."
  fi
fi

confirm_recursive_once

#------------------------------------------------------------------------------
# Apply blocks
#------------------------------------------------------------------------------
for ((b=0; b<BLOCK_COUNT; b++)); do
  mapfile -t _raw_targets < <(printf '%s\n' "${B_TGTS[$b]-}" | sed '/^$/d')
  ((${#_raw_targets[@]} > 0)) || { warn "Block $((b+1)) has no targets."; continue; }

  declare -a tgts=()
  declare -a missing=()

  for t in "${_raw_targets[@]}"; do
    tc="$(canon_path "$t")"
    if [[ -e "$tc" ]]; then
      tgts+=("$tc")
    else
      missing+=("$t")
    fi
  done

  owner="${B_OWNER[$b]-}"
  if [[ "$owner" == "activeuser" ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      owner="$SUDO_USER"
    else
      owner="$(id -un)"
    fi
  fi

  group="${B_GROUP[$b]-}"
  perm_raw="${B_PERM_RAW[$b]-}"
  perm_oct="${B_PERM_OCT[$b]-}"
  rec="${B_RECURSIVE[$b]-false}"

  if [[ "$owner" =~ ^[^:]+:[^:]+$ && -n "$group" ]]; then
    die "Ambiguous: --owner '$owner' already sets group; remove --group."
  fi

  B_OWNER[$b]="$owner"
  B_GROUP[$b]="$group"

  print_plan_header "$b"

  if ((${#missing[@]} > 0)); then
    printf 'Missing targets (skipped):\n'
    for m in "${missing[@]}"; do
      printf '  - %s\n' "$m"
    done
    printf '\n'
  fi

  ((${#tgts[@]} > 0)) || { printf 'No existing targets. Nothing to do.\n\n'; continue; }

  declare -a pre_u pre_g pre_p post_u post_g post_p
  for i in "${!tgts[@]}"; do
    stat_owner_group_perm "${tgts[$i]}" pre_u[$i] pre_g[$i] pre_p[$i]
  done

  declare -a chown_cnt chmod_cnt
  for i in "${!tgts[@]}"; do
    chown_cnt[$i]=-1
    chmod_cnt[$i]=-1
  done

  declare -A chown_dirs=()
  declare -A chmod_dirs=()

  rec_opt=()
  [[ "$rec" == "true" ]] && rec_opt=(-R)

  #---------------------------
  # chown (once per block)
  #---------------------------
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

  if $do_chown; then
    if $DRY_RUN; then
      printf '[DRY RUN] chown %s %s -- (%d target(s))\n\n' \
        "${rec_opt[*]-}" "$chown_spec" "${#tgts[@]}"
    else
      if ! $AUDIT; then
        LC_ALL=C chown "${rec_opt[@]}" -- "$chown_spec" "${tgts[@]}"
      else
        for i in "${!tgts[@]}"; do
          chown_cnt[$i]=0
        done

        fd=""
        pid=""
        run_streamed_cmd fd pid LC_ALL=C chown -c "${rec_opt[@]}" \
          -- "$chown_spec" "${tgts[@]}"

        while IFS= read -r line <&"$fd"; do
          p="$(extract_quoted_path "$line" || true)"
          [[ -n "$p" ]] || continue
          idx="$(match_target_idx "$p" tgts)"
          if ((idx >= 0)); then
            chown_cnt[$idx]=$((chown_cnt[$idx] + 1))
            if ((VERBOSE >= 1)); then
              d="$(dir_of_path "$p")"
              chown_dirs["$idx|$d"]=1
            fi
          fi
          if ((VERBOSE >= 2)); then
            printf '%s\n' "$line"
          fi
        done

        close_read_fd "$fd"
        wait "$pid"
        rc="$?"
        ((rc == 0)) || die "chown failed (exit $rc)"
      fi
    fi
  fi

  #---------------------------
  # chmod (once per block)
  #---------------------------
  do_chmod=false
  [[ -n "$perm_oct" ]] && do_chmod=true

  if $do_chmod; then
    if $DRY_RUN; then
      printf '[DRY RUN] chmod %s %s -- (%d target(s))\n\n' \
        "${rec_opt[*]-}" "$perm_oct" "${#tgts[@]}"
    else
      if ! $AUDIT; then
        LC_ALL=C chmod "${rec_opt[@]}" -- "$perm_oct" "${tgts[@]}"
      else
        for i in "${!tgts[@]}"; do
          chmod_cnt[$i]=0
        done

        fd=""
        pid=""
        run_streamed_cmd fd pid LC_ALL=C chmod -c "${rec_opt[@]}" \
          -- "$perm_oct" "${tgts[@]}"

        while IFS= read -r line <&"$fd"; do
          p="$(extract_quoted_path "$line" || true)"
          [[ -n "$p" ]] || continue
          idx="$(match_target_idx "$p" tgts)"
          if ((idx >= 0)); then
            chmod_cnt[$idx]=$((chmod_cnt[$idx] + 1))
            if ((VERBOSE >= 1)); then
              d="$(dir_of_path "$p")"
              chmod_dirs["$idx|$d"]=1
            fi
          fi
          if ((VERBOSE >= 2)); then
            printf '%s\n' "$line"
          fi
        done

        close_read_fd "$fd"
        wait "$pid"
        rc="$?"
        ((rc == 0)) || die "chmod failed (exit $rc)"
      fi
    fi
  fi

  for i in "${!tgts[@]}"; do
    stat_owner_group_perm "${tgts[$i]}" post_u[$i] post_g[$i] post_p[$i]
  done

  printf 'Results:\n'
  changed_targets=0
  unchanged_targets=0

  for i in "${!tgts[@]}"; do
    t="${tgts[$i]}"
    printf -- '-- %s\n' "$t"

    # Ownership
    if $do_chown; then
      if $DRY_RUN; then
        summarize_target_line "Ownership" \
          "planned -> ${chown_spec} (top: ${pre_u[$i]}:${pre_g[$i]})"
      else
        if ! $AUDIT; then
          summarize_target_line "Ownership" \
            "${pre_u[$i]}:${pre_g[$i]} -> ${post_u[$i]}:${post_g[$i]} (children: not audited)"
        else
          summarize_target_line "Ownership" \
            "${pre_u[$i]}:${pre_g[$i]} -> ${post_u[$i]}:${post_g[$i]} (changed: ${chown_cnt[$i]})"
        fi
      fi
    else
      summarize_target_line "Ownership" "not requested"
    fi

    # Perms
    if $do_chmod; then
      if $DRY_RUN; then
        summarize_target_line "Perms" \
          "planned -> ${perm_raw} (= ${perm_oct}) (top: ${pre_p[$i]})"
      else
        if ! $AUDIT; then
          summarize_target_line "Perms" \
            "${pre_p[$i]} -> ${post_p[$i]} (children: not audited)"
        else
          summarize_target_line "Perms" \
            "${pre_p[$i]} -> ${post_p[$i]} (changed: ${chmod_cnt[$i]})"
        fi
      fi
    else
      summarize_target_line "Perms" "not requested"
    fi

    # Changed vs unchanged (top-level only unless audited)
    did_change=false
    if $DRY_RUN; then
      did_change=true
    else
      if $do_chown; then
        [[ "${pre_u[$i]}" != "${post_u[$i]}" ]] && did_change=true
        [[ "${pre_g[$i]}" != "${post_g[$i]}" ]] && did_change=true
        if $AUDIT && ((${chown_cnt[$i]} > 0)); then
          did_change=true
        fi
      fi
      if $do_chmod; then
        [[ "${pre_p[$i]}" != "${post_p[$i]}" ]] && did_change=true
        if $AUDIT && ((${chmod_cnt[$i]} > 0)); then
          did_change=true
        fi
      fi
    fi

    if $did_change; then
      changed_targets=$((changed_targets + 1))
    else
      unchanged_targets=$((unchanged_targets + 1))
    fi

    # Optional verbose: changed directories (requires audit)
    if ((VERBOSE >= 1)) && ! $DRY_RUN && $AUDIT; then
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
        count=$((count + 1))
        if ((count >= MAX_VERBOSE_DIRS)); then
          printf '    - (truncated at %d)\n' "$MAX_VERBOSE_DIRS"
          break
        fi
      done

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
        count=$((count + 1))
        if ((count >= MAX_VERBOSE_DIRS)); then
          printf '    - (truncated at %d)\n' "$MAX_VERBOSE_DIRS"
          break
        fi
      done
    fi

    printf '\n'
  done

  printf 'Block %d summary: %d changed, %d unchanged, %d missing.\n\n' \
    "$((b+1))" "$changed_targets" "$unchanged_targets" "${#missing[@]}"

  unset tgts missing pre_u pre_g pre_p post_u post_g post_p
  unset chown_cnt chmod_cnt chown_dirs chmod_dirs rec_opt
done

#------------------------------------------------------------------------------
# Optional refresh-rc (subshell only; does not affect current shell)
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
