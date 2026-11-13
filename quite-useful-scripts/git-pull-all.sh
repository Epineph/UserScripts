#!/usr/bin/env bash

set -uo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

ROOT_DIR="$PWD"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/git-pull-all-repos"
FNM_MODE="ask"            # ask | always | never
USE_SAFE_DIRECTORY="1"    # 1 = yes, 0 = no
USE_STASH="1"             # 1 = yes, 0 = no
HELP_PAGER_DEFAULT="less -R"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
Usage:
  git-pull-all-repos [OPTIONS]

Description:
  Scan the immediate child directories under --root. For each Git repository,
  print its origin URL, optionally add it to Git safe.directory, pull the
  current branch with --ff-only, optionally stash/pop local changes, and
  optionally install/use the repo's declared Node.js version with fnm.

Options:
  -r, --root DIR
      Parent directory to scan.
      Default: current working directory

      --fnm-install MODE
      Control fnm handling of .node-version / .nvmrc files.
      Allowed values: ask | always | never
      Default: ask

      --log-dir DIR
      Directory where log files are written.
      Default:
      ${XDG_STATE_HOME:-$HOME/.local/state}/git-pull-all-repos

      --no-safe-directory
      Do not add repositories to git safe.directory.

      --no-stash
      Do not stash dirty repositories before pulling.

      --pager
      Page this help output.

  -h, --help
      Show this help.

Notes:
  - Only immediate subdirectories are scanned, mirroring your original
    function's behavior.
  - The script uses `git pull --ff-only` for safer bulk updates.
  - If a repository is in detached HEAD state, it is skipped.
  - If fnm is enabled and a repo has .node-version or .nvmrc, the script reads
    the first non-empty, non-comment line and passes that value to:
        fnm install <value>
        fnm use <value>

Examples:
  git-pull-all-repos

  git-pull-all-repos --root "$HOME/repos"

  git-pull-all-repos --root "$HOME/repos" --fnm-install always

  git-pull-all-repos --fnm-install never --no-stash

  git-pull-all-repos --log-dir "$HOME/logs/git-pulls"

EOF
}

function page_help() {
  local pager_cmd="${HELP_PAGER:-$HELP_PAGER_DEFAULT}"

  if command -v less >/dev/null 2>&1; then
    show_help | eval "$pager_cmd"
  else
    show_help
  fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--root)
        [[ $# -ge 2 ]] || {
          printf 'Error: %s requires an argument.\n' "$1" >&2
          exit 1
        }
        ROOT_DIR="$2"
        shift 2
        ;;
      --fnm-install)
        [[ $# -ge 2 ]] || {
          printf 'Error: %s requires an argument.\n' "$1" >&2
          exit 1
        }
        FNM_MODE="${2,,}"
        shift 2
        ;;
      --log-dir)
        [[ $# -ge 2 ]] || {
          printf 'Error: %s requires an argument.\n' "$1" >&2
          exit 1
        }
        LOG_DIR="$2"
        shift 2
        ;;
      --no-safe-directory)
        USE_SAFE_DIRECTORY="0"
        shift
        ;;
      --no-stash)
        USE_STASH="0"
        shift
        ;;
      --pager)
        page_help
        exit 0
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        printf 'Error: unknown argument: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  case "$FNM_MODE" in
    ask|always|never) ;;
    *)
      printf 'Error: --fnm-install must be ask, always, or never.\n' >&2
      exit 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

function setup_logging() {
  local timestamp

  mkdir -p "$LOG_DIR"
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  LOG_FILE="${LOG_DIR}/git-pull-all-repos_${timestamp}.log"

  exec > >(tee -a "$LOG_FILE") 2>&1
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function init_fnm() {
  HAVE_FNM="0"

  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
    HAVE_FNM="1"
  fi
}

function maybe_prompt_for_fnm() {
  if [[ "$FNM_MODE" != "ask" ]]; then
    return 0
  fi

  if [[ "$HAVE_FNM" != "1" ]]; then
    FNM_MODE="never"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    FNM_MODE="never"
    return 0
  fi

  printf 'Use fnm for repos declaring Node versions? [y/N]: '
  read -r answer || answer="n"

  case "${answer,,}" in
    y|yes)
      FNM_MODE="always"
      ;;
    *)
      FNM_MODE="never"
      ;;
  esac
}

function ensure_safe_directory() {
  local repo_abs="$1"

  if git config --global --get-all safe.directory 2>/dev/null \
    | grep -Fqx -- "$repo_abs"; then
    return 0
  fi

  git config --global --add safe.directory "$repo_abs"
}

function repo_status_is_dirty() {
  [[ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]]
}

function detect_node_version() {
  local file

  for file in ".node-version" ".nvmrc"; do
    if [[ -f "$file" ]]; then
      awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          print FILENAME "\t" $0
          exit
        }
      ' "$file"
      return 0
    fi
  done

  return 1
}

function process_repo() {
  local repo_dir="$1"
  local repo_abs=""
  local repo_name=""
  local origin_url=""
  local branch=""
  local stash_before=""
  local stash_after=""
  local created_stash="0"
  local node_file=""
  local node_version=""

  echo
  echo "========================================================================"
  echo "Repository: $repo_dir"

  (
    cd "$repo_dir" || exit 1

    repo_abs="$(pwd -P)"
    repo_name="$(basename "$repo_abs")"

    echo "Path:   $repo_abs"

    origin_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -n "$origin_url" ]]; then
      echo "Origin: $origin_url"
    else
      echo "Origin: <no origin remote>"
    fi

    if [[ "$USE_SAFE_DIRECTORY" == "1" ]]; then
      ensure_safe_directory "$repo_abs"
      echo "Safe:   ensured"
    else
      echo "Safe:   skipped"
    fi

    branch="$(git branch --show-current 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      echo "Branch: <detached HEAD or unavailable>"
      echo "Result: skipped"
      exit 2
    fi

    echo "Branch: $branch"

    if [[ "$USE_STASH" == "1" ]] && repo_status_is_dirty; then
      stash_before="$(git rev-parse -q --verify refs/stash 2>/dev/null || true)"

      git stash push --include-untracked \
        --message "git-pull-all-repos: ${repo_name}: $(date '+%F %T')" \
        >/dev/null

      stash_after="$(git rev-parse -q --verify refs/stash 2>/dev/null || true)"

      if [[ -n "$stash_after" && "$stash_before" != "$stash_after" ]]; then
        created_stash="1"
        echo "Stash:  created temporary stash"
      else
        echo "Stash:  nothing created"
      fi
    else
      echo "Stash:  skipped (clean repo or disabled)"
    fi

    if git pull --ff-only; then
      echo "Pull:   OK"
    else
      echo "Pull:   FAILED"
      if [[ "$created_stash" == "1" ]]; then
        echo "Stash:  retained because pull failed"
      fi
      exit 1
    fi

    if IFS=$'\t' read -r node_file node_version < <(detect_node_version); then
      echo "Node:   ${node_file} -> ${node_version}"

      if [[ "$FNM_MODE" == "always" ]]; then
        if [[ "$HAVE_FNM" == "1" ]]; then
          if fnm install "$node_version" && fnm use "$node_version"; then
            echo "fnm:    install/use OK"
          else
            echo "fnm:    install/use FAILED"
            exit 1
          fi
        else
          echo "fnm:    not available; skipped"
        fi
      else
        echo "fnm:    skipped by configuration"
      fi
    else
      echo "Node:   <no .node-version or .nvmrc>"
    fi

    if [[ "$created_stash" == "1" ]]; then
      if git stash pop; then
        echo "Stash:  restored"
      else
        echo "Stash:  pop produced conflicts; inspect manually"
        exit 1
      fi
    fi

    echo "Result: success"
  )

  return $?
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function main() {
  local total="0"
  local success="0"
  local failed="0"
  local skipped="0"
  local dir=""

  parse_args "$@"

  if [[ ! -d "$ROOT_DIR" ]]; then
    printf 'Error: root directory does not exist: %s\n' "$ROOT_DIR" >&2
    exit 1
  fi

  ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"
  setup_logging
  init_fnm
  maybe_prompt_for_fnm

  echo "Started:  $(date '+%F %T %z')"
  echo "Root:     $ROOT_DIR"
  echo "Log file: $LOG_FILE"
  echo "fnm:      $FNM_MODE"
  echo

  shopt -s nullglob

  for dir in "$ROOT_DIR"/*/; do
    if [[ ! -d "${dir}/.git" ]]; then
      continue
    fi

    total=$((total + 1))

    if process_repo "$dir"; then
      success=$((success + 1))
    else
      case "$?" in
        2)
          skipped=$((skipped + 1))
          ;;
        *)
          failed=$((failed + 1))
          ;;
      esac
    fi
  done

  echo
  echo "========================================================================"
  echo "Summary"
  echo "------------------------------------------------------------------------"
  echo "Total repos: $total"
  echo "Succeeded:   $success"
  echo "Skipped:     $skipped"
  echo "Failed:      $failed"
  echo "Log file:    $LOG_FILE"

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
