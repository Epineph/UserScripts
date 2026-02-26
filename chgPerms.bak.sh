#!/usr/bin/env bash
# chPerms — batch-safe ownership & permission changer with per-target scoping
# Version: 2.0.0  |  License: MIT  |  Author: Heini W. Johnsen (revised)
# Exit codes: 0 ok, 1 usage, 2 privilege policy unmet, 3 runtime error

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
VERSION="2.0.0"

# ─────────────────────────────── Help ───────────────────────────────
show_help() {
  cat <<'EOF'
Usage:
  chPerms [TARGET ...] [batch-options] [--] [ -t LIST [batch-options] ] ...

Description:
  Change ownership and/or permissions on one or more TARGET paths.
  Options are **batch-scoped**: every time you start a new batch with
  positional TARGET(s) or -t/--target LIST, the options that follow apply
  only to that batch, until the next batch begins.

Batches:
  • Positional TARGET(s)   e.g.,  chPerms dirA dirB -o user -g group -p 755 -R
  • -t, --target LIST      Comma and/or space separated list, quotes allowed.
                           e.g., -t "/usr/local/bin, ~/bin /opt/tools"

Batch options:
  -R, --recursive                 Recurse (prompts unless --noconfirm).
      --noconfirm                 Do not prompt for recursive operations.
  -o, --owner USER[:GROUP]        Set owner (and optional group).
  -g, --group GROUP               Set group.
  -p, --perm MODE                 Permissions: octal (755|0755), symbolic
                                  (u=rwx,go=rx or a+rwX), or raw 9-chars
                                  (rwxr-x---), which is converted to octal.
  -c, --current-owner             Show current owner:group of each target.
  -a, --active-perms              Show current permissions (symbolic & octal).

Global options:
  --dry-run, -n                   Print intended actions only.
  --refresh, --refresh-rc         Source the caller's rc file in a subshell.
  --version                       Print version and exit.
  --help                          Show this help and exit.

Examples:
  # One batch via -t:
  sudo chPerms -t "$HOME/repos, $HOME/Documents" -R --noconfirm -o heini -g adm -p 775

  # Multiple batches in one call (each with its own options):
  sudo chPerms \
    -t "$HOME/bin"         -R --noconfirm -o heini -g adm -p rwxrwx--- \
    -t "/usr/local/bin"    -R --noconfirm -o heini -g adm -p 755

Notes:
  • Changing owner/group typically requires sudo. The script will re-exec
    itself with sudo preserving arguments if needed and allowed.
EOF
}

# ───────────────────────── Utilities ─────────────────────────
die() { printf '%s\n' "$*" >&2; exit 1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

stat_owner() { stat -c '%U' -- "$1"; }
stat_group() { stat -c '%G' -- "$1"; }
stat_perm_sym() { stat -c '%A' -- "$1"; }
stat_perm_oct() { stat -c '%a' -- "$1"; }

display_ownership() {
  printf 'Current ownership of %q:\n  Owner: %s\n  Group: %s\n' \
    "$1" "$(stat_owner "$1" 2>/dev/null || echo '?')" "$(stat_group "$1" 2>/dev/null || echo '?')"
}

display_permissions() {
  local sym oct
  sym="$(stat_perm_sym "$1" 2>/dev/null || echo '??????????')"
  oct="$(stat_perm_oct "$1" 2>/dev/null || echo '???')"
  printf 'Current permissions of %q:\n  Symbolic: %s\n  Numeric: %s\n' "$1" "$sym" "$oct"
  if [[ $sym != '??????????' ]]; then
    printf '  Detailed: u=%s, g=%s, o=%s\n' "${sym:1:3}" "${sym:4:3}" "${sym:7:3}"
  fi
}

# Convert a 3-char rwx triplet to a single octal digit (0–7)
triplet_to_digit() {
  local t=$1 d=0
  [[ $t == *r* ]] && ((d+=4))
  [[ $t == *w* ]] && ((d+=2))
  [[ $t == *x* ]] && ((d+=1))
  printf '%d' "$d"
}

# Accepts 9-char rwx form (e.g., rwxr-x---) → prints octal (e.g., 750)
nine_to_octal() {
  local s=$1
  [[ ${#s} -eq 9 && $s =~ ^[rwx-]{9}$ ]] || return 1
  printf '%d%d%d' \
    "$(triplet_to_digit "${s:0:3}")" \
    "$(triplet_to_digit "${s:3:3}")" \
    "$(triplet_to_digit "${s:6:3}")"
}

# Parse a -t/--target list (commas and/or spaces). Honors shell quotes upstream.
parse_target_list() {
  local raw=$1 chunk
  # Split on commas first, then on IFS for inner spaces
  while IFS= read -r chunk; do
    chunk="${chunk//,/ }"
    for p in $chunk; do
      [[ -n $p ]] && printf '%s\n' "$p"
    done
  done <<<"$raw"
}

confirm_recursive() {
  local prompt_allowed=$1
  $prompt_allowed || return 0
  printf '%s\n' "Recursive operation may alter many files."
  read -rp "Proceed? [y/N]: " ans
  [[ $ans == [Yy] ]] || die "Aborted by user."
}

# ───────────────────────── Data model ─────────────────────────
# We store batches in parallel arrays; each index i is a batch.
BATCH_TARGETS=()     # newline-separated list per batch
BATCH_RECURSIVE=()
BATCH_NOCONFIRM=()
BATCH_OWNER=()       # may contain "user" or "user:group" or empty
BATCH_GROUP=()       # group only
BATCH_PERM=()        # raw mode string; we normalize at apply time
BATCH_SHOW_OWNER=()  # boolean
BATCH_SHOW_PERMS=()  # boolean

new_batch() {
  BATCH_TARGETS+=("")
  BATCH_RECURSIVE+=("false")
  BATCH_NOCONFIRM+=("false")
  BATCH_OWNER+=("")
  BATCH_GROUP+=("")
  BATCH_PERM+=("")
  BATCH_SHOW_OWNER+=("false")
  BATCH_SHOW_PERMS+=("false")
}

set_batch_field() {  # idx key value
  local i=$1 key=$2 val=$3
  case $key in
    targets)       BATCH_TARGETS[$i]=$val ;;
    recursive)     BATCH_RECURSIVE[$i]=$val ;;
    noconfirm)     BATCH_NOCONFIRM[$i]=$val ;;
    owner)         BATCH_OWNER[$i]=$val ;;
    group)         BATCH_GROUP[$i]=$val ;;
    perm)          BATCH_PERM[$i]=$val ;;
    show_owner)    BATCH_SHOW_OWNER[$i]=$val ;;
    show_perms)    BATCH_SHOW_PERMS[$i]=$val ;;
  esac
}

append_targets() {  # idx value...
  local i=$1; shift
  local cur=${BATCH_TARGETS[$i]}
  local add
  for add in "$@"; do
    cur+=$'\n'"$add"
  done
  BATCH_TARGETS[$i]="$cur"
}

# ───────────────────────── Parse args (batch-scoped) ─────────────────────────
ORIGINAL_ARGS=("$@")

DRY_RUN=false
REFRESH_RC=false

new_batch
cur=0
saw_any_target=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) show_help; exit 0 ;;
    --version) printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --refresh|--refresh-rc) REFRESH_RC=true; shift ;;

    -R|--recursive) set_batch_field "$cur" recursive true; shift ;;
    --noconfirm)    set_batch_field "$cur" noconfirm true; shift ;;

    -o|--owner)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" owner "$2"; shift 2 ;;
    -g|--group)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" group "$2"; shift 2 ;;
    -p|--perm|--perms|--permission)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" perm "$2"; shift 2 ;;

    -c|--current-owner) set_batch_field "$cur" show_owner true; shift ;;
    -a|--active-perms)  set_batch_field "$cur" show_perms true; shift ;;

    -t|--target)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1 (comma/space separated paths)"
      # If current batch already has targets, start a new batch
      if [[ -n ${BATCH_TARGETS[$cur]} ]]; then new_batch; ((cur++)); fi
      # Expand list into lines and append
      mapfile -t paths < <(parse_target_list "$2")
      [[ ${#paths[@]} -gt 0 ]] || die "Empty target list for $1"
      append_targets "$cur" "${paths[@]}"
      saw_any_target=true
      shift 2
      ;;
    --) shift; # everything after -- are positional targets for current/new batch
        if [[ -n ${BATCH_TARGETS[$cur]} ]]; then new_batch; ((cur++)); fi
        while [[ $# -gt 0 ]]; do
          [[ $1 == -* ]] && break
          append_targets "$cur" "$1"; saw_any_target=true; shift || true
        done
        ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)  # positional TARGET → start or continue current batch
      append_targets "$cur" "$1"; saw_any_target=true; shift ;;
  esac
done

# Remove any empty final batch
if [[ -z ${BATCH_TARGETS[$cur]} ]]; then
  # but keep if it is the only (empty) batch
  if (( ${#BATCH_TARGETS[@]} > 1 )); then
    unset 'BATCH_TARGETS[-1]' 'BATCH_RECURSIVE[-1]' 'BATCH_NOCONFIRM[-1]' \
          'BATCH_OWNER[-1]' 'BATCH_GROUP[-1]' 'BATCH_PERM[-1]' \
          'BATCH_SHOW_OWNER[-1]' 'BATCH_SHOW_PERMS[-1]'
  fi
fi

# Help if no targets at all
if ! $saw_any_target; then
  show_help
  exit 1
fi

# Determine if any batch needs sudo (owner/group changes anywhere)
needs_priv=false
for i in "${!BATCH_TARGETS[@]}"; do
  [[ -n ${BATCH_OWNER[$i]} || -n ${BATCH_GROUP[$i]} ]] && needs_priv=true
done

if $needs_priv && ! is_root; then
  # Re-exec with sudo, preserving args
  exec sudo -E -- "$0" "${ORIGINAL_ARGS[@]}"
fi

# ───────────────────────── Apply batches ─────────────────────────
apply_perm() {  # target mode recursiveFlag
  local T=$1 mode=$2 rec=$3

  # Accept NNN/NNNN; accept full chmod symbolic; convert 9-char if needed.
  local eff="$mode"
  if [[ $mode =~ ^[rwx-]{9}$ ]]; then
    if ! eff="$(nine_to_octal "$mode")"; then
      die "Invalid 9-char mode: $mode"
    fi
  fi

  if $DRY_RUN; then
    printf '[DRY RUN] chmod %s %q %q\n' "$([[ $rec == true ]] && echo -R || true)" "$eff" "$T"
  else
    chmod $([[ $rec == true ]] && echo -R) -- "$eff" "$T"
  fi
}

apply_owner_group() {  # target owner group recursiveFlag
  local T=$1 owner=$2 grp=$3 rec=$4
  local spec=""
  if [[ -n $owner && -n $grp ]]; then
    spec="${owner}:$grp"
  elif [[ -n $owner ]]; then
    spec="$owner"
  elif [[ -n $grp ]]; then
    spec=":$grp"
  else
    return 0
  fi
  if $DRY_RUN; then
    printf '[DRY RUN] chown %s %q %q\n' "$([[ $rec == true ]] && echo -R || true)" "$spec" "$T"
  else
    chown $([[ $rec == true ]] && echo -R) -- "$spec" "$T"
  fi
}

for i in "${!BATCH_TARGETS[@]}"; do
  # Resolve batch flags/values
  rec="${BATCH_RECURSIVE[$i]}"
  noconf="${BATCH_NOCONFIRM[$i]}"
  show_o="${BATCH_SHOW_OWNER[$i]}"
  show_p="${BATCH_SHOW_PERMS[$i]}"
  own="${BATCH_OWNER[$i]}"
  grp="${BATCH_GROUP[$i]}"
  prm="${BATCH_PERM[$i]}"

  # Materialize target list
  mapfile -t targets <<<"${BATCH_TARGETS[$i]}"
  # Filter empties & expand ~
  cleaned=()
  for T in "${targets[@]}"; do
    [[ -z $T ]] && continue
    cleaned+=( "$(readlink -f -- "$T" 2>/dev/null || echo "$T")" )
  done
  targets=("${cleaned[@]}")

  # Recursion confirmation (once per batch)
  if [[ $rec == true && $noconf != true ]]; then
    confirm_recursive true
  fi

  for T in "${targets[@]}"; do
    if [[ ! -e $T ]]; then
      printf 'Warning: target %q does not exist. Skipping.\n' "$T" >&2
      continue
    fi

    printf '=== Processing target: %q ===\n' "$T"

    # Show before?
    [[ $show_o == true ]] && display_ownership "$T"
    [[ $show_p == true ]] && display_permissions "$T"

    # Owner/group
    if [[ -n $own || -n $grp ]]; then
      [[ $own == "activeuser" ]] && own="$(id -un)"
      apply_owner_group "$T" "$own" "$grp" "$rec"
      display_ownership "$T"
    fi

    # Permissions
    if [[ -n $prm ]]; then
      apply_perm "$T" "$prm" "$rec"
      display_permissions "$T"
    fi

    echo
  done
done

# ───────────────────────── Optional: refresh RC ─────────────────────────
if $REFRESH_RC; then
  # Source caller's rc in subshell; informative only.
  who="${SUDO_USER:-$USER}"
  home="$(eval echo "~$who")"
  shell_base="$(basename "${SHELL:-/bin/bash}")"
  rc="$home/.bashrc"
  [[ $shell_base == "zsh" ]] && rc="$home/.zshrc"
  if [[ -f $rc ]]; then
    echo "Sourcing $rc in a subshell (informational; won’t alter current shell)."
    # shellcheck disable=SC1090
    ( source "$rc" ) >/dev/null 2>&1 || true
  else
    echo "No rc file at $rc; skipping."
  fi
fi

exit 0
#!/usr/bin/env bash
# chPerms — batch-safe ownership & permission changer with per-target scoping
# Version: 2.0.0  |  License: MIT  |  Author: Heini W. Johnsen (revised)
# Exit codes: 0 ok, 1 usage, 2 privilege policy unmet, 3 runtime error

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
VERSION="2.0.0"

# ─────────────────────────────── Help ───────────────────────────────
show_help() {
  cat <<'EOF'
Usage:
  chPerms [TARGET ...] [batch-options] [--] [ -t LIST [batch-options] ] ...

Description:
  Change ownership and/or permissions on one or more TARGET paths.
  Options are **batch-scoped**: every time you start a new batch with
  positional TARGET(s) or -t/--target LIST, the options that follow apply
  only to that batch, until the next batch begins.

Batches:
  • Positional TARGET(s)   e.g.,  chPerms dirA dirB -o user -g group -p 755 -R
  • -t, --target LIST      Comma and/or space separated list, quotes allowed.
                           e.g., -t "/usr/local/bin, ~/bin /opt/tools"

Batch options:
  -R, --recursive                 Recurse (prompts unless --noconfirm).
      --noconfirm                 Do not prompt for recursive operations.
  -o, --owner USER[:GROUP]        Set owner (and optional group).
  -g, --group GROUP               Set group.
  -p, --perm MODE                 Permissions: octal (755|0755), symbolic
                                  (u=rwx,go=rx or a+rwX), or raw 9-chars
                                  (rwxr-x---), which is converted to octal.
  -c, --current-owner             Show current owner:group of each target.
  -a, --active-perms              Show current permissions (symbolic & octal).

Global options:
  --dry-run, -n                   Print intended actions only.
  --refresh, --refresh-rc         Source the caller's rc file in a subshell.
  --version                       Print version and exit.
  --help                          Show this help and exit.

Examples:
  # One batch via -t:
  sudo chPerms -t "$HOME/repos, $HOME/Documents" -R --noconfirm -o heini -g adm -p 775

  # Multiple batches in one call (each with its own options):
  sudo chPerms \
    -t "$HOME/bin"         -R --noconfirm -o heini -g adm -p rwxrwx--- \
    -t "/usr/local/bin"    -R --noconfirm -o heini -g adm -p 755

Notes:
  • Changing owner/group typically requires sudo. The script will re-exec
    itself with sudo preserving arguments if needed and allowed.
EOF
}

# ───────────────────────── Utilities ─────────────────────────
die() { printf '%s\n' "$*" >&2; exit 1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

stat_owner() { stat -c '%U' -- "$1"; }
stat_group() { stat -c '%G' -- "$1"; }
stat_perm_sym() { stat -c '%A' -- "$1"; }
stat_perm_oct() { stat -c '%a' -- "$1"; }

display_ownership() {
  printf 'Current ownership of %q:\n  Owner: %s\n  Group: %s\n' \
    "$1" "$(stat_owner "$1" 2>/dev/null || echo '?')" "$(stat_group "$1" 2>/dev/null || echo '?')"
}

display_permissions() {
  local sym oct
  sym="$(stat_perm_sym "$1" 2>/dev/null || echo '??????????')"
  oct="$(stat_perm_oct "$1" 2>/dev/null || echo '???')"
  printf 'Current permissions of %q:\n  Symbolic: %s\n  Numeric: %s\n' "$1" "$sym" "$oct"
  if [[ $sym != '??????????' ]]; then
    printf '  Detailed: u=%s, g=%s, o=%s\n' "${sym:1:3}" "${sym:4:3}" "${sym:7:3}"
  fi
}

# Convert a 3-char rwx triplet to a single octal digit (0–7)
triplet_to_digit() {
  local t=$1 d=0
  [[ $t == *r* ]] && ((d+=4))
  [[ $t == *w* ]] && ((d+=2))
  [[ $t == *x* ]] && ((d+=1))
  printf '%d' "$d"
}

# Accepts 9-char rwx form (e.g., rwxr-x---) → prints octal (e.g., 750)
nine_to_octal() {
  local s=$1
  [[ ${#s} -eq 9 && $s =~ ^[rwx-]{9}$ ]] || return 1
  printf '%d%d%d' \
    "$(triplet_to_digit "${s:0:3}")" \
    "$(triplet_to_digit "${s:3:3}")" \
    "$(triplet_to_digit "${s:6:3}")"
}

# Parse a -t/--target list (commas and/or spaces). Honors shell quotes upstream.
parse_target_list() {
  local raw=$1 chunk
  # Split on commas first, then on IFS for inner spaces
  while IFS= read -r chunk; do
    chunk="${chunk//,/ }"
    for p in $chunk; do
      [[ -n $p ]] && printf '%s\n' "$p"
    done
  done <<<"$raw"
}

confirm_recursive() {
  local prompt_allowed=$1
  $prompt_allowed || return 0
  printf '%s\n' "Recursive operation may alter many files."
  read -rp "Proceed? [y/N]: " ans
  [[ $ans == [Yy] ]] || die "Aborted by user."
}

# ───────────────────────── Data model ─────────────────────────
# We store batches in parallel arrays; each index i is a batch.
BATCH_TARGETS=()     # newline-separated list per batch
BATCH_RECURSIVE=()
BATCH_NOCONFIRM=()
BATCH_OWNER=()       # may contain "user" or "user:group" or empty
BATCH_GROUP=()       # group only
BATCH_PERM=()        # raw mode string; we normalize at apply time
BATCH_SHOW_OWNER=()  # boolean
BATCH_SHOW_PERMS=()  # boolean

new_batch() {
  BATCH_TARGETS+=("")
  BATCH_RECURSIVE+=("false")
  BATCH_NOCONFIRM+=("false")
  BATCH_OWNER+=("")
  BATCH_GROUP+=("")
  BATCH_PERM+=("")
  BATCH_SHOW_OWNER+=("false")
  BATCH_SHOW_PERMS+=("false")
}

set_batch_field() {  # idx key value
  local i=$1 key=$2 val=$3
  case $key in
    targets)       BATCH_TARGETS["$i"]=$val ;;
    recursive)     BATCH_RECURSIVE["$i"]=$val ;;
    noconfirm)     BATCH_NOCONFIRM["$i"]=$val ;;
    owner)         BATCH_OWNER["$i"]=$val ;;
    group)         BATCH_GROUP["$i"]=$val ;;
    perm)          BATCH_PERM["$i"]=$val ;;
    show_owner)    BATCH_SHOW_OWNER["$i"]=$val ;;
    show_perms)    BATCH_SHOW_PERMS["$i"]=$val ;;
  esac
}

append_targets() {  # idx value...
  local i=$1; shift
  local cur=${BATCH_TARGETS[$i]}
  local add
  for add in "$@"; do
    cur+=$'\n'"$add"
  done
  BATCH_TARGETS["$i"]="$cur"
}

# ───────────────────────── Parse args (batch-scoped) ─────────────────────────
ORIGINAL_ARGS=("$@")

DRY_RUN=false
REFRESH_RC=false

new_batch
cur=0
saw_any_target=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) show_help; exit 0 ;;
    --version) printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --refresh|--refresh-rc) REFRESH_RC=true; shift ;;

    -R|--recursive) set_batch_field "$cur" recursive true; shift ;;
    --noconfirm)    set_batch_field "$cur" noconfirm true; shift ;;

    -o|--owner)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" owner "$2"; shift 2 ;;
    -g|--group)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" group "$2"; shift 2 ;;
    -p|--perm|--perms|--permission)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1"
      set_batch_field "$cur" perm "$2"; shift 2 ;;

    -c|--current-owner) set_batch_field "$cur" show_owner true; shift ;;
    -a|--active-perms)  set_batch_field "$cur" show_perms true; shift ;;

    -t|--target)
      [[ $# -ge 2 && $2 != -* ]] || die "Missing argument for $1 (comma/space separated paths)"
      # If current batch already has targets, start a new batch
      if [[ -n ${BATCH_TARGETS[$cur]} ]]; then new_batch; ((cur++)); fi
      # Expand list into lines and append
      mapfile -t paths < <(parse_target_list "$2")
      [[ ${#paths[@]} -gt 0 ]] || die "Empty target list for $1"
      append_targets "$cur" "${paths[@]}"
      saw_any_target=true
      shift 2
      ;;
    --) shift; # everything after -- are positional targets for current/new batch
        if [[ -n ${BATCH_TARGETS[$cur]} ]]; then new_batch; ((cur++)); fi
        while [[ $# -gt 0 ]]; do
          [[ $1 == -* ]] && break
          append_targets "$cur" "$1"; saw_any_target=true; shift || true
        done
        ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)  # positional TARGET → start or continue current batch
      append_targets "$cur" "$1"; saw_any_target=true; shift ;;
  esac
done

# Remove any empty final batch
if [[ -z ${BATCH_TARGETS[$cur]} ]]; then
  # but keep if it is the only (empty) batch
  if (( ${#BATCH_TARGETS[@]} > 1 )); then
    unset 'BATCH_TARGETS[-1]' 'BATCH_RECURSIVE[-1]' 'BATCH_NOCONFIRM[-1]' \
          'BATCH_OWNER[-1]' 'BATCH_GROUP[-1]' 'BATCH_PERM[-1]' \
          'BATCH_SHOW_OWNER[-1]' 'BATCH_SHOW_PERMS[-1]'
  fi
fi

# Help if no targets at all
if ! $saw_any_target; then
  show_help
  exit 1
fi

# Determine if any batch needs sudo (owner/group changes anywhere)
needs_priv=false
for i in "${!BATCH_TARGETS[@]}"; do
  [[ -n ${BATCH_OWNER[$i]} || -n ${BATCH_GROUP[$i]} ]] && needs_priv=true
done

if $needs_priv && ! is_root; then
  # Re-exec with sudo, preserving args
  exec sudo -E -- "$0" "${ORIGINAL_ARGS[@]}"
fi

# ───────────────────────── Apply batches ─────────────────────────
apply_perm() {  # target mode recursiveFlag
  local T=$1 mode=$2 rec=$3

  # Accept NNN/NNNN; accept full chmod symbolic; convert 9-char if needed.
  local eff="$mode"
  if [[ $mode =~ ^[rwx-]{9}$ ]]; then
    if ! eff="$(nine_to_octal "$mode")"; then
      die "Invalid 9-char mode: $mode"
    fi
  fi

  if $DRY_RUN; then
    printf '[DRY RUN] chmod %s %q %q\n' "$([[ $rec == true ]] && echo -R || true)" "$eff" "$T"
  else
    chmod "$([[ $rec == true ]] && echo -R)" -- "$eff" "$T"
  fi
}

apply_owner_group() {  # target owner group recursiveFlag
  local T=$1 owner=$2 grp=$3 rec=$4
  local spec=""
  if [[ -n $owner && -n $grp ]]; then
    spec="${owner}:$grp"
  elif [[ -n $owner ]]; then
    spec="$owner"
  elif [[ -n $grp ]]; then
    spec=":$grp"
  else
    return 0
  fi
  if $DRY_RUN; then
    printf '[DRY RUN] chown %s %q %q\n' "$([[ $rec == true ]] && echo -R || true)" "$spec" "$T"
  else
    chown "$([[ $rec == true ]] && echo -R)" -- "$spec" "$T"
  fi
}

for i in "${!BATCH_TARGETS[@]}"; do
  # Resolve batch flags/values
  rec="${BATCH_RECURSIVE[$i]}"
  noconf="${BATCH_NOCONFIRM[$i]}"
  show_o="${BATCH_SHOW_OWNER[$i]}"
  show_p="${BATCH_SHOW_PERMS[$i]}"
  own="${BATCH_OWNER[$i]}"
  grp="${BATCH_GROUP[$i]}"
  prm="${BATCH_PERM[$i]}"

  # Materialize target list
  mapfile -t targets <<<"${BATCH_TARGETS[$i]}"
  # Filter empties & expand ~
  cleaned=()
  for T in "${targets[@]}"; do
    [[ -z $T ]] && continue
    cleaned+=( "$(readlink -f -- "$T" 2>/dev/null || echo "$T")" )
  done
  targets=("${cleaned[@]}")

  # Recursion confirmation (once per batch)
  if [[ $rec == true && $noconf != true ]]; then
    confirm_recursive true
  fi

  for T in "${targets[@]}"; do
    if [[ ! -e $T ]]; then
      printf 'Warning: target %q does not exist. Skipping.\n' "$T" >&2
      continue
    fi

    printf '=== Processing target: %q ===\n' "$T"

    # Show before?
    [[ $show_o == true ]] && display_ownership "$T"
    [[ $show_p == true ]] && display_permissions "$T"

    # Owner/group
    if [[ -n $own || -n $grp ]]; then
      [[ $own == "activeuser" ]] && own="$(id -un)"
      apply_owner_group "$T" "$own" "$grp" "$rec"
      display_ownership "$T"
    fi

    # Permissions
    if [[ -n $prm ]]; then
      apply_perm "$T" "$prm" "$rec"
      display_permissions "$T"
    fi

    echo
  done
done

# ───────────────────────── Optional: refresh RC ─────────────────────────
if $REFRESH_RC; then
  # Source caller's rc in subshell; informative only.
  who="${SUDO_USER:-$USER}"
  home="$(eval echo "~$who")"
  shell_base="$(basename "${SHELL:-/bin/bash}")"
  rc="$home/.bashrc"
  [[ $shell_base == "zsh" ]] && rc="$home/.zshrc"
  if [[ -f $rc ]]; then
    echo "Sourcing $rc in a subshell (informational; won’t alter current shell)."
    # shellcheck disable=SC1090
    ( source "$rc" ) >/dev/null 2>&1 || true
  else
    echo "No rc file at $rc; skipping."
  fi
fi

exit 0
