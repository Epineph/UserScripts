#!/usr/bin/env bash
#
# git_generate_clone_script.sh
#
# Generate a “clone-everything” script by inspecting existing local Git clones.
#
# USAGE:
#   git_generate_clone_script.sh [SOURCE_DIR] [OUTPUT_FILE]
#
# ARGS:
#   SOURCE_DIR   Directory to scan for Git repositories.
#                  Defaults to the current directory.
#   OUTPUT_FILE  Where to write the generated script.
#                  If omitted, writes to STDOUT.
#
# EXAMPLES:
#   # Print to terminal:
#   git_generate_clone_script.sh ~/repos
#
#   # Save to a file and make it executable:
#   git_generate_clone_script.sh ~/repos ~/clone_all.sh
#

set -euo pipefail

# --- 1. Parse and validate arguments ------------------------------

SRC_DIR="${1:-$(pwd)}"
OUT_FILE="${2:-/dev/stdout}"

if [[ ! -d "$SRC_DIR" ]]; then
	echo "Error: SOURCE_DIR '$SRC_DIR' is not a directory." >&2
	exit 1
fi

# --- 2. Gather repositories ---------------------------------------

# We'll build an array of lines: "<name> <origin-url>"
declare -a REPO_LIST=()

for dir in "$SRC_DIR"/*; do
	# Skip anything that's not a directory
	[[ -d "$dir" ]] || continue

	# Only consider if it contains a .git folder
	if [[ -d "$dir/.git" ]]; then
		name="$(basename -- "$dir")"

		# Ask Git for the 'origin' URL; skip if none
		if url="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
			REPO_LIST+=("$name $url")
		else
			echo "Warning: '$name' has no 'origin' remote; skipping." >&2
		fi
	fi
done

if ((${#REPO_LIST[@]} == 0)); then
	echo "No Git repositories found in '$SRC_DIR'." >&2
	exit 2
fi

# --- 3. Emit the clone script -------------------------------------

{
	echo "#!/usr/bin/env bash"
	echo "# Auto-generated clone script – $(date --iso=seconds)"
	echo "set -euo pipefail"
	echo
	echo "# List of repositories as: \"<dir-name> <remote-url>\""
	echo "repos=("
	for entry in "${REPO_LIST[@]}"; do
		# Quote each entry for safety
		echo "  \"$entry\""
	done
	echo ")"
	echo
	echo "# Where to clone:"
	echo "repo_dir=\"\${HOME}/repos\"  # modify as desired"
	echo "mkdir -p \"\$repo_dir\""
	echo
	echo "for repo in \"\${repos[@]}\"; do"
	echo "  name=\$(cut -d' ' -f1 <<< \"\$repo\")"
	echo "  url=\$(cut -d' ' -f2- <<< \"\$repo\")   # allow spaces in URL if any"
	echo "  dest=\"\$repo_dir/\$name\""
	echo
	echo "  if [[ ! -d \"\$dest/.git\" ]]; then"
	echo "    echo \"Cloning \$name from \$url…\""
	echo "    git clone --recurse-submodules \"\$url\" \"\$dest\""
	echo "  else"
	echo "    echo \"\$name already exists at \$dest; skipping.\""
	echo "  fi"
	echo "done"
} >|"$OUT_FILE"

# --- 4. Make it executable if it’s a real file --------------------

if [[ "$OUT_FILE" != "/dev/stdout" ]]; then
	chmod +x "$OUT_FILE"
	echo "✅ Clone script written to: $OUT_FILE"
fi
