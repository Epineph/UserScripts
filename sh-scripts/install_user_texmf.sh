#!/usr/bin/env bash
# Install a LaTeX .sty file to the user's texmf tree
# Usage: ./install_user_texmf.sh /path/to/tikz-uml.sty

set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo -e "Usage: $0 <file.sty>\nE.g.,:\n"
	printf './%s ' "$(basename "$0")"

	echo "/usr/share/texmf-dist/tex/latex/tikz-uml/tikz-uml.sty"
	exit 1
fi

STYFILE="$1"
PKGNAME="$(basename "$STYFILE" .sty)"

# User-level texmf tree
TARGET_DIR="$HOME/texmf/tex/latex/$PKGNAME"

echo "Installing $STYFILE into $TARGET_DIR ..."
mkdir -p "$TARGET_DIR"
cp "$STYFILE" "$TARGET_DIR/"

echo "Done. User texmf overrides system tree automatically."
echo "Verify with: kpsewhich $(basename "$STYFILE")"
