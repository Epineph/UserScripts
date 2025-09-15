#!/usr/bin/env bash
# git-remote-filetimes
#
# Show per-file timestamps from BOTH the local filesystem and the REMOTE branch
# (e.g., origin/main). Useful when you want the “time GitHub shows” (remote
# commit time) next to your local times or for export to PDF via bat/batwrap.
#
# Dependencies: git (required); GNU coreutils (date/stat on Linux).
#
# USAGE:
#   git-remote-filetimes [options] [PATH...]
#
# OPTIONS:
#   -r, --remote NAME      Remote to inspect (default: origin)
#   -b, --branch BRANCH    Remote branch (default: remote HEAD, e.g. origin/main)
#       --author-date      Use author date instead of committer date for Git times
#       --committer-date   Use committer date (default)
#       --fetch            Run 'git fetch --prune <remote>' first
#       --format FMT       table | tsv | csv   (default: table)
#       --tracked-only     Only list files tracked in Git (default)
#       --all              Include untracked regular files under PATH (slower)
#       --only-diff        Only show files that differ from remote branch
#   -h, --help             Show help and exit
#
# EXAMPLES:
#   # Plain table for all tracked files on origin/HEAD:
#   git-remote-filetimes
#
#   # Ensure we’re up to date, then use origin/main explicitly and TSV:
#   git-remote-filetimes --fetch -r origin -b main --format tsv
#
#   # Limit to subdir and export nicely with bat/batwrap:
#   git-remote-filetimes --format table ./convenient_scripts \
#     | bat --paging=never --style="grid,header,snip"
#
#   # Join with an eza listing by filename (advanced; both sorted by path):
#   # eza -l --no-user --no-permissions --no-filesize --time-style=long-iso \
#   #   | awk '{print $NF"\t"$0}' | sort -k1,1 \
#   #   | join -t $'\t' -1 1 -2 1 \
#   #       <(git-remote-filetimes --format tsv | sort -k1,1) - \
#   #   | cut -f2-
set -euo pipefail

print_help() { sed -n '1,80p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- defaults ----
REMOTE="origin"
BRANCH=""            # will resolve from origin/HEAD
USE_FIELD="%cd"      # committer date by default
FORMAT="table"
LIST_MODE="tracked"  # or all
ONLY_DIFF=0
DO_FETCH=0

# ---- parse args ----
ARGS=()
while (($#)); do
  case "$1" in
    -r|--remote)       REMOTE="${2:?}"; shift 2 ;;
    -b|--branch)       BRANCH="${2:?}"; shift 2 ;;
       --author-date)  USE_FIELD="%ad"; shift ;;
       --committer-date) USE_FIELD="%cd"; shift ;;
       --fetch)        DO_FETCH=1; shift ;;
       --format)       FORMAT="${2:?}"; shift 2 ;;
       --tracked-only) LIST_MODE="tracked"; shift ;;
       --all)          LIST_MODE="all"; shift ;;
       --only-diff)    ONLY_DIFF=1; shift ;;
    -h|--help)         print_help; exit 0 ;;
    --)                shift; break ;;
    -*)                echo "Unknown option: $1" >&2; exit 2 ;;
    *)                 ARGS+=("$1"); shift ;;
  esac
done
PATHS=("${ARGS[@]:-}")

# ---- sanity checks ----
git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "Not inside a Git repository." >&2; exit 1; }

if (( DO_FETCH )); then
  git fetch --prune "$REMOTE"
fi

# Resolve default remote branch if not given (origin/HEAD -> origin/main, etc.)
if [[ -z "$BRANCH" ]]; then
  # Try symbolic-ref; fallback to 'git remote show'.
  if REF=$(git symbolic-ref -q --short "refs/remotes/${REMOTE}/HEAD" 2>/dev/null); then
    BRANCH="${REF#${REMOTE}/}"
  else
    BRANCH=$(git remote show "$REMOTE" | awk '/HEAD branch:/{print $3}')
    [[ -n "$BRANCH" ]] || { echo "Cannot resolve default branch for $REMOTE." >&2; exit 1; }
  fi
fi

REMOTE_REF="${REMOTE}/${BRANCH}"

# ---- file enumeration ----
declare -a FILES
if [[ "$LIST_MODE" == "tracked" ]]; then
  if ((${#PATHS[@]})); then
    mapfile -t FILES < <(git -c core.quotepath=off ls-files -- "${PATHS[@]}")
  else
    mapfile -t FILES < <(git -c core.quotepath=off ls-files)
  fi
else
  # Include untracked files under PATHS or repo root.
  ROOT=$(git rev-parse --show-toplevel)
  if ((${#PATHS[@]})); then
    mapfile -t FILES < <(cd "$ROOT" && find "${PATHS[@]}" -type f -printf '%P\n' | LC_ALL=C sort)
  else
    mapfile -t FILES < <(cd "$ROOT" && find . -type f -printf '%P\n' | sed 's#^\./##' | LC_ALL=C sort)
  fi
fi

# ---- helpers ----
hr_delta() {
  # human-readable time delta: seconds -> e.g., 3d12h
  local secs=$1; ((secs<0)) && secs=$(( -secs ))
  local d=$((secs/86400)); secs=$((secs%86400))
  local h=$((secs/3600)); secs=$((secs%3600))
  local m=$((secs/60));  local s=$((secs%60))
  local out=""
  ((d)) && out+="${d}d"
  ((h)) && out+="${h}h"
  ((m)) && out+="${m}m"
  ((s)) && { [[ -z "$out" ]] && out="${s}s" || out+="${s}s"; }
  [[ -n "$out" ]] && printf "%s" "$out" || printf "0s"
}

# ---- header ----
case "$FORMAT" in
  table)
    printf "%-8s  %-19s  %-19s  %-19s  %-7s  %s\n" \
      "STATUS" "REMOTE_COMMIT" "LOCAL_COMMIT" "FS_MTIME" "Δ(fs-rem)" "PATH"
    ;;
  tsv)
    printf "STATUS\tREMOTE_COMMIT\tLOCAL_COMMIT\tFS_MTIME\tDELTA_FS_REMOTE\tPATH\n"
    ;;
  csv)
    printf "STATUS,REMOTE_COMMIT,LOCAL_COMMIT,FS_MTIME,DELTA_FS_REMOTE,PATH\n"
    ;;
  *) echo "Unknown --format: $FORMAT" >&2; exit 2 ;;
esac

# ---- main loop ----
for f in "${FILES[@]}"; do
  # Last commit touching file on remote branch
  if ! REMOTE_DATE=$(git log -1 --date=iso-strict --pretty="$USE_FIELD" "$REMOTE_REF" -- "$f" 2>/dev/null); then
    # File may not exist on remote (new/unpushed)
    REMOTE_DATE=""
  fi
  REMOTE_SHA=$(git log -1 --pretty='%H' "$REMOTE_REF" -- "$f" 2>/dev/null || true)

  # Last commit touching file on local HEAD
  LOCAL_DATE=$(git log -1 --date=iso-strict --pretty="$USE_FIELD" HEAD -- "$f" 2>/dev/null || true)
  LOCAL_SHA=$(git log -1 --pretty='%H' HEAD -- "$f" 2>/dev/null || true)

  # Filesystem mtime (if present)
  FS_MTIME=""
  if [[ -f "$f" ]]; then
    # GNU stat + UTC ISO 8601
    FS_MTIME=$(date -u -d "@$(stat -c %Y "$f")" +%Y-%m-%dT%H:%M:%SZ)
  fi

  # Status vs remote content
  STATUS="ok"
  if [[ -z "$REMOTE_SHA" ]]; then
    STATUS="untracked-remote"
  elif ! git diff --quiet "$REMOTE_REF" -- "$f"; then
    STATUS="differs"
  fi

  # Skip if only-diff requested
  if (( ONLY_DIFF )) && [[ "$STATUS" == "ok" ]]; then
    continue
  fi

  # Δ(fs - remote)
  DELTA="NA"
  if [[ -n "$FS_MTIME" && -n "$REMOTE_DATE" ]]; then
    FS_S=$(date -u -d "$FS_MTIME" +%s)
    REM_S=$(date -u -d "$REMOTE_DATE" +%s)
    DELTA=$(hr_delta $((FS_S - REM_S)))
  fi

  case "$FORMAT" in
    table)
      printf "%-8s  %-19s  %-19s  %-19s  %-7s  %s\n" \
        "$STATUS" "${REMOTE_DATE:0:19}" "${LOCAL_DATE:0:19}" "${FS_MTIME:0:19}" "$DELTA" "$f"
      ;;
    tsv)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$STATUS" "$REMOTE_DATE" "$LOCAL_DATE" "$FS_MTIME" "$DELTA" "$f"
      ;;
    csv)
      printf "%s,%s,%s,%s,%s,%s\n" \
        "$STATUS" "$REMOTE_DATE" "$LOCAL_DATE" "$FS_MTIME" "$DELTA" "$f"
      ;;
  esac
done
