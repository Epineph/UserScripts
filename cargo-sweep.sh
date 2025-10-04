#!/usr/bin/env bash
# cargo-sweep — Traverse and operate on multiple Rust repos consistently.
# Place in /usr/local/bin/cargo-sweep (chmod +x).

set -euo pipefail


# ────────────────────────────────────────────────────────────────────────────────
# Bat/cat wrapper (respects your preference; falls back to cat)
view_help() {
  if command -v bat > /dev/null 2>&1; then
    bat --style="grid,header,snip" --italic-text="always" \
      --theme="gruvbox-dark" --squeeze-blank --squeeze-limit="2" \
      --force-colorization --terminal-width="auto" --tabs="2" \
      --paging="never" --chop-long-lines
  else
    cat
  fi
}

print_help() {
  cat << 'EOF' | view_help
# cargo-sweep — Batch cargo operations across many repos

**Usage**
  cargo-sweep [OPTIONS]

**Core**
  -m, --mode MODE          One of: clean | build | check | clippy | fmt | test |
    doc
                           Default: build

**Cargo flags (forwarded appropriately)**
      --all-features       Build/check with all features
      --features STR       Comma/space separated list (e.g., "foo,bar")
      --bins               Build/check all bins
      --examples           Build/check all examples
      --release            Use release profile
  -j,  --jobs N            Parallel codegen units for cargo (e.g., -j 8)

**Traversal**
      --root DIR           Start directory (default: .)
      --max-depth N        Limit directory depth for search (default: unlimited)
      --exclude GLOB       Exclude matching paths (can be given multiple times)
      --only-workspaces    Only operate on workspace roots (Cargo.toml with [workspace])

**Git integration**
      --git-pull           Run: git pull --rebase --autostash before cargo

**Behavior**
      --dry-run            Print what would be done, don't execute
      --continue-on-error  Do not stop on first failure; report summary at end
      --fmt-write          In fmt mode: format in place (default is --check)
      --doc-no-deps        In doc mode: pass --no-deps
      --clippy-deny-warn   In clippy mode: add '-- -D warnings' (default: on)
      --no-clippy-deny     Disable '-D warnings' addition

**Other**
  -h,  --help              Show this help

**Examples**
  # Rebuild every crate with all features in release, 8 jobs:
  cargo-sweep --mode build --all-features --release -j 8

  # Clean everywhere:
  cargo-sweep --mode clean

  # Quick static checks without compiling codegen:
  cargo-sweep --mode check --all-features --bins -j 8

  # Lint strictly across repos:
  cargo-sweep --mode clippy --all-features --bins

  # Format check (no changes) across repos; to write use --fmt-write:
  cargo-sweep --mode fmt
  cargo-sweep --mode fmt --fmt-write

  # Generate docs without building dependencies:
  cargo-sweep --mode doc --doc-no-deps

**Notes**
- `fmt` mode defaults to `cargo fmt --all --check` to keep changes explicit.
- `clippy` adds `-- -D warnings` by default to surface actionable issues. Disable with --no-clippy-deny.
- `--bins` and `--examples` imply `--all-targets` where relevant (clippy).
- You can combine `--features`, `--all-features`, `--release`, `-j N` etc. as needed.
- If you previously removed ~/.cargo and ~/.rustup, cargo will re-fetch registries as needed.

EOF
}


# ────────────────────────────────────────────────────────────────────────────────
# Defaults
MODE="build"
ROOT="."
MAX_DEPTH=""
EXCLUDES=()
ONLY_WS="0"
DO_GIT_PULL="0"
DRY_RUN="0"
CONTINUE="0"
FMT_WRITE="0"
DOC_NO_DEPS="0"
CLIPPY_DENY="1" # default on

CARGO_COMMON=()
CARGO_TARGET_SEL=()


# ────────────────────────────────────────────────────────────────────────────────
# Parse args (supporting long options)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    -m | --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --max-depth)
      MAX_DEPTH="${2:-}"
      shift 2
      ;;
    --exclude)
      EXCLUDES+=("${2:-}")
      shift 2
      ;;
    --only-workspaces)
      ONLY_WS="1"
      shift
      ;;
    --git-pull)
      DO_GIT_PULL="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --continue-on-error)
      CONTINUE="1"
      shift
      ;;
    --fmt-write)
      FMT_WRITE="1"
      shift
      ;;
    --doc-no-deps)
      DOC_NO_DEPS="1"
      shift
      ;;
    --clippy-deny-warn)
      CLIPPY_DENY="1"
      shift
      ;;
    --no-clippy-deny)
      CLIPPY_DENY="0"
      shift
      ;;
    --all-features)
      CARGO_COMMON+=("--all-features")
      shift
      ;;
    --features)
      CARGO_COMMON+=("--features" "${2:-}")
      shift 2
      ;;
    --bins)
      CARGO_TARGET_SEL+=("--bins")
      shift
      ;;
    --examples)
      CARGO_TARGET_SEL+=("--examples")
      shift
      ;;
    --release)
      CARGO_COMMON+=("--release")
      shift
      ;;
    -j | --jobs)
      CARGO_COMMON+=("-j" "${2:-}")
      shift 2
      ;;

    # Allow transparent passthrough after --
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# Any residual args after '--' get passed to cargo subcommand (rare, but
# supported)
CARGO_TRAILING=("$@")

# Validate mode
case "$MODE" in
  clean | build | check | clippy | fmt | test | doc) ;;
  *)
    echo "Invalid --mode: $MODE" >&2
    exit 2
    ;;
esac


# ────────────────────────────────────────────────────────────────────────────────
# Helpers

is_workspace_root() {
  # Returns 0 if Cargo.toml contains [workspace]
  grep -q '^\s*\[workspace\]\s*$' Cargo.toml 2> /dev/null
}

should_skip_path() {
  local path="$1"
  for pat in "${EXCLUDES[@]:-}"; do
    if [[ "$path" == $pat ]]; then return 0; fi
  done
  return 1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY] %s\n' "$*"
  else
    eval "$@"
  fi
}

# Bold label for sections
section() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
submsg() { printf '    %s\n' "$*"; }


# ────────────────────────────────────────────────────────────────────────────────
# Build the find command
FIND_ARGS=("$ROOT" -type f -name Cargo.toml)
if [[ -n "$MAX_DEPTH" ]]; then
  FIND_ARGS=("$ROOT" -maxdepth "$MAX_DEPTH" -type f -name Cargo.toml)
fi

# Collect repos
mapfile -t CARGO_TOMLS < <(find "${FIND_ARGS[@]}" 2> /dev/null | sort)

if [[ "${#CARGO_TOMLS[@]}" -eq 0 ]]; then
  echo "No Cargo.toml found under: $ROOT" >&2
  exit 0
fi

# Filter workspace roots if requested
FILTERED=()
for file in "${CARGO_TOMLS[@]}"; do
  dir="$(dirname "$file")"
  # Exclusion check (on full path)
  if should_skip_path "$dir"; then
    continue
  fi
  if [[ "$ONLY_WS" == "1" ]]; then
    if (cd "$dir" && is_workspace_root); then
      FILTERED+=("$dir")
    fi
  else
    FILTERED+=("$dir")
  fi
done

# Deduplicate directories (just in case)
mapfile -t REPOS < <(printf '%s\n' "${FILTERED[@]}" | awk '!seen[$0]++')

if [[ "${#REPOS[@]}" -eq 0 ]]; then
  echo "No matching Rust repos after filters." >&2
  exit 0
fi


# ────────────────────────────────────────────────────────────────────────────────
# Mode-specific assembly

# Common flags can be reused in multiple modes:
COMMON_FLAGS=("${CARGO_COMMON[@]}" "${CARGO_TARGET_SEL[@]}")

# Construct command per mode
build_cargo_cmd() {
  local mode="$1"
  local cmd=()

  case "$mode" in
    clean)
      cmd=(cargo clean)
      ;;
    build)
      cmd=(cargo build "${COMMON_FLAGS[@]}" "${CARGO_TRAILING[@]:-}")
      ;;
    check)
      cmd=(cargo check "${COMMON_FLAGS[@]}" "${CARGO_TRAILING[@]:-}")
      ;;
    clippy)
      # Prefer strict linting to actually catch issues.
      local clippy_tail=()
      if [[ "$CLIPPY_DENY" == "1" ]]; then
        clippy_tail=(-- -D warnings)
      fi
      # --all-targets gives broader coverage when using --bins/--examples
      cmd=(cargo clippy --all-targets "${COMMON_FLAGS[@]}" "${CARGO_TRAILING[@]:-}" "${clippy_tail[@]}")
      ;;
    fmt)
      if [[ "$FMT_WRITE" == "1" ]]; then
        cmd=(cargo fmt --all)
      else
        cmd=(cargo fmt --all --check)
      fi
      ;;
    test)
      cmd=(cargo test "${COMMON_FLAGS[@]}" "${CARGO_TRAILING[@]:-}")
      ;;
    doc)
      local doc_flags=()
      if [[ "$DOC_NO_DEPS" == "1" ]]; then
        doc_flags+=(--no-deps)
      fi
      cmd=(cargo doc "${COMMON_FLAGS[@]}" "${doc_flags[@]}" "${CARGO_TRAILING[@]:-}")
      ;;
  esac

  printf '%q ' "${cmd[@]}"
}


# ────────────────────────────────────────────────────────────────────────────────
# Execution loop

section "cargo-sweep: mode=${MODE}, repos=${#REPOS[@]}"
FAILED=0
START_DIR="$(pwd)"

for repo in "${REPOS[@]}"; do
  section "Repo: $repo"
  cd "$repo"

  if [[ "$DO_GIT_PULL" == "1" && -d .git ]]; then
    submsg "git pull --rebase --autostash"
    run "git pull --rebase --autostash"
  fi

  # Workspace filtering (if user asked for only workspaces earlier, we already
  # filtered)
  if [[ "$ONLY_WS" == "1" && ! -f Cargo.toml ]]; then
    submsg "No Cargo.toml here; skipped (ONLY workspaces requested)"
    cd "$START_DIR"
    continue
  fi

  CARGO_CMD=$(build_cargo_cmd "$MODE")
  submsg "Running: $CARGO_CMD"
  if ! run "$CARGO_CMD"; then
    echo "ERROR in $repo" >&2
    FAILED=$((FAILED + 1))
    if [[ "$CONTINUE" != "1" ]]; then
      cd "$START_DIR"
      exit 1
    fi
  fi

  cd "$START_DIR"
done

section "Summary"
submsg "Processed: ${#REPOS[@]} repos"
submsg "Failures : ${FAILED}"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
