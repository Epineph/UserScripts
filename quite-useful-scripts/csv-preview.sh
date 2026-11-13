#!/usr/bin/env bash
# csv-show — Display CSV either as a pretty table (mlr+bat) or raw bytes (cat-like).
#
# Requirements:
#   - Pretty table mode: miller (mlr). bat is optional (falls back to plain mlr output).
#   - Raw mode: no dependencies beyond coreutils.
#
# Usage:
#   csv-show [-t table|csv] [INPUT.csv|-]
#
# Options:
#   -t, --target {table|csv}  Presentation target (default: table)
#   -h, --help                Show help and exit
#
# Behavior:
#   • table:   mlr --icsv --opprint cat INPUT | bat (if present) | else plain mlr output
#   • csv:     exact raw bytes (like `cat INPUT` or pass-through from stdin)
#
# Environment:
#   BAT_CSV_ARGS  Optional. Extra flags for `bat` in table mode.
#                 Default: --style="grid,header,snip" --italic-text="always" --theme="gruvbox-dark" \
#                          --squeeze-blank --squeeze-limit="2" --force-colorization --terminal-width="-1" \
#                          --tabs="2" --paging="never" --chop-long-lines
#
# Examples:
#   csv-show -t table ~/path/to/data.csv
#   csv-show -t csv   ~/path/to/data.csv
#   mlr --icsv filter '$age>70' data.csv | csv-show -t table -
#   mlr --icsv filter '$age>70' data.csv | csv-show -t csv   -   # raw pass-through
#
# Exit codes:
#   0 success, 1 usage/input error, 2 missing dependency for requested mode, 3 processing failure
set -Eeuo pipefail
IFS=$'\n\t'

have() { command -v "$1" >/dev/null 2>&1; }
die() {
	printf '%s\n' "$*" >&2
	exit 1
}

print_help() { sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET="table" # {table|csv}
INPUT=""

# Default bat args (can be overridden via BAT_CSV_ARGS)
BAT_CSV_ARGS_DEFAULT='--style="grid,header,snip" --italic-text="always" --theme="gruvbox-dark" --squeeze-blank --squeeze-limit="2" --force-colorization --terminal-width="-1" --tabs="2" --paging="never" --chop-long-lines'
BAT_CSV_ARGS="${BAT_CSV_ARGS:-$BAT_CSV_ARGS_DEFAULT}"

# ---- parse args --------------------------------------------------------------
ARGS=()
while (($#)); do
	case "$1" in
	-t | --target)
		TARGET="${2:-}"
		shift 2
		case "$TARGET" in table | csv) ;; *) die "Invalid --target: use 'table' or 'csv'" ;; esac
		;;
	-h | --help)
		print_help
		exit 0
		;;
	--)
		shift
		break
		;;
	-*) die "Unknown option: $1" ;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done

if ((${#ARGS[@]})); then
	INPUT="${ARGS[0]}"
else
	# No positional: use stdin if provided; else error.
	if [ ! -t 0 ]; then
		INPUT="-"
	else
		die "No INPUT provided. Pass a file path or '-' for stdin. See --help."
	fi
fi

# Validate input when it's a path
if [[ "$INPUT" != "-" && ! -r "$INPUT" ]]; then
	die "Cannot read input file: $INPUT"
fi

# ---- dispatch ---------------------------------------------------------------
case "$TARGET" in
table)
	have mlr || {
		echo "Missing dependency: miller (mlr) required for table mode." >&2
		exit 2
	}
	if have bat; then
		# shellcheck disable=SC2086  # intentional splitting of $BAT_CSV_ARGS
		if ! mlr --icsv --opprint cat "$INPUT" | eval "bat $BAT_CSV_ARGS"; then
			exit 3
		fi
	else
		# No bat: still show aligned table via mlr
		mlr --icsv --opprint cat "$INPUT" || exit 3
	fi
	;;
csv)
	# Exact bytes like cat; if INPUT='-', just pass-through
	if [[ "$INPUT" == "-" ]]; then
		cat || exit 3
	else
		cat -- "$INPUT" || exit 3
	fi
	;;
esac
