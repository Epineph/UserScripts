#!/usr/bin/env bash
###############################################################################
#  git-ic ( “git-interactive-commit” )
#
#  A lightweight TUI for the most common Git workflow:
#    ▸ interactively stage     (git add)
#    ▸ write / re-use message  (git commit)
#    ▸ push to remote          (git push)
#
#  It combines:
#    - git-delta : colourful, side-by-side diffs in previews
#    - bat       : syntax-highlighted file previews & log messages
#    - fzf       : fuzzy, multi-select pickers with custom key-binds
#    - rg        : fast search inside the repo / staged changes
#    - fd        : locating untracked files to add
#
#  Author:  <your-name>
#  Version: 0.1.0
###############################################################################
set -euo pipefail

###############################################################################
# Configuration ───────────────────────────────────────────────────────────────
###############################################################################
: "${GIT_PAGER:=delta}"          # fall back to delta if user hasn’t configured one
: "${EDITOR:=vim}"
FZF_DEF_OPTS=(
  --height=95%
  --border=rounded
  --layout=reverse
  --prompt="❯ "
  --cycle
)
DIFF_CMD="git --no-pager diff --color=always --"  # coloured diff for previews

###############################################################################
# Usage & help ────────────────────────────────────────────────────────────────
###############################################################################
usage() {
  cat <<'USAGE' | bat --language=help --paging=never --style=plain
git-ic  –  tiny fuzzy TUI for Git

USAGE:
  git-ic [options]

OPTIONS:
  -h, --help          Show this help and exit.
  -m, --message TEXT  Bypass editor; commit with given message.
  -n, --no-push       Do NOT push after committing.
  --branch NAME       Create/switch to branch NAME before staging.
  --dry-run           Parse everything but perform no git changes.

KEY BINDINGS (inside the pickers):
  <TAB>         add/remove file from selection
  <Ctrl-D>      view entire diff of repo in δ-pager
  <Ctrl-R>      ripgrep the work-tree (opens second fzf)
  <Ctrl-L>      view recent commit messages to re-use
USAGE
}

###############################################################################
# Dependency checks ───────────────────────────────────────────────────────────
###############################################################################
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

for bin in git fzf delta bat rg fd; do need "$bin"; done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "git-ic must be run inside a Git repository."; exit 1; }

###############################################################################
# Helper functions ────────────────────────────────────────────────────────────
###############################################################################

# full-screen delta diff of entire repo
show_repo_diff() {
  git --no-pager diff --stat && git --no-pager diff | delta
  printf "\n[Press any key to return] "; read -n 1
}

# ripgrep picker – fuzzy search in code, open match in $EDITOR
do_ripgrep() {
  local sel
  sel=$(rg --line-number --column --color=always "" \
        | fzf "${FZF_DEF_OPTS[@]}" \
              --ansi --delimiter : --nth 1,2,3.. \
              --preview 'bat --style=numbers --color=always --highlight-line {2} {1} | sed -n "{2},+100p"' \
              --preview-window=right:60%:wrap)
  [[ -n $sel ]] || return 0
  local file line
  file=$(cut -d':' -f1 <<<"$sel")
  line=$(cut -d':' -f2 <<<"$sel")
  "$EDITOR" +"$line" "$file"
}

# recent messages picker
pick_recent_msg() {
  git --no-pager log -n 20 --pretty=format:%s \
    | bat --plain --style=plain --paging=never --language=log \
    | fzf "${FZF_DEF_OPTS[@]}" --prompt="Reuse commit msg ❯ " --tac
}

###############################################################################
# Argument parsing ────────────────────────────────────────────────────────────
###############################################################################
MSG=''  NO_PUSH=false  NEW_BRANCH=''  DRY=false
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

###############################################################################
# Optional branch handling ────────────────────────────────────────────────────
###############################################################################
if [[ -n $NEW_BRANCH ]]; then
  echo "↳ Switching to branch '$NEW_BRANCH'…"
  [[ $DRY == true ]] || git switch -c "$NEW_BRANCH" 2>/dev/null || git switch "$NEW_BRANCH"
fi

###############################################################################
# Collect candidate paths ─────────────────────────────────────────────────────
###############################################################################
#   M  modified,  A  added,  ?? untracked
mapfile -t CHANGED < <(git status --porcelain=v1 \
                        | awk '{print $2}' )

# include *ignored* untracked via fd (e.g. new file in .gitignore override)
mapfile -t UNTRACKED < <(fd --type f --no-ignore --exclude .git \
                      | git check-ignore --stdin -v -n --quiet || true)
CANDIDATES=("${CHANGED[@]}" "${UNTRACKED[@]}")

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "Nothing to stage. Exiting."
  exit 0
fi

###############################################################################
# Interactive staging with fzf ────────────────────────────────────────────────
###############################################################################
SEL=$(printf '%s\n' "${CANDIDATES[@]}" \
  | fzf "${FZF_DEF_OPTS[@]}" \
        --multi --ansi \
        --header="Select files to stage (<TAB> to mark, <Ctrl-D> repo diff, <Ctrl-R> rg…)" \
        --bind "ctrl-d:execute:show_repo_diff+reload(echo {})" \
        --bind "ctrl-r:execute:do_ripgrep+reload(echo {})" \
        --preview="$DIFF_CMD {+}" \
        --preview-window=right:60%:wrap)

[[ -n $SEL ]] || { echo "No files selected. Aborting."; exit 1; }

###############################################################################
# Stage the selection ─────────────────────────────────────────────────────────
###############################################################################
echo "↳ Staging…"
while IFS= read -r file; do
  echo "  + $file"
  [[ $DRY == true ]] || git add -- "$file"
done <<<"$SEL"

###############################################################################
# Compose commit message ──────────────────────────────────────────────────────
###############################################################################
if git diff --cached --quiet; then
  echo "No staged changes. Exiting."
  exit 0
fi

if [[ -z $MSG ]]; then
  # Offer reuse via Ctrl-L
  MSG=$(fzf --prompt="Commit msg ❯ " --print-query \
        --bind "ctrl-l:replace-query(pick_recent_msg)" \
        <<<"")
  MSG=${MSG#*$'\n'}           # keep the query line only
fi

if [[ -z $MSG ]]; then
  # Fallback to editor
  TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
  [[ $DRY == true ]] || { git --no-pager diff --cached | delta >"$TMP.diff"; }
  { echo "# Write commit message above. Lines starting with # are ignored."
    echo "# Preview of staged diff:"
    cat "$TMP.diff"
  } >"$TMP"
  "$EDITOR" "$TMP"
  MSG=$(grep -v '^\s*#' "$TMP" | sed '/^\s*$/d')
fi

[[ -n $MSG ]] || { echo "Empty message. Aborting."; exit 1; }

echo "↳ Committing…"
if [[ $DRY == true ]]; then
  echo "[dry-run] git commit -m \"$MSG\""
else
  git commit -m "$MSG"
fi

###############################################################################
# Push (unless suppressed) ────────────────────────────────────────────────────
###############################################################################
if [[ $NO_PUSH == false ]]; then
  CUR_BRANCH=$(git symbolic-ref --short HEAD)
  echo "↳ Pushing → origin/$CUR_BRANCH"
  [[ $DRY == true ]] || git push -u origin "$CUR_BRANCH"
fi

echo "✔ Done."
###############################################################################
# End of git-ic
###############################################################################

