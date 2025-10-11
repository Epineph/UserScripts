#!/usr/bin/env bash
# shellcheck shell=bash
# ──────────────────────────────────────────────────────────────────────────────
# reinstall-native-pkgs.sh — Reinstall all native (repo) packages via pacman
# ──────────────────────────────────────────────────────────────────────────────
# Default behavior: dry-run. Prints the chunked pacman command to STDOUT.
# Opt-in execution with --run. AUR/foreign packages are excluded by definition.
# Supports exclusions, explicit-only, chunk sizing, and writing artifacts.
# Width target ≈81 cols; 2-space indents; functions with `function` keyword.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ------------------------------- Defaults ------------------------------------
DRY_RUN=1
EXPLICIT_ONLY=0
OUT_DIR=""
NO_CONFIRM=0
CHUNK=200
LOG_PATH=""
EXCLUDES=()   # user-supplied names to exclude (comma/space separated accepted)

# Your preferred bat options; fall back chain: helpout | batwrap | bat | cat.
BAT_OPTS=(
  --style="grid,header,snip" --italic-text="always" --theme="gruvbox-dark"
  --squeeze-blank --squeeze-limit="2" --force-colorization
  --terminal-width="auto" --tabs="2" --paging="never" --chop-long-lines
)

# ------------------------------- Helpers -------------------------------------
function have() { command -v "$1" >/dev/null 2>&1; }

function pager() {
  if have helpout; then helpout; return; fi
  if have batwrap; then batwrap; return; fi
  if have bat; then bat "${BAT_OPTS[@]}"; return; fi
  cat
}

function show_help() {
  cat <<'EOF' | pager
# `reinstall-native-pkgs.sh` — Reinstall all native (repo) packages

**Synopsis**
- `reinstall-native-pkgs.sh [options]`
- Defaults to *dry-run*: prints the exact chunked pacman command(s).

**Description**
Reinstalls every package that `pacman` considers *native* (present in any
configured sync repository, including non-official binary repos like Chaotic).
AUR/foreign/local packages (`pacman -Qm`) are *excluded* by design.

To actually execute the reinstall, pass `--run`. To write artifacts (a package
list and a runnable reinstall script), use `-o/--output`.

**Options**
- `-h, --help`            Show this help (rendered for terminals).
- `-n, --dry-run`         Print commands only (default).
- `-r, --run`             Execute the reinstall (disables dry-run).
- `-e, --explicit-only`   Limit to explicitly installed native packages only
                          (uses \`pacman -Qqen\` instead of \`-Qnq\`).
- `-x, --exclude <list>`  Exclude packages by name; accept comma/space list.
                          Examples: \`-x "linux, linux-headers"\`
                                    \`-x linux linux-headers\`
- `-o, --output [DIR]`    Write \`packages-native.txt\` and
                          \`reinstall-native.sh\`. If DIR omitted, use \$PWD.
- `--no-confirm`          Add \`--noconfirm\` to pacman.
- `--chunk <N>`           Max packages per pacman invocation (default: 200).
- `--log <PATH>`          Log pacman output to PATH (append mode).

**What gets reinstalled**
- *Native* packages: \`pacman -Qnq\` (or explicit-only: \`pacman -Qqen\`).
- Foreign/AUR: skipped (they require an AUR helper; not handled here).

**Notes**
- Reinstalling can produce \`*.pacnew\` files. Reconcile them afterwards
  (\`pacdiff\` from \`pacman-contrib\` can help).
- Use \`--exclude\` to skip sensitive kernels or drivers if you prefer staged
  testing (e.g., \`-x "linux, nvidia-dkms"\`).

EOF
}

function die() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

function parse_args() {
  local arg
  while (($#)); do
    arg="$1"; shift
    case "$arg" in
      -h|--help) show_help; exit 0 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -r|--run) DRY_RUN=0 ;;
      -e|--explicit-only) EXPLICIT_ONLY=1 ;;
      -x|--exclude)
        (($#)) || die "--exclude requires a value"
        EXCLUDES+=("$1"); shift ;;
      -o|--output)
        if (($#)) && [[ ! "$1" =~ ^- ]]; then OUT_DIR="$1"; shift
        else OUT_DIR="$PWD"; fi ;;
      --no-confirm) NO_CONFIRM=1 ;;
      --chunk)
        (($#)) || die "--chunk requires an integer"
        CHUNK="$1"; shift ;;
      --log)
        (($#)) || die "--log requires a path"
        LOG_PATH="$1"; shift ;;
      *) die "Unknown option: $arg" ;;
    esac
  done
}

function normalize_excludes() {
  # Accept comma and/or space separated values across all -x occurrences.
  local raw="${EXCLUDES[*]-}"
  raw="${raw//,/ }"
  read -r -a EXCLUDES <<<"$raw"
}

function collect_packages() {
  if ((EXPLICIT_ONLY)); then
    mapfile -t PKGS < <(pacman -Qqen | sort -u)
  else
    mapfile -t PKGS < <(pacman -Qnq | sort -u)
  fi
  ((${#PKGS[@]})) || die "No native packages found."
}

function apply_excludes() {
  ((${#EXCLUDES[@]})) || return 0
  local -A skip=()
  for p in "${EXCLUDES[@]}"; do [[ -n "$p" ]] && skip["$p"]=1; done
  local keep=()
  for p in "${PKGS[@]}"; do
    [[ -n "${skip[$p]-}" ]] || keep+=("$p")
  done
  PKGS=("${keep[@]}")
  ((${#PKGS[@]})) || die "All packages excluded; nothing to do."
}

function write_artifacts() {
  [[ -z "$OUT_DIR" ]] && return 0
  mkdir -p "$OUT_DIR"
  local list="$OUT_DIR/packages-native.txt"
  local sh="$OUT_DIR/reinstall-native.sh"
  printf '%s\n' "${PKGS[@]}" >"$list"

  cat >"$sh" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
# Reinstall native packages listed alongside this script (chunked via xargs).
LIST_FILE="$(dirname "$0")/packages-native.txt"
CHUNK="${CHUNK:-200}"
NO_CONFIRM="${NO_CONFIRM:-0}"
LOG_PATH="${LOG_PATH:-}"
PAC_FLAGS=()
((NO_CONFIRM)) && PAC_FLAGS+=(--noconfirm)
if [[ -n "$LOG_PATH" ]]; then
  exec > >(tee -a "$LOG_PATH") 2>&1
fi
# shellcheck disable=SC2046
xargs -r -n "$CHUNK" sudo pacman -S "${PAC_FLAGS[@]}" -- <"$LIST_FILE"
EOSH
  chmod +x "$sh"

  printf '[INFO] Wrote package list: %s (%d pkgs)\n' "$list" "${#PKGS[@]}" >&2
  printf '[INFO] Wrote reinstall script: %s\n' "$sh" >&2
  printf '[INFO] To run with no-confirm: NO_CONFIRM=1 %q\n' "$sh" >&2
  printf '[INFO] To change chunk size:   CHUNK=300 %q\n' "$sh" >&2
  if [[ -n "$LOG_PATH" ]]; then
    printf '[INFO] To enable logging:     LOG_PATH=%q %q\n' "$LOG_PATH" "$sh" >&2
  fi
}

function print_or_run() {
  local -a PAC_FLAGS=()
  ((NO_CONFIRM)) && PAC_FLAGS+=(--noconfirm)
  local logredir=""
  if [[ -n "$LOG_PATH" ]]; then
    logredir=" | tee -a $(printf '%q' "$LOG_PATH")"
  fi

  # Print exact command(s) users can redirect or inspect.
  printf '# Packages to reinstall: %d\n' "${#PKGS[@]}"
  printf '# Example (chunk=%d):\n' "$CHUNK"
  printf 'printf "%%s\\n" \\\n'
  for p in "${PKGS[@]}"; do
    printf '  %q \\\n' "$p"
  done
  printf '  | xargs -r -n %d sudo pacman -S' "$CHUNK"
  for f in "${PAC_FLAGS[@]}"; do printf ' %q' "$f"; done
  printf ' --%s\n' "$logredir"

  ((DRY_RUN)) && return 0

  # Execute now (chunked to avoid argv length issues).
  if [[ -n "$LOG_PATH" ]]; then
    # Append both stdout/stderr to log while mirroring to terminal.
    exec > >(tee -a "$LOG_PATH") 2>&1
  fi
  printf '[INFO] Starting reinstall in chunks of %d…\n' "$CHUNK" >&2
  printf '%s\n' "${PKGS[@]}" | xargs -r -n "$CHUNK" \
    sudo pacman -S "${PAC_FLAGS[@]}" --
}

# --------------------------------- Main --------------------------------------
function main() {
  parse_args "$@"
  normalize_excludes
  collect_packages
  apply_excludes
  write_artifacts
  print_or_run
}
main "$@"

