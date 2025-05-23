#!/usr/bin/env bash
###############################################################################
#  git-ic  —  git-interactive-commit  (v0.1.1)
#
#  Interactively stage ▸ commit ▸ push with a tiny, fzf-powered TUI.
#
#  Uses: git-delta • bat • fzf • rg • fd       (all checked below)
###############################################################################
set -euo pipefail

###############################################################################
# Config
###############################################################################
: "${GIT_PAGER:=delta}"
: "${EDITOR:=vim}"
FZF_DEF_OPTS=( --height=95% --border=rounded --layout=reverse --prompt='❯ ' --cycle )
DIFF_CMD='git --no-pager diff --color=always --'

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<'USAGE' | bat --language=help --style=plain --paging=never
git-ic  –  tiny fuzzy TUI for Git

USAGE
  git-ic  [options]

OPTIONS
  -h, --help            Show this help and exit.
  -m, --message TEXT    Commit message (skip editor/picker).
  -n, --no-push         Do not push after committing.
  --branch NAME         Create / switch to branch NAME first.
  --dry-run             Parse everything but make no Git changes.

INSIDE THE PICKERS
  <TAB>        mark/unmark file           •  <Ctrl-D>  full repo diff in delta
  <Ctrl-R>     ripgrep code search        •  <Esc>     abort
USAGE
}

###############################################################################
# Dependency checks
###############################################################################
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
for bin in git fzf delta bat rg fd; do need "$bin"; done
git rev-parse --is-inside-work-tree >/dev/null || {
  echo "git-ic: run inside a Git repository"; exit 1; }

###############################################################################
# Helpers
###############################################################################
show_repo_diff() { git --no-pager diff --stat && git --no-pager diff | delta; read -n1 -s; }

ripgrep_picker() {
  local hit
  hit=$(rg --line-number --column --color=always '' \
        | fzf "${FZF_DEF_OPTS[@]}" --ansi --delimiter : --nth 1,2,3.. \
               --preview 'bat --style=numbers --color=always --highlight-line {2} {1}' \
               --preview-window=right:60%:wrap) || return
  local file line; file=${hit%%:*}; line=${hit#*:}; line=${line%%:*}
  "$EDITOR" +"$line" "$file"
}

recent_commit_msg() {
  git --no-pager log -n 20 --pretty=format:%s \
    | fzf "${FZF_DEF_OPTS[@]}" --prompt='Pick old msg ❯ ' || true
}

###############################################################################
# Argument parsing
###############################################################################
MSG='' NO_PUSH=false NEW_BRANCH='' DRY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -m|--message) MSG=$2; shift 2 ;;
    -n|--no-push) NO_PUSH=true; shift ;;
    --branch) NEW_BRANCH=$2; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    *) echo "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

if [[ -n $NEW_BRANCH ]]; then
  echo "↳ switching to branch '$NEW_BRANCH'…"
  [[ $DRY == true ]] || git switch -c "$NEW_BRANCH" 2>/dev/null || git switch "$NEW_BRANCH"
fi

###############################################################################
# Collect candidate files
###############################################################################
mapfile -t CANDIDATES < <(git status --porcelain=v1 | sed 's/^...//')
(( ${#CANDIDATES[@]} )) || { echo "Nothing to stage."; exit 0; }

###############################################################################
# Interactive staging
###############################################################################
SEL=$(printf '%s\n' "${CANDIDATES[@]}" \
  | fzf "${FZF_DEF_OPTS[@]}" --multi --ansi \
        --header='Select files to stage (<TAB> mark, Ctrl-D diff, Ctrl-R rg)' \
        --bind 'ctrl-d:execute:show_repo_diff+refresh-preview' \
        --bind 'ctrl-r:execute:ripgrep_picker+refresh-preview' \
        --preview="$DIFF_CMD {+}" \
        --preview-window=right:60%:wrap) || { echo "Aborted."; exit 1; }

echo "↳ staging…"
while IFS= read -r f; do
  [[ -z $f ]] || { echo "  + $f"; [[ $DRY == true ]] || git add -- "$f"; }
done <<<"$SEL"

git diff --cached --quiet && { echo "No staged changes. Exiting."; exit 0; }

###############################################################################
# Commit message
###############################################################################
if [[ -z $MSG ]]; then
  echo
  read -rp "Commit message (empty = picker/editor)? " MSG
  if [[ -z $MSG ]]; then
    MSG=$(recent_commit_msg)
  fi
fi

if [[ -z $MSG ]]; then
  TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP.diff"' EXIT
  git --no-pager diff --cached | delta >"$TMP.diff"
  {
    echo "# Write commit message above. Lines beginning with # are ignored."
    echo "# ---------------- STAGED DIFF -----------------"
    cat "$TMP.diff"
  } >"$TMP"
  "$EDITOR" "$TMP"
  MSG=$(grep -v '^\s*#' "$TMP" | sed '/^\s*$/d')
fi

[[ -n $MSG ]] || { echo "Empty message. Aborting."; exit 1; }

echo "↳ committing…"
[[ $DRY == true ]] && echo "[dry-run] git commit -m \"$MSG\"" || git commit -m "$MSG"

###############################################################################
# Push
###############################################################################
if [[ $NO_PUSH == false ]]; then
  CUR=$(git symbolic-ref --short HEAD)
  echo "↳ pushing → origin/$CUR"
  [[ $DRY == true ]] || git push -u origin "$CUR"
fi

echo "✔ Done."

