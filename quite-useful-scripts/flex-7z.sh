#!/usr/bin/env bash
# flex-7z — flexible 7z archiver wrapper with multi-target support.
#
# Features:
#   - Multiple targets: files and/or directories, via -t and/or bare args
#   - Modes: include parent dir vs only children, files-only vs subdirs-only
#   - Optional password protection with header encryption (-mhe=on)
#   - Flexible output selection: directory or explicit file path
#   - Sensible defaults if -o / -n / -t are omitted
#
# Exit codes:
#   0  success
#   1  usage / input error
#   2  missing dependency
#   3  runtime failure (7z, filesystem, etc.)

set -Eeuo pipefail
IFS=$'\n\t '

VERSION="0.1.0"
SCRIPT_NAME="$(basename "$0")"

# ────────────────────────────── Globals ────────────────────────────────

VERBOSE=false
PASSWORD_PROTECT=false

# parent: add directory itself, 7z recurses
# children: add contents under directory (optionally filtered)
COMPRESS_MODE="parent" # parent | children
SELECTION="all"        # all | files | subdirs

OUTPUT=""       # -o / --output
ARCHIVE_NAME="" # -n / --name
ARCHIVE_PATH=""
ARCHIVE_PASSWORD=""

TARGETS=() # input paths (files/dirs)
TO_ADD=()  # normalized list passed to 7z

HELP_VIEWER_CMD=()

# ────────────────────────────── Helpers ────────────────────────────────

function log() {
	if "$VERBOSE"; then
		printf '%s\n' "$*" >&2
	fi
}

function die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

function choose_help_pager() {
	if [[ -n "${HELP_PAGER:-}" ]]; then
		# shellcheck disable=SC2206
		HELP_VIEWER_CMD=("$HELP_PAGER")
		return
	fi

	if command -v helpout >/dev/null 2>&1; then
		HELP_VIEWER_CMD=(helpout)
	elif command -v batwrap >/dev/null 2>&1; then
		HELP_VIEWER_CMD=(batwrap)
	elif command -v bat >/dev/null 2>&1; then
		HELP_VIEWER_CMD=(
			bat
			--style="grid,header,snip"
			--italic-text="always"
			--theme="gruvbox-dark"
			--squeeze-blank
			--squeeze-limit="2"
			--force-colorization
			--terminal-width="auto"
			--tabs="2"
			--paging="never"
			--chop-long-lines
		)
	elif command -v less >/dev/null 2>&1; then
		HELP_VIEWER_CMD=(less -R)
	else
		HELP_VIEWER_CMD=(cat)
	fi
}

function show_help() {
	choose_help_pager

	"${HELP_VIEWER_CMD[@]}" <<EOF
${SCRIPT_NAME} — flexible 7z archiver wrapper

Usage:
  ${SCRIPT_NAME} [options] [-t TARGETS...]

Targets:
  -t, --target PATHS     One or more targets (files or directories).
                         PATHS may contain commas and/or spaces. Example:
                           -t "\$HOME/Downloads,/shared, \$HOME/repos \$HOME/Videos"
                         You may repeat -t and also pass bare paths without -t.

If no targets are supplied, you will be asked whether to use the
current directory ("$(pwd)") as the single target.

Compression mode (directories):
  -c, --compress MODE    MODE in {parent,children} (default: parent)
      --include-parent   Alias for --compress parent
  -a, --all-contents,
      --all-children     Alias for --compress children
  -f, --files-only       When using children-mode, include only files
  -s, --sub-directories  When using children-mode, include only directories

Semantics:
  • Files are always added as-is.
  • Directories in parent-mode are added as a whole; 7z recurses inside.
  • Directories in children-mode are replaced by all contents beneath them.
    - With no -f/-s: all files and directories under each target dir.
    - With -f: only regular files under each target dir.
    - With -s: only directories under each target dir.
    (-f and -s together are allowed but redundant.)
  • Modes apply globally to all directory targets (per-target policy would
    turn this into a DSL; not implemented here on purpose).

Output:
  -o, --output PATH      Output archive path OR directory.
                         If PATH is a directory, -n/--name chooses the
                         filename inside it.
  -n, --name NAME        Archive filename (with or without .7z).
                         When -o is omitted, output is $(pwd)/NAME(.7z).

  If neither -o nor -n is given, a generic timestamped name is used in
  the current directory, derived from the first target.

Password protection:
  -P, --password-protect Enable password protection.
                         The script will prompt for the password twice
                         and use 7z header-encryption (-mhe=on) so the
                         file list is hidden.

  Security note: the password is passed to 7z via -pPASSWORD, which
  means it may briefly appear in process listings for local users.
  For stronger secrecy, you could adapt this script to let 7z prompt
  interactively instead, or wrap with gpg if you care enough.

Other options:
  -v, --verbose          Verbose logging about what is being added.
  -h, --help             Show this help.

Examples:

  1) Use current directory as single target (prompted automatically)
     flex-7z

  2) Compress parent directories for two targets
     flex-7z -t "$HOME/Downloads,/shared" -n backup.7z

  3) Compress only the contents (children) of one directory
     flex-7z -t "$HOME/Downloads" -c children -n dl-contents

  4) Compress only files under two directory targets (children-mode)
     flex-7z -f -c children -t "$HOME/Documents, $HOME/Notes" \
             -o "$HOME/archives" -n docs-files

  5) Password-protect an archive and hide its file list
     flex-7z -P -t "$HOME/private"

  6) Mix file and directory targets in one archive
     flex-7z -t "$HOME/Videos, $HOME/notes.txt, /shared/data"

  7) Output to a directory with a generated timestamped name
     flex-7z -t "$HOME/Projects" -o "$HOME/archives"

  8) Use an explicit output file path
     flex-7z -t "/data/experiments" -o "/data/backups/exp.7z"

  9) Multiple -t flags combined with bare paths
     flex-7z -t "$HOME/logs" -t "/etc,/opt" "$HOME/script.py"

  10) Subdirectories only (children-mode)
      flex-7z -c children -s -t "/srv/www"

  11) Files only (children-mode) with password protection
      flex-7z -P -c children -f -t "$HOME/secrets"

  12) Combine include-parent for some paths and bare targets
      flex-7z --include-parent -t "$HOME/Projects" "/var/backups"

  13) Full verbose mode for debugging
      flex-7z -v -t "$HOME/repos"

  14) Mixed whitespace and commas in -t argument
      flex-7z -t "$HOME/A,    $HOME/B   ,/srv/C   ,   /tmp/D"

  15) Archive the contents of the current directory without prompting
      flex-7z -c children -t "$(pwd)"


Version: ${VERSION}
EOF
}

# ────────────────────────────── Parsing ────────────────────────────────

function add_targets_from_arg() {
	local raw="$1"
	local word

	# Replace commas with spaces, then split on whitespace.
	raw="${raw//,/ }"
	for word in "${raw[@]}"; do
		[[ -z "$word" ]] && continue
		TARGETS+=("$word")
	done
}

function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			show_help
			exit 0
			;;
		-v | --verbose)
			VERBOSE=true
			;;
		-P | --password-protect)
			PASSWORD_PROTECT=true
			;;
		-t | --target | --targets)
			shift || die "Missing argument to $1"
			add_targets_from_arg "$1"
			;;
		-c | --compress)
			shift || die "Missing argument to $1"
			case "$1" in
			parent | include-parent)
				COMPRESS_MODE="parent"
				;;
			child | children | contents | all-children | all-contents)
				COMPRESS_MODE="children"
				;;
			*)
				die "Invalid compress mode '$1' (use parent|children)"
				;;
			esac
			;;
		-a | --all-contents | --all-children)
			COMPRESS_MODE="children"
			;;
		-i | --include-parent)
			COMPRESS_MODE="parent"
			;;
		-f | --files-only | --files-contents)
			SELECTION="files"
			;;
		-s | --sub-directories | --subdirs-only)
			SELECTION="subdirs"
			;;
		-o | --output)
			shift || die "Missing argument to $1"
			OUTPUT="$1"
			;;
		-n | --name)
			shift || die "Missing argument to $1"
			ARCHIVE_NAME="$1"
			;;
		--)
			shift
			while [[ $# -gt 0 ]]; do
				add_targets_from_arg "$1"
				shift
			done
			break
			;;
		-*)
			die "Unknown option '$1'"
			;;
		*)
			# bare path -> treated as targets as well
			add_targets_from_arg "$1"
			;;
		esac
		shift || true
	done
}

# ────────────────────────────── Core logic ─────────────────────────────

function ensure_7z() {
	if command -v 7z >/dev/null 2>&1; then
		return
	fi

	if command -v 7za >/dev/null 2>&1; then
		# Fallback alias if only 7za exists.
		alias 7z=7za
		return
	fi

	printf '7z/7za not found in PATH. Install p7zip first.\n' >&2
	exit 2
}

function prompt_for_default_target() {
	local and
	printf 'No targets given. Use current directory "%s" as target? [y/N]: ' \
		"$PWD" >&2
	read -r and || die "Failed to read answer from stdin"
	case "$and" in
	[Yy] | [Yy][Ee][Ss])
		TARGETS+=("$PWD")
		;;
	*)
		die "No targets specified; aborting."
		;;
	esac
}

function default_archive_name() {
	local ts first base
	ts="$(date +%Y%m%d_%H%M%S)"
	first="${TARGETS[0]}"
	base="${first##*/}"

	if [[ ${#TARGETS[@]} -gt 1 ]]; then
		printf '%s_and_%d_targets_%s' "$base" "${#TARGETS[@]}" "$ts"
	else
		printf '%s_%s' "$base" "$ts"
	fi
}

function resolve_archive_path() {
	local path name

	if [[ -n "$OUTPUT" ]]; then
		if [[ -d "$OUTPUT" ]]; then
			if [[ -z "$ARCHIVE_NAME" ]]; then
				ARCHIVE_NAME="$(default_archive_name)"
			fi
			name="$ARCHIVE_NAME"
			path="$OUTPUT/$name"
		else
			# Treat OUTPUT as file path
			path="$OUTPUT"
		fi
	else
		if [[ -z "$ARCHIVE_NAME" ]]; then
			ARCHIVE_NAME="$(default_archive_name)"
		fi
		name="$ARCHIVE_NAME"
		path="$PWD/$name"
	fi

	# Ensure .7z suffix
	if [[ "$path" != *.7z ]]; then
		path+=".7z"
	fi

	ARCHIVE_PATH="$path"
}

function maybe_overwrite_archive() {
	if [[ -e "$ARCHIVE_PATH" ]]; then
		local and
		printf 'Archive "%s" already exists. Overwrite? [y/N]: ' \
			"$ARCHIVE_PATH" >&2
		read -r and || die "Failed to read answer from stdin"
		case "$and" in
		[Yy] | [Yy][Ee][Ss])
			rm -f -- "$ARCHIVE_PATH" || die "Failed to remove existing archive"
			;;
		*)
			die "Refusing to overwrite existing archive."
			;;
		esac
	fi
}

function prompt_password_if_needed() {
	local p1 p2

	if ! "$PASSWORD_PROTECT"; then
		return
	fi

	while :; do
		printf 'Enter archive password: ' >&2
		read -rs p1 || die "Failed to read password"
		printf '\nConfirm archive password: ' >&2
		read -rs p2 || die "Failed to read password confirmation"
		printf '\n' >&2

		if [[ -z "$p1" ]]; then
			printf 'Password must not be empty. Try again.\n' >&2
			continue
		fi

		if [[ "$p1" != "$p2" ]]; then
			printf 'Passwords do not match. Try again.\n' >&2
			continue
		fi

		ARCHIVE_PASSWORD="$p1"
		break
	done
}

function build_to_add_for_target() {
	local t="$1"

	if [[ -f "$t" || -L "$t" ]]; then
		log "Adding file: $t"
		TO_ADD+=("$t")
		return
	fi

	if [[ -d "$t" ]]; then
		if [[ "$COMPRESS_MODE" == "parent" ]]; then
			log "Adding directory (with parent): $t"
			TO_ADD+=("$t")
		else
			log "Adding children of directory: $t (selection=$SELECTION)"
			case "$SELECTION" in
			all)
				while IFS= read -r path; do
					TO_ADD+=("$path")
				done < <(find "$t" -mindepth 1)
				;;
			files)
				while IFS= read -r path; do
					TO_ADD+=("$path")
				done < <(find "$t" -type f -mindepth 1)
				;;
			subdirs)
				while IFS= read -r path; do
					TO_ADD+=("$path")
				done < <(find "$t" -type d -mindepth 1)
				;;
			esac
		fi
		return
	fi

	die "Target '$t' does not exist or is not a regular file/directory"
}

function build_to_add_list() {
	local t

	if [[ ${#TARGETS[@]} -eq 0 ]]; then
		prompt_for_default_target
	fi

	for t in "${TARGETS[@]}"; do
		build_to_add_for_target "$t"
	done

	if [[ ${#TO_ADD[@]} -eq 0 ]]; then
		die "Nothing to add to the archive (check targets and filters)."
	fi
}

function run_7z() {
	local cmd=(7z a)

	if "$VERBOSE"; then
		cmd+=(-bb3)
	else
		cmd+=(-bb1)
	fi

	if "$PASSWORD_PROTECT"; then
		cmd+=(-p"$ARCHIVE_PASSWORD" -mhe=on)
	fi

	cmd+=("$ARCHIVE_PATH")
	cmd+=("${TO_ADD[@]}")

	log "Running: ${cmd[*]}"

	# shellcheck disable=SC2068
	"${cmd[@]}"
}

# ──────────────────────────────── Main ────────────────────────────────

function main() {
	parse_args "$@"

	ensure_7z
	build_to_add_list
	resolve_archive_path
	maybe_overwrite_archive
	prompt_password_if_needed

	log "Targets      : ${TARGETS[*]}"
	log "Archive path : $ARCHIVE_PATH"
	log "Mode         : $COMPRESS_MODE (selection=$SELECTION)"
	log "Password     : $([[ "$PASSWORD_PROTECT" == true ]] && echo 'yes' || echo 'no')"

	run_7z

	printf 'Created archive: %s\n' "$ARCHIVE_PATH"
}

main "$@"
