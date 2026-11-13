#!/usr/bin/env bash
#
# ghfzf - Search GitHub repositories with gh and select them with fzf.
#
# Dependencies:
#   github-cli, fzf, git
#
# Install on Arch Linux:
#   sudo pacman -S --needed github-cli fzf git
#
# Authentication:
#   gh auth login
#
# Usage examples:
#   ghfzf terminal recorder
#   ghfzf "vim plugin"
#   ghfzf -l Rust -s '>=100' --sort stars terminal recorder
#   ghfzf --updated '>=2026-01-01' --sort updated fuzzy cli
#   ghfzf -C "$HOME/repos" --depth 1 neuroscience R
#   ghfzf linux -- -topic:windows

set -Eeuo pipefail

readonly PROGRAM="${0##*/}"

LIMIT=100
SORT="best-match"
ORDER="desc"
LANGUAGE=""
STARS=""
OWNER=""
UPDATED=""
TOPIC=""
LICENSE=""
MATCH=""
INCLUDE_FORKS="false"
ARCHIVED="false"
CLONE_DIR="$PWD"
DEPTH=""

declare -a QUERY=()
declare -a RAW_QUERY=()

# -----------------------------------------------------------------------------
# Help and diagnostics
# -----------------------------------------------------------------------------

function usage() {
  cat <<USAGE
Usage:
  $PROGRAM [OPTIONS] [QUERY ...]
  $PROGRAM [OPTIONS] [QUERY ...] -- [RAW_GITHUB_QUALIFIER ...]

Search GitHub repositories with GitHub CLI, interactively filter the results
with fzf, preview repositories, and clone the selected repository or
repositories.

Options:
  -n, --limit N           Maximum results to fetch (default: 100).
  -l, --language LANG     Filter by programming language.
  -s, --stars EXPR        Filter by stars, e.g. '>=100' or '100..500'.
  -o, --owner OWNER       Restrict results to an owner or organization.
      --updated DATE      Filter by update date, e.g. '>=2026-01-01'.
  -t, --topic TOPICS      Filter by topic(s), e.g. 'linux,terminal'.
      --license LICENSE   Filter by license identifier.
  -m, --match FIELD       Match only name, description, or readme.
      --sort FIELD        best-match, stars, forks, updated, or
                          help-wanted-issues (default: best-match).
      --order ORDER       asc or desc (default: desc).
      --include-forks M   false, true, or only (default: false).
      --archived BOOL     Include only archived/non-archived repositories
                          (default: false).
  -C, --directory DIR     Clone into DIR (default: current directory).
      --depth N           Pass --depth=N to git clone.
  -h, --help              Show this help text and exit.

fzf keys:
  Enter                   Accept current/selected repositories and clone.
  Tab                     Toggle selection; multiple repositories may clone.
  Ctrl-O                  Open the highlighted repository in the browser.
  Ctrl-P                  Toggle the repository preview pane.
  Esc                     Cancel without cloning.

Examples:
  $PROGRAM terminal recorder
  $PROGRAM "vim plugin"
  $PROGRAM -l Rust -s '>=100' --sort stars terminal recorder
  $PROGRAM --updated '>=2026-01-01' --sort updated fuzzy finder
  $PROGRAM -C ~/repos --depth 1 neuroscience R
  $PROGRAM linux -- -topic:windows

Notes:
  Quoting affects GitHub search semantics. For example, "vim plugin" is a
  phrase search, whereas two unquoted arguments are separate search terms.
  Arguments after '--' are passed as raw GitHub search qualifiers, which is
  useful for exclusions such as '-topic:windows'.
USAGE
}

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function warn() {
  printf 'Warning: %s\n' "$*" >&2
}

function require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command not found: $command_name"
}

function require_value() {
  local option="$1"
  local value="${2-}"

  [[ -n "$value" ]] || die "$option requires a value"
}

function require_positive_integer() {
  local option="$1"
  local value="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
    die "$option requires a positive integer: $value"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -n | --limit)
        require_value "$1" "${2-}"
        LIMIT="$2"
        shift 2
        ;;
      -l | --language)
        require_value "$1" "${2-}"
        LANGUAGE="$2"
        shift 2
        ;;
      -s | --stars)
        require_value "$1" "${2-}"
        STARS="$2"
        shift 2
        ;;
      -o | --owner)
        require_value "$1" "${2-}"
        OWNER="$2"
        shift 2
        ;;
      --updated)
        require_value "$1" "${2-}"
        UPDATED="$2"
        shift 2
        ;;
      -t | --topic)
        require_value "$1" "${2-}"
        TOPIC="$2"
        shift 2
        ;;
      --license)
        require_value "$1" "${2-}"
        LICENSE="$2"
        shift 2
        ;;
      -m | --match)
        require_value "$1" "${2-}"
        MATCH="$2"
        shift 2
        ;;
      --sort)
        require_value "$1" "${2-}"
        SORT="$2"
        shift 2
        ;;
      --order)
        require_value "$1" "${2-}"
        ORDER="$2"
        shift 2
        ;;
      --include-forks)
        require_value "$1" "${2-}"
        INCLUDE_FORKS="$2"
        shift 2
        ;;
      --archived)
        require_value "$1" "${2-}"
        ARCHIVED="$2"
        shift 2
        ;;
      -C | --directory)
        require_value "$1" "${2-}"
        CLONE_DIR="$2"
        shift 2
        ;;
      --depth)
        require_value "$1" "${2-}"
        DEPTH="$2"
        shift 2
        ;;
      --)
        shift
        RAW_QUERY=("$@")
        break
        ;;
      -*)
        die "Unknown option: $1 (use '--' for raw GitHub qualifiers)"
        ;;
      *)
        QUERY+=("$1")
        shift
        ;;
    esac
  done
}

function validate_options() {
  require_positive_integer "--limit" "$LIMIT"

  if [[ -n "$DEPTH" ]]; then
    require_positive_integer "--depth" "$DEPTH"
  fi

  case "$SORT" in
    best-match | stars | forks | updated | help-wanted-issues) ;;
    *) die "Invalid --sort value: $SORT" ;;
  esac

  case "$ORDER" in
    asc | desc) ;;
    *) die "Invalid --order value: $ORDER" ;;
  esac

  case "$INCLUDE_FORKS" in
    false | true | only) ;;
    *) die "Invalid --include-forks value: $INCLUDE_FORKS" ;;
  esac

  case "$ARCHIVED" in
    false | true) ;;
    *) die "Invalid --archived value: $ARCHIVED" ;;
  esac

  if [[ -n "$MATCH" ]]; then
    case "$MATCH" in
      name | description | readme) ;;
      *) die "Invalid --match value: $MATCH" ;;
    esac
  fi
}

# -----------------------------------------------------------------------------
# GitHub search
# -----------------------------------------------------------------------------

function build_search_command() {
  local -n command_ref="$1"

  command_ref=(
    gh search repos
    --limit "$LIMIT"
    --sort "$SORT"
    --order "$ORDER"
    --include-forks "$INCLUDE_FORKS"
    "--archived=$ARCHIVED"
    --json \
      fullName,stargazersCount,language,updatedAt,description,url
    --jq \
      '.[] | [
        .fullName,
        (.stargazersCount | tostring),
        (.language // "-"),
        (.updatedAt[0:10]),
        (.description // "")
      ] | @tsv'
  )

  [[ -z "$LANGUAGE" ]] || command_ref+=(--language "$LANGUAGE")
  [[ -z "$STARS" ]] || command_ref+=(--stars "$STARS")
  [[ -z "$OWNER" ]] || command_ref+=(--owner "$OWNER")
  [[ -z "$UPDATED" ]] || command_ref+=(--updated "$UPDATED")
  [[ -z "$TOPIC" ]] || command_ref+=(--topic "$TOPIC")
  [[ -z "$LICENSE" ]] || command_ref+=(--license "$LICENSE")
  [[ -z "$MATCH" ]] || command_ref+=(--match "$MATCH")

  command_ref+=("${QUERY[@]}")

  if ((${#RAW_QUERY[@]} > 0)); then
    command_ref+=(-- "${RAW_QUERY[@]}")
  fi
}

function search_repositories() {
  local -a search_command=()
  local results

  build_search_command search_command

  if ! results="$("${search_command[@]}")"; then
    die "GitHub repository search failed"
  fi

  [[ -n "$results" ]] || die "No repositories matched the search"

  printf '%s\n' "$results"
}

# -----------------------------------------------------------------------------
# fzf selection and actions
# -----------------------------------------------------------------------------

function select_repositories() {
  local results="$1"
  local selection
  local header

  header=$'Enter: clone | Tab: select | Ctrl-O: browser | Ctrl-P: preview\n'
  header+=$'REPOSITORY\tSTARS\tLANGUAGE\tUPDATED\tDESCRIPTION'

  if ! selection="$({ printf '%s\n' "$results"; } | fzf \
    --multi \
    --delimiter=$'\t' \
    --height='90%' \
    --layout=reverse \
    --border \
    --header="$header" \
    --preview='gh repo view {1} 2>/dev/null' \
    --preview-window='right,60%,wrap' \
    --bind='ctrl-o:execute-silent(gh repo view {1} --web)' \
    --bind='ctrl-p:toggle-preview')"; then
    return 1
  fi

  [[ -n "$selection" ]] || return 1
  printf '%s\n' "$selection"
}

function clone_repository() {
  local repository="$1"
  local repository_name="${repository##*/}"
  local target="$CLONE_DIR/$repository_name"

  if [[ -e "$target" ]]; then
    warn "Skipping $repository; target already exists: $target"
    return 1
  fi

  printf 'Cloning %s -> %s\n' "$repository" "$CLONE_DIR"

  if [[ -n "$DEPTH" ]]; then
    (
      cd "$CLONE_DIR"
      gh repo clone "$repository" -- --depth="$DEPTH"
    )
  else
    (
      cd "$CLONE_DIR"
      gh repo clone "$repository"
    )
  fi
}

function clone_selection() {
  local selection="$1"
  local repository
  local ignored
  local failures=0

  mkdir -p "$CLONE_DIR"

  while IFS=$'\t' read -r repository ignored; do
    [[ -n "$repository" ]] || continue

    if ! clone_repository "$repository"; then
      ((failures += 1))
    fi
  done <<<"$selection"

  if ((failures > 0)); then
    warn "$failures repository clone(s) failed or were skipped"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  local results
  local selection

  parse_args "$@"
  validate_options

  require_command gh
  require_command fzf
  require_command git

  gh auth status >/dev/null 2>&1 ||
    die "GitHub CLI is not authenticated; run: gh auth login"

  results="$(search_repositories)"

  if ! selection="$(select_repositories "$results")"; then
    printf 'No repository selected.\n'
    return 0
  fi

  clone_selection "$selection"
}

main "$@"
