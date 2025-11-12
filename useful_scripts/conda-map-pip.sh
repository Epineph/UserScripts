#!/usr/bin/env bash
# conda-map-pip — Map pip package names to conda packages (by channel),
# and emit remainder that must be installed via pip.
#
# Requirements:
#   - One of: mamba (preferred) or micromamba with `repoquery`, or conda.
#   - jq (for JSON parsing).
#
# Outputs:
#   • Table: pip_name → conda_name @ channel (for matches)
#   • CONDA_PKGS="..."  (space-separated conda names)
#   • PIP_ONLY="..."    (space-separated pip-only names)
#   • Example install commands (micromamba & pip)

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
VERSION="0.5.0"

# ─────────────────────────────── Defaults ───────────────────────────────
declare -a CHANNELS=("conda-forge" "bioconda" "defaults")
CUSTOM_CHANNELS=false
PACKAGES_STR=""
INPUT_FILE=""
READ_STDIN=false
OVERRIDES_CSV=""   # "pip1:conda1,pip2:conda2"
QUIET=false

# ─────────────────────────────── Helpers ────────────────────────────────
usage() {
  cat <<'EOF'
conda-map-pip — map pip names to conda packages (by channel) and emit pip remainders.

USAGE:
  conda-map-pip [options] [PKG1 PKG2 ...]
OPTIONS:
  -c, --channel NAME       Add a conda channel to search (in priority order).
                           If provided at least once, overrides defaults.
  -p, --packages "LIST"    Space-separated pip package names as a single string.
  -f, --file PATH          Read package names from a file (whitespace/comment separated).
      --stdin              Read package names from STDIN (whitespace/comment separated).
      --override CSV       Explicit pip→conda mappings, e.g. "opencv-python:opencv,PyYAML:pyyaml"
  -q, --quiet              Suppress the summary table; only emit the two strings and commands.
  -h, --help               Show this help and exit.
  -V, --version            Print version and exit.

NOTES:
  • Uses: mamba|micromamba repoquery/search (JSON) with conda search as last fallback; requires jq.
  • Name matching tries exact, hyphen/underscore swaps, lowercasing, and a few special cases.
  • Channel priority follows the order specified with -c options (or defaults).

OUTPUT:
  1) Mapping table "pip_name → conda_name @ channel" (unless --quiet).
  2) CONDA_PKGS="..."   # all conda-installable names
  3) PIP_ONLY="..."     # remaining pip-only names
  4) Example micromamba and pip commands

EOF
}

log()  { printf '%s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

choose_query_tool() {
  if need_cmd mamba && mamba repoquery --help >/dev/null 2>&1; then echo "mamba"; return; fi
  if need_cmd micromamba && micromamba repoquery --help >/dev/null 2>&1; then echo "micromamba"; return; fi
  if need_cmd conda; then echo "conda"; return; fi
  echo ""
}

# Normalize whitespace & comments into tokens
tokenize_pkgs() {
  # reads stdin; emits one package per line (non-empty)
  sed -E 's/#.*$//g' | tr '\t\r\n' '   ' | xargs -n1 printf "%s\n" | sed '/^$/d'
}

# Deduplicate while preserving order
dedupe() { awk '!seen[$0]++'; }

# Split CSV overrides "a:b,c:d" into assoc array OVERRIDE_MAP[pip]=conda
declare -A OVERRIDE_MAP
load_overrides() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  IFS=',' read -r -a pairs <<<"$csv"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    if [[ "$pair" == *:* ]]; then
      local k="${pair%%:*}"
      local v="${pair#*:}"
      [[ -n "$k" && -n "$v" ]] && OVERRIDE_MAP["$k"]="$v"
    else
      log "WARN: ignoring malformed override '$pair' (expected pip:conda)"
    fi
  done
}

# Generate candidate conda names for a pip name
candidates_for() {
  local name="$1"
  local lower="${name,,}"
  local dash_to_us="${name//-/_}"
  local us_to_dash="${name//_/-}"
  local lower_dash_to_us="${lower//-/_}"
  local lower_us_to_dash="${lower//_/-}"

  printf '%s\n' \
    "$name" "$lower" \
    "$dash_to_us" "$us_to_dash" \
    "$lower_dash_to_us" "$lower_us_to_dash"

  case "$lower" in
    opencv-python) printf '%s\n' "opencv" ;;        # common rename
    pyyaml|pyyaml) printf '%s\n' "pyyaml" ;;
    sklearn)       printf '%s\n' "scikit-learn" ;;
    jupyterlab-server) printf '%s\n' "jupyterlab_server" ;;
    *) : ;;
  esac
}

# Query a single candidate on a single channel; echo conda_name on success
query_one() {
  local TOOL="$1" CHAN="$2" CAND="$3" out name

  if [[ "$TOOL" == "mamba" || "$TOOL" == "micromamba" ]]; then
    # 1) libmamba repoquery JSON (filter exact in jq)
    out=$(
      MAMBA_NO_BANNER=1 "$TOOL" repoquery search --json --channel "$CHAN" "$CAND" 2>/dev/null || true
    )
    name=$(jq -r --arg n "$CAND" '
      # try several possible shapes; keep only exact-name matches
      ( .result.pkgs // [] )
      | map( .name // .package.name // .base.name // empty )
      | map(select(. == $n))
      | unique[]
    ' <<<"$out" 2>/dev/null | head -n1)
    if [[ -n "$name" ]]; then echo "$name"; return 0; fi

    # 2) mamba/micromamba search JSON (slower but broadly compatible)
    out=$("$TOOL" search -c "$CHAN" --json "^${CAND}\$" 2>/dev/null || true)
    name=$(jq -r '
      # conda/mamba search formats vary; try keys that carry .name fields
      ( .result.pkgs // .result[""] // .packages // [] )
      | map( .name // .package.name // .base.name // empty )
      | unique[]
    ' <<<"$out" 2>/dev/null | head -n1)
    if [[ -n "$name" ]]; then echo "$name"; return 0; fi
  fi

  # 3) ultimate fallback: conda search JSON (regex-anchored)
  if need_cmd conda; then
    conda search --json -c "$CHAN" "^${CAND}\$" 2>/dev/null \
      | jq -r 'to_entries[]?.value? // .[]? | .[]? | .name? // empty' \
      | sort -u | head -n1 || true
  fi
}

# Resolve pip_name → (channel, conda_name) or empty
resolve_pkg() {
  local TOOL="$1"; shift
  local -a CHANS=("$@")
  local pip_name="$1"; shift || true

  # explicit override wins
  if [[ -n "${OVERRIDE_MAP[$pip_name]:-}" ]]; then
    printf '%s\t%s\n' "override" "${OVERRIDE_MAP[$pip_name]}"
    return 0
  fi

  local cand conda_name chan
  mapfile -t cand_list < <(candidates_for "$pip_name" | dedupe)

  for chan in "${CHANS[@]}"; do
    for cand in "${cand_list[@]}"; do
      [[ -z "$cand" ]] && continue
      conda_name="$(query_one "$TOOL" "$chan" "$cand")"
      if [[ -n "$conda_name" ]]; then
        printf '%s\t%s\n' "$chan" "$conda_name"
        return 0
      fi
    done
  done
  return 1
}

# ─────────────────────────────── Parse args ──────────────────────────────
if [[ $# -eq 0 ]]; then usage; exit 1; fi

declare -a POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--channel)
      [[ -n "${2:-}" ]] || die "Missing argument for $1"
      if ! $CUSTOM_CHANNELS; then CHANNELS=(); CUSTOM_CHANNELS=true; fi
      CHANNELS+=("$2"); shift 2 ;;
    -p|--packages) PACKAGES_STR="${2:-}"; shift 2 ;;
    -f|--file)     INPUT_FILE="${2:-}"; shift 2 ;;
    --stdin)       READ_STDIN=true; shift ;;
    --override)    OVERRIDES_CSV="${2:-}"; shift 2 ;;
    -q|--quiet)    QUIET=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    -V|--version)  printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1 (see --help)" ;;
    *)  POSITIONAL+=("$1"); shift ;;
  esac
done
# Remaining args after -- are positional packages too
if [[ $# -gt 0 ]]; then POSITIONAL+=("$@"); fi

# Dependencies
need_cmd jq || die "Missing dependency: jq"
QUERY_TOOL="$(choose_query_tool)"
[[ -n "$QUERY_TOOL" ]] || { log "TIP: install 'mamba' or 'micromamba' for best results."; die "No query tool available (need mamba|micromamba|conda)."; }

# ───────────── Build package list from sources (no subshell loss) ───────
declare -a INPUT_PKGS=()
mapfile -t INPUT_PKGS < <(
  {
    # 1) positional
    for p in "${POSITIONAL[@]:-}"; do printf '%s\n' "$p"; done

    # 2) string (tokenized later)
    if [[ -n "$PACKAGES_STR" ]]; then printf '%s\n' "$PACKAGES_STR"; fi

    # 3) file
    if [[ -n "$INPUT_FILE" ]]; then
      [[ -r "$INPUT_FILE" ]] || die "Cannot read file: $INPUT_FILE"
      tokenize_pkgs < "$INPUT_FILE"
    fi

    # 4) stdin
    if $READ_STDIN; then
      if [ -t 0 ]; then die "--stdin specified but no data on stdin."; fi
      tokenize_pkgs
    fi
  } | tokenize_pkgs | dedupe
)
[[ ${#INPUT_PKGS[@]} -gt 0 ]] || die "No packages provided."

# Apply overrides
load_overrides "$OVERRIDES_CSV"

# ───────────────────────────── Resolution loop ───────────────────────────
declare -A MAPPED_CHAN    # pip -> channel
declare -A MAPPED_CONDA   # pip -> conda-name
declare -a CONDA_LIST=()
declare -a PIP_ONLY_LIST=()

for pip_name in "${INPUT_PKGS[@]}"; do
  if out="$(resolve_pkg "$QUERY_TOOL" "${CHANNELS[@]}" "$pip_name")"; then
    chan="$(cut -f1 <<<"$out")"
    conda_name="$(cut -f2- <<<"$out")"
    if [[ "$chan" == "override" ]]; then chan="${CHANNELS[0]}"; fi
    MAPPED_CHAN["$pip_name"]="$chan"
    MAPPED_CONDA["$pip_name"]="$conda_name"
    CONDA_LIST+=("$conda_name")
  else
    PIP_ONLY_LIST+=("$pip_name")
  fi
done

# Deduplicate final lists
mapfile -t CONDA_LIST < <(printf '%s\n' "${CONDA_LIST[@]}" | dedupe)
mapfile -t PIP_ONLY_LIST < <(printf '%s\n' "${PIP_ONLY_LIST[@]}" | dedupe)

# ─────────────────────────────── Output ──────────────────────────────────
if ! $QUIET; then
  printf '\nResolved conda packages (by channel):\n'
  printf '  %-35s → %-30s @ %s\n' "pip_name" "conda_name" "channel"
  printf '  %s\n' "-------------------------------------------------------------------------"
  for pip_name in "${INPUT_PKGS[@]}"; do
    if [[ -n "${MAPPED_CONDA[$pip_name]:-}" ]]; then
      printf '  %-35s → %-30s @ %s\n' "$pip_name" "${MAPPED_CONDA[$pip_name]}" "${MAPPED_CHAN[$pip_name]}"
    fi
  done
  printf '\nUnresolved (pip-only):\n  '
  # join with spaces regardless of global IFS
  (IFS=' '; printf '%s\n' "${PIP_ONLY_LIST[*]:-(none)}")
fi

# Shell-friendly strings (space-joined)
(IFS=' '; printf '\nCONDA_PKGS="%s"\n' "${CONDA_LIST[*]:-}")
(IFS=' '; printf 'PIP_ONLY="%s"\n' "${PIP_ONLY_LIST[*]:-}")

# Ready-to-run commands (safely quoted)
printf '\n# Example install commands:\n'
printf 'micromamba install -y'
for ch in "${CHANNELS[@]}"; do printf ' -c %q' "$ch"; done
for name in "${CONDA_LIST[@]}"; do printf ' %q' "$name"; done
printf '\n'
if [[ ${#PIP_ONLY_LIST[@]} -gt 0 ]]; then
  printf 'python -m pip install --upgrade'
  for name in "${PIP_ONLY_LIST[@]}"; do printf ' %q' "$name"; done
  printf '\n'
fi
