#!/usr/bin/env bash
# cargo-clean-all
#
# Recursively scans a root directory for Rust projects (Cargo.toml) and runs
# `cargo clean` in each *topmost* Cargo directory (avoids redundant nested cleans).
#
# Default root: /shared/repos
#
# Output:
#   - Progress lines while running
#   - Final list of directories cleaned successfully
#
# Logs (default):
#   $HOME/.log/cargo-clean-all/
#
# ------------------------------------------------------------------------------
set -uo pipefail

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
ROOT_DIR="/shared/repos"
DRY_RUN=0
PRINT_ONLY=0
NO_LOG=0
LOG_DIR="${HOME}/.log/cargo-clean-all"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
function die() {
  printf 'ERROR: %s\n' "${1:-unknown error}" >&2
  exit 1
}

function have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function usage() {
  cat <<'EOF'
cargo-clean-all

Usage:
  cargo-clean-all [options]

Options:
  -r, --root DIR        Root directory to scan (default: /shared/repos)
      --dry-run         Print what would be cleaned, do not run cargo
      --print-only      Print detected top-level Cargo directories, then exit
      --no-log          Do not write per-project logs
      --log-dir DIR     Directory for logs (default: $HOME/.log/cargo-clean-all)
  -h, --help            Show this help

Notes:
  - A "Cargo directory" is any directory containing Cargo.toml.
  - For nested crates, this script cleans only the topmost Cargo.toml directory
    within that subtree (i.e., if parent has Cargo.toml, child is skipped).
EOF
}

function path_id() {
  local p="${1:-}"
  if have_cmd sha1sum; then
    printf '%s' "$p" | sha1sum | awk '{print $1}'
    return 0
  fi
  # Fallback: lossy but deterministic.
  p="${p//\//_}"
  p="${p// /_}"
  printf '%s\n' "$p"
}

function is_within_root() {
  local root="$1"
  local path="$2"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

function find_top_cargo_dir() {
  local root="$1"
  local start_dir="$2"
  local cur="$start_dir"
  local parent=""

  while :; do
    parent="$(dirname -- "$cur")"

    # Stop if we would escape the requested root.
    if ! is_within_root "$root" "$parent"; then
      break
    fi

    # Stop if we're at the root boundary.
    if [[ "$parent" == "$cur" ]]; then
      break
    fi

    # Climb if the parent is also a Cargo directory.
    if [[ -f "$parent/Cargo.toml" ]]; then
      cur="$parent"
      continue
    fi

    break
  done

  printf '%s\n' "$cur"
}

# ------------------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      ROOT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --print-only)
      PRINT_ONLY=1
      shift
      ;;
    --no-log)
      NO_LOG=1
      shift
      ;;
    --log-dir)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      LOG_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------
[[ -d "$ROOT_DIR" ]] || die "Root directory not found: $ROOT_DIR"
have_cmd cargo || die "cargo not found in PATH"

if [[ "$NO_LOG" -eq 0 ]]; then
  mkdir -p -- "$LOG_DIR" || die "Failed to create log dir: $LOG_DIR"
fi

# ------------------------------------------------------------------------------
# Discover Cargo projects (topmost Cargo.toml directories)
# ------------------------------------------------------------------------------
declare -A TOP_DIRS=()

# Exclusions: common heavy/irrelevant trees that may contain Cargo.toml copies.
# Adjust as needed.
while IFS= read -r -d '' cargo_toml; do
  dir="$(dirname -- "$cargo_toml")"
  top="$(find_top_cargo_dir "$ROOT_DIR" "$dir")"
  TOP_DIRS["$top"]=1
done < <(
  find "$ROOT_DIR" \
    -type f -name 'Cargo.toml' -print0 \
    -not -path '*/.git/*' \
    -not -path '*/target/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    -not -path '*/out/*' \
    -not -path '*/.direnv/*' \
    -not -path '*/.venv/*' \
    -not -path '*/__pycache__/*'
)

mapfile -t DIR_LIST < <(printf '%s\n' "${!TOP_DIRS[@]}" | sort)

if [[ "${#DIR_LIST[@]}" -eq 0 ]]; then
  printf 'No Cargo.toml projects found under: %s\n' "$ROOT_DIR"
  exit 0
fi

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  printf '%s\n' "${DIR_LIST[@]}"
  exit 0
fi

# ------------------------------------------------------------------------------
# Run cargo clean
# ------------------------------------------------------------------------------
declare -a OK_DIRS=()
declare -a FAIL_DIRS=()

if [[ "$NO_LOG" -eq 0 ]]; then
  MAP_FILE="${LOG_DIR}/paths.tsv"
  : >"$MAP_FILE" || die "Failed to write: $MAP_FILE"
fi

total="${#DIR_LIST[@]}"
idx=0

for dir in "${DIR_LIST[@]}"; do
  idx=$((idx + 1))

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[%d/%d] Would clean: %s\n' "$idx" "$total" "$dir"
    OK_DIRS+=("$dir")
    continue
  fi

  if [[ ! -f "$dir/Cargo.toml" ]]; then
    # Should not happen (we derived dirs from Cargo.toml), but be defensive.
    printf '[%d/%d] SKIP (no Cargo.toml): %s\n' "$idx" "$total" "$dir"
    FAIL_DIRS+=("$dir")
    continue
  fi

  if [[ "$NO_LOG" -eq 1 ]]; then
    printf '[%d/%d] Cleaning: %s\n' "$idx" "$total" "$dir"
    if ( cd -- "$dir" && cargo clean ); then
      printf '[%d/%d] OK: %s\n' "$idx" "$total" "$dir"
      OK_DIRS+=("$dir")
    else
      printf '[%d/%d] FAIL: %s\n' "$idx" "$total" "$dir" >&2
      FAIL_DIRS+=("$dir")
    fi
    continue
  fi

  id="$(path_id "$dir")"
  log_file="${LOG_DIR}/${id}.log"
  printf '%s\t%s\n' "$id" "$dir" >>"$MAP_FILE" || die "Write failed: $MAP_FILE"

  printf '[%d/%d] Cleaning: %s\n' "$idx" "$total" "$dir"
  if ( cd -- "$dir" && cargo clean ) >"$log_file" 2>&1; then
    printf '[%d/%d] OK: %s\n' "$idx" "$total" "$dir"
    OK_DIRS+=("$dir")
  else
    printf '[%d/%d] FAIL: %s (see %s)\n' \
      "$idx" "$total" "$dir" "$log_file" >&2
    FAIL_DIRS+=("$dir")
  fi
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf '\n'
printf 'Detected Cargo directories: %d\n' "$total"
printf 'Succeeded:               %d\n' "${#OK_DIRS[@]}"
printf 'Failed:                  %d\n' "${#FAIL_DIRS[@]}"

printf '\nFolders cleaned successfully:\n'
for d in "${OK_DIRS[@]}"; do
  printf '  %s\n' "$d"
done

if [[ "${#FAIL_DIRS[@]}" -gt 0 ]]; then
  printf '\nFolders that failed:\n' >&2
  for d in "${FAIL_DIRS[@]}"; do
    printf '  %s\n' "$d" >&2
  done
fi
