#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# replace-fixed
#
# Fixed-string replacement across selected files and directories.
#
# Default mode is dry-run. Use --apply to modify files.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
replace-fixed

Fixed-string replacement across selected files and directories.

Usage:
  replace-fixed --from OLD --to NEW [options] FILE_OR_DIR [...]

Required:
  -f, --from TEXT       Fixed string to search for.
  -t, --to TEXT         Replacement string.

Selection:
  -r, --recursive       Recurse into directories.
      --include GLOB    Only include paths or basenames matching GLOB.
      --exclude GLOB    Exclude paths or basenames matching GLOB.

Action:
      --dry-run         Preview only. This is the default.
      --apply           Modify files.
  -i, --interactive     Ask before modifying each matching file.
  -b, --backup EXT      Create backup copies, e.g. --backup .bak.

Examples:
  replace-fixed -f '/home/heini' -t '$HOME' --dry-run ~/repos

  replace-fixed -f '/home/heini' -t '$HOME' -r --apply ~/repos

  replace-fixed -f '/home/heini' -t '$HOME' --apply file1.sh file2.zsh

  replace-fixed -f '/home/heini' -t '$HOME' -r \
    --include '*.sh' --include '*.zsh' --apply ~/repos

  replace-fixed -f '/home/heini' -t '$HOME' -r \
    --exclude '.git/*' --dry-run ~/repos
EOF
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function need_value() {
  local option="$1"
  local value="${2-}"

  [[ -n "$value" ]] || die "$option requires an argument"
}

function path_matches_any_glob() {
  local path="$1"
  shift

  local pattern
  for pattern in "$@"; do
    if [[ "$path" == $pattern || "${path##*/}" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

function path_is_selected() {
  local path="$1"

  if ((${#INCLUDE_GLOBS[@]} > 0)); then
    path_matches_any_glob "$path" "${INCLUDE_GLOBS[@]}" || return 1
  fi

  if ((${#EXCLUDE_GLOBS[@]} > 0)); then
    path_matches_any_glob "$path" "${EXCLUDE_GLOBS[@]}" && return 1
  fi

  return 0
}

function add_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0
  [[ -n "${SEEN_FILES[$file]+x}" ]] && return 0

  SEEN_FILES["$file"]=1
  FILES+=("$file")
}

function collect_files_from_target() {
  local target="$1"
  local file

  if [[ -f "$target" ]]; then
    add_file "$target"
    return 0
  fi

  if [[ ! -d "$target" ]]; then
    printf 'warning: skipping missing target: %s\n' "$target" >&2
    return 0
  fi

  if ((RECURSIVE)); then
    while IFS= read -r -d '' file; do
      add_file "$file"
    done < <(find "$target" -type f -print0)
  else
    while IFS= read -r -d '' file; do
      add_file "$file"
    done < <(find "$target" -maxdepth 1 -type f -print0)
  fi
}

function file_has_match() {
  local file="$1"

  LC_ALL=C grep -IqF -- "$FROM_TEXT" "$file"
}

function show_matches() {
  local file="$1"

  printf '\n==> %s\n' "$file"
  LC_ALL=C grep -nIF -- "$FROM_TEXT" "$file" || true
}

function confirm_file() {
  local file="$1"
  local reply

  printf 'Replace in this file? [y/N] '
  read -r reply

  case "${reply,,}" in
    y|yes)
      return 0
      ;;
    *)
      printf 'skipped: %s\n' "$file"
      return 1
      ;;
  esac
}

function replace_file() {
  local file="$1"
  local dir
  local base
  local tmp

  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  tmp="$(mktemp --tmpdir="$dir" ".${base}.replace.XXXXXX")"

  if [[ -n "$BACKUP_EXT" ]]; then
    cp -a -- "$file" "${file}${BACKUP_EXT}"
  fi

  if ! FROM_TEXT="$FROM_TEXT" TO_TEXT="$TO_TEXT" perl -0pe '
    BEGIN {
      $from = $ENV{"FROM_TEXT"};
      $to   = $ENV{"TO_TEXT"};
    }

    s/\Q$from\E/$to/g;
  ' -- "$file" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file"
}

FROM_TEXT=''
TO_TEXT=''
RECURSIVE=0
DRY_RUN=1
INTERACTIVE=0
BACKUP_EXT=''

declare -a TARGETS=()
declare -a FILES=()
declare -a INCLUDE_GLOBS=()
declare -a EXCLUDE_GLOBS=()
declare -A SEEN_FILES=()

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;

    -f|--from)
      need_value "$1" "${2-}"
      FROM_TEXT="$2"
      shift 2
      ;;

    -t|--to)
      need_value "$1" "${2-}"
      TO_TEXT="$2"
      shift 2
      ;;

    -r|--recursive)
      RECURSIVE=1
      shift
      ;;

    --include)
      need_value "$1" "${2-}"
      INCLUDE_GLOBS+=("$2")
      shift 2
      ;;

    --exclude)
      need_value "$1" "${2-}"
      EXCLUDE_GLOBS+=("$2")
      shift 2
      ;;

    --dry-run)
      DRY_RUN=1
      shift
      ;;

    --apply)
      DRY_RUN=0
      shift
      ;;

    -i|--interactive)
      INTERACTIVE=1
      shift
      ;;

    -b|--backup)
      need_value "$1" "${2-}"
      BACKUP_EXT="$2"
      shift 2
      ;;

    --)
      shift
      TARGETS+=("$@")
      break
      ;;

    -*)
      die "unknown option: $1"
      ;;

    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

[[ -n "$FROM_TEXT" ]] || die 'missing --from TEXT'
[[ -n "$TO_TEXT" ]] || die 'missing --to TEXT'
[[ "$FROM_TEXT" != "$TO_TEXT" ]] || die '--from and --to are identical'

if ((${#TARGETS[@]} == 0)); then
  TARGETS=(".")
fi

command -v perl >/dev/null 2>&1 || die 'missing dependency: perl'
command -v grep >/dev/null 2>&1 || die 'missing dependency: grep'
command -v find >/dev/null 2>&1 || die 'missing dependency: find'

for target in "${TARGETS[@]}"; do
  collect_files_from_target "$target"
done

matched=0
changed=0

for file in "${FILES[@]}"; do
  path_is_selected "$file" || continue
  file_has_match "$file" || continue

  ((matched += 1))
  show_matches "$file"

  if ((DRY_RUN)); then
    continue
  fi

  if ((INTERACTIVE)); then
    confirm_file "$file" || continue
  fi

  replace_file "$file"
  ((changed += 1))
done

printf '\nmatched files: %d\n' "$matched"

if ((DRY_RUN)); then
  printf 'changed files: 0 -- dry-run only\n'
else
  printf 'changed files: %d\n' "$changed"
fi
