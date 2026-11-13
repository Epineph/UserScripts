#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# safe-clean.sh
#
# Conservative disk cleanup for developer machines.
#
# Design goals:
#   - Never delete Git internals directly. Use Git maintenance + gc only.
#   - Only remove clearly-rebuildable artifacts and well-defined caches.
#   - Provide explicit directory selection for repo cleanup:
#       * Default repo root: $HOME/repos
#       * Optional: /shared/repos, $HOME/my_repos
#       * If no repo roots are specified, defaults to $HOME/repos.
#       * If repo roots are specified, only those are used.
#
# Paging:
#   - Off by default. This script is meant to run non-interactively.
#
# -----------------------------------------------------------------------------

# ---------------------------------------
# Defaults
# ---------------------------------------
typeset -g DEFAULT_REPO_ROOT="$HOME/repos"
typeset -g DEFAULT_SHARED_ROOT="/shared/repos"
typeset -g DEFAULT_MY_ROOT="$HOME/my_repos"

typeset -ga REPO_ROOTS=()
typeset -g CLEAN_NPM=0
typeset -g CLEAN_MAMBA=0
typeset -g CLEAN_VCPKG=0
typeset -g CLEAN_PACMAN_CACHE=0
typeset -g CLEAN_ALL_CACHE=0

typeset -g JOURNAL_VACUUM="14d"
typeset -g PACMAN_KEEP="2"

# ---------------------------------------
# Helpers
# ---------------------------------------
function die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function usage() {
  cat <<'EOF'
safe-clean.sh

USAGE
  safe-clean.sh [OPTIONS]

REPO ROOT SELECTION
  --repos-home
      Include $HOME/repos

  --repos-shared
      Include /shared/repos

  --repos-my
      Include $HOME/my_repos

  --repos PATH
      Include an arbitrary repo root directory PATH (repeatable)

  Notes:
    - If you do not specify any --repos-* or --repos options, the script
      defaults to $HOME/repos only.
    - If you specify any repo roots, only those specified are used.
    - $HOME/repos is included only if:
        (a) you did not specify any repo roots, OR
        (b) you explicitly included it via --repos-home or --repos "$HOME/repos".

CACHE CLEANING
  --npm
      Run: npm cache clean --force   (if npm exists)

  --micromamba
      Run: micromamba clean --all --yes   (if micromamba exists)

  --vcpkg
      Remove vcpkg download/build caches (best-effort; see details in script)

  --pacman
      Clean pacman package cache using paccache (keep last N versions)

  --all-cache
      Remove $HOME/.cache entirely (DANGEROUS for convenience; safe for data)
      This does not delete non-cache data, but will cause many apps to rebuild
      caches and may log you out of some apps. Use deliberately.

OTHER
  --journal-vacuum DURATION
      Vacuum systemd journal, e.g. 7d, 14d, 1month (default: 14d)

  --pacman-keep N
      Keep N package versions in paccache (default: 2)

  -h, --help
      Show this help

EXAMPLES (8)
  1) Default behavior: only $HOME/repos Git maintenance + safe build cleanup
     safe-clean.sh

  2) Clean Git in /shared/repos only
     safe-clean.sh --repos-shared

  3) Clean Git in $HOME/repos and $HOME/my_repos
     safe-clean.sh --repos-home --repos-my

  4) Clean Git in all three standard roots
     safe-clean.sh --repos-home --repos-my --repos-shared

  5) Clean Git in a custom path and also $HOME/repos explicitly
     safe-clean.sh --repos /data/repos --repos-home

  6) Add caches: npm + micromamba + pacman cache
     safe-clean.sh --npm --micromamba --pacman

  7) Aggressive user cache reset
     safe-clean.sh --all-cache

  8) Full “dev machine hygiene”
     safe-clean.sh --repos-home --repos-my --repos-shared --npm --micromamba \
       --vcpkg --pacman --journal-vacuum 14d --pacman-keep 2

SAFETY RULE
  The script NEVER deletes files inside .git/objects directly.
  It uses "git maintenance" and "git gc" only.

EOF
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function add_repo_root() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  # Expand tilde-ish patterns manually if user passes them; keep simple.
  p="${p/#\~/$HOME}"
  # Normalize trailing slash
  p="${p%/}"
  REPO_ROOTS+=("$p")
}

function dedup_repo_roots() {
  local -A seen=()
  local -a out=()
  local r=""
  for r in "${REPO_ROOTS[@]}"; do
    if [[ -z "${seen[$r]+x}" ]]; then
      seen["$r"]=1
      out+=("$r")
    fi
  done
  REPO_ROOTS=("${out[@]}")
}

function require_sudo_if_needed() {
  # Try to refresh sudo timestamp early when sudo-required tasks are selected.
  # Avoids failing half-way through.
  local need=0
  [[ "$CLEAN_PACMAN_CACHE" -eq 1 ]] && need=1
  [[ -n "$JOURNAL_VACUUM" ]] && need=1
  if [[ "$need" -eq 1 ]]; then
    sudo -v
  fi
}

# ---------------------------------------
# Argument parsing
# ---------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos-home)
      add_repo_root "$DEFAULT_REPO_ROOT"
      shift
      ;;
    --repos-shared)
      add_repo_root "$DEFAULT_SHARED_ROOT"
      shift
      ;;
    --repos-my)
      add_repo_root "$DEFAULT_MY_ROOT"
      shift
      ;;
    --repos)
      [[ $# -ge 2 ]] || die "--repos requires a PATH argument"
      add_repo_root "$2"
      shift 2
      ;;
    --npm)
      CLEAN_NPM=1
      shift
      ;;
    --micromamba)
      CLEAN_MAMBA=1
      shift
      ;;
    --vcpkg)
      CLEAN_VCPKG=1
      shift
      ;;
    --pacman)
      CLEAN_PACMAN_CACHE=1
      shift
      ;;
    --all-cache)
      CLEAN_ALL_CACHE=1
      shift
      ;;
    --journal-vacuum)
      [[ $# -ge 2 ]] || die "--journal-vacuum requires a duration, e.g. 14d"
      JOURNAL_VACUUM="$2"
      shift 2
      ;;
    --pacman-keep)
      [[ $# -ge 2 ]] || die "--pacman-keep requires an integer"
      PACMAN_KEEP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (use --help)"
      ;;
  esac
done

# ---------------------------------------
# Repo roots defaulting logic
# ---------------------------------------
if [[ "${#REPO_ROOTS[@]}" -eq 0 ]]; then
  # No directories chosen => default to $HOME/repos only.
  add_repo_root "$DEFAULT_REPO_ROOT"
fi
dedup_repo_roots

# ---------------------------------------
# Pre-flight sudo
# ---------------------------------------
require_sudo_if_needed

# ---------------------------------------
# Git maintenance: safe by construction
# ---------------------------------------
printf '==> Git maintenance (safe)\n'
for base in "${REPO_ROOTS[@]}"; do
  if [[ ! -d "$base" ]]; then
    printf '  -> %s (missing, skipped)\n' "$base"
    continue
  fi

  # Search shallowly: most repo layouts are base/<repo>/.git
  find "$base" -mindepth 1 -maxdepth 4 -type d -name .git -print0 2>/dev/null |
    while IFS= read -r -d '' gitdir; do
      local_repo="$(dirname "$gitdir")"
      printf '  -> %s\n' "$local_repo"

      # Keep these non-fatal: some repos are odd, permissions, or locked.
      git -C "$local_repo" maintenance run --auto >/dev/null 2>&1 || true
      git -C "$local_repo" gc --prune=now >/dev/null 2>&1 || true
    done
done

# ---------------------------------------
# Build artifacts: rebuildable outputs only
# ---------------------------------------
printf '\n==> Removing build artifacts (rebuildable)\n'
for base in "${REPO_ROOTS[@]}"; do
  [[ -d "$base" ]] || continue

  find "$base" \
    -type d \( \
      -name target -o \
      -name __pycache__ -o \
      -name .pytest_cache -o \
      -name .mypy_cache -o \
      -name .ruff_cache -o \
      -name dist -o \
      -name build -o \
      -name node_modules \
    \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
done

# ---------------------------------------
# npm cache
# ---------------------------------------
if [[ "$CLEAN_NPM" -eq 1 ]]; then
  printf '\n==> npm cache clean\n'
  if have npm; then
    npm cache clean --force
  else
    printf '  -> npm not found, skipped\n'
  fi
fi

# ---------------------------------------
# micromamba cache
# ---------------------------------------
if [[ "$CLEAN_MAMBA" -eq 1 ]]; then
  printf '\n==> micromamba clean\n'
  if have micromamba; then
    micromamba clean --all --yes
  else
    printf '  -> micromamba not found, skipped\n'
  fi
fi

# ---------------------------------------
# vcpkg cache (best-effort)
# ---------------------------------------
if [[ "$CLEAN_VCPKG" -eq 1 ]]; then
  printf '\n==> vcpkg cache cleanup (best-effort)\n'
  # vcpkg caches vary by install mode. Conservative targets:
  #   - downloads/ is safe to delete (re-fetchable)
  #   - buildtrees/ and packages/ can be large but deleting them may force rebuilds
  #     and can be annoying; we keep default conservative: only downloads/
  #
  # Try common locations; user can add more via --repos PATH if they keep vcpkg
  # inside repos and want buildtrees deleted (node_modules already handled above).
  #
  # If you want more aggressive vcpkg cleanup, extend targets explicitly.
  candidates=(
    "$HOME/vcpkg"
    "$HOME/repos/vcpkg"
    "$HOME/my_repos/vcpkg"
    "/shared/repos/vcpkg"
  )

  did=0
  for v in "${candidates[@]}"; do
    if [[ -d "$v/downloads" ]]; then
      printf '  -> rm -rf %s\n' "$v/downloads"
      rm -rf "$v/downloads"
      did=1
    fi
  done

  if [[ "$did" -eq 0 ]]; then
    printf '  -> no vcpkg downloads/ dirs found, skipped\n'
  fi
fi

# ---------------------------------------
# pacman package cache via paccache
# ---------------------------------------
if [[ "$CLEAN_PACMAN_CACHE" -eq 1 ]]; then
  printf '\n==> Pacman cache cleanup (keep last %s versions)\n' "$PACMAN_KEEP"
  if have paccache; then
    sudo paccache -rk"$PACMAN_KEEP"
  else
    printf '  -> paccache not found (package: pacman-contrib), skipped\n'
  fi
fi

# ---------------------------------------
# systemd journal vacuum
# ---------------------------------------
if [[ -n "$JOURNAL_VACUUM" ]]; then
  printf '\n==> systemd journal vacuum: %s\n' "$JOURNAL_VACUUM"
  sudo journalctl --vacuum-time="$JOURNAL_VACUUM"
fi

# ---------------------------------------
# optional: remove all of $HOME/.cache
# ---------------------------------------
if [[ "$CLEAN_ALL_CACHE" -eq 1 ]]; then
  printf '\n==> Removing %s/.cache (this is safe but disruptive)\n' "$HOME"
  rm -rf "$HOME/.cache"
fi

printf '\n==> Done.\n'

