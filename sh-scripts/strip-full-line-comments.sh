#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# strip-full-line-comments.sh
#
# Remove full-line comments from a target file (or directory tree), without
# modifying the original(s). Writes:
#   (1) a "cleaned" copy (comment-only lines removed)
#   (2) a companion file containing only the removed comment-only lines
#
# A "comment-only line" is a line whose first non-whitespace character is '#':
#   ^[[:space:]]*#
#
# NOTE:
#   - Inline comments are NOT removed:  echo hi  # stays
#   - With --keep-shebang, lines starting "#!" are kept in cleaned output.
#
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

OUT_ROOT="/shared/modified_zshrc"
COMMENT_SUFFIX="-commented"
KEEP_SHEBANG=0
DRY_RUN=0
QUIET=0
FOLLOW_SYMLINKS=0
GROUP_OVERRIDE=""
PATTERNS=("*")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function die() {
  local msg="${1:-Unknown error}"
  printf 'ERROR: %s\n' "$msg" >&2
  exit 1
}

function require_cmd() {
  local cmd=""
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

function expand_tilde() {
  local p="${1:-}"
  if [[ "$p" == "~" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  if [[ "$p" == "~/"* ]]; then
    printf '%s\n' "${HOME}/${p:2}"
    return 0
  fi
  printf '%s\n' "$p"
}

function sanitize_group() {
  local s="${1:-}"
  s="${s#.}"           # .zshrc -> zshrc
  s="${s%.*}"          # zsh_misc.zsh -> zsh_misc
  s="${s//[^A-Za-z0-9_-]/_}"
  [[ -n "$s" ]] || s="group"
  printf '%s\n' "$s"
}

function choose_pager_cmd() {
  if [[ -n "${HELP_PAGER:-}" ]]; then
    printf '%s\n' "${HELP_PAGER}"
    return 0
  fi
  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "less -R"
  else
    printf '%s\n' "cat"
  fi
}

function show_help() {
  local pager=""
  pager="$(choose_pager_cmd)"
  cat <<'EOF' | /usr/bin/env bash -c "$pager"
strip-full-line-comments.sh

NAME
  strip-full-line-comments.sh — Split full-line comment rows out of file(s)

SYNOPSIS
  strip-full-line-comments.sh [OPTIONS] <PATH>

DESCRIPTION
  This script removes (only) full-line comments from a file, or from a directory
  tree of files, and writes results into a structured output directory. The
  original file(s) are never modified.

  The script produces two outputs per processed file:
    1) CLEANED FILE
       The original content with full-line comment rows removed.

    2) COMMENTS-ONLY FILE
       A file containing exactly the removed full-line comment rows, in order.

  What counts as a "full-line comment row"?
    Any line whose first non-whitespace character is '#':
      ^[[:space:]]*#

  Important behavior:
    - Inline comments are NOT removed:
        echo hi  # this stays in the cleaned file
    - Blank lines are NOT removed.
    - A shebang line (#!...) matches the comment rule; use --keep-shebang to
      preserve it in cleaned output.

PATH MODES
  If PATH is a file:
    Process that single file.

  If PATH is a directory:
    Recursively find files and process matching ones (see --pattern). Output
    preserves the relative directory structure under PATH.

OUTPUT LAYOUT
  Output is grouped by a "group name" and a per-run timestamp:

    OUT_ROOT/<group>/<run_id>/<...>

  Where:
    OUT_ROOT  default: /shared/modified_zshrc
    group     derived from basename of PATH (sanitized), or overridden by --group
    run_id    date stamp: YYYYMMDD-HHMMSS

  Single file example:
    Input:
      ~/.zshrc

    Output:
      /shared/modified_zshrc/zshrc/20260102-214501/.zshrc
      /shared/modified_zshrc/zshrc/20260102-214501/.zshrc-commented

  Directory example:
    Input:
      ~/.zsh_profile

    Output (example file):
      /shared/modified_zshrc/zsh_profile/20260102-214501/zsh_misc.zsh
      /shared/modified_zshrc/zsh_profile/20260102-214501/zsh_misc.zsh-commented

  Companion files:
    The "comments-only" file path is the cleaned output file path plus the
    configured suffix (default: -commented).

MANIFEST AND SUMMARY
  Each run writes two metadata files (unless --dry-run):
    __manifest.tsv
      Tab-separated rows:
        source_path    cleaned_path    comments_path    kept_lines    removed_lines

    __summary.txt
      A simple key/value summary of the run configuration.

OPTIONS
  -o, --out-root DIR
      Root output directory.
      Default: /shared/modified_zshrc

  --comment-suffix SUFFIX
      Suffix appended to the cleaned-file path to form the comments-only path.
      Default: -commented

  --group NAME
      Override the group directory name.
      Useful when you want a stable group regardless of PATH basename.

  --keep-shebang
      Preserve a leading shebang (#!...) in cleaned output.
      Without this, shebang lines are treated as comment-only and moved to the
      comments-only file.

  --pattern GLOB
      When PATH is a directory, only process files whose *basename* matches the
      glob. May be provided multiple times.

      Examples:
        --pattern '*.zsh'
        --pattern '.zshrc'
        --pattern '*.sh' --pattern '*.zsh'

      Default: '*' (process all files)

  --all
      Equivalent to: --pattern '*'

  --follow-symlinks
      When PATH is a directory, follow symlinks during traversal (find -L).

  -n, --dry-run
      Print what would be done; do not write output files.

  -q, --quiet
      Reduce output (still writes files and manifests).

  -h, --help
      Show this help.

ENVIRONMENT
  HELP_PAGER
    Pager command used to display --help output.
    Default: "less -R" if available, else "cat".

EXIT STATUS
  0  Success
  2  Usage error (bad args)
  1  Other error (missing command, IO error, etc.)

EXAMPLES
  1) Process a single file, default output root:
     strip-full-line-comments.sh ~/.zshrc

  2) Keep shebang in cleaned file:
     strip-full-line-comments.sh --keep-shebang ~/.zshrc

  3) Use a custom output root and suffix:
     strip-full-line-comments.sh \
       --out-root /shared/modified_zsh \
       --comment-suffix '.comments' \
       ~/.zshrc

  4) Process a directory, only *.zsh files:
     strip-full-line-comments.sh --pattern '*.zsh' ~/.zsh_profile

  5) Process multiple patterns:
     strip-full-line-comments.sh \
       --pattern '.zshrc' \
       --pattern '*.zsh' \
       ~/.config/zsh

NOTES / LIMITATIONS (BY DESIGN)
  - This script does not parse shell syntax; it matches lines by a simple regex.
  - It does not remove inline comments.
  - It does not attempt to preserve or normalize line endings; it writes output
    as text via awk (normally LF). If you have CRLF inputs and need to preserve
    CRLF, add a conversion pass or run in a Windows-aware pipeline.

EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  local arg=""
  local -a positionals=()

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -h|--help)
        show_help
        exit 0
        ;;
      -o|--out-root)
        [[ $# -ge 2 ]] || die "Missing value for $arg"
        OUT_ROOT="$2"
        shift 2
        ;;
      --comment-suffix)
        [[ $# -ge 2 ]] || die "Missing value for $arg"
        COMMENT_SUFFIX="$2"
        shift 2
        ;;
      --group)
        [[ $# -ge 2 ]] || die "Missing value for $arg"
        GROUP_OVERRIDE="$2"
        shift 2
        ;;
      --keep-shebang)
        KEEP_SHEBANG=1
        shift
        ;;
      --pattern)
        [[ $# -ge 2 ]] || die "Missing value for $arg"
        if [[ "${PATTERNS[*]}" == "*" ]]; then
          PATTERNS=()
        fi
        PATTERNS+=("$2")
        shift 2
        ;;
      --all)
        PATTERNS=("*")
        shift
        ;;
      --follow-symlinks)
        FOLLOW_SYMLINKS=1
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          positionals+=("$1")
          shift
        done
        ;;
      -*)
        die "Unknown option: $arg"
        ;;
      *)
        positionals+=("$arg")
        shift
        ;;
    esac
  done

  if [[ ${#positionals[@]} -ne 1 ]]; then
    show_help >&2
    exit 2
  fi

  printf '%s\n' "${positionals[0]}"
}

# -----------------------------------------------------------------------------
# Core processing
# -----------------------------------------------------------------------------

function awk_split_comments() {
  local in_file="$1"
  local out_clean="$2"
  local out_comment="$3"
  local keep_shebang="$4"

  : >"$out_clean"
  : >"$out_comment"

  awk -v out_clean="$out_clean" \
      -v out_comment="$out_comment" \
      -v keep_shebang="$keep_shebang" \
      '
      BEGIN { kept = 0; dropped = 0 }
      {
        line = $0
        if (keep_shebang == 1 && line ~ /^#!/) {
          print line >> out_clean
          kept++
          next
        }
        if (line ~ /^[[:space:]]*#/) {
          print line >> out_comment
          dropped++
        } else {
          print line >> out_clean
          kept++
        }
      }
      END { printf "%d\t%d\n", kept, dropped }
      ' "$in_file"
}

function process_one_file() {
  local src_abs="$1"
  local out_base="$2"
  local rel_path="$3"
  local manifest="$4"

  local out_clean="${out_base}/${rel_path}"
  local out_comment="${out_clean}${COMMENT_SUFFIX}"
  local out_dir=""
  out_dir="$(dirname -- "$out_clean")"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s -> %s\n' "$src_abs" "$out_clean"
    printf 'DRY-RUN: comments -> %s\n' "$out_comment"
    return 0
  fi

  mkdir -p -- "$out_dir"

  local mode=""
  mode="$(stat -c '%a' -- "$src_abs" 2>/dev/null || true)"

  local counts=""
  local kept="0"
  local dropped="0"

  counts="$(awk_split_comments "$src_abs" "$out_clean" "$out_comment" \
    "$KEEP_SHEBANG")"
  kept="${counts%%$'\t'*}"
  dropped="${counts##*$'\t'}"

  if [[ -n "$mode" ]]; then
    chmod -- "$mode" "$out_clean" "$out_comment" 2>/dev/null || true
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$src_abs" "$out_clean" "$out_comment" "$kept" "$dropped" >>"$manifest"

  if [[ $QUIET -eq 0 ]]; then
    printf 'WROTE: %s (kept=%s, removed=%s)\n' "$out_clean" "$kept" "$dropped"
  fi
}

function main() {
  require_cmd awk date find mkdir stat chmod realpath

  local target=""
  target="$(parse_args "$@")"
  target="$(expand_tilde "$target")"

  local target_abs=""
  target_abs="$(realpath -m -- "$target")"
  [[ -e "$target_abs" ]] || die "Path does not exist: $target_abs"

  local run_id=""
  run_id="$(date +%Y%m%d-%H%M%S)"

  local group=""
  if [[ -n "$GROUP_OVERRIDE" ]]; then
    group="$(sanitize_group "$GROUP_OVERRIDE")"
  else
    group="$(sanitize_group "$(basename -- "$target_abs")")"
  fi

  local out_base="${OUT_ROOT}/${group}/${run_id}"
  local manifest="${out_base}/__manifest.tsv"
  local summary="${out_base}/__summary.txt"

  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p -- "$out_base"
    : >"$manifest"
  fi

  if [[ -f "$target_abs" ]]; then
    if [[ $QUIET -eq 0 ]]; then
      printf 'TARGET: %s\n' "$target_abs"
      printf 'OUT:    %s\n' "$out_base"
    fi
    process_one_file "$target_abs" "$out_base" "$(basename -- "$target_abs")" \
      "$manifest"
  elif [[ -d "$target_abs" ]]; then
    if [[ $QUIET -eq 0 ]]; then
      printf 'TARGET DIR: %s\n' "$target_abs"
      printf 'OUT:        %s\n' "$out_base"
      printf 'PATTERNS:   %s\n' "${PATTERNS[*]}"
    fi

    local -a find_cmd=()
    if [[ $FOLLOW_SYMLINKS -eq 1 ]]; then
      find_cmd=(find -L "$target_abs" -type f)
    else
      find_cmd=(find "$target_abs" -type f)
    fi

    if [[ ${#PATTERNS[@]} -gt 0 && "${PATTERNS[0]}" != "*" ]]; then
      find_cmd+=( \( )
      local i=0
      for i in "${!PATTERNS[@]}"; do
        [[ $i -gt 0 ]] && find_cmd+=(-o)
        find_cmd+=(-name "${PATTERNS[$i]}")
      done
      find_cmd+=( \) )
    fi
    find_cmd+=(-print0)

    local f=""
    while IFS= read -r -d '' f; do
      local f_abs=""
      f_abs="$(realpath -m -- "$f")"

      local rel=""
      rel="$(realpath --relative-to="$target_abs" -- "$f_abs")"

      process_one_file "$f_abs" "$out_base" "$rel" "$manifest"
    done < <("${find_cmd[@]}")
  else
    die "Unsupported path type: $target_abs"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  {
    printf 'run_id\t%s\n' "$run_id"
    printf 'group\t%s\n' "$group"
    printf 'target\t%s\n' "$target_abs"
    printf 'out_base\t%s\n' "$out_base"
    printf 'comment_suffix\t%s\n' "$COMMENT_SUFFIX"
    printf 'keep_shebang\t%s\n' "$KEEP_SHEBANG"
    printf 'follow_symlinks\t%s\n' "$FOLLOW_SYMLINKS"
    printf 'patterns\t%s\n' "${PATTERNS[*]}"
    printf 'manifest\t%s\n' "$manifest"
  } >"$summary"

  if [[ $QUIET -eq 0 ]]; then
    printf 'MANIFEST: %s\n' "$manifest"
    printf 'SUMMARY:  %s\n' "$summary"
  fi
}

main "$@"

