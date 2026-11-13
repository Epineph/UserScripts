#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# recent-git-repos.sh
# List remote URLs from recently modified repository directories; optionally
# clone those remotes, including their submodules, into a destination directory.
# Requires: Bash 4+, Git, GNU findutils, and GNU coreutils (Linux).
# -----------------------------------------------------------------------------

set -euo pipefail

function usage() {
  cat <<'HELP'
Usage: recent-git-repos [OPTIONS]

Print one remote URL per repository whose top-level directory was modified
within the last 24 hours. Scan immediate subdirectories of the current directory
by default, including hidden directories, sorted oldest first.

Options:
  -s, --source DIR           Directory to scan (default: current directory).
  -H, --hours N              Positive whole-number age limit (default: 24).
  -r, --remote NAME          Remote to query (default: origin).
  -p, --path DIR             Clone destination; requires --clone.
  -c, --clone                Clone the discovered remotes and their submodules.
      --clone-repositories  Alias for --clone.
  -n, --dry-run              Print clone commands without changing anything.
                            Requires --clone and --path.
  -h, --help                 Show usage and examples.
      --long-help            Also explain timestamp and cloning behaviour.

Examples:
  recent-git-repos
  recent-git-repos --hours 48 > repository-urls.txt
  recent-git-repos --source "$HOME/.local/share/zinit/plugins"
  recent-git-repos --clone --path "$HOME/repos"
  recent-git-repos -s ./plugins -c -p "$HOME/repos" --dry-run
HELP
}

function long_help() {
  usage
  cat <<'HELP'

Details:
  * This reads directory modification times, like a normal date-sorted listing.
    It does not inspect commit dates or recursively find recently edited files.
    Editing an existing file may leave its parent directory's time unchanged.
  * Only immediate, real subdirectories are scanned. Symlinks are not followed.
    Regular worktrees, linked worktrees, and submodule roots are supported;
    bare repositories and arbitrary subdirectories inside repositories are not.
  * One fetch URL is printed per matching repository, using git remote get-url.
    Missing remotes are reported to stderr and skipped. Duplicate URLs are kept.
  * stdout contains only URLs; progress and clone commands go to stderr. This
    allows redirection to a URL list even while cloning.
  * Clones retain the SOURCE DIRECTORY NAME: SOURCE/foo becomes DESTINATION/foo.
    Existing destination entries, including empty directories, are skipped.
  * --recurse-submodules initializes and clones nested submodules. Authentication
    uses your normal Git credentials. Relative local remote paths are resolved
    relative to their source repository when cloning.
  * Cloning retrieves remote history; uncommitted edits, unpushed commits, and
    other local-only state are not copied. A failed clone may leave a partial
    destination behind; this command never automatically deletes it.
  * Exit status: 0 = finished, 1 = discovery/clone/runtime failure,
    2 = invalid arguments. No matching repositories is a successful result.
HELP
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

function require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
}

function print_command() {
  printf '  ' >&2
  printf '%q ' "$@" >&2
  printf '\n' >&2
}

work_dir=""

function cleanup() {
  if [[ -n $work_dir ]]; then
    rm -rf -- "$work_dir"
  fi
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

source_dir="."
destination=""
hours="24"
remote="origin"
clone=false
dry_run=false

while (( $# )); do
  case "$1" in
    -s|--source)
      require_value "$@"
      source_dir=$2
      shift 2
      ;;
    --source=*) source_dir=${1#*=}; shift ;;
    -H|--hours)
      require_value "$@"
      hours=$2
      shift 2
      ;;
    --hours=*) hours=${1#*=}; shift ;;
    -r|--remote)
      require_value "$@"
      remote=$2
      shift 2
      ;;
    --remote=*) remote=${1#*=}; shift ;;
    -p|--path)
      require_value "$@"
      destination=$2
      shift 2
      ;;
    --path=*) destination=${1#*=}; shift ;;
    -c|--clone|--clone-repositories) clone=true; shift ;;
    -n|--dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --long-help) long_help; exit 0 ;;
    *) die "Unknown argument: $1. Use --help." ;;
  esac
done

[[ $hours =~ ^[1-9][0-9]*$ ]] || die "--hours needs a positive integer."
[[ -n $source_dir ]] || die "--source cannot be empty."
[[ -n $remote && $remote != -* ]] || die "Invalid remote name."

if $clone; then
  [[ -n $destination ]] || die "--clone requires --path DIR."
else
  [[ -z $destination ]] || die "--path requires --clone."
  ! $dry_run || die "--dry-run requires --clone and --path DIR."
fi

for dependency in git find sort mktemp; do
  command -v "$dependency" >/dev/null 2>&1 ||
    die "Required command not found: $dependency."
done

[[ -d $source_dir ]] || die "Source is not a directory: $source_dir."
source_dir=$(cd -P -- "$source_dir" && printf '%s/' "$PWD")
source_dir=${source_dir%/}

# Anchor relative destinations before any Git commands change working directory.
if $clone; then
  case "$destination" in
    /*) ;;
    *) destination="$PWD/$destination" ;;
  esac
fi

# -----------------------------------------------------------------------------
# Discover and sort first; cloning cannot change this candidate list.
# NUL-delimited records preserve spaces, tabs, and newlines in directory names.
# -----------------------------------------------------------------------------

work_dir=$(mktemp -d)
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! LC_ALL=C find "$source_dir" -mindepth 1 -maxdepth 1 -type d \
  -newermt "$hours hours ago" ! -newermt now \
  -printf '%T@ %p\0' | LC_ALL=C sort -z -n > "$work_dir/candidates"; then
  printf 'Error: Could not scan and sort source directories.\n' >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Query remotes and optionally clone. Keep Git output away from the URL stream.
# -----------------------------------------------------------------------------

failures=0
found=0
destination_ready=false

while IFS= read -r -d '' entry <&3; do
  repository=${entry#* }

  # A .git file also identifies linked worktrees and checked-out submodules.
  [[ -e "$repository/.git" ]] || continue
  if ! git -C "$repository" rev-parse --is-inside-work-tree \
    >/dev/null 2>&1; then
    printf 'Skipping invalid worktree: %q\n' "$repository" >&2
    continue
  fi

  if ! url=$(git -C "$repository" remote get-url "$remote" 2>/dev/null); then
    printf 'Skipping %q: remote %q is unavailable.\n' \
      "$repository" "$remote" >&2
    continue
  fi

  if [[ -z $url || $url == *$'\n'* || $url == *$'\r'* ]]; then
    printf 'Skipping %q: URL is empty or contains a line break.\n' \
      "$repository" >&2
    failures=$((failures + 1))
    continue
  fi

  printf '%s\n' "$url"
  found=$((found + 1))
  $clone || continue

  name=${repository##*/}
  target="$destination/$name"
  if [[ -e $target || -L $target ]]; then
    printf 'Skipping existing destination: %q\n' "$target" >&2
    continue
  fi

  # Git otherwise interprets a relative local URL from the clone destination.
  clone_url=$url
  case "$url" in
    /*|~*|*:*) ;;
    *) clone_url="$repository/$url" ;;
  esac

  if $dry_run; then
    print_command git -C "$destination" clone --recurse-submodules \
      -- "$clone_url" "$name"
    continue
  fi

  if ! $destination_ready; then
    mkdir -p -- "$destination"
    destination_ready=true
  fi

  if ! git -C "$destination" clone --recurse-submodules \
    -- "$clone_url" "$name" >&2; then
    printf 'Clone failed for: %q\n' "$repository" >&2
    failures=$((failures + 1))
  fi
done 3< "$work_dir/candidates"

if (( found == 0 )); then
  printf 'No matching repositories with a usable %q remote.\n' "$remote" >&2
fi

(( failures == 0 ))
