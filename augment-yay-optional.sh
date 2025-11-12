#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# augment-yay-optional.sh — append missing optional deps to a yay install line
# ──────────────────────────────────────────────────────────────────────────────
# Criteria implemented:
#   1) Take every entry listed under “Optional dependencies for …” in the log
#   2) Exclude any that show status tags: “[installed]” or “[pending]”
#   3) Exclude any already present in the existing install command
#
# Output:
#   Prints an augmented 'yay -S --needed ...' command to stdout. Also prints a
#   report to stderr with counts and a preview of added packages.
#
# Notes:
#   • Robust to “name: description” lines — only the token before ':' is used.
#   • Ignores non-package bullets and blank lines.
#   • Detects the first line containing 'yay -S' (handles a leading 'gen_log').
#   • By default includes ALL optional deps (R and non-R). Use --only-r to
#     restrict to r-* packages.
#   • Pure Bash/AWK; no external JSON/YAML deps.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Default config
ONLY_R=0
LOG_FILE=""
CMD_FILE=""

# ──────────────────────────────────────────────────────────────────────────────
function pager_show() {
	# Minimal pager for help text; respects $HELP_PAGER; falls back to cat
	local pager="${HELP_PAGER:-}"
	if [[ -z "$pager" ]]; then
		if command -v less >/dev/null 2>&1; then
			pager="less -R"
		else
			pager="cat"
		fi
	fi
	eval "$pager"
}

# ──────────────────────────────────────────────────────────────────────────────
function show_help() {
	cat <<'HLP' | pager_show
# augment-yay-optional.sh — append missing optional deps to a yay install line

## Purpose
Parse an Arch install log and your current install script to produce an
augmented 'yay -S --needed ...' command that **adds only** those optional
dependencies which:
  • are shown in “Optional dependencies for …” sections of the log, and
  • are **not** marked “[installed]” or “[pending]”, and
  • are **not** already present in your current install command.

## Usage
  augment-yay-optional.sh --log <r-installs.log> --cmd <install-3.sh> [options]

## Options
  --log <file>       Path to the pacman/yay log you showed (e.g., r-installs.log)
  --cmd <file>       Script/file that contains your 'yay -S ...' line
  --only-r           Restrict additions to packages matching '^r-'
  --help, -h         This help

## Examples
  # Include all optional deps (R + non-R) that match the criteria:
  augment-yay-optional.sh --log ~/Documents/r-installs.log \
                          --cmd ~/Documents/install-3.sh

  # Restrict to r-* only:
  augment-yay-optional.sh --log ~/Documents/r-installs.log \
                          --cmd ~/Documents/install-3.sh --only-r

## Output
  • Prints the full augmented 'yay -S --needed ...' line to stdout
  • Writes a brief report to stderr (counts + first N added pkgs)

## Safety
  The original file is never modified. Redirect stdout to save the new command:
    augment-yay-optional.sh --log … --cmd … > ~/Documents/install-3-augmented.sh
HLP
}

# ──────────────────────────────────────────────────────────────────────────────
function die() {
	echo "error: $*" >&2
	exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--log)
			LOG_FILE="${2:-}"
			shift 2
			;;
		--cmd)
			CMD_FILE="${2:-}"
			shift 2
			;;
		--only-r)
			ONLY_R=1
			shift
			;;
		-h | --help)
			show_help
			exit 0
			;;
		*) die "unknown argument: $1" ;;
		esac
	done
	[[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || die "--log file missing"
	[[ -n "$CMD_FILE" && -f "$CMD_FILE" ]] || die "--cmd file missing"
}

# ──────────────────────────────────────────────────────────────────────────────
# Extract the first yay install line's package list from the command file.
#   • Handles a leading 'gen_log'
#   • Removes options like -S, --needed, etc.
#   • Outputs one package per line
function extract_cmd_packages() {
	awk '
    BEGIN { found=0 }
    # pick the first line containing "yay" followed later by "-S"
    found==0 && /(^|[[:space:]])yay([[:space:]].*)?-S([[:space:]]|$)/ {
      line=$0; found=1
      # strip a leading "gen_log"
      sub(/^[[:space:]]*gen_log[[:space:]]+/, "", line)
      # drop everything up to and including "-S"
      sub(/.*\byay[[:space:]]+/, "", line)
      sub(/^-S([[:space:]]|$)/, "", line)
      sub(/^(-[-[:alnum:]]+[[:space:]]+)*/, "", line) # if -S wasn’t first
      # remove known flags (extendable)
      gsub(/(^|[[:space:]])--needed($|[[:space:]])/, " ", line)
      gsub(/(^|[[:space:]])-[[:alnum:]]+($|[[:space:]])/, " ", line)
      # split by whitespace and print tokens that are not empty
      n=split(line, a, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (a[i]!="") print a[i]
    }
  ' "$CMD_FILE" | sed 's/[[:space:]]//g' | sed '/^$/d' |
		sort -u
}

# ──────────────────────────────────────────────────────────────────────────────
# From the log, collect optional-dependency names that have NO [installed] or
# [pending] tag. Output one name per line, unique and sorted.
#   • Extracts the token before a colon ':' if present
#   • Stops each Optional block when a blank line or a line starting with '(' appears
function extract_missing_optionals() {
	awk -v only_r="$ONLY_R" '
    function flush(){}

    BEGIN { inopt=0 }
    /^Optional dependencies for / { inopt=1; next }
    inopt && /^$/               { inopt=0; next }
    inopt && /^\(/              { inopt=0; next }
    inopt {
      # skip lines that *have* a status tag
      if ($0 ~ /\[installed\]|\[pending\]/) next
      # capture first token (letters, digits, . _ + - @ allowed)
      if (match($0, /^[[:space:]]*([A-Za-z0-9_.+@-]+)/, m)) {
        name=m[1]
        if (only_r=="1" && name !~ /^r-/) next
        print name
      }
      next
    }
  ' "$LOG_FILE" | sort -u
}

# ──────────────────────────────────────────────────────────────────────────────
# Set difference: A \ B  (each input: one item per line), both assumed unique
function set_diff() {
	comm -23 <(sort -u) <(sort -u)
}

# ──────────────────────────────────────────────────────────────────────────────
function main() {
	parse_args "$@"

	mapfile -t current_pkgs < <(extract_cmd_packages)
	mapfile -t candidate_pkgs < <(extract_missing_optionals)

	# Build sets in temp files for comm
	tmpA="$(mktemp)"
	tmpB="$(mktemp)"
	trap 'rm -f "$tmpA" "$tmpB"' EXIT
	printf '%s\n' "${candidate_pkgs[@]}" >"$tmpA"
	printf '%s\n' "${current_pkgs[@]}" >"$tmpB"

	# candidate \ current
	mapfile -t to_add < <(comm -23 <(sort -u "$tmpA") <(sort -u "$tmpB"))

	# Reconstruct the original prefix (yay -S line) from the cmd file
	# If not found, default to 'yay -S --needed'
	prefix="$(awk '
    found==0 && /(^|[[:space:]])yay([[:space:]].*)?-S([[:space:]]|$)/ {print; exit}
  ' "$CMD_FILE" || true)"
	if [[ -z "$prefix" ]]; then
		prefix="yay -S --needed"
	else
		# keep the portion up to and including flags; normalize to include --needed
		prefix="$(sed -E 's/^([[:space:]]*gen_log[[:space:]]+)?(.*\byay[[:space:]]+-S([^[:alnum:]].*)?).*$/\2/' \
			<<<"$prefix" | sed -E 's/[[:space:]]+$/ /')"
		[[ "$prefix" =~ --needed ]] || prefix="$prefix --needed"
	fi

	# Report
	echo "Current-packages: ${#current_pkgs[@]}" >&2
	echo "Optionals-candidate: ${#candidate_pkgs[@]}" >&2
	echo "To-add (after diff): ${#to_add[@]}" >&2
	printf 'Preview: %s\n' "$(printf '%s ' "${to_add[@]:0:20}")" >&2

	# Emit augmented command to stdout
	if ((${#to_add[@]} == 0)); then
		echo "$prefix" # nothing to add; still print normalized prefix
	else
		# Keep original packages and append the new (unique) ones at the end
		printf '%s ' "$prefix"
		printf '%s ' "${current_pkgs[@]}"
		printf '%s ' "${to_add[@]}"
		echo
	fi
}

main "$@"
